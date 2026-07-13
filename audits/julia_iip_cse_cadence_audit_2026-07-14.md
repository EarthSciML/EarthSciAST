# EarthSciAST.jl — CSE Coverage & Cadence Handling in the In-Place Runner

**Date:** 2026-07-14
**Scope:** `src/tree_walk/{compile,build,vectorize,oop}.jl`, `src/cadence.jl`, `src/canonicalize.jl`
**Subject:** the `form=:inplace` RHS (`_make_rhs` → `_eval_node`), its CSE pass (`_cse_compile_scalar`, ess-r7h), and how the three cadence tiers (`const ⊏ discrete ⊏ continuous`) are actually realized at build time.
**Status:** review-only. Every finding below was reproduced against the current tree; no code changed.

Severity: **P1** high · **P2** medium · **P3** low.

---

## Executive summary

CSE works, and its evaluate-once property is real. But its **identity is `canonical_json` while its
placement is an unconditional prelude** — and those two choices interact badly with parts of the
evaluator that were designed independently. Three of the five findings are correctness issues that
only fire in specific model shapes, and all three share one root cause: *the prelude is evaluated
before the tree it was hoisted out of, and nothing checks whether that is legal.*

The cadence side is the mirror image. The runner **does** implement the `discrete` cut
(`DiscreteMaterializer`, on by default through `simulate`) and a `const` cut for array observeds with
parameter-indexed gathers. What it has **no tier for at all is const-cadence scalar algebra** — and
that is precisely what CSE hoists into the prelude. So the pass that identifies shared subexpressions
and the lattice that knows which of them never change are both present, and they do not talk to each
other: every parameter-only subexpression the CSE pass finds is recomputed on every RHS call, forever.

| # | Finding | Severity |
|---|---|---|
| 1 | CSE hoists guarded subexpressions out of lazy `ifelse`/`and`/`or` → `DomainError` crash | **P1** |
| 2 | "Bit-exact" is false: canonical keys collapse float association order | **P1** |
| 6 | Array cadence classifier is blind to `filter`/`key` → state-dependent field silently frozen at `u=0` | **P1** |
| 3 | CSE is silently disabled for *any* expression touching a live forcing buffer | **P2** |
| 4 | No CSE on the array path at all — at any of four levels, incl. a `fn` hoist barrier | **P2** |
| 5 | No const-cadence tier: parameter-only prelude slots recompute every step | **P2** |

**Arrays specifically** (findings 4 and 6) are the weakest area, and the two failures are opposite in
kind. On the CSE side the array path has *no value-numbering of any sort* — the two mechanisms that
look like CSE (structural cell-grouping, lane-invariant hoisting) dedupe different things — and it
carries a `fn` hoist barrier that is the exact bug ess-obs already removed from the scalar path. On the
cadence side the array cut is the one place the runner *does* implement a real cadence tier, and its
soundness rests on a reachability walker that misses two of the fields it needs to look at, backed by a
`materialize!` that reads `u = zeros(...)` on the assumption it will never matter.

---

## 1. CSE hoists out of a lazy guard, turning a working model into a crash — **P1**

`_eval_node_op` is **lazy** for `ifelse` (only the taken branch is walked) and short-circuits `and`/`or`.
The CSE prelude is **unconditional** — `_make_rhs` fills every slot at the top of every call
(`vectorize.jl:951-953`) before any equation runs. `ifelse`, `and` and `or` are not in
`_CSE_OPAQUE_OPS`, so a subexpression sitting *under* a guard is a hoist candidate like any other.

The consequence is that whether a guard protects its operand depends on **how many times that operand
happens to appear in the model**:

```
D(a) = ifelse(a >= 0, sqrt(a), 0)          # a = -1.0
D(b) = 2 * ifelse(a >= 0, sqrt(a), 0)      # same guarded sqrt(a) — 2nd occurrence
```

| | | |
|---|---|---|
| `sqrt(a)` appears **once** | `n_cse_slots=0` | `du = [0.0, 0.0]` ✅ |
| `sqrt(a)` appears **twice** | `n_cse_slots=3` | **`DomainError with -1.0`** 💥 |

Identical for short-circuit `or` with `log(a)`. The throw is inside the prelude loop
(`vectorize.jl:952`), evaluating a node whose guard says it must not run.

This is the standard way to write clipped physics — `sqrt` of a possibly-negative quantity, `log` of a
possibly-zero mixing ratio, a divide-by-zero guard — so it is not an exotic shape. And the failure mode
is the nastiest kind: **adding an unrelated equation crashes an equation that already worked.**

**What makes this worth fixing rather than documenting:** the three emitters do not agree on whether
`ifelse` is even lazy. I checked all three with a *single* (un-CSE'd) occurrence:

| emitter | `ifelse` behaviour |
|---|---|
| `_eval_node` (iip scalar) | **lazy** — guard holds, returns `0.0` |
| `_eval_vec` (iip vectorized, `vectorize.jl:848`) | **eager** — broadcasts all three children |
| `_oop_eval_op` (`oop.jl:355`) | **eager** — fills every child into `c` before dispatch |

So `form=:oop` already throws `DomainError` on the one-occurrence model that `form=:inplace` evaluates
fine. Laziness is not a property of the format; it is an accident of the one walker that recurses
lazily. CSE then makes that walker *conditionally* eager on top.

Recommendation: **pick one semantics and enforce it.** The vectorized and oop paths cannot be lazy
(broadcast is eager by construction), so the only self-consistent choice is that `ifelse`/`and`/`or`
are **eager everywhere**, stated in the spec, with the iip scalar walker's laziness removed so the
guard illusion cannot form. If lazy semantics are wanted instead, they have to be paid for on all
three paths (a `select`-style node with a per-lane mask), and CSE must treat guarded operands as
opaque. Either way the current state — the answer depends on the occurrence count — is not defensible.

---

## 2. The "bit-exactness" claim does not hold — **P1**

`compile.jl:403-408` states:

> BIT-EXACTNESS: a cached subexpression's definition is compiled from its original (first-seen)
> operand order — identical to what `_compile` emits inline today — so each occurrence reads back
> the exact bytes it would have computed.

The first clause is true and the conclusion does not follow from it. The key is
`canonical_json`, and `canonical_json` **canonicalizes before emitting** (`canonicalize.jl:291`):
n-ary `+`/`*` are flattened and their arguments sorted. So two *differently associated* trees have the
same key, and the first-seen one's evaluation order wins for both. Float addition is not associative:

```
D(x) = (a+b)+c        # a = 1e16, b = -1e16, c = 1.0
D(y) = a+(b+c)        # same canonical key: {"args":["a","b","c"],"op":"+"}
```

| model | `n_cse_slots` | `du[y]` |
|---|---|---|
| `D(y)` alone | 0 | `0.0` — the value its own equation specifies |
| `D(y)` + `D(x)` above | 1 | **`1.0`** |

`D(y)`'s equation is byte-for-byte unchanged between the two models. Adding an unrelated equation
changed its value by 100%. (Catastrophic cancellation makes it dramatic; the everyday version is a
silent ~1 ulp drift, which is why no test caught it.)

There is a coherent defence — canonical form *is* the format's notion of expression identity, so a
conforming reader may associate `+(a,b,c)` however it likes. If that is the intended reading, then the
fix is documentation plus honesty in the header comment. But it should be a decision, not an
accident, because it means **the numeric output of an equation is not a function of that equation
alone** — which is a surprising property for a reference implementation whose conformance suite
compares RHS values at `rtol=1e-9`. The alternative fix is to key CSE on structural identity
(pre-canonicalization shape) rather than canonical identity, which loses commutative sharing but
restores the property the comment claims.

---

## 3. CSE is silently switched off by live forcing buffers — **P2**

`_resolve_indices` lowers a `param_arrays` gather to a **synthetic argless `index` node carrying a
`_PGatherRef` in its `value` slot** (`compile.jl:74-80`). `index` is `cse_opaque`, so the gather itself
is correctly never hoisted. But `_cse_key` is called on every *hoistable ancestor* of that node, and
`canonical_json` emits the `value` field (`canonicalize.jl:371`) → `_emit_canonical_value` meets a
`_PGatherRef`, which is not a JSON type → `CanonicalizeError("E_CANONICAL_BAD_CONST")` → `_cse_key`
returns `nothing` → **sharing is declined for that subtree and every parent of it.**

The comment at `compile.jl:74-80` anticipates the opposite ("the `index` op is CSE-opaque and this
node never reaches serialization") — but it reaches serialization as a *child*, every time.

Measured on `sin(F[1]*k) + cos(F[1]*k)` / `F[1]*k` (three occurrences of `F[1]*k`):

| how `F` is bound | `n_cse_slots` | `n_cse_occurrences` |
|---|---|---|
| `const_arrays` (frozen → folds to a literal) | 1 | 3 |
| `param_arrays` (live gather) | **0** | **0** |

Values stay correct — this is pure coverage loss, and it fails *closed*, which is the right direction.
But it is invisible (no warning, and `n_cse_slots=0` reads exactly like "nothing to share"), and it
takes out **the single biggest CSE target in a real earth-science model**: the met→physics stack built
over forcing buffers. The FastJX case the ess-obs comment is written to defend
(`interp.linear(table_i, axis, cos_sza)` × 18 bands over one shared solar chain) is fully CSE'd only
as long as the solar chain touches no live buffer; route it through an ERA5 gather and every band
silently re-walks it.

Fix is small: give the gather a canonicalizable identity. Emitting `value` as e.g.
`["__pgather", <buffer id>, <linear offset>]` — or keying CSE on `(objectid(flat), lin)` — makes the
gather a first-class, *distinguishable* leaf and restores sharing above it. It must stay
*distinguishable*: two gathers into different buffers or different offsets must never collide, or the
failure flips from lost sharing to wrong numbers.

---

## 4. CSE on the array path: not supported at all, at any of the four levels — **P2**

**There is no CSE on the array path.** `_cse_count!` / `_compile_cse` are run over `scalar_entries`
only (`build.jl:1488`); array (`arrayop`) equations compile to `_VecKernel`s, and no value-numbering,
key, or cache slot exists anywhere in that lowering. What the array path has instead is two *different*
mechanisms that are easy to mistake for CSE:

- **structural cell-grouping** (`_merge_nodes`) — collapses the N per-cell `_Node` trees into one
  template. This is what makes kernel count N-independent. It dedupes *compiled nodes across cells*,
  not *values within a cell*.
- **lane-invariant hoisting** (`_VK_INVARIANT`, `vectorize.jl:86-110`) — collapses a subtree with no
  free cell index to one scalar eval + `fill!`. Per kernel, per call.

Both are real wins and neither is CSE. Redundancy therefore survives at **all four** levels:

**(a) Within one kernel, a repeated lane-varying subexpression is not shared.**
`D(u[i]) = sin(u[i]+w[i]) + cos(u[i]+w[i])`, N=100, lowers to:

```
OP(+) ├─ OP(sin) └─ OP(+) ├─ GATHER └─ GATHER      9 _VecNodes
      └─ OP(cos) └─ OP(+) ├─ GATHER └─ GATHER      900 floats of lane buffer
```

`u[i]+w[i]` is lowered **twice**, each copy carrying its own 100-lane buffer and re-evaluated every RHS
call. The scoping note at `compile.jl:415-421` argues this level is already handled ("eliminated at
DISCRETIZE time … canonicalization already merges like additive/multiplicative terms"). That is true
for the *Laplacian fixture* it cites, and only for like-term merging — canonicalization does not share
`x` between `sin(x)` and `cos(x)`. The conclusion "every gather appears exactly once, nothing to share"
generalizes from one fixture shape, and the conformance PDE fixtures (pure single-field arrayops)
cannot expose the difference.

**(b) `fn` is a hoist BARRIER — the exact bug ess-obs already fixed on the scalar side.**
`_maybe_hoist_invariant` bails outright on `op === :fn` (`vectorize.jl:249`), and `_VK_FN` is not in
`_vk_lane_invariant` (`vectorize.jl:214-216`) — so a `fn` node is never hoisted *and no ancestor of one
can ever be hoisted either*. A closed-function call that is a pure function of time:

```
D(u[i]) = interp.linear(tbl, axis, t) * u[i]      # identical in all 100 lanes
  →  OP(*) ├─ FN ── TIME        hoisted to INVARIANT? false
           └─ GATHER            100 table lookups per RHS call, not 1
```

This is precisely the barrier that ess-obs removed from the scalar CSE pass — the reasoning at
`op_registry.jl:222-228` ("Flagging it opaque made every closed-function call a CSE BARRIER … ~250
re-walks of the same solar chain per RHS call") applies verbatim here, and the array path is where the
FastJX-shaped workload actually lives. The stated reason for the exclusion is mechanical, not
semantic: `_vk_to_scalar` can't reconstruct a scalar `_Node` from a lowered `_VK_FN` because the
payload shapes differ (`vectorize.jl:227-229`). That is fixable — carry the source `_Node` alongside
the lowered node, or reconstruct from the typed spec.

*Documentation bug, same area:* the header at `vectorize.jl:88` gives `interp.linear(table, t)` as an
**example of what gets hoisted**, while `vectorize.jl:98-100` and the code say `fn` is never hoisted.
The file contradicts itself; the line-88 example is wrong. (`_VK_REDUCE` is excluded too, so a
lane-invariant contraction is likewise not hoisted.)

**(c) Between kernels, nothing is shared.** A coupled multi-field PDE whose species balances share a
flux `k*A[i]*B[i]` recomputes it once per kernel. This one *is* acknowledged as a follow-up
(`compile.jl:428-432`).

**(d) Between the scalar prelude and the kernels, nothing is shared** — and this direction is not
mentioned anywhere. For a lane-invariant Arrhenius factor in two array equations plus one scalar
equation:

```
n_vec_kernels = 2   _VK_INVARIANT nodes per kernel = [1, 1]
n_cse_slots   = 0   ← the scalar occurrence is a SINGLETON, because the two
                      array occurrences are invisible to the count pass
→ the identical subtree is evaluated 3× per RHS call
```

Note the second-order effect in that `n_cse_slots = 0`: because the count pass cannot see
array-equation occurrences, a subexpression appearing once in a scalar equation and twenty times across
kernels is counted **once** and so isn't cached on the scalar side either. Kernels don't just fail to
share with the prelude — they suppress the prelude.

(d) is the cheapest fix of the four and unlocks the rest: `_VK_INVARIANT`'s payload is already a plain
scalar `_Node`, so it can be keyed and routed into the existing prelude and cache slot with no new
machinery. Fixing (b) then makes far more subtrees eligible to be routed there. (a) needs genuine
value-numbering over `_VecNode` (structural keys, a per-call lane-buffer cache) and is the real
follow-up.

---

## 5. The cadence lattice is never consulted by the hot path — **P2**

This is the structural finding, and the one the other four keep pointing at.

`Cadence` (src/cadence.jl) implements the §5.7 partition properly: `const ⊏ discrete ⊏ continuous`,
`class(node) = max` over children, the gather rule, the guards. But it is a **conformance/analysis pass
over raw JSON** — `partition_model` / `classify` are called from the conformance suite and from
`value_invention.jl`, and **never from `build_evaluator`**. The runner re-derives what it needs with
its own bespoke, string-set reachability analysis (`_discrete_materialize_split`, `build.jl:905`).

What the runner actually implements:

- **`discrete` tier** — ✅ real. `DiscreteMaterializer` cuts param-tainted, non-state-reaching *array*
  observeds into cache buffers refilled once per refresh, and `simulate` turns it on by default
  (`simulate.jl:320`). Downstream readers gather the cache via `_NK_PARAM_GATHER`. This is good.
- **`const` tier, arrays** — ✅ partially. `const_vars` handles coordinate-regrid gathers whose
  subscript is a parameter float, materialized build-once.
- **`const` tier, scalar algebra** — ❌ **absent.** Nothing classifies a scalar subexpression by
  cadence. So every parameter-only subexpression that CSE identifies goes into the per-call prelude
  and is recomputed on every RHS call, forever.

Measured on the Arrhenius model (`A*exp(-Ea/(R*Tref))`, all four leaves parameters, shared across two
equations):

```
n_cse_slots = 5   →  slot 1 neg  · slot 2 * · slot 3 / · slot 4 exp · slot 5 *
                     5/5 slots are state-free AND time-free
```

CSE correctly finds the whole chain, names it, and then the prelude re-evaluates all five slots —
including the `exp` — on every stage of every step, for the entire integration. The cadence pass would
label every one of them `const` on sight. This is the gap the `julia-invariant-hoist` branch name
implies, and finding #4 is the same gap seen from the array side.

**Design constraint for the fix (this is why it isn't just "fold at build time"):** a const-cadence
slot is const in *cadence*, not in *value type*. `p` is passed into `f!` on every call and legitimately
changes — parameter sweeps, `remake`, and above all **ForwardDiff-over-parameters**, where the
parameter values are `Dual`s (which is exactly why `_rhs_value_type` promotes over `values(p)` and not
just `eltype(u)`). Hoisting a parameter-only slot to build time would silently freeze it at its
Float64 build value and break AD-over-p and every parameter study.

The shape that actually works is a **two-tier prelude**: partition the prelude slots by whether their
subtree touches `_NK_STATE` / `_NK_TIME` / `_NK_PARAM_GATHER` (a one-line predicate on the compiled
`_Node` — I used exactly this to produce the numbers above), and re-evaluate the const tier only when
`p` changes identity, caching per value type alongside the existing `_CSECache.alt` mechanism. That
keeps AD-over-p correct, keeps the Float64 path zero-alloc, and drops the const chain from
once-per-stage to once-per-parameter-epoch. The `discrete` tier (subtrees whose only non-const leaves
are `_NK_PARAM_GATHER`) is the same trick keyed on refresh events, and it would subsume the
scalar half of what `DiscreteMaterializer` does for arrays.

---

## 6. Cadence processing for arrays: the classifier is blind to `filter` and `key` — **P1**

The array cadence cut (`_discrete_materialize_split`, `build.jl:905`) decides which array observeds are
`discrete` (frozen into a cache, refilled once per refresh) and which are `const` (materialized
build-once). Both decisions turn on one predicate — *does this def transitively reach a state or `t`?*
— computed by a name-reachability closure over `_referenced_var_names`.

**`_referenced_var_names` (`geometry_setup.jl:1000-1017`) walks `args`, `expr_body`, `lower`, `upper`,
`values`. It does not walk `filter` or `key`.** `Cadence.child_exprs` (`cadence.jl:209`) walks exactly
`args`, `expr`, `key`, `filter`, `lower`, `upper`. There are two enumeration walkers in this codebase,
they disagree about which fields are value inputs, and the runner uses the one that is missing two.

`filter` is not a dead field: `OpExpr.filter` is a full `ASTExpr` (`types.jl:211`), and `resolve.jl:156`
lowers it to a **runtime** guard — "guard filter-rejected terms with a runtime `ifelse(pred, term, 0̄)`".
A filter predicate is therefore a first-class, state-readable value input.

Take a masked regrid over a live forcing buffer — aggregate `raw[j]`, keeping only cells where the
state is positive. `u` appears **only** in the filter:

```
_referenced_var_names(agg)  ->  ["j", "raw"]        # `u` is MISSED

state referenced in FILTER  ->  discrete_vars = ["Fcache"]     # cut into a cache
state referenced in BODY    ->  discrete_vars = String[]       # correctly not cut
```

Same dependency on `u`, opposite classification, decided purely by *where in the node* the reference
sits. And the cut fails **silently**: `materialize!` evaluates each fill node with `uz = zeros(n_states)`
and `t = 0.0` (`build.jl:1042-1046`), under the comment *"Discrete vars are state-free, so the zero `u`
/ `t=0` passed to `_eval_node` is never read."* That sentence is an **assumption, not a check** — and
when it is false, the field freezes at `u = 0` and thereafter updates only on data-refresh events. No
error, no warning, wrong trajectory.

Two fixes, and the second matters more than the first:

1. Make `_referenced_var_names` walk `filter` and `key` (and audit `join_gates`, `table_axes`, and
   expression-valued `ranges` bounds, none of which it walks either). Better: delete it and route the
   runner through `Cadence`'s enumeration, so there is one definition of "child expression" instead of
   two that drift.
2. **Make the cut fail loud.** After compiling the fill nodes, assert that no fill node contains an
   `_NK_STATE` or `_NK_TIME` leaf. That is a three-line build-time check, it turns this entire class of
   bug from silent staleness into a build error, and it would have caught this instance regardless of
   which walker is used — the filtered aggregate's fill node lowers to `ifelse(u[j] > 0, raw[j], 0)`,
   which contains an `_NK_STATE` node in plain sight.

**Related structural notes on the array cadence tiers:**

- **The runner never consults the `Cadence` lattice.** `partition_model` / `classify` are called from
  the conformance suite and `value_invention.jl`, never from `build_evaluator`. The runner re-derives
  cadence with the bespoke closure above, and the two definitions of `discrete` are not the same
  predicate: the runner's is *"transitively reads a `param_arrays` buffer"*, the spec's is *"a variable
  declared `type: discrete`, refined by whether its loader declares a `temporal` block"*
  (`cadence.jl:160-165`). The typed parser does not even model the `discrete` variable kind
  (`cadence.jl:31-33` says so outright). So a model that declares cadence the way the spec describes
  gets no runner support, and the runner's tier keys off something the spec does not mention.
- **The discrete cut actively degrades CSE.** A cut field is read back through
  `_NK_PARAM_GATHER` / `_VK_PGATHER` — which is exactly the node that makes `_cse_key` decline
  (finding #3). So every field successfully moved to the discrete tier converts *all of its readers*
  into CSE-blind expressions. The two optimizations fight each other, and today the cadence cut wins
  by silently disabling the other. This is the strongest argument for doing #3 first: without a
  canonicalizable gather identity, extending the cadence cuts trades one redundancy for another.
- **Filters make finding #1 reachable from ordinary array code.** Because a filter lowers to a runtime
  `ifelse`, the natural pattern `aggregate(log(u[i]/u0), filter = u[i] > 0)` produces exactly the
  guarded-operand shape that the CSE prelude hoists out from behind its guard. Finding #1 is not
  confined to hand-written `ifelse`; filtered aggregates generate it.
- **Fail-loud restrictions that are fine as they are** (P3): a discrete var's def must be an
  arrayop/aggregate producer (`build.jl:991`) and every dim's range must be exactly `1..n`
  (`build.jl:999`). Both throw `E_TREEWALK_DISCRETE_MATERIALIZE` with a clear message. No action needed
  — noted only to contrast with the silent failure above.

---

## Secondary observations

- **`seed_leaf` seeds `observed` → `const`** (`cadence.jl:167`). In a `max`-lattice, `const` is the
  *least* conservative seed, not the most: an observed defined as `y = u1 + u2` is continuous, and
  seeding it `const` would under-classify — weakening guard 2 and letting `hot_tree_empty` report true
  for a model that has hot work. It is safe today only because fixtures inline observed definitions
  before classification and never reference an observed as a leaf. The Python reference
  (`scripts/run-cadence-conformance.py:154-157`) does the same thing with the same rationale, so this
  is **cross-binding consistent and not a Julia bug** — but for a pass whose docstring says the guards
  are "*checked*, not hoped for", an un-checked convention is a soft spot. Either resolve observed
  leaves through their defining equation, or reject an observed leaf outright. (P3, spec-level.)
- **`seed_leaf` returns `const` for any unrecognized string** — index-set name, bound index, relation
  tag, *or a typo'd variable name*. A misspelled state silently classifies `const`. (P3.)
- **Prelude slots are evaluated even when every occurrence sits in a not-taken branch.** Subsumed by
  finding #1; worth restating as a pure-perf item if #1 is resolved by making `ifelse` eager.
- **Non-reentrancy** (shared `_CSECache` / `_VecNode.buf`) is correctly documented at
  `vectorize.jl:152-155` and `compile.jl:505-509`. Not a finding — but it does mean the two-tier
  prelude in #5 must not introduce a `last_p` field that a second thread could race on any more than
  the existing buffers already do.

---

## Suggested order of work

1. **#6 safety net first** — the three-line "no `_NK_STATE`/`_NK_TIME` in a discrete fill node" build
   assertion. It is the cheapest change in this document and it converts the only *silent* wrong-answer
   bug here into a build error. Do it before anything else touches the cadence cut. Then fix the walker
   (`filter`/`key`), ideally by collapsing the two child-enumeration walkers into one.
2. **#1** — decide `ifelse`/`and`/`or` semantics and make the three emitters agree. It is the only
   finding that turns a working model into a crash, and filtered aggregates generate the shape.
3. **#2** — decide whether canonical identity is the intended CSE identity, then either fix the comment
   or fix the key. Cheap; unblocks confidence in everything else.
4. **#3 → #4 → #5** — one piece of work, not three, and this order matters. Give the pgather a
   canonicalizable identity (#3) *first*, because until it exists the cadence cuts actively destroy CSE
   coverage. Then route `_VK_INVARIANT` representatives into the shared prelude and lift the `fn` hoist
   barrier (#4). Then split the prelude into const / discrete / continuous tiers (#5). Each step is
   independently testable, and `n_cse_slots` / `n_cse_occurrences` extend naturally into per-tier counts
   that pin the result. True value-numbering inside a kernel template (#4a) is the genuine follow-up and
   should be scoped separately.
