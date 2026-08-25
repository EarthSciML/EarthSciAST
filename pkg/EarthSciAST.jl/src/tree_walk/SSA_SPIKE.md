# ess-oop-ssa — SSA-style class-to-class references in the `:oop` emitter (spike)

Status: **spike**, behind `ESS_OOP_SSA=1` (read at build time, default OFF — the
flag-off build is byte-for-byte the pre-spike emitter). Code: `oop.jl` (the
`_OopSSA*` section before `_oop_eval_acck`, the analysis section before
`_make_rhs_oop`, and the guarded arms threaded through `_oop_eval_acck` /
`_oop_run_acc_vec` / `_oop_fill_level`). Tests:
`test/tree_walk_oop_ssa_test.jl` (host, bit-identity + engagement + AD),
`test/reactant_oop_ssa_test.jl` (traced census; opt-in via `ESM_TEST_REACTANT=1`).

## What it attacks

The register-file tax measured on ReSEACT at 288 cells: the compiled `:oop`
step communicates between merged kernel classes THROUGH the flat extended
vector `ue` — every fill kernel's result scattered in (whole-buffer
`dynamic_update_slice` rewrites under a trace), every consumer reading it back
through dense precomputed gathers whose index vectors are also ~17 kB/cell of
constants. 58.3% of the optimized step's element volume was data movement; the
buffers are pure implementation artifact (the step returns only `(u_next, err)`).

With the flag on, a consumer descriptor references its producer's RESULT VALUE:

* **tier 1 (direct)** — the gather is exactly one producer's whole block ⇒ the
  producer's SSA value, zero ops;
* **tier 2 (slice)** — the gather decomposes into few consecutive-position runs,
  each inside one producer ⇒ one `slice` per run (+ one `concatenate` when
  more than one run);
* **tier 3 (fallback)** — everything else keeps the dense gather from `ue`,
  byte-for-byte.

A producer's scatter into `ue` is emitted only when static accounting finds a
residual reader of its block; otherwise it is skipped and the value flows only
through references. Final `du` scatters (the real output) are untouched.

## Soundness (static facts + one runtime guard)

* Fill levels read the state and strictly LOWER levels only; redirects require
  `producer.level < consumer.level` (the raw state `u` is producer 1, level 0).
* Slot ownership is LAST-writer: slots rewritten by later kernels, level
  scalar fills, per-cell fallback kernels, or level scan folds are disowned
  (or re-owned by the later writer), and the level check refuses any redirect
  that could observe the wrong write.
* Every non-redirected read surface marks residual slots: scalar-walker trees
  (`_NK_STATE`, `_NK_STATE_GATHER`), E-lane (in-reduce) and sub-kernel plans,
  `_AK_STATE_FIXED` pins, ghost-masked table gathers, declined descriptors,
  level scan folds. Any per-cell (non-vectorizable) kernel disables ALL
  scatter skipping — its reads cannot be enumerated.
* Runtime guard: a producer whose spine hoists to a lane-invariant SCALAR
  records no value; redirects to it fall back to the gather and its scatter
  still runs, so the build-time `skip` verdict never outruns reality.

Bit-identity is the contract: a redirect returns the exact array (or slice of
it) the scatter would have copied, so `:oop`(on) ≡ `:oop`(off) ≡ `:inplace`
at Float64 `==`, ForwardDiff jacobians `==`, and compiled-on ≡ compiled-off
bit-for-bit (asserted).

## Coverage map (test fixtures, `oop_ssa_stats`)

"Edges" = redirect candidates: top-level cell-lane state-gather descriptors of
vectorizable kernels (ghost-masked ones excluded and counted as fallback).

| fixture | edges fast/total | elems fast/total | scatters skipped | notes |
|---|---|---|---|---|
| fan (2 observeds × 4 classes, N=12) | 11/11 | 132/132 | 2/2 | all tier 1/2 |
| chain g→h→state (N=12, ghost at edge) | 6/6 | 59/59 | 3/3 | build splits `h`; final read = 2-producer slice+concat |
| merged class (g1,g2 → one kernel, N=6) | 3/3 | 24/24 | 1/1 | member reads = slices at offsets inside ONE producer value |
| reaction–diffusion, no observeds (N=16) | 7/7 | 46/46 | 0/0 | prefix reads become slices of `u` |

Whole host corpus green with the flag FORCED on: tree_walk_oop (164),
oop_merge (75), array_obs_materialize (78), scan_prefix (333),
oop_scalar_batch (42), observed_materialization (20), observed_slots (36),
iip_generic — all bit-identical to `f!` — and green with the flag OFF
(default path untouched: tree_walk_oop 164, tree_walk_oop_ssa 45). A sweep
over the shared `tests/valid` conformance corpus is inert (the 16 fixtures
that build a bare evaluator are 0-D — no array kernels, 0 edges) and 16/16
bit-pattern-identical on/off.

## Census delta (raw `@code_hlo optimize=false`, ON vs OFF)

| module | total ops | dynamic_update_slice | constants | slices | concat |
|---|---|---|---|---|---|
| fan | **150** / 176 | **4** / 6 | **33** / 39 | 4 / 5 | 1 / 1 |
| chain | **77** / 113 | **1** / 4 | **14** / 23 | 6 / 7 | **2** / 1 |

The DUS delta equals `n_skipped_scatters` exactly (asserted); the extra chain
concatenate is the multi-producer reference's cost. On these toy fixtures
XLA's optimizer converges the two programs (18 ≡ 18 ops optimized) — at scale
that convergence is precisely what fails (pairwise slice-CSE went quadratic on
CONUS; the buffers exceed L3), so the emission-level census is the measure.

## What blocks the rest (tier-3 fallbacks, in expected ReSEACT impact order)

1. **Ghost-masked `_AK_STATE_TBL_BOX` gathers** (boundary stencils through slot
   tables with 0-entries). Extension is mechanical: redirect the safe-index
   gather to producer slices and keep the select-against-mask.
2. **Sub-kernel (`_NK_SUBCALL`) descriptor plans.** Their tables are resolved
   against parent lanes but indexed per-sub, so the per-kernel redirect table
   does not align; needs per-sub redirect tables built in
   `_build_oop_acc_plan`-style. Mechanical, not conceptual.
3. **E-lane (in-reduce) CSR gathers.** Per-entry `(cell, neighbour)` reads
   repeat cells — median run length 1 — so slices+concat lose to the gather;
   would need segment-level ops instead. Left as gathers deliberately.
4. **Scalar-walker and lane-batched scalar reads** (`_NK_STATE`,
   `_NK_STATE_GATHER`, batch slot vectors). Redirectable through the same
   slot→(producer, position) map; not done in the spike. They also hold
   producer scatters alive wherever they read.
5. **Fragmented gathers** (`nseg > max(8, L÷4)`): kept dense by the
   worthwhileness threshold; they also keep their producers' scatters.
6. **Per-cell fallback kernels** disable scatter-skipping globally (reads
   un-enumerable). Rare on affine builds.

## Interactions

* `reactant_oop_test.jl` passes 35/35 with the flag forced on (traced
  end-to-end, ODE solve, frozen-`t` contract, live-forcing refusal — all
  unchanged).
* `reactant_oop_intern_test.jl` under a FORCED corpus-wide `ESS_OOP_SSA=1`
  fails its 5 interning-ENGAGEMENT assertions (hits == 0, slices already
  minimal) while every value assertion passes: with the fan model's reads
  redirected there are no duplicate `ue` reads left for the memo to dedupe.
  That is the two features composing, not a regression — interning remains
  load-bearing for exactly the reads SSA does not redirect (ghost gathers,
  E-lane plans, fallback descriptors). The default suite (flag off) is
  untouched.
* Live forcing (`param_arrays`/`rhs_with_buffers`) rides through unchanged —
  forcing reads go through the buffers argument, never `ue` — and the
  discrete-cadence refresh stays visible with fill scatters skipped (probed).

## Generalization assessment (honest)

The chemistry chain this spike targets is exactly the fixture shape that
redirects 100%: merged `_is_outs` classes with concatenated member runs,
consumers reading per-member slices (the gather-lattice study measured ~2/3 of
ReSEACT's dense gathers decomposable into slices+concat, and the rest keep the
fallback plus the corresponding producer scatters). The Jacobian and stage
solves run through the same emitter, so they inherit whatever the RHS trace
gains; nothing here is chemistry-specific. NOT verified here: ReSEACT itself
(needs the offline env) — the A/B timing is the coordinator's follow-up.
