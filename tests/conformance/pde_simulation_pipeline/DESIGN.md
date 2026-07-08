# Conformance for pre-discretization + data-loader PDE simulations

**Status:** Phase 0 contract (design). Drives the Python/Rust/Julia alignment
work and the harness build. Sibling to `tests/conformance/pde_simulation/`
(which stays untouched).

## 1. Why a new category

The existing `pde_simulation` golden set assumes fixtures that are (a)
**self-contained** — no data loaders, BCs baked into `makearray` as constants;
(b) **linear** — so each carries an independent analytic anchor: `analytic_rhs =
L·u + b` per probe and a **matrix-exponential** `trajectory.analytic`; (c)
**already discretized** — the adapters evaluate a compiled `makearray` RHS and
integrate, doing no lowering.

`advection_reaction_loaded_ic_bc.esm` breaks all three: it needs loaded fields
(ICs, per-species inflow BCs, wind), it is **nonlinear** (mass-action `k1·NO·O3`
— no matrix-exponential exists), and it must run the **full pipeline**
(reaction-gen → template `match` → `operator_compose` → pointwise-lift →
scoped-`ic`) before an RHS exists. This category is that class.

## 2. The provider-injection contract (the core design)

Loaded data enters **only** through each binding's existing data-**Provider**
seam — never as raw `const_arrays` keyed by internal consumer names. The harness
installs a **static stub provider** that serves the fixture's *declared* loader
variables from the manifest's committed arrays; the binding's normal resolution
then binds loader outputs to consumer parameters and folds scoped-`ic` fields
into u0. This exercises the real loader path.

Per-binding seam (all already exist):

| Binding | Stub seam | Build-time reach for scoped-`ic` |
|---|---|---|
| Python | `simulate(..., loader_provider=stub)` where `stub: (LoaderField, t) -> ndarray` (or a `provider_factory`) | ic-resolver reads the seeded `loader_arrays` registry at u0 build (seed already runs at t0) |
| Julia | a stub object satisfying `provider_sample(p,t)` / `provider_is_const(p)` / `provider_refresh_times(p)` returning the manifest arrays | `_resolve_field_ic` reads the provider-seeded field instead of a raw `const_arrays` entry |
| Rust | a `CadenceProvider` impl (`provider.rs`) returning the manifest arrays into the forcing buffer | new build-time channel: ic-resolver pulls the seeded field before `ArrayCompiled::simulate` |

**Requirement R1.** Every loaded field the model consumes is served by the stub
provider from the manifest `inputs`. No field may be injected by internal
consumer name. This includes the Julia reference path (it migrates off
`const_arrays`).

**Requirement R2.** The provider must be reachable at **build time** so
scoped-`ic` can fold `InitialConditions.*` into u0 before integration.

## 3. Fixture completion (loader → consumer bindings)

The fixture currently declares `data_loaders` but only the scoped-`ic`
equations reference a loader symbol (`InitialConditions.O3_init`); `u_wind` and
`*_inflow` are plain parameters filled by the test. To make provider injection
honest, every loaded input must resolve from its declared loader:

- `Meteorology.u_wind` → `Advection.u_wind`
- `BoundaryConditions.{O3,NO,NO2}_inflow` → `Advection.{…}_inflow`
- `InitialConditions.{O3,NO,NO2}_init` → scoped-`ic` RHS (already done)

Use the **spec-canonical loader→consumer binding** (esm-spec §11.5 "BCs from
data" and the data-loader coupling mechanism — a producer-symbol reference /
coupling edge, *not* a name coincidence). Model equations keep reading the local
parameter names; the binding is declared. The migrated fixture must still pass
its inline `tests` block byte-for-byte (same 21/21 values).

## 4. Manifest schema (`pde_simulation_pipeline/manifest.json`)

Same top-level shape as `pde_simulation/manifest.json`, plus per fixture:

```jsonc
{
  "id": "advection_reaction_loaded_ic_bc",
  "path": "fixtures/advection_reaction_loaded_ic_bc.esm",
  "pipeline": "full",                    // NEW: run the full lowering pipeline
  "inputs": {                             // NEW: the stub-provider dataset,
    "InitialConditions.O3_init":  [[38,42],[39,43],[41,45],[43,47]],
    "InitialConditions.NO_init":  [[0.10,0.12],[0.11,0.13],[0.09,0.14],[0.12,0.15]],
    "InitialConditions.NO2_init": [[1.0,1.2],[1.1,1.3],[0.9,1.4],[1.2,1.5]],
    "Meteorology.u_wind":         [[2.0,2.2],[2.1,2.3],[2.2,2.4],[2.3,2.5]],
    "BoundaryConditions.O3_inflow":  [35.0, 36.0],
    "BoundaryConditions.NO_inflow":  [0.20, 0.25],
    "BoundaryConditions.NO2_inflow": [1.5, 1.6]
  },
  "state_order": ["O3[1,1]", "..."],     // flattened element order
  "rhs_probes": [ { "id": "...", "t": 0.0, "state": {...},
                    "analytic_rhs": {...} } ],   // from the reference integrator §5
  "trajectory": {
    "checkpoints": [0.0, 600.0],          // = the fixture's inline `tests` times
    "reference": "reference/advection_reaction_loaded_ic_bc.json"  // NEW §5
    // NOTE: no "analytic" (matrix-exp) — nonlinear; see §6
  },
  "golden": "golden/advection_reaction_loaded_ic_bc.json"
}
```

Keys in `inputs` are `"<Loader>.<variable>"` exactly as declared in the
fixture's `data_loaders` — the stub provider maps `LoaderField -> array` from
this table. `[lon,lat]` arrays are row=lon, col=lat.

## 5. Independent reference integrator (the strong anchor)

A standalone, dependency-light integrator (NumPy + `scipy.integrate` allowed)
that hardcodes **this system's** discretized 24-state RHS *derived from the
fixture's declared math, NOT from any binding's evaluator source*:

- 3 species × (4×2) cells; per cell the mass-action reactions
  `D(O3)=−k1·NO·O3+jNO2·NO2`, `D(NO)=−k1·NO·O3+jNO2·NO2`,
  `D(NO2)=+k1·NO·O3−jNO2·NO2`;
- plus per-species lon advection `−u_wind·grad`, with the fixture's stencil:
  interior central difference, west face (i=1) Dirichlet from the loaded
  `*_inflow[j]`, east face (i=4) one-sided; `dx=100`.

It lives in the runner as `run-pde-simulation-conformance.py`'s reference layer
(or a small importable module). It does **double duty**:
1. its RHS `f(u,t)` evaluated at each probe state **is** the probe's
   `analytic_rhs` (independent of all bindings);
2. integrated tightly to the checkpoints, it is the independent
   `trajectory.reference` anchor.

**Gate G0 (de-risk):** the reference integrator must reproduce the fixture's
committed inline `tests` values (O3[1,1]=34.7975…, etc.) within
`traj_analytic` tol *before* any port work starts. A mismatch means the
committed numbers are wrong — fix that first.

## 6. Anchoring policy for this category

- **RHS:** tight (`rhs_rtol=1e-9`, `rhs_atol=1e-11`) vs the reference
  integrator's `analytic_rhs` — required for every probe.
- **Trajectory:** each binding gated against **both** (a) the Julia golden
  (`traj_golden`) and (b) the independent `trajectory.reference`
  (`traj_analytic` band — absorbs integrator differences). No matrix-exponential
  `analytic` (impossible; nonlinear).
- The runner treats absent `trajectory.analytic` + present `trajectory.reference`
  as this category's sanctioned mode.

## 7. Adapter I/O contract

Each `earthsci-pde-sim-adapter-<binding>` gains a `pipeline:"full"` path: given
`{fixture_path, inputs, rhs_probes, checkpoints}` it MUST
1. install a stub provider from `inputs` (§2),
2. run the full flatten+lift+scoped-`ic` pipeline (no pre-discretized shortcut),
3. emit `rhs[probe_id] -> {element: value}` at each probe state and
   `trajectory[checkpoint] -> {element: value}` — same element naming/order as
   `state_order`.

Existing linear fixtures keep the `pipeline:"discretized"` (default) path
untouched.

## 8. Runner extensions (`run-pde-simulation-conformance.py`)

Small, additive:
- pass `inputs` + `pipeline` through to adapters;
- accept `trajectory.reference` and gate against it (`traj_analytic` band)
  alongside the golden;
- allow absent `trajectory.analytic` when `trajectory.reference` is present;
- `--self-test` also runs Gate G0 (reference integrator vs committed inline
  `tests`), and a negative control (perturbed trajectory must fail).
- new `test-conformance.sh` hooks: `run_pde_pipeline_conformance_{self_test,
  julia,python,rust}` (self-test always; producers `bindings_required`).

## 9. Per-binding work (Phase 1) — symmetric

Front half (reaction lowering, template `match`, `operator_compose` merge,
integrate entry) already exists in all three. Missing everywhere:

- **pointwise-lift** — array-ify the merged 0-D reaction+advection ODEs onto the
  grid (`_apply_pointwise_lift!` analogue). Julia ✓; Python (flatten.py, MED);
  Rust (flatten.rs, LARGE).
- **scoped-`ic` field fold via provider** — resolve `ic(Sys.sp) ~ Loader.var`
  by reading the provider-seeded field into u0 per cell. Julia ✓ (but migrate
  from `const_arrays` to provider); Python (flatten.py+simulation.py, LARGE);
  Rust (flatten.rs+simulate_array.rs, LARGE).
- **build-time provider reach** (§2 R2) + stub provider in the adapter.

Gate per binding: reproduce the fixture's inline `tests` (21/21) through the
provider path.

## 10. Phasing

- **Phase 0** (this doc): contract + reference integrator + fixture completion +
  manifest/runner scaffolding + Gate G0.
- **Phase 1** (3 parallel agents): align Julia/Python/Rust on provider-based
  pointwise-lift + scoped-`ic`; each passes the inline `tests`.
- **Phase 2**: adapters to the §7 contract; add manifest entry; regenerate Julia
  golden (`--write-golden`); wire `test-conformance.sh`.
- **Phase 3**: cross-binding gate green (RHS vs reference; trajectory vs golden +
  reference); no regressions.
