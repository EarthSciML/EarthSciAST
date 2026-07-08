# Build-Once Spatial-Field Consumption Conformance (`tests/conformance/build_once_spatial_field/`)

Cross-language conformance for a **build-once spatial field** that is
materialized **once at setup** (a `const`-derived array — regridded and/or
differentiated) and then **consumed elementwise by an ODE**. Governed by
**CONFORMANCE_SPEC.md §5.12**.

This set pins the two paths the terrain-regrid coupling
(`wildlandfire.esm` → `TerrainRegrid`) surfaced in the Julia runner:

```
area[c]  = polygon_intersection_area(poly[c], poly[c], planar)   # build-once geometry leaf  -> [10,30,60]
darea    = D_c(area)                                              # build-once makearray STENCIL (Gap 1)
D(u[c])  = darea[c] - u[c],  u(0)=0                               # ODE gathers darea per cell (Gap 2)
```

1. **Gap 1 — setup materialization of a non-aggregate array op.** The build-once
   `darea` is a `makearray` (the periodic centered-difference stencil a
   discretization rule lowers `D` to): an interior region plus two periodic-face
   regions, each a nested central-difference aggregate over `area`, divided by
   `2·dx`. A `makearray` (and a `reshape`) carries no `output_idx`/`ranges`, so
   the setup-time materializer must evaluate it per output cell through the same
   build-time array pipeline the ODE RHS uses for `index(makearray, …)` — not
   only the aggregate (`output_idx`) form.
2. **Gap 2 — build-once array crossing into the ODE RHS.** `area` and `darea`
   are build-once functions of the const geometry, so they are materialized at
   setup into const arrays; the per-cell ODE then references `index(darea, c)`,
   which must resolve against the setup-registered const-array registry.

With `dx = 1` the difference is `darea = [(30-60)/2, (60-10)/2, (10-30)/2] =
[-15, 25, -10]`, so `u_c(t) = darea_c (1 - e^-t)` is analytic and network-free.

## Why this fixture exists

The other geometry/loader fixtures cover neighbouring pieces but not this one:

| Fixture set | Covers | Does NOT cover |
|-------------|--------|----------------|
| `tests/conformance/geometry/` | build-once conservative-regrid **areas** | a downstream **makearray** `D`, an **ODE** consuming the field |
| `tests/conformance/subsystem_loader/` | bind a CONST **loader** field consumed bare/gather | **geometry**, build-once **makearray**, setup materialization |
| **this** | build-once **makearray** at setup + build-once array **gathered into an ODE** | (the composed path) |

## Layout

| File | What it is |
|------|------------|
| `manifest.json` | Fixture list, tolerances, pinned integrators, required/excluded bindings. |
| `fixtures/build_once_spatial_ode.esm` | The shared model `Field`: const `poly` rings → `area` (pia) → `darea` (makearray) → ODE `D(u)=darea-u`. |
| `golden/build_once_spatial_ode.json` | The analytic golden: the setup fields `area`/`darea` and the integrated trajectory. |

Strictly **offline** — no providers, no network, no file I/O.

## Adapter contract

For the fixture, a binding's adapter:

1. Loads and flattens the fixture; asserts `Field.area` and `Field.darea` are
   observeds with no ODE slot (materialized/inlined, not integrated states).
2. Integrates `D(u[c]) = darea[c] - u[c]`, u(0)=0 over `golden.cadence.tspan`
   with the pinned integrator.
3. **Asserts** each golden `trajectory` time-point's `Field.u[c]` within
   `traj_rtol` / `traj_atol`. Julia additionally asserts the materialized
   `setup_fields` (`Field.area = [10,30,60]`, `Field.darea = [-15,25,-10]`) via
   `BuildInspection`.

Per-binding runners:

* **Julia** — `pkg/EarthSciAST.jl/test/build_once_spatial_field_conformance_test.jl`
* **Python** — `pkg/earthsci-ast-py/tests/test_build_once_spatial_field_conformance.py`
* **Rust** — `pkg/earthsci-ast-rs/tests/build_once_spatial_field_conformance.rs`

## Bindings

`bindings_required` is `["julia", "python", "rust"]`. Julia was the binding the
two gaps were fixed in (setup-materializer + const-array crossing); Python and
Rust already evaluate `polygon_intersection_area` + `makearray` + array-ODE
end-to-end, resolving the build-once field at the RHS rather than at a separate
setup pass (so the numeric result is identical to Julia's setup-materialized
path). Rust drives the composed path through its `simulate_array` runtime — the
geometry-leaf aggregate, the `makearray` boundary-region stencil, and the array
ODE's per-cell `index(darea, c)` gather — with no source changes required to
enable it.

## Tolerances

From `manifest.json` (`tolerances`); the trajectory band matches §5.9/§5.10/§5.11's
manufactured-solution band, absorbing integrator truncation.

| Band | rtol | atol |
|------|------|------|
| Integrated trajectory (vs analytic) | 1e-4 | 1e-6 |
