# `Enzyme.API.strictAliasing!(false)` — what it costs, and what it would take to stop needing it

Investigation of the claim in the header of `src/tree_walk/oop.jl` (lines ~55-72) that
CPU reverse-mode AD over the `:oop` RHS requires the process-global
`Enzyme.API.strictAliasing!(false)`, and that the durable fix is a payload-free IR.

Measured 2026-08-12 against **Enzyme v0.13.199** (`Enzyme_jll` v0.0.290), Julia 1.12,
`EarthSciAST` at `origin/main` (`43bbf986`). (0.13.199 is what a fresh resolve picks
today; 0.13.190 is also in the depot and was **not** separately tested.) Everything
below is reproduced by the scripts in this directory; none of it is inferred from the
note.

Run them in a minimal environment that `Pkg.develop`s this package plus
`JSON3, ForwardDiff, Test, Enzyme` — **not** `Pkg.test()`. One process per mode:
the flag is a process-global consumed at Enzyme *compile* time and Enzyme caches
compiled adjoints, so toggling it mid-process does not give a clean answer.

```
julia --project=<env> repro_oop.jl      strict|relaxed
julia --project=<env> repro_iip.jl      strict|relaxed [nocodegen]
julia --project=<env> micro_variants.jl any|anyunused|barrier|inactive|union|concrete [relaxed]
```

---

## 1. Does the claim still hold? Yes — and it is broader than the note says

`repro_oop.jl strict`, on both a 0-D 2-state model and a 1-D reaction-diffusion model
at N=16, fails identically:

```
Enzyme.Compiler.IllegalTypeAnalysisException
  Failure within method: _oop_eval(::_Node, ::Vector{Float64}, ::@NamedTuple{...},
                                  ::Float64, ::Vector{Float64}, ::_OopForcing{...})
  @ src/tree_walk/oop.jl:822
  Caused by: getproperty @ Base_compiler.jl:54
             _oop_eval @ src/tree_walk/oop.jl:846
```

(Full log: `measurements/oop-strict.txt`.) Line 846 is
`convert(T, (n.payload::Base.RefValue{Int})[])` — the `_NK_LOOPVAR` arm. So the
mechanism the note describes is real and current: a load out of the `Any` variant slot
is what type analysis chokes on.

Three corrections to the note, all measured:

**(a) The struct it names no longer exists.** The note is written against `_VecNode`
(`payload::Any` + `fnargs::Vector{Any}` + `altbuf::RefValue{Any}`). That struct was
deleted; the array IR is now `_AccKernel` + the concretely-typed tagged `_AccDesc`
(`src/tree_walk/access_kernel.jl`), and `_AccScratch.alt::Any` is the only `Any`
left there. The blocker today is the **scalar** `_Node.payload::Any`
(`src/tree_walk/compile.jl:75`), serving 12 node kinds
(`_NK_LITERAL` … `_NK_STATE_GATHER`).

**(b) It is not an `:oop` problem.** `repro_iip.jl strict nocodegen` shows the default
in-place `f!` fails the same way, at `_eval_node` (`src/tree_walk/compile.jl:1704`,
the same `_NK_LOOPVAR` payload load), reached from the scalar CSE-prelude /
`rhs_list` tier of the `f!` closure. `f!` additionally needs
`Enzyme.set_runtime_activity(Reverse)` to get that far — without it you get an
`EnzymeRuntimeActivityError` on the captured `Vector{Tuple{Int,_Node}}` first. The
wart belongs to the shared `_Node` IR, not to either emitter.

**(c) The runtime tree does not have to contain the offending kind.** The 0-D model
has no loop-var node, no gather and no `fn` node at all, and still fails on the
`_NK_LOOPVAR` arm. Enzyme type-analyzes the whole *statically reachable* method,
so an arm that this model can never execute still poisons the walk. This is the
single most important structural fact here, and it is what makes "handle the
payload more carefully at runtime" a non-strategy.

### What the flag buys, and what it now costs

Not measured to completion. `repro_oop.jl relaxed` on the trivial 0-D model
(2 states, one shared subexpression) **did not finish an Enzyme compile in 50
minutes** on a contended shared box, and a second run was still compiling at the
point this note was written. The note's "reverse mode then produces gradients
matching ForwardDiff to ~1e-16" was presumably measured against an older Enzyme;
we could not confirm it at 0.13.199. Treat "the flag makes it work" as unverified
at current versions — *see the open item at the bottom.*

The micro harness (below) does confirm the flag's *effect*: `micro_variants.jl any`
fails with the identical exception and `micro_variants.jl any relaxed` returns a
gradient exactly equal to ForwardDiff's, in seconds. So the flag does what it says;
it is the size of the real walker that is the problem.

---

## 2. What does `strictAliasing!(false)` cost? Not correctness — per Enzyme's own source

Short answer: **it is a wart, not a hazard.** It makes Enzyme's type analysis
*decline to learn* facts; it does not make it assert unproven ones. The flag that
can produce wrong derivatives is a different one (`looseTypeAnalysis!`).

Evidence, in descending order of authority:

1. **The C++.** `EnzymeStrictAliasing` is declared at
   `enzyme/Enzyme/TypeAnalysis/TypeAnalysis.cpp:94-96`
   (`cl::init(true)`, "Assume strict aliasing of types / type stability") and is read
   in **that file only** — verified by code search over the whole repo at tag
   `v0.0.290`, which is the `Enzyme_jll` this depot ships. It appears at 7 sites; at 5
   of them, turning it off *skips* an update or an upward propagation:
   - `:1177-1206` / `:1209-1223` — `updateAnalysis` skips entirely when the origin
     block does not post-dominate the target.
   - `:2331` (`visitPHINode`) and `:2713` (`visitSelectInst`) — under `direction & UP`,
     skip propagating type info into the operands of a phi/select unless the node is
     degenerate. This is exactly the "propagate type information up through
     conditional branches" the Julia docstring names.
   - `:512` — a SCEV known-value set becomes a superset (more conservative).

   Every gated propagation is `direction & UP` (backward, use → operand); forward
   propagation is untouched. The one site where OFF enables an *extra* deduction,
   `:2122-2131`, marks GEP indices `Integer` for non-`inbounds` GEPs, and only when
   the base operand **and** the GEP result are already proven `Pointer` — a guard the
   in-source comment above it describes as firmer than the `inbounds` path it stands
   in for.

   Pinned upstream regression: `enzyme/test/TypeAnalysis/strictalphi.ll` runs with
   `-enzyme-strict-aliasing=0` and CHECKs that a fact learned at a load is *not*
   pushed up through the phi. Fewer facts on operands — locked into a test.

2. **The contrast with `looseTypeAnalysis`** (`Enzyme/src/api.jl:1271`, "may produce
   incorrect results") is not rhetorical: it is read in the *derivative generator*
   (`AdjointGenerator.h`, `EnzymeLogic.cpp`, `DiffeGradientUtils.cpp`), where e.g.
   `AdjointGenerator.h:1411-1424` substitutes an unproven float type and emits a
   derivative from it. `EnzymeStrictAliasing` appears in none of those files. One
   restricts inference; the other fabricates conclusions from failed inference.

3. **No issue-tracker evidence of wrong gradients.** GitHub search for
   `strictAliasing` in `EnzymeAD/Enzyme.jl` returns 33 hits, all
   `IllegalTypeAnalysis` / cannot-deduce reports; `"strictAliasing" "incorrect"`
   returns zero. Enzyme.jl *recommends* the flag in its own error text
   (`Enzyme/src/errors.jl:719-720`) with no correctness caveat, and its own test
   suite (`test/basic.jl:436-445`) uses it while asserting an exact derivative value.
   Rust's Enzyme frontend ships with strict aliasing **off by default**
   (EnzymeAD/Enzyme#2885, PR #2887); wsmoses declined to change the shared default
   on reproducibility grounds, explicitly not on correctness grounds.

4. **The one real caveat, and it is not introduced by the flag.** Losing a fact
   usually fails loud (`EmitNoTypeError` → Enzyme.jl's `EnzymeNoTypeError`, whose
   text is literally "Enzyme cannot statically prove the type of a value being
   differentiated and risks a correctness error if it gets it wrong"). But at loads
   and stores it does not: `AdjointGenerator.h:420` and `:988` in v0.0.290 read
   `if (looseTypeAnalysis || true)` — the guess is **unconditional**, independent of
   either flag — and fall back to `defaultTypeTreeForLLVM`, guessing structurally
   from the LLVM type. A wrong guess there (an `i64` load of what is really float
   data) drops a derivative contribution. Two mitigations: it emits a
   `CannotDeduceType` warning, and it is already the behaviour with strict aliasing
   **on**. So the flag can make that pre-existing hazard *more reachable*; it does not
   create it.

   That warning goes to LLVM's diagnostic stream via `EmitWarning`, not through
   Enzyme.jl's typed-exception path (there is no `ET_` code for it in the `ErrorType`
   enum, `src/api.jl:1360-1374`), so it is easy to miss. **If we keep the flag, we
   should grep stderr for `CannotDeduceType` in whatever harness sets it.**

5. **It is process-global with no scoped alternative.** `strictAliasing!` writes an
   LLVM `cl::opt` inside `libEnzyme` (`src/api.jl:1289-1292`): one variable per
   process, all threads, all subsequent compilations, no locking. There is no
   `autodiff` keyword, no `ScopedValue`, nothing on `EnzymeCompilerParams`, nothing in
   `EnzymeCore`. Upstream's only added configurability is build-time (CMake, PR #2886).
   The practical cost of the global is therefore *blast radius*: if any other package
   in the same process relies on strict aliasing to type-analyze through a branch, it
   loses that too — and it loses it loudly (a cannot-deduce error), which is the
   good failure mode, but it is still someone else's build breaking because of us.

**Verdict for (2): a wart.** Keep it if it is cheap to keep. The decision-relevant
risk is not wrong numbers; it is (i) the process-global blast radius and (ii) the
compile-time behaviour in §1.

---

## 3. Is there a cheaper intermediate? Partly — and the note's "I tried that" is too strong

`micro_variants.jl` is a 200-line standalone tree walker with the same shape as
`_oop_eval` (a `kind::UInt8` branch ladder over a struct with a variant slot,
recursing through `children::Vector{Node}`). It reproduces the production failure
exactly — same exception, same `getproperty` cause — in about 30 seconds, which makes
it a usable design instrument. Results, all at Enzyme 0.13.199, default flag:

| variant | node representation | Enzyme reverse |
|---|---|---|
| `any` | `payload::Any`, loaded by the walk | **FAIL** `IllegalTypeAnalysisException` |
| `union` | `payload::Union{Nothing,Vector{Float64},RefValue{Int}}` | **FAIL**, identical |
| `anyunused` | `payload::Any` present in the struct, **never loaded** | **OK**, exact match to ForwardDiff |
| `barrier` | `payload::Any`, arms behind `@noinline` helpers | **OK**, exact match |
| `inactive` | `payload::Any`, arms behind `EnzymeRules.inactive` fns | **OK**, exact match |
| `concrete` | no payload field; side tables indexed by `idx` | **OK**, exact match |

(Full log: `measurements/micro-variants.txt`, which also records `any relaxed` — the
same walker under the flag, returning a gradient exactly equal to ForwardDiff's.)

Three things follow.

**A small closed `Union` does not help.** Answered, cheaply, before anyone spends a
week on it. Enzyme's message names unions specifically, and a union of heap types is
still a boxed pointer field at the LLVM level.

**The note's "routing around the `Any` payload does NOT help — I tried that" does not
hold as stated.** `anyunused` — the field is still on the struct, the tree still
stores non-`nothing` in it, but no *load* appears in the differentiated method —
passes. It is the **load**, not the field's presence, that Enzyme rejects. What is
true, and is probably what was actually hit, is that you cannot route around the loads
*one at a time*: they are everywhere, and the failure just moves.

That is worth being concrete about, because it is the size estimate for the cheap
option. Walking the real `:oop` path with `@noinline` barriers, each fix exposed the
next blocker, in this order:

1. `_oop_eval` `_NK_PARAM_GATHER` arm (`n.payload::Vector{Float64}`) → barrier fixes it
2. `_oop_state_gather`'s `n.payload::_StateGather`, inlined into `_oop_eval` → barrier fixes it
3. `_oop_fn` → `_eval_closed_fn(pl[1], Any[...], T)` — **a barrier does not fix this**
4. `_oop_eval_batch` (`_OopBatchNode`, its own `payload::Any`) — the whole ladder again

Blocker 3 is qualitatively different and is the real limit of the cheap option: the
boxed closed-function path builds a genuine `Vector{Any}` of *active* values and hands
it to a `String`-dispatched registry. No barrier can hide that — the values in it carry
derivative. And it is statically reachable from every model, including models with no
`fn` node. Nobody in the Enzyme corpus reports getting a `Vector{Any}` in the active
dataflow to work; the advice is uniformly "make it type stable".

**`EnzymeRules.inactive` is the supported form of the barrier, and it is the one to
use if we go this way.** `@noinline` working at all appears to be luck: Enzyme's type
analysis is an LLVM pass that recurses through call sites regardless of Julia-level
inlining, and it stops only at callees carrying `enzyme_ta_norecur`. `EnzymeRules.inactive`
sets exactly that attribute (`Enzyme/src/compiler.jl`, five sites around 920-1045 in
v0.13.199) *and* keeps the call from being inlined away (the `inactive_rules` machinery
in `src/compiler/interpreter.jl`), which is why it is robust where `@noinline` is
incidental. Two independent reports confirm it fixing this exact exception
(SciML/SciMLSensitivity.jl#1524, EpiAware/CensoredDistributions.jl#701).

Its soundness condition must be respected: `inactive` asserts the return value carries
**no derivative**. That is true of a live-forcing-buffer read, a loop counter, a slot
table, a const-gather offset — the structural/data reads. It is **not** true of an
interp table lookup, whose value is a function of an active query. Marking the wrong
one inactive silently zeroes a gradient path rather than erroring, which is a worse
failure than the one we are fixing. So this option must be applied per-arm with an
argument for each, not blanket.

### Size estimate for the cheap option

~10-20 `EnzymeRules.inactive` declarations plus arm extraction across the three
walkers (`_oop_eval` / `_oop_eval_batch` in `oop.jl`, `_eval_node` in `compile.jl`,
`_eval_acc` in `access_kernel.jl`), **plus** a restructure of `_oop_fn`/`_eval_closed_fn`
to drop the `Vector{Any}`. Call it 2-4 days. It does not remove the flag on its own
unless blocker 3 is also solved, and it adds a permanent, invisible correctness
obligation (every `inactive` is an unchecked assertion). **Recommendation: do not do
this** unless CPU reverse mode becomes load-bearing. It buys removing a wart at the
cost of a hazard, which is the wrong trade given §2.

---

## 4. Scoping the payload-free lowering

### The convergence claim is real, and better than the note knew: half of it is already built

`src/tree_walk/codegen_kernel.jl` (1,213 lines) already does, for the array/kernel tier
of `f!`, exactly what the note proposes: at `build_evaluator` time each `_AccKernel` is
**emitted as Julia source** — the per-box loop nest with the spine as a straight-line
expression, literal strides and offsets baked in, direct indexing — and fused into one
function compiled via RuntimeGeneratedFunctions. It is bit-exactness-contracted against
the interpreter, eltype-generic (derives `T = _rhs_value_type(u,p,t)` the same way), has
a per-kernel decline/fallback protocol and a kill switch (`ESS_CODEGEN_DISABLE=1`).
Emitted code contains no payload loads.

So the design question is not "what would a lowering look like" but "extend the
lowering that exists to the tiers it does not yet cover". Those are:

- **The scalar tier of `f!`**: the CSE prelude (three cadence tiers) and `rhs_list`,
  both still walked by the `_eval_node` interpreter. This is what the 0-D model hits.
- **The `:oop` emitter entirely**: `_oop_eval`, `_oop_eval_batch`, the oop acc walkers.
  `oop.jl` (2,678 lines) + `oop_merge.jl` (1,077) are interpreters end to end.
- **The boxed closed-function path**, in both, which no lowering fixes by itself —
  it needs a typed calling convention (a tuple, or a per-name generated dispatch)
  rather than `Vector{Any}` + `String`.

### But: RuntimeGeneratedFunctions and Enzyme do not currently mix

Measured, and this is load-bearing for the plan. On the RD model with the codegen tier
**enabled**, `repro_iip.jl strict` fails with an Enzyme *internal* error:

```
UndefVarError: `codegen_ft` not defined in `Enzyme.Compiler`
```

With `ESS_CODEGEN_DISABLE=1` the same case gives the ordinary
`IllegalTypeAnalysisException` instead, and the 0-D model (which emits no kernels, so
no RGF) gives `IllegalTypeAnalysisException` either way. That 2x2 isolates the RGF as
the trigger. This matches the general concern that RGFs produce runtime-generated code,
which cuts against Enzyme's need for static IR — though `UndefVarError` on an internal
name is an Enzyme bug worth reporting upstream regardless.

**Consequence: "lower to Julia source via RGF" is the right shape for XLA/Reactant and
for `f!` speed, but it is not on its own a route to Enzyme support.** The convergence
the note claims is real for the *representation* (a concretely-typed, payload-free
node tree with the variant resolved at build time) and real for the device backend. It
is not yet real for Enzyme, because the delivery vehicle the codebase already chose for
that representation is one Enzyme currently trips over. Anyone budgeting this work
should not assume Enzyme falls out for free.

### What the representation should be

Given 12 `_Node` kinds and ~120 `.payload` sites across 10 files, the shape the
evidence points at is what DynamicExpressions.jl converged on after ~2 years of the
same fight (SymbolicML/DynamicExpressions.jl#52, driven by
EnzymeAD/Enzyme.jl#548/#552/#810): keep the tagged struct, but make every variant
resolution **static** — a `@generated`/`Base.Cartesian.@nif` switch over the kind tag,
with the payload for each kind in a side table whose element type is concrete
(`Vector{Vector{Float64}}` for forcing gathers, `Vector{_StateGather}` for state
gathers, …), indexed by the node's existing `idx`. That is the `concrete` micro variant,
which passes. The operator set has to move into the type as well (their `OperatorEnum`
went from `Vector{Function}` to tuples), which for us is the `op::Symbol` ladder.

Two warnings from that project, both still open: `@nif` over a large kind set blows up
compile time (their #1156 is unresolved — 6 operators plus one level of fusion hit a
`StackOverflowError`), and it is a whole-evaluator change, not a local one.

### Size estimate

- Side-table representation + build-time lowering pass after `_compile`: **~1,500-2,500
  lines touched**, concentrated in `compile.jl`, `oop.jl`, `oop_merge.jl`,
  `access_kernel.jl`, `acc_merge.jl`, with follow-on edits in the other 12 files that
  name `_Node`.
- The bit-exactness contract makes this tractable but not cheap: `:oop` is the oracle
  the in-place tests use, so both sides move at once and the differential test is the
  safety net. Expect the oracle property itself to need care during the transition.
- The `Vector{Any}` closed-function calling convention is a separable, smaller piece
  (~200-400 lines) and is a prerequisite for *any* Enzyme story, cheap or expensive.
- Honest total: **3-6 weeks**, and it does not deliver Enzyme support without
  additionally resolving the RGF interaction.

Given that the CPU reverse path is not on the critical path (gradients go through
Reactant/XLA, which needs no flag), the ordering that maximises value per unit risk is:

1. Keep the flag. Add the `CannotDeduceType` stderr check wherever it is set, and a
   comment pointing at this note. **(hours)**
2. Fix the boxed closed-function calling convention. Wanted by the lowering, by
   Enzyme, and by the tracer independently. **(days)**
3. Do the payload-free lowering when the device backend asks for it, not when Enzyme
   does — and re-test Enzyme afterwards rather than promising it. **(weeks)**

---

## 5. What we could not determine

- **Whether the flag still makes `:oop` reverse mode actually work at 0.13.199.**
  Two runs did not complete an Enzyme compile of the trivial 0-D model (50 min and
  counting) on a heavily contended shared box. The failure without the flag is
  reproduced in under a minute; the success *with* it is not reproduced at all here.
  This should be re-run on an idle machine before anyone relies on the note's
  "~1e-16 agreement" claim.
- **Whether the `UndefVarError: codegen_ft` is specific to this RGF usage** or a
  general Enzyme 0.13.199 bug. The 2x2 above isolates the RGF as the trigger in our
  case; we did not minimise it to a standalone reproducer or check it against
  0.13.190.
- **Whether `EnzymeRules.inactive` scales to the real walkers.** It is verified in the
  micro harness only. The real walkers were probed with `@noinline`, which reached the
  `Vector{Any}` wall at blocker 3; `inactive` would hit the same wall, so the question
  is moot until that is fixed.
- **The size estimates in §4 are structural, not empirical.** They come from counting
  call sites and files, not from a spike. Treat them as an order of magnitude.
