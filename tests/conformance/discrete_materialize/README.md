# Discrete-Cadence Materialization Conformance (`tests/conformance/discrete_materialize/`)

Cross-language conformance for **discrete-cadence materialization** — the *middle*
cadence phase of the `const ⊏ discrete ⊏ continuous` partition. Governed by
**CONFORMANCE_SPEC.md §5.13**.

A state-free array observed that mixes a **CONST** weight with a **DISCRETE**
forcing field is neither build-once (it changes when the forcing refreshes) nor
per-continuous-step (it changes only at cadence *boundaries*). It materializes
**once per refresh**: a materializing binding caches it and gathers it into the
hot RHS; a re-evaluating binding recomputes it once per segment with the forcing
frozen. Both must land the same trajectory.

This set is the **discrete** sibling of two neighbours:

* **§5.12 build-once spatial field** (`tests/conformance/build_once_spatial_field/`)
  — the **CONST** tier of the same materialize ⇄ gather seam: a field derived
  once at setup and gathered into an ODE. No refresh.
* **§5.10 refresh path** (`tests/conformance/refresh/`) — the full
  loader → **regrid** → refresh capstone. Providers, a non-identity conservative
  remap, cadence boundaries from a loader's `temporal` block.

§5.13 sits between them: it keeps the **discrete refresh** of §5.10 but drops the
regrid (`src` is delivered directly on the sim index) and the provider/loader
stack (the adapter drives the segments from offline snapshots), isolating the
**const-vs-discrete cadence classification inside a contraction**.

## The fixture

Model `M` over `j ∈ [1,3]`, `i ∈ [1,2]` (dense ranges, no `index_sets`):

| Var | Kind | Expression | Cadence |
|-----|------|------------|---------|
| `W` | observed | `const` `[[1,2,3],[4,5,6]]` | CONST (build-once) |
| `offset` | parameter | `1.0` | CONST |
| `src` | *(undeclared forcing name)* | — | **DISCRETE** (refreshed at anchors) |
| `g` | observed | `sum_i W[i,j]·src[i]` | **DISCRETE** — const × forcing |
| `k` | observed | `sum_i W[i,j]·offset` | CONST — const × parameter |
| `c` | state | `D(c[j]) = g[j] + k[j]` | continuous |

`g` is the **contraction that must materialize discretely** (it reads the live
forcing `src`); `k` is the **regression guard** — same contraction shape but
forcing-free, so it MUST stay CONST-cadence and never become a per-refresh cache.

## Layout

| File | What it is |
|------|------------|
| `manifest.json` | Fixture list, tolerances, pinned integrators, required bindings. |
| `fixtures/discrete_materialize_contraction.esm` | The shared model (above). |
| `golden/discrete_materialize_contraction.json` | The analytic golden. |

Strictly **offline** — `src` is written from the golden's `forcing.by_anchor`
snapshots; no network, no file I/O.

## The golden

The DISCRETE forcing is **piecewise-constant** across the cadence segments, so
everything is closed-form and exact:

* `forcing.by_anchor` — the `src[i]` snapshot at each `refresh_times` anchor
  (`0.0 → [1,1]`, `1.0 → [2,3]`, `2.0 → [3,5]`). Distinct paired values make the
  contraction load-bearing: a **stale** (un-refreshed) `src` yields a visibly
  wrong slope.
* `discrete_field.M.g` — `g` re-materialized at each anchor (the discrete cache
  contents): `[5,7,9]`, `[14,19,24]`, `[23,31,39]`.
* `const_field.M.k` — `[5,7,9]`, refresh-invariant.
* `trajectory` — the segmented integral of `D(c[j]) = g[j] + k[j]`. With the
  rate `r_k = g_k + k` frozen per unit segment, `c` accumulates piecewise-linearly
  to `[10,14,18]`, `[29,40,51]`, `[57,78,99]` at `t = 1, 2, 3`.

## Adapter contract

For the fixture, each binding:

1. Loads + flattens; asserts `W`/`g`/`k` are observeds and `c` is the only state.
2. Drives a **segmented solve** over the `refresh_times` anchors ∩ `tspan`,
   writing `src` from `forcing.by_anchor` at each boundary (forcing frozen within
   a segment → RHS pure) and threading state across segments.
3. **Asserts** the **trajectory band** — each segment-boundary `M.c[j]` equals
   `golden.trajectory` within `traj_rtol` / `traj_atol`.

Julia **additionally** asserts the **field band** — the `DiscreteMaterializer`
caches `g` (not `k`) and its cache equals `golden.discrete_field` at each anchor
within `field_rtol` / `field_atol` — because it is the binding with the explicit
discrete-materialization cut. Python and Rust have no separate cache pass: they
re-materialize the state-free `g` at each segment's RHS build (forcing frozen), so
the numeric result matches Julia's materialized path.

Each binding uses its own forcing primitive to write `src` (key `M.src`):

| Binding | Forcing primitive | Segment drive |
|---------|-------------------|---------------|
| Julia | `build_evaluator(…; param_arrays)` + `DiscreteMaterializer` | ONE `solve` over `build_refresh_callback` whose `post_refresh = dm.materialize!` fires per anchor |
| Python | `_simulate_with_numpy(…, loader_arrays=…)` (`input_arrays` seam) | manual per-segment loop |
| Rust | `ArrayCompiled::forcing_handle()` | manual per-segment loop |

## Tolerances

From `manifest.json` (`tolerances`); see §5.13.

| Band | rtol | atol |
|------|------|------|
| Discrete-cache / const field (vs analytic) | 1e-9 | 1e-11 |
| Integrated trajectory (vs analytic) | 1e-4 | 1e-6 |

The field band is tight (a contraction on exact integer weights is exact up to
floating-point); the trajectory band absorbs integrator truncation, matching the
§5.10 / §5.12 bands.

## Bindings

`bindings_required` is `["julia", "python", "rust"]` — all three simulation
bindings reproduce the golden. Go and TypeScript are out of scope (rewrite-only
ports; no array/ODE simulator).

## Runners

* **Julia** — `packages/EarthSciSerialization.jl/test/discrete_materialize_conformance_test.jl`
* **Python** — `packages/earthsci_toolkit/tests/test_discrete_materialize_conformance.py`
* **Rust** — `packages/earthsci-toolkit-rs/tests/discrete_materialize_conformance.rs`
