# Upstream issues we are waiting on

Six issues filed 2026-08-24 against Reactant.jl and Enzyme-JAX, all found while
compiling the ReSEACT atmospheric chemistry model through the Reactant backend.

> **What has changed here since.** These were measured against the TRACED
> emitter — the tree walk run with `TracedRNumber` in place of `Float64` — which
> has been retired in favour of direct StableHLO emission from the compiled IR
> (`ext/reactant_direct/`, `direct_rhs`). The direct emitter constructs
> `stablehlo.*` operations itself rather than going through Julia's broadcast
> tracing, so #3215 and #3216 no longer describe a cost this repository pays:
> the notes below are the record of why they were filed, not a statement about
> the backend as it stands. #2938, #3217, #3218 and #2939 are about the compile
> pipeline and autodiff, and are unaffected by which emitter feeds them.

Every candidate was re-verified against current versions before filing rather
than filed from the older write-ups. That mattered — two of the most serious
candidates turned out to be **already fixed upstream** and were not filed (see
[Not filed](#not-filed) below).

**Environment all of these were measured on:** Julia 1.12.6 x86_64-linux-gnu ·
Reactant 0.2.280 · Reactant_jll 0.0.405+0 · Enzyme 0.13.199 · EnzymeCore 0.8.21 ·
Enzyme_jll 0.0.290+0 · CPU (PJRT).

| # | Issue | Repo | Status |
|---|---|---|---|
| 1 | [`concat_broadcast_slice` merges concatenate operands along the wrong axis](https://github.com/EnzymeAD/Enzyme-JAX/issues/2938) | Enzyme-JAX #2938 | open |
| 2 | [`Ops.constant(::Number)` is not memoized while `Ops.constant(::DenseArray)` is](https://github.com/EnzymeAD/Reactant.jl/issues/3215) | Reactant.jl #3215 | open |
| 3 | [`broadcast_to_size` emits `broadcast_in_dim` for already-matching shapes](https://github.com/EnzymeAD/Reactant.jl/issues/3216) | Reactant.jl #3216 | open |
| 4 | [Batched forward mode fails to lower, by either available route](https://github.com/EnzymeAD/Reactant.jl/issues/3217) | Reactant.jl #3217 | open |
| 5 | [Segfault instead of a diagnostic when `CreateReverseDiff` fails](https://github.com/EnzymeAD/Reactant.jl/issues/3218) | Reactant.jl #3218 | open |
| 6 | [Missing autodiff rules for `stablehlo.case`, in either direction](https://github.com/EnzymeAD/Enzyme-JAX/issues/2939) | Enzyme-JAX #2939 | open |

Two notes on #3218. It is the one candidate that was **not** re-run on 0.2.280 —
it needs a ~600 s model build per probe and was last observed on Reactant 0.2.274
/ Reactant_jll 0.0.395+1 / Enzyme 0.13.190. And the defect is in Enzyme's
`CoreDialectsAutoDiffImplementations.cpp`, so it may get moved to EnzymeAD/Enzyme.
The requested fix — a null check on `revFn` before `revFn.getOperation()` — is
worth making whether or not the underlying failure still reproduces.

Reproducers live in the ReSEACT model repository under `tools/diag/`:
`rof_concat_repro.jl` (#2938), `reactant_emission_repro.jl` (#3215 and #3216),
`rof_batchfwd.jl` (#3217), `rof_repro.jl` / `rof_sweep.sh` / `rof_results.tsv`
(the #3218 bisection), `mwe_case_reverse.jl` (#2939). Full prior write-up:
`tools/diag/UPSTREAM_reverse_over_forward.md`.

## What each one unblocks

### #2938 — `concat_broadcast_slice` miscompile

**Today:** any build that forms this shape must pass
`excluded_passes=["concat_broadcast_slice"]`. Because the input program contains
no `concatenate` at all — `vcat` lowers to `dynamic_update_slice`, and the
pipeline itself forms the concatenate via `dynamic_update_to_concat` — there is
no way to avoid it by writing the emitter differently.

**Unblocks:** dropping that workaround, and more importantly *emitting
concatenates at all without fear*. Here it failed the verifier loudly, but the
same merge is a silent wrong-shape miscompile whenever the shapes happen to
agree. Two pieces of planned work emit exactly this shape and are gated on it:

- the **lattice-gather replacement** — merged access-descriptor slot vectors are
  affine lattices (`oop_merge.jl` concatenates each member's `out .+ delta`), and
  ~2/3 of the s64 index-constant bytes could be replaced by *k* strided slices and
  one `concatenate` instead of a `stablehlo.gather` over a dense index constant;
- `Reactant.Compiler.CONCATS_TO_DUS[] = true`, which rewrites in the opposite
  direction and therefore changes which concatenates survive to this pattern.

### #3215 — scalar constants not memoized

**Superseded here.** The traced emitter's value-numbering seam (`ess-oop-gvn`)
existed partly to work around this: two uses of the same scalar got different SSA
values, so structural CSE above them could not see `k .* x` and `k .* x` as the
same expression, and the sharing had to be recovered by our own memo. The direct
emitter interns constants in its own emission context and never calls
`Ops.constant(::Number)`, so the defect no longer reaches a module this
repository emits. Filed because it is real upstream, and because any consumer
that does trace Julia code pays it.

### #3216 — broadcast scaffolding

**Superseded here.** One elementwise `a .+ b` on two identically-shaped operands
traces to eleven `stablehlo` ops (5 transpose, 4 broadcast_in_dim, 1 constant, 1
add). The direct emitter builds the one `stablehlo.add` itself, so the
scaffolding is not in the module it hands XLA. Filed for the same reason as
#3215: the defect is upstream and real for anyone tracing Julia code.

### #3217 — batched forward mode

**This is the one that unblocks a design choice rather than an optimisation.**

**Today:** a coloured Jacobian built from N serial forward derivatives does not
share one differentiated callee — each colour carries roughly its own copy of the
RHS. Measured on ReSEACT: **120.1 MB against 34.8 MB** for the same program with
a finite-difference Jacobian, a 3.5x module and a 6.1x trace time. Both documented
routes to a batched form fail to lower, so the only available shape is the one
that multiplies the nested-derivative count.

**Unblocks:** an AD-based Jacobian at a module size that is actually affordable,
which is currently the reason the symbolic block Jacobian
(`rx_sym_block_jac.jl`) and finite differences are carrying that role. It also
reduces what an *outer* derivative has to cross, which is the reverse-over-forward
adjoint path.

### #3218 — segfault instead of a diagnostic

**Today:** a reverse-over-forward compile dies with SIGSEGV, no MLIR diagnostic,
and a Julia `try`/`catch` cannot see it. The failing callee cannot be identified
from outside the compiler: the information exists only in the process that dies,
and the shipped `libReactantExtra.so` is stripped.

**Unblocks:** diagnosis, not performance. With `emitError()` in place the report
would have named the failing op in one run instead of a bisection that never
reproduced it on a toy. This is the difference between "reverse-over-forward is
mysteriously broken on large modules" and a specific, fixable callee.

### #2939 — no autodiff rule for `stablehlo.case`

**Today:** `Reactant.Ops.case` inside differentiated code is a hard compile
failure in both directions — reverse with `could not compute the adjoint for this
operation`, forward with `RegionBranchOpInterface not implemented`. It fails at
compile time rather than returning a silently wrong gradient, which is the good
kind of broken.

**Unblocks:** the least of the six, for us specifically, and worth saying so.
Two constructs in the same script already do this exactly, at relative error 0:

| Construct | Emits | Reverse mode |
|---|---|---|
| `@trace if` (2-arm) | `stablehlo.if` | exact, rel err 0 |
| `@trace if` (3-arm) | 2x `stablehlo.if` | exact, rel err 0 |
| `ifelse` | `stablehlo.select` | exact, rel err 0 |
| `Ops.case` | `stablehlo.case` | **fails** |

So there is a working route today and nothing is blocked outright. What a fix
buys is spelling an n-way branch as ONE dispatch instead of n-1 nested two-arm
`stablehlo.if`s — which matters if a multi-way branch ever lands on a hot lane
axis, and not otherwise. The narrowness of the gap is also the argument for it
being tractable to implement; precedent is Enzyme-JAX #1579 (`stablehlo.sort`),
closed once a concrete case arrived.

Related correction: our own `HELPERS.md` used to say "keep `@trace if` out of
differentiated code". That is wrong — `@trace if` emits `stablehlo.if`, never
`stablehlo.case` (`grep -c Ops.case src/ControlFlow.jl` is 0 across
0.2.274-0.2.280), and it differentiates exactly. Only an explicit
`Reactant.Ops.case` reaches the broken op.

## What these do NOT unblock

Worth stating plainly so nobody waits on the wrong thing. The dominant costs
measured in the ReSEACT adjoint workstream are **not** caused by any of these:

- The ROS23 step is **bandwidth-bound**. It performs ~1,005 M element-ops of
  which only 4.1% is physics arithmetic; ~72% is traffic on >=500k-element
  buffers, dominated by whole-buffer `concatenate` rewrites of the flat extended
  observed buffer. That was an emitter-shape problem in *our* code, not an
  upstream bug: the traced emitter composed the extended state as one flat
  buffer. The direct emitter has no such buffer — a materialized observed's fill
  result is a slot map — which is the structural answer to it.
- **Build cost** was ~90% geometry setup, addressed by the compile-once and
  rank-specialisation fixes in `src/tree_walk/geometry_setup.jl`.
- **Compile cost** is sublinear in grid and driven by constant bytes, of which
  ~2/3 are affine-lattice gather indices we materialise ourselves.

#3215 and #3216 shrink the module handed to XLA, so they help trace and compile
time. Neither changes execution time. Only #3217 changes an architectural option.

## Worth reporting, not yet filed

### `x / c` is rewritten to `x * fl(1/c)` on f64, and `floor` can then read one short

**What happens.** The StableHLO pipeline's algebraic simplifier turns a division
by a floating-point constant into a multiplication by its reciprocal, on `f64`,
with no fast-math flag asked for. The optimized module for `floor.(x ./ 3600000.0)`
is, in full:

```mlir
%cst = stablehlo.constant dense<2.7777777777777776E-7> : tensor<5xf64>
%0 = stablehlo.multiply %arg0, %cst : tensor<5xf64>
%1 = stablehlo.floor %0 : tensor<5xf64>
```

A reciprocal is a second rounding. `fl(1/3600000)` is below the true reciprocal,
so `3600000.0 * fl(1/3600000)` is `0.9999999999999999` and the `floor` of it is
`0` where the host's `floor(3600000.0 / 3600000.0)` is `1`. Measured on Reactant
0.2.285 / CPU (PJRT), Julia 1.12.6:

```julia
using Reactant
f(x) = floor.(x ./ 3600000.0)
x = Reactant.ConcreteRArray([3600000.0, 7200000.0, 25200000.0, 21600000.0, 46800000.0])
Array((Reactant.@compile sync=true f(x))(x))   # [0.0, 1.0, 6.0, 6.0, 13.0]
floor.(Array(x) ./ 3600000.0)                  # [1.0, 2.0, 7.0, 6.0, 13.0]
```

The same thing happens for `c = 146097`. It is not every constant — `86400000`,
`60000`, `1000`, `365`, `153` are all exact — which is what makes it hard to
notice: most operands give the right answer and the ones on an exact multiple of
`c` do not.

**Why it is worth reporting.** `floor(a / b)` on exact integers is the standard
spelling of floored integer division in a float-only IR, and it is EXACT under a
correctly rounded divide (IEEE 754 §5.4), which is what makes the idiom safe to
write. The rewrite silently withdraws that guarantee, and the failures land
exactly on the round numbers a test is most likely to use and a model is most
likely to care about — midnight, the top of the hour, the start of a 400-year
era. A simplifier that only applied the rewrite when `1/c` is exactly
representable (a power of two) would keep the optimization where it is free and
drop it where it is not.

**Where it bit us.** The closed `datetime.*` calendar
(`src/registered_functions.jl`) decomposes `t_utc` with `floor(a/b)`, and both
unsafe constants are divisors in it: `3600000` ms per hour and `146097` days per
400-year era. Compiled through either backend, `datetime.hour` returned the
previous hour at exactly the top of every hour. The host path was never wrong,
so nothing in the interpreter's exhaustive `Dates` oracle
(`test/datetime_arithmetic_test.jl`) could see it.

**Our workaround.** `_cdiv` recovers the floor from the remainder rather than
trusting the quotient: `r = a - q*b` is exact for exact-integer operands, and two
selects repair any quotient that is within one unit of the truth. Branch-free,
value-identical on the host, and independent of which constants a given
simplifier decides are safe. See the note above `_cdiv` in
`src/registered_functions.jl`, and the tier-level reading in
`tests/conformance/compiled_rhs/README.md` (§"Readings taken", item 8), which is
where the next binding to lower a calendar will look.

### `call_llvm_generator` recurses once per level of a recursive traced callee

**What happens.** Reactant's interpreter rewrites every type-unstable call
inside a traced body into its generated `call_with_reactant`, and the generator
(`Reactant/src/utils.jl`, `call_llvm_generator`) runs a full nested GPUCompiler
inference to produce the replacement code. When the traced callee is itself
recursive, that nesting follows the recursion: one generator invocation per
level, each holding a GPUCompiler job open on the stack while the next one
starts. The backtrace is a clean repeating cycle —

```
call_llvm_generator                     (Reactant/src/utils.jl)
  GPUCompiler.emit_llvm -> irgen -> compile_method_instance
    ci_cache_populate -> typeinf -> ... -> abstract_call_method
      typeinf_edge -> retrieve_code_info -> get_staged -> jl_call_staged
        call_llvm_generator                 (next level)
```

— repeated until the process either wedges inside `typeinf` with no error and no
progress, or prints `detected a stack overflow` and dies with `SIGSEGV`.

**Why it is worth reporting even though we worked around it.** The failure is
intermittent (the depth reached depends on what inference has already cached),
it is silent in the wedge case, and it gets *worse* with a larger stack, which
sends the first person who meets it in exactly the wrong direction. A recursive
host-side function in a traced body is not an exotic thing to write.

**Reproducer step.** `EarthSciASTReactantExt`'s compiled backend
(`ext/reactant_direct/`) is a recursive walk over a tree IR whose node payload is
`Any`. Compile any fixture through it with the `@skip_rewrite_func` marks in
`ext/reactant_direct/device.jl` removed — a small stencil model is enough — and
the compile wedges or crashes on a fair fraction of runs at the default stack,
and on nearly all of them at `ulimit -s 131072`.

**Our workaround, which is also the documented answer.**
`Reactant.@skip_rewrite_func` on the walk's entry function. A skipped call is
left alone in the rewritten body and runs natively, and nothing reachable from
it is rewritten either, so one mark covers the whole recursion. It is only safe
because the walk needs no `@reactant_overlay` method: it builds `stablehlo.*`
operations directly on the traced values' `mlir_data` and otherwise reads host
data. The two places under it that do want Reactant's own semantics re-enter by
name with `Reactant.call_with_reactant`.

**What an upstream fix might look like** (for whoever files it): a depth counter
in `call_llvm_generator` that raises a diagnostic naming the recursive callee
instead of letting the nesting run to the guard, and a note in the
`@skip_rewrite_func` docstring that a recursive traced callee is the case it
exists for. Either would have turned several days of bisection into one error
message.

### `enzyme-hlo-opt`'s `cse_slice` is quadratic in the slice count

**What happens.** `enzyme-hlo-opt` runs a greedy rewrite driver, and one of its
patterns, `cse_slice`, deduplicates `stablehlo.slice` operations by comparing
them PAIRWISE through `mlir::OperationEquivalence::isEquivalentTo`. On a module
carrying a few thousand slices that is invisible. On one carrying tens of
thousands it is the whole compile, and it grows with the square.

Where it shows up for us is the run of `enzyme-hlo-opt` over the module
`enzyme` has just DIFFERENTIATED, because reverse mode multiplies the slice
population: the reverse of a slice is a pad-and-add, so a primal with ~10,000
slices differentiates into ~24,000 to ~28,000 slices plus ~9,000 pads. Measured
on a four-stage SSPRK43 transport step at 288 cells, Reactant 0.2.285 / CPU:

| | primal, before `enzyme` | adjoint, after `enzyme` |
| --- | ---: | ---: |
| `stablehlo.slice` | 9,932 | 27,610 |
| `stablehlo.pad` | — | 9,583 |
| `enzyme-hlo-opt` wall | 4.5 s | > 37 min, never finished |

`perf record -F 199 -g`, 150 s, 29,727 samples, taken live on the second run:

| share | symbol |
| ---: | --- |
| 19.8% | `mlir::OperationEquivalence::isEquivalentTo` (two frames) |
| 6.9% | `mlir::enzyme::failIfDynamicShape` (the `CheckedOpRewritePattern` guard) |
| 2.2% | `StaticSlice::get` |
| 2.0% | `CSE<stablehlo::SliceOp>::matchAndRewriteImpl` |

with the remainder in the generic accessors those frames call
(`DenseArrayAttrImpl<long>`, `RankedTensorType::getShape`, `hasStaticShape`).

**Why it is worth reporting.** The pass is not doing anything wrong — it is
doing an O(n²) amount of the right thing, on a population that a hash of the
(operand, start, limit, stride) tuple would deduplicate in one pass. The same
module reached through a different emitter, carrying 2,712 slices instead,
compiles its reverse in 115 s end to end.

**And it is the whole compile at a continental grid, where the population is an
emitter DECISION rather than an accident.** The same four-stage step at 6,552
cells, timed pass by pass on one module: the differentiation is 145.7 s and the
`enzyme-hlo-opt` over its output 312.5 s, against 5.6 s for everything before
them and 9.8 s for everything after — 96% of a 477 s pipeline in two stages, of
which the quadratic one is two thirds. The scaling is visible across three
grids on one model: 1,297 / 1,837 / 8,126 slices entering the differentiation
give 5.3 / 17.7 / 312.5 s, i.e. 17.7x the time for 4.42x the population against
19.6x for the square.

What makes the population a decision is the asymmetry of the two read forms
under reverse mode. On that CONUS module, 567 `stablehlo.gather` produce 548
`stablehlo.scatter` and nothing else, while 8,126 `stablehlo.slice` produce
20,470 slices plus 8,137 pads, which this pass then turns into 22,777 slices.
An emitter that prices a slice against a gather on the PRIMAL module — one
operation against one index constant — is therefore pricing the wrong module,
because downstream the slice is charged at the square of the population it
joins and the index constant is linear.

**Why excluding it is not the answer.** `cse_slice` is also what keeps the other
slice patterns — `slice_elementwise` in particular, which CREATES two slices per
rewrite — from multiplying an un-deduplicated set. Excluding both
(`excluded_passes = slice_elementwise,cse_slice`) was OOM-killed thirteen
minutes in. There is no pass exclusion that wins here.

**Our workaround.** Emit fewer slices: memoize the emitter's own reads so a span
is emitted once, emit a congruent per-cell scalar surface ONCE over its lane
axis (one gather) rather than once per cell (one one-element slice per cell),
and cap what a single read may cost in slices at the width below which the
emitter will not gather at all (`_DE_GATHER_MAX_PIECES`, `ext/reactant_direct/
values.jl`). The cap cannot go to zero: a gather is an indexed copy at runtime
where a slice is a contiguous one, so the trade reverses at execution time and
the cap has to be chosen against both.
All three are properties of our emitter, not of the pass, which is why this is
recorded here rather than treated as a blocker. See reseact.esm's
COMPILE_COST.md for the measurement the numbers above come from.

### XLA:CPU's own `HloCSE` is quadratic in the same population, one layer down

**What happens.** The entry above is Enzyme-JAX's MLIR-level `cse_slice`. XLA
has its own, and it fails the same way on the same input: `xla::HloCSE`
deduplicates by comparing instructions pairwise through
`HloInstruction::IdenticalInternal`, and it runs inside an `HloPassFix`, i.e.
to a fixed point.

Where we met it is the CONTINENTAL grid. ReSEACT's transport right-hand side at
13x7x72 (6,552 cells, 85,176 states) reached XLA carrying **97,385
`stablehlo.slice` in 105,474 operations** — a 221 MB module text — and the
four-stage step built from it four times over. `@compile reactant_ssp_step`
printed XLA's own "Very slow compile?" alarm and did not finish. A `perf`
profile taken live on it:

| share | frame |
| ---: | --- |
| 99.32% | `HloPassPipeline::RunPassesInternal` → … → `HloCSE::RunOnComputation` |
| 23.85% (self) | `HloInstruction::IdenticalInternal` |

The run then died in the object-file layer rather than in the pass:
`contiguous_section_memory_manager.cc: allocateMappedMemory failed`, then
`LLVM ERROR: Unable to allocate section memory!`, 6 h 27 m in, on a node with
160 GB requested and the cgroup not exhausted — the CPU backend's section
allocator reserves a contiguous region per compiled object and a module this
size does not fit one.

**Why it is worth reporting.** Same shape of remark as `cse_slice`: a hash of
the (opcode, operands, shape, literal attributes) tuple deduplicates in one pass
what the pairwise comparison does in n². And the section-memory failure is a
hard abort with no diagnostic that names the module, on a configuration that
would otherwise only have been slow.

**Our workaround is the same one, and it is now the emitter's.** Do not hand it
the population: a read past a piece cap is one gather, the base a gather reads
from is budgeted against the model rather than an absolute element count, and
each slot map is concatenated ONCE into a canonical base every read addresses by
slot (`ext/reactant_direct/values.jl`). The transport right-hand side at the
same grid is then flat in the grid rather than proportional to it. See
reseact.esm's COMPILE_COST.md for the measurement.

## Not filed

Recorded so nobody re-walks them.

- **Reverse mode over a `while` loop with a data-dependent condition** —
  already open as Enzyme-JAX #2565. Do not re-file.
- **Enzyme-JAX #88** is the umbrella "Tracking issue for missing HLO derivatives"
  and already lists `CaseOp`. #2939 was filed as a standalone issue with a
  concrete Julia reproducer rather than as a comment there; nothing was added
  to #88.
- **Binomial checkpointing: wrong gradient + segfault — FIXED upstream.**
  Re-verified clean on 0.2.280, and confirmed to still fire on a pinned 0.2.274
  environment (rel 1.05e-3 wrong gradient; SIGSEGV rc 139), so the probes are
  known to fire rather than merely known to be quiet.
- **XLA:CPU wrong results with >1 intra-op thread — ~~FIXED upstream~~
  RETRACTED 2026-08-24, STILL FIRES, belongs on the file-it list.** The clean bill
  (238,400 calls, zero faults) was measured at 6x6x8. At CONUS with the
  `xla_cpu_prefer_vector_width=128` workaround off, a 40,000-call chemistry soak
  (`tools/diag/conus_race_soak.sbatch`, slurm 10127446, 4 intra-op threads, 3h03)
  produced **1 non-finite and 1 bit-differing call**: 13 non-finite entries, every
  state group at the single cell (2,1,1), at call 7,909. Four immediate re-issues
  of the byte-identical call each came back clean and each differed from the bad
  result in exactly those 13 entries — the documented signature. Rate ~2.5e-5,
  about 400x rarer than the ~1e-2 on record at 6x6x8, but not zero. Independently,
  slurm 10127204 leg 0 aborted a real CONUS backward sweep with `fixed-sequence
  replay of macro step 11 lands NaN`.

  **Why the clean bill was wrong, and the lesson worth keeping.** 6x6x8 is not
  merely a smaller n — it is the WRONG PROGRAM. Transport (`ssp_step`) never
  faulted in 40,000 CONUS calls either; only the larger chemistry graph reaches
  whatever is left. **No number of 6x6x8 calls can clear this flag.** A negative
  result is only as good as the program it ran on, and "we ran 238,400 calls"
  reads as thoroughness while measuring the wrong thing.
- **`update_global_state!(; xla_force_host_platform_device_count=N)`** — our own
  misuse, not a defect. That function is distributed-coordinator setup only and
  has no XLA-flag keyword; the flag belongs in `XLA_FLAGS`.

Because the Binomial entry is fixed, one piece of in-repo guidance is now wrong:
`Binomial(n)` is the **only** checkpointing setting that works with a runtime
trip count on 0.2.280 (no checkpointing and `Periodic(n)` both fail with
`'stablehlo.dynamic_pad' op can't be translated to XLA HLO`).

Separately, `xla_cpu_use_fusion_emitters=false` is not a field in 0.2.280's
`CompileOptions` DebugOptions at all, and the way it fails is a trap:
`CompileOptions(; xla_debug_options=(; xla_cpu_use_fusion_emitters=false))`
validates nothing and returns happily, then throws an `ArgumentError` later inside
`Reactant.XLA.get_debug_options` — i.e. at `@compile` time, after the trace.

## RESEACT_ADJ_XLAFIX: keep it at 1

Measured at CONUS on one allocation, both legs (slurm 10127204, NMACRO=12):
the workaround costs **1.13x peak RSS** (17.83 vs 15.82 GB) and **6.8% of forward
pass** (76.63 vs 71.78 s over a byte-identical accept/reject ladder); compile wall
time is a wash (1051.3 vs 1077.8 s). The driver comment's "roughly doubles compile
memory" does **not** survive. Its 4.0e-5 relative J shift does: +8.30e-05 measured
at 12 macro steps, same sign and order. But the MECHANISM has changed — in August
the gap was attributed to the racy leg integrating a different trajectory through
spurious rejections; here both legs produced byte-identical ladders and identical
accepted-step counts, so the residual gap is the vector-width change itself.
