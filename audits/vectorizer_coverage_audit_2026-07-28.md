# Vectorizer coverage audit — what still falls back to the per-cell AST oracle

**Branch** `perf/rust-vec-coverage-audit`, from `ef51292c`.
**Date** 2026-07-28.
**Scope** every simulable fixture in `EarthSciAST/tests/conformance/`, the
`EarthSciDiscretizations` conformance corpus (simulation + convergence +
regridding), and `simpleclimate.esm`.

`ef51292c` engaged the whole-array overlay for one real model. This audit
establishes what is still on the per-cell path **everywhere else**, and turns it
into a ranked work queue.

Headline: **coverage is already very high, and the remaining gaps are few and
sharply defined.** Across 220 model runs the sweep found **six** distinct
bail-out root causes. Two of them are worth implementing, one is strategic, one
is a design question, one is negligible, and one is deliberate.

The single largest finding is not a gap at all: **39 of the 87 ESD simulation
manifests exclude the Rust binding because "Rust hangs / does not terminate".
Those exclusions are now stale.** 37 of the 39 run to completion and pass at
`ef51292c`, with zero per-cell fallbacks, several of them 30–169× faster than
with the overlay disabled. Re-enabling them is a larger, cheaper win than
anything in the inventory below.

---

## 1. Coverage sweep

| corpus | runs | vectorized units | per-cell units | cases with any fallback |
|---|---|---|---|---|
| `earthsci-ast-rs` test suite (905 tests, `ESS_VEC_DEBUG=1`) | 905 | — | **22** distinct sites | 18 tests |
| ESD `simulation`, Rust-included | 48 | 154 | **14** | 4 |
| ESD `simulation`, Rust-**excluded** (traced anyway) | 39 | 145 | **0** | 0 |
| ESD `convergence` (coarsest resolution) | 101 | 264 | **1** | 1 |
| ESD `regridding` | 8 | — | 2 kinds | 8 (build-once only) |
| `EarthSciAST` `pde_simulation` manifest | 8 | all | **0** | 0 |
| `simpleclimate.esm` 12×7×7 | 1 | 53 observeds + 4 rules | **0** | 0 |

A "unit" is one rule or one observed, deduplicated per case (a solve emits the
same trace block on every RHS call).

Reproduce: `tools/vec-coverage-sweep/sweep_esd.py`, `timeit.py`,
`validate_metric.py`. Raw traces and parsed JSON are under `sweep-out/`
(git-ignored).

### The 39 stale ESD exclusions

Every one of these manifests carries a `scope_excluded.rust` reason of the form
*"Rust hangs at every tolerance tried"* / *"does not terminate"* — recorded
before the overlay was engaged. Traced at `ef51292c`:

* **37 of 39 complete and pass** their inline MMS assertions at the manifest's
  own solver (`Erk`, reltol 1e-10, abstol 1e-12), with **zero** per-cell
  fallbacks between them.
* 2 time out at the 150 s sweep budget:
  `latlon3d_transport_cwc_regional_inflow`, `latlon3d_transport_per_tracer_inflow`
  (both rank-3 makearray flux-form transport, whose exclusion reason is
  "not exercised by the Rust binding's simulation pathway", not a hang).

Measured A/B on four of them (serial, min of 2 reps, overlay vs `ESS_VEC_DISABLE=1`):

| case | with overlay | overlay disabled | speedup |
|---|---|---|---|
| `anisotropic_diffusion_2d_periodic` | 2.4 s | >400 s (timeout) | **>169×** |
| `heat_1d_varcoeff_zero_flux` | 0.22 s | 12.2 s | **56×** |
| `latlon_advection_zonal_upwind` | 0.065 s | 3.6 s | **56×** |
| `advection_1d_periodic_superbee` | 2.5 s | 76.0 s | **30×** |
| `advection_1d_inflow_weno5` | 0.27 s | 2.4 s | 9× |
| `laplace_beltrami_band_mms` | 117 s | >400 s (timeout) | >3.4× |

The hangs were the per-cell interpreter, exactly as in `simpleclimate.esm`.
**Recommended action, ahead of any item in the inventory: re-run
`scripts/runners/run-rust.sh --categories simulation` against `ef51292c` and
strike the stale `scope_excluded.rust` entries.** That converts 37 currently
unmeasured cases into live regression coverage for the overlay.

---

## 2. Ranked inventory of bail-out constructs

Ranked by (breadth × measured cost) ÷ difficulty. Category legend:

* **[1] not covered yet** — should vectorize, no reason it cannot.
* **[2] correctly per-cell** — the overlay would be wrong, bit-inequivalent, or
  asymptotically worse. Do not "fix" these.
* **[3] negligible payoff** — possible, not worth it.

---

### #1 · F1 — forcing-channel read · **[1]** · difficulty LOW

**Construct.** Any variable resolved through the external forcing buffer:
`variable: unresolved symbol (forcing/loop-bind?): <name>`.

**Where it bails.** `vectorized.rs::eval_vec_variable`, final arm. The
resolution ladder is `t` → contraction bind → output-index ramp → state →
observed → param → *bail*. The per-cell oracle's `lookup_variable` has one more
rung after params: `ctx.forcing.borrow().get(name)`.

**Why it bails.** Stated in situ: `EvalCtx.forcing` is
`&'a RefCell<HashMap<String, ArrayD<f64>>>`, so `borrow()` yields a
guard-scoped `Ref`, not the `&'a ArrayD<f64>` that `VecValue::View` needs.

**Breadth.** The widest gate in the corpus: **15 of the 22** distinct fallback
sites in the `earthsci-ast-rs` suite, across **11 tests** — provider injection
(`Meteorology.u_wind` in the loaded-IC/BC wildfire model), the PR-1 forcing
channel (`w`, `wind`), segmented/cadence runs (`Box.scale`), refresh bands
(`M.F_src`, `M.scale_src`), discrete materialization (`M.src`). It does not
appear in the ESD corpus, which has no loader-fed fields — so its cost is
under-represented by the ESD numbers and over-represented by nothing.

**Cost.** Not directly timed (compiled rules carry no per-rule timing in the
trace). Circumstantially: `loaded_ic_bc_simulation_provider_injection` alone
emitted 11 147 bail blocks — 3 chemistry rules × ~3 700 RHS calls, every one of
them per-cell. Every forcing-fed model in the repo is 100 % on the oracle.

**Fix.** Add a forcing rung to `eval_vec_variable` that copies into a pooled
buffer instead of borrowing:

```rust
if let Some(a) = ctx.forcing.borrow().get(name) {
    return Some(if a.ndim() == 0 {
        VecValue::Scalar(a[IxDyn(&[])])
    } else {
        let mut buf = pool.take_array(a.shape());
        buf.assign(a);
        VecValue::Owned { data: buf, origin: DimI::from_elem(1, a.ndim()) }
    });
}
```

Order matters: it must go **after** params, matching `lookup_variable`, so
forcing only ever fills a gap and never shadows a live binding.

**Bit-identity.** By construction — an element-for-element copy of the same
buffer the oracle reads, then the same `apply_binary` kernels. One copy per
*read*, versus the oracle's `a.clone()` per read **per cell**, so it is also
strictly less allocation than today.

**Caveat to check when implementing.** The copy costs one allocation per forcing
read per RHS call, which the `pde_zero_alloc` steady-state test may notice for a
forcing-fed model. `pool.take_array` is the right vehicle; verify against that
test.

**Owner.** `pkg/earthsci-ast-rs/src/simulate_array/vectorized.rs` — **not mine**
(allocator / axis-classification agent). Not implemented here.

---

### #2 · C1 — clamped ("replicate-edge") index · **[1]** · difficulty LOW–MEDIUM

**Construct.** `index(u, max(lo, min(hi, sym ± k)))` — the clamp-to-edge /
zero-gradient boundary idiom.

**Where it bails.** `vectorized.rs::eval_vec_index`, the
`classify_axis_index` / `const_index_value` fallthrough:

```
index: axis expression is neither an affine/wrap map of an unclaimed output
symbol nor a constant select: axis 1 = op max/2 (unclaimed output syms = ["gi","gj"])
```

**Breadth.** `EarthSciDiscretizations/grids/duo/rules/duo_extend.esm` contains
**242** of them. It is the sole blocker on 3 observeds and both compiled rules of
ESD `duo_swe_freestream` — **the only Rust-included ESD simulation case that
does not terminate**, and it is not on the stale-exclusion list, so it is a live
failure.

**Cost — the largest single measured number in this audit.** One RHS evaluation
of `duo_swe_freestream`, from the per-observed trace timing:

| observed | verdict | cost |
|---|---|---|
| `node` | per-cell (gate C4) | 134.2 ms |
| `ua_e` | per-cell (**C1**) | 97.4 ms |
| `dp_e` | per-cell (**C1**) | 93.3 ms |
| `va_e` | per-cell (**C1**) | 89.8 ms |
| 7 others | vectorized | 5.8 ms total |

**414.6 ms of 420.4 ms — 98.6 % of traced observed time — is per-cell**, and C1
accounts for 280.5 ms of it. Plus the compiled rules `ua` and `va`. The case
was killed at the sweep's 900 s budget.

**Fix.** A clamp over one axis is exactly **three** copy segments in the machinery
`eval_vec_index` already has:

* left plateau `[0, lo_p)` — every output position reads source index `lo`;
* affine middle run — the existing `AxisIndex::Affine` segment;
* right plateau — every output position reads source index `hi`.

`AxisIndex::Wrap` already emits a two-segment roll through the same
`axis_segs` loop, so the shape of the change is known. The one genuinely new
piece is that a plateau is a **stride-0 broadcast of a single source slice**,
where today's segments are contiguous 1:1 runs; the broadcast machinery
(`rv.broadcast(...)`, used for unmapped output axes) already exists a few lines
below and can be reused.

Recognition side: extend `classify_axis_index` to accept
`max(c1, min(c2, <affine in sym>))` and its commuted spellings, returning
`AxisIndex::Clamp { k, lo, hi }`. Reject anything where the clamp bounds are not
loop-invariant constants.

**Bit-identity.** A clamp selects exactly the source element the oracle's
per-cell `index` selects; no arithmetic is introduced. Pin it with
`frontier_clamped_index_falls_back` in `tests/vec_coverage_frontier.rs`, which
already does the bit comparison — implementing the gate flips that assertion and
the same test then proves equivalence.

**Owner.** `vectorized.rs` — **not mine**. Not implemented here.

---

### #3 · C4 — array-valued `const` · **[1]** · difficulty LOWEST

**Construct.** An inlined constant *table*: `index(const([...]), i)`.

**Where it bails.** `vectorized.rs::eval_vec_op`, the `"const"` arm:

```rust
"const" => match eval_const(node) {
    Value::Scalar(s) => Some(VecValue::Scalar(s)),
    Value::Array(_) => { note_bail(|| "op: array-valued `const`".to_string()); None }
}
```

**Breadth.** Narrow but expensive: ESD `duo_swe_freestream`'s `node` observed;
the in-crate ragged-CSR miniature ships its mesh factors this way
(`nEdgesOnCell`, `edgesOnCell`, `w` are all `const` observeds).

**Cost.** **134.2 ms in a single RHS evaluation** of `duo_swe_freestream` — 32 %
of that model's traced observed time, from a gate whose fix is a few lines.

**Fix.** `eval_const` has already built the `ArrayD`. Copy it into a pooled
buffer and return it with origin 1, exactly as the state/observed arms do:

```rust
Value::Array(a) => {
    let mut buf = pool.take_array(a.shape());
    buf.assign(&a);
    Some(VecValue::Owned { data: buf, origin: DimI::from_elem(1, a.ndim()) })
}
```

No new analysis, no new numerics.

**Bit-identity.** The oracle materializes the same `ArrayD` from the same JSON
literal through the same `eval_const`. Pinned by
`frontier_array_valued_const_falls_back`.

**Caveat.** `eval_const` re-parses the JSON literal on *every* visit. Hoisting
the parse is a separate (and larger) win that belongs with the CSE work, not
here.

**Owner.** `vectorized.rs` — **not mine**. Not implemented here.

---

### #4 · C2 — indirect (data-dependent) gather · **[1]** · difficulty MEDIUM–HIGH

**Construct.** `index(phi, index(cellsOnEdge, e, 2))` — the inner `index` is
itself an affine map of an output symbol, so it evaluates to a whole-array
vector of **indices**, and the outer read is a gather along it.

**Where it bails.** Same site as C1 — the axis classifier sees an `index` node
where it wants affine / wrap / constant:

```
index: axis expression is neither an affine/wrap map ... : axis 0 = op index/3
(unclaimed output syms = ["e"])
```

**Breadth.** Every unstructured-mesh rule in the corpus:
`grids/mpas/rules/{fv_gradient_edge, fv_divergence_cell, fv_laplacian_cell}`,
driving ESD `divergence_mpas`, `gradient_mpas`, and the
`mpas_l0_to_octants_sphere` regrid (`src_poly`).

**Cost today — measured at 1.00×.** The A/B is unusually clean here:

| case | with overlay | overlay disabled | speedup |
|---|---|---|---|
| `divergence_mpas` | 0.065 s | 0.065 s | **1.00×** |
| `gradient_mpas` | 0.115 s | 0.115 s | **1.00×** |
| `laplacian_mpas` | 0.216 s | 0.216 s | **1.00×** |

The overlay contributes *literally nothing* to any MPAS case. Absolute cost is
small only because the L0 test meshes are tiny (50–120 µs per observed); the
construct is the entire unstructured-mesh story, so this is a **strategic** entry
rather than a hot one.

**Fix.** A new `AxisIndex::Gather` carrying the evaluated index array, plus a
gather kernel (`result[p] = src[idx[p] − origin]`, out-of-range → the Dirichlet
ghost 0 the oracle produces). It cannot reuse the contiguous-segment copy path,
so it is a genuinely new code path — hence the difficulty rating. Note C3 below
usually co-occurs with it on the same rule, so fixing C2 alone will not
vectorize `divergence_mpas`/`laplacian_mpas` end to end; `gradient_mpas` is the
one case C2 unblocks by itself.

**Bit-identity.** An exact element copy, no arithmetic. Pinned by
`frontier_indirect_gather_falls_back`.

**Owner.** `vectorized.rs` — **not mine**. Not implemented here.

---

### #5 · C3 — ragged / derived contraction bound · **[2]/[3] boundary** · difficulty HIGH

**Construct.** A CSR neighbour sum whose per-row extent comes from an offsets
factor: `contracted: non-static contraction dim (ragged/derived): Ragged {
offsets: "nEdgesOnCell", of: ["i"] }`.

**Where it bails.** `vectorized.rs::eval_vec_contracted`, the
`ContractDim::Ragged` arm. Deliberate: a per-output-tuple extent is not a
uniform whole-array window.

**Breadth.** ESD `divergence_mpas`, `laplacian_mpas` (simulation and
convergence); in-crate `ragged_csr_miniature_through_subsystem_and_aliases`,
`ragged_index_set_drives_dynamic_reduction_bound`,
`inspection_does_not_change_the_run`. 3 of the 22 unit-suite sites, 1 of the 265
convergence units.

**Cost.** 50–120 µs per observed on the L0 meshes. Included in the 1.00× A/B
above.

**Assessment — do not treat this as a simple gap.** The whole-array analogue is
a segmented reduction: pad to the widest row and mask short rows to the
reduction identity. That is a win only when rows are near-uniform (MPAS hexes:
5–7 neighbours, so ~15 % waste — fine) and asymptotically **worse** for a
genuinely skewed set, where it does `max_row / mean_row` times the work. If it
is implemented, it should be behind a uniformity guard on the offsets factor,
and the guard is most of the work. Recommend deferring until an unstructured
model is actually hot.

**Owner.** `vectorized.rs` — **not mine**. Not implemented here, and not
recommended for implementation now.

---

### #6 · G1 — closed-registry geometry fn (`polygon_intersection_area`) · **[3]** · difficulty MEDIUM

**Construct.** `op: unsupported operator `polygon_intersection_area`/2`, from
`eval_vec_op`'s catch-all.

**Breadth.** All 8 ESD `regridding` fixtures (`A_ij`, `A_ij_dense`), 4 unit
tests, the wildfire/ocean coupled fixture (`OceanDynamics.rg_A`).

**Cost.** 12–14 ms once on `mpas_l0_to_octants_sphere`, 0.05–1.3 ms elsewhere —
and these are **build-once setup arrays** materialized through
`BuildInspection`, not per-RHS work. Each appears 2–4 times in a whole run, not
thousands.

**Assessment — negligible payoff.** Beyond the build-once cost, the operation is
inherently a per-pair geometry kernel: a "vectorized" version is the same loop
with the same S2 calls, so the overlay would buy nothing but AST-walk overhead
that is already amortized once. Leave it.

---

## 3. Category [2] — constructs correctly on the per-cell / non-overlay path

Do not propose vectorizing these.

* **The O(N) forward prefix scan.** `eval.rs::detect_prefix_scan` runs *before*
  the overlay is tried, precisely because the overlay's answer is bit-identical
  but O(N²) (an N-tuple fold of N-element arrays). `ef51292c` fixed a regression
  where the widened overlay started winning this race, and
  `forward_scan_work_grows_linearly_not_quadratically` enforces it. Confirmed
  live in `simpleclimate.esm`: `Phi_below` costs 270 µs and reports **0 node
  visits** — it never entered the overlay, by design.

* **`arrayop: body reduced to a bare whole-array view`.** The overlay must bail
  when the body reduces to a bare array read, because the per-cell oracle
  scalarizes such a body to `NaN` (`eval.rs::reduce_contraction`). Returning the
  array would *diverge* from the reference. Deliberate, and documented in situ.

* **Boolean reductions (`or` / `and`) in a contraction.** `reduce_combine_op`
  returns `None`. Never appeared anywhere in the sweep — zero demand.

* **The overlay is a net loss at very small N.** The `pde_simulation` manifest
  (N = 4…8, and one 3×3) runs **0.92×** with the overlay — i.e. ~8 % *slower*
  than with `ESS_VEC_DISABLE=1` (min of 5 reps per fixture, 8 fixtures, serial).
  That is the fixed per-node overlay overhead not yet amortized. It is not worth
  gating on grid size — the crossover is below any real model — but it means a
  micro-benchmark at toy N will mislead anyone tuning the overlay.

---

## 4. Coverage metric and why it can be trusted

**The metric.** Per rule and per observed, from the `ESS_VEC_DEBUG=1`
deepest-first bail log: `per-cell` if the rule/observed emitted a bail block,
`vectorized` otherwise, with the **first** log line taken as the root cause.

**Known defects of the instrument** (all found during this audit):

1. **Silence is ambiguous.** There is **no positive trace line** for a
   vectorized compiled rule or a vectorized `ArrayLoop` observed — only
   `AlgebraicRule::Scalar` observeds print a `vectorized` line. So "no bail
   lines" can mean *fully vectorized* or *never reached a traced call site*.
   This is why the whole sweep is cross-checked against timing below.

2. **`take_op_count()` leaks across observeds.** In `rhs.rs` it is drained only
   on the *vectorized* branch of the `[vec-obs]` print. A PER-CELL observed
   never drains, so its node visits are attributed to the **next** vectorized
   observed. Absolute "node visits" figures are only reliable in a run with no
   per-cell observeds (e.g. `simpleclimate.esm`). Draining it on both branches
   would fix this; it is a one-line change in a file this audit does not own.

3. **The prefix-scan path is reported as "vectorized".** It leaves an empty bail
   log, so the trace cannot distinguish "went through the overlay" from "was
   claimed by `detect_prefix_scan` before the overlay". The `0 node visits`
   figure is the tell (`Phi_below` in `simpleclimate.esm`).

**The `RhsStats` discrepancy, measured.** `simpleclimate.esm` at 12×7×7,
`--build-only` (first RHS evaluation at u0), same binary, overlay toggled:

```
overlay ON   rules: 4 vectorized / 0 per-cell;  observeds: 0 / 0;  127 kernel ops
             first RHS eval at u0 in 0.353 s
overlay OFF  rules: 0 vectorized / 4 per-cell;  observeds: 0 / 0;    0 kernel ops
             first RHS eval at u0 in 3.798 s
```

`observeds: 0 vectorized / 0 per-cell` **in both runs** — while 3.45 s of a
3.80 s RHS, a **10.8× swing**, lives entirely in observeds that those counters
do not see. The trace shows what `RhsStats` misses: 53 observeds, all
vectorized, six of which (`advx_*`, `advz_*`) account for ~347 ms of the 353 ms.
`kernel_ops = 127` is likewise compiled-rule-only, against ~1.09 M node visits
actually performed. **`RhsStats`'s observed counters and `kernel_ops` are
structurally blind to `AlgebraicRule::Scalar` observeds, which reach the overlay
through `eval_arrayop` rather than the counted call sites. Do not use them as a
coverage metric.**

**Independent validation — wall clock with `ESS_VEC_DISABLE=1`.** Every case the
trace calls vectorized must get materially slower with the overlay off; every
case the trace calls per-cell should be indifferent. Serial, min of 2 reps,
built binary invoked directly (a first parallel attempt produced a cluster of
~31 s readings that were pure cargo target-lock contention and were discarded):

| case | trace verdict | with overlay | disabled | speedup |
|---|---|---|---|---|
| `heat_1d_varcoeff_zero_flux` | fully vectorized | 0.215 s | 12.197 s | 56.7× |
| `latlon_advection_zonal_upwind` | fully vectorized | 0.065 s | 3.623 s | 56.1× |
| `advection_1d_periodic_superbee` | fully vectorized | 2.521 s | 76.016 s | 30.2× |
| `advection_1d_inflow_ppm` | fully vectorized | 0.717 s | 13.394 s | 18.7× |
| `advection_1d_inflow_weno5` | fully vectorized | 0.266 s | 2.421 s | 9.1× |
| `advection_2d_x_periodic_central` | fully vectorized | 0.065 s | 0.516 s | 8.0× |
| `anisotropic_diffusion_2d_periodic` | fully vectorized | 2.371 s | >400 s | >169× |
| `godunov_norm_1d_eikonal_mms` | fully vectorized | 0.065 s | 0.165 s | 2.5× |
| `divergence_mpas` | **has fallbacks** | 0.065 s | 0.065 s | **1.00×** |
| `gradient_mpas` | **has fallbacks** | 0.115 s | 0.115 s | **1.00×** |
| `laplacian_mpas` | **has fallbacks** | 0.216 s | 0.216 s | **1.00×** |

The two instruments agree on every case, and they disagree with each other
nowhere. The three cases the trace flags as falling back are exactly the three
where disabling the overlay changes nothing. Plus `simpleclimate.esm` at 10.8×
above. That is the evidence the metric is load-bearing rather than vacuous.

---

## 5. What was implemented

Only what does not touch another agent's files.

* `pkg/earthsci-ast-rs/tests/vec_coverage_frontier.rs` — **new**. Pins the
  frontier as executable fact: four `covered_*` tripwires against a silent
  narrowing of coverage during the in-flight rewrites, and three `frontier_*`
  cases (C1 clamped index, C2 indirect gather, C4 array-valued `const`) that
  assert today's fallback verdict, so implementing a gate *fails the test* and
  forces this inventory to be updated. Every case — covered and frontier alike —
  also compares the overlay result against the per-cell oracle by **raw IEEE
  bits** (`f64::to_bits`, not a tolerance) over three perturbed states, so each
  frontier fixture is already the bit-identity check for whoever implements it.
  C3 is deliberately *not* pinned there, and says why in situ.

* `tools/vec-coverage-sweep/{sweep_esd,validate_metric,timeit}.py` — **new**.
  The sweep harness, driven from *outside* the crate via the published
  `pde_conformance` example so it needs no edit to any owned file.

**Verification.** `cargo test --release`: **912 passed / 0 failed** (905
baseline + 7 new). `scripts/run-pde-simulation-conformance.py --bindings rust`:
**OK, all 8 fixtures**.

No gate was implemented, because **every gate in this inventory lives in
`pkg/earthsci-ast-rs/src/simulate_array/vectorized.rs`**, which another agent is
actively rewriting. Each entry above therefore carries the bail site, the
construct, the fix, the bit-identity argument, and a ready-made failing test, so
it can be picked up without rediscovering anything.

---

## 6. What this sweep did NOT cover

* **ESD `convergence` at fine resolution.** Only the coarsest resolution of each
  of the 101 cases was traced. A bail verdict is a property of the discretized
  expression, not of N, so this is not expected to hide a construct — but the
  fine grids were not run.
* **2 ESD simulation cases never produced a verdict:**
  `latlon3d_transport_cwc_regional_inflow` and
  `latlon3d_transport_per_tracer_inflow` timed out at the 150 s sweep budget
  before emitting a trace block.
* **1 ESD simulation case did not complete:** `duo_swe_freestream` was killed at
  900 s. Its coverage verdict *is* complete (the trace is emitted on the first
  RHS call), and it is the source of the C1/C4 cost figures — but its A/B
  speedup could not be measured, because it does not terminate either way.
* **ESD `reprojection` (2 cases) and `ast` (135 cases)** were not swept:
  neither category runs a time integration, so neither reaches a traced call
  site.
* **`EarthSciModels`** was not swept at all. It was listed as a sibling checkout
  in scope; no simulable manifest was identified in it within the time budget,
  and the ESD + `simpleclimate` corpora were judged the higher-value targets.
  This is the largest known blind spot.
* **Julia and Python bindings** are out of scope — this audit is about the Rust
  overlay only.
* **`force_scalar` was used as the oracle** in `vec_coverage_frontier.rs`. That
  is sound *only* because every fixture there is rule-shaped; it is documented
  in situ, and `ESS_VEC_DISABLE=1` was used for every observed-shaped
  measurement (`simpleclimate.esm`, all ESD A/B timings).
