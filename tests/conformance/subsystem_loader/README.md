# Subsystem-Loader Consumption Conformance (`tests/conformance/subsystem_loader/`)

Cross-language conformance for a **pure-I/O data loader mounted as a model
subsystem** and consumed by the **owning model's own equations** (RFC
`pure-io-data-loaders` §4.3). Governed by **CONFORMANCE_SPEC.md §5.11**.

This set pins the lowering + binding the flattener and simulator must perform
when a loader is a subsystem of the model that reads it:

```
models.Box.subsystems.raw = <DataLoader>          # loader mounted as a subsystem
Box.equations: D(c) = (raw.k + wind[2]) - c       # owner consumes raw.k (bare) and raw.wind (gather)
                                                  #   raw.k    -> observed  Box.raw.k    (bare-scalar consumption)
                                                  #   raw.wind -> observed  Box.raw.wind (gather consumption)
```

Each in-scope binding lowers the two loader variables to const-array-backed
observeds `Box.raw.k` / `Box.raw.wind` (Python also records a `LoaderField`;
Julia keys them for the provider / `const_arrays` seam), seeds one **offline**
CONST provider per field from the golden's `loaders[*].native`, and integrates
`D(c) = (raw.k + wind[2]) - c`, c(0)=0. With `k=2`, `wind[2]=5` the forcing
`F = 7` is constant, so `c(t) = 7 (1 - e^-t)` is analytic and exact.

## Why this fixture exists

The other loader fixtures only cover **top-level** `data_loaders` /
**variable_map-coupled** subsystem loaders consumed via a **gather** (see
`tests/valid/advection_reaction_loaded_ic_bc.esm` and
`packages/earthsci_toolkit/tests/fixtures/loader_injection/loader_consumer.esm`).
Neither exercises a **subsystem-mounted** loader consumed **directly by the
owning model** — and in particular neither exercises a **bare-scalar** reference
`raw.k` (as opposed to an `index(...)` gather). That direct path was the
`E_TREEWALK_UNBOUND_VARIABLE: <owner>.<subkey>.<var>` gap in the Julia runner and
a 2-part-reference structural-validation gap in Python; this fixture locks both.

## Layout

| File | What it is |
|------|------------|
| `manifest.json` | Fixture list, tolerances, pinned integrators, required/optional/excluded bindings. |
| `fixtures/subsystem_loader_ode.esm` | The shared model: `Box` mounts a static (CONST) loader `raw` (vars `k`, `wind`) and consumes `raw.k` bare + `index(raw.wind, 2)`. |
| `golden/subsystem_loader_ode.json` | The analytic golden: offline native loader values, the constant forcing, and the integrated trajectory. |

Strictly **offline** — providers are seeded from the golden's `loaders[*].native`;
no network, no file I/O.

## Adapter contract

For the fixture, a binding's adapter:

1. Loads the fixture and flattens it, asserting each loader variable lowered to
   an observed named `Box.raw.<var>` with **no defining equation**.
2. Seeds one **offline CONST provider** per loader field from
   `golden.loaders[*].native` (Julia: `providers = Dict("Box.raw.k"=>…, "Box.raw.wind"=>…)`;
   Python: a `loader_provider(field, t)` dispatching on `field.var`).
3. Integrates over `golden.cadence.tspan` with the pinned integrator.
4. **Asserts** each golden `trajectory` time-point's `Box.c` within
   `traj_rtol` / `traj_atol`.

Per-binding runners:

* **Julia** — `packages/EarthSciSerialization.jl/test/subsystem_loader_conformance_test.jl`
* **Python** — `packages/earthsci_toolkit/tests/test_subsystem_loader_conformance.py`
* **Rust** — `packages/earthsci-toolkit-rs/tests/subsystem_loader_conformance.rs`

## Bindings

`bindings_required` is `["python", "julia", "rust"]`. Rust's flattener now lowers
a DataLoader mounted as a model subsystem: `flatten.rs`
(`lower_loader_subsystems`) turns each loader variable into a const-array-backed
observed `Box.raw.<var>` with **no defining expression**, and namespaces the
owner's bare `raw.<var>` references (`raw.k`, `raw.wind`) to `Box.raw.<var>`.
Both then resolve at the RHS through the same data-Provider **forcing seam** the
top-level-loader fixtures use (`ArrayCompiled::forcing_handle`): a bare-scalar
field is seeded as a 0-D forcing array (read back as a scalar), a gathered field
as a 1-D array. Go/TypeScript stay excluded (rewrite-only ports, no array
simulator).

## Tolerances

From `manifest.json` (`tolerances`); the trajectory band matches §5.9/§5.10's
manufactured-solution band, absorbing integrator truncation.

| Band | rtol | atol |
|------|------|------|
| Integrated trajectory (vs analytic) | 1e-4 | 1e-6 |
