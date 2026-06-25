# Cross-Language PDE-Simulation Conformance (ess-fmw)

The **simulation** analogue of the byte-identity conformance gates. Where the
rewrite/IR tiers assert canonical-JSON **byte-identity** across five bindings,
this tier asserts that the three **PDE-simulation-capable** bindings — **Julia
(reference), Python, and Rust** — agree, on a **numeric-tolerance** basis, on:

1. the **discretized method-of-lines RHS** `f(u, t)` evaluated at fixed probe
   states (catches discretization/evaluation divergence directly, independent of
   the integrator), and
2. the **integrated trajectory** to a fixed horizon (catches integrator/stepper
   divergence), compared both **across bindings** (against the Julia golden) and
   against the **exact matrix-exponential / manufactured solution**.

> ⛔ **Numeric-tolerance, NOT byte-identical.** Trajectories are floating-point
> evaluation that legitimately differs in the last bits across language math
> libraries and integrators. Do **not** attempt byte-identity on simulation
> output. The integrator + step controls are pinned per binding in
> `manifest.json` so the trajectory comparison is apples-to-apples.

## Fixtures

Each fixture is a **pre-discretized** ESM document: the spatial operator is
already lowered to a full-grid `arrayop` whose body is
`index(makearray(regions, values), …)` — the same form the
`tests/fixtures/arrayop/15,16` heat fixtures use. Boundary-cell stencils live in
dedicated single-cell `makearray` regions, so the **BC ghost / makearray path**
is conformance-checked, not just the interior stencil.

| Fixture | Operator | Grid | BC kind | Notes |
|---------|----------|------|---------|-------|
| `diffusion_1d_dirichlet_n4` | 1-D heat | 4 | dirichlet | ghost = 0 |
| `diffusion_1d_neumann_n4` | 1-D heat | 4 | neumann | constant-flux ghost (inhomogeneous `b`) |
| `diffusion_1d_zero_gradient_n4` | 1-D heat | 4 | zero_gradient | mirror ghost (∂u/∂n = 0) |
| `diffusion_1d_robin_n4` | 1-D heat | 4 | robin | ghost = α·u + β |
| `diffusion_1d_periodic_n4` | 1-D heat | 4 | periodic | wrap u[0]→u[N], u[N+1]→u[1] |
| `diffusion_1d_periodic_n8` | 1-D heat | 8 | periodic | **second grid size** (no-scalarization / shape generality) |
| `diffusion_2d_dirichlet_n3` | 2-D heat | 3×3 | dirichlet | implicit zero ghost (neighbour-coupled stencil) |
| `advection_1d_periodic_n4` | 1-D advection | 4 | periodic | upwind first-derivative stencil |

This covers all five BC kinds, 1-D + 2-D diffusion, 1-D advection, and one
operator at two grid sizes — the full coverage matrix for the spatial machinery.

The fixtures and the `manifest.json` are produced by
`scripts/gen_pde_sim_fixtures.py`, which also assembles each operator as an
explicit matrix `L` (+ constant vector `b`), `du/dt = L u + b`, the source of the
**independent** analytic anchors:

* `analytic_rhs = L u + b` for each probe state, and
* `analytic_trajectory = expm(L t)·u0 + (∫₀ᵗ expm(L s) ds)·b` (Van Loan
  augmented form, exact even for the singular pure-Neumann / periodic operators).

## Adapter contract

Each binding ships a thin adapter discovered by the runner via
`$EARTHSCI_PDE_SIM_ADAPTER_<BINDING>` (or on PATH as
`earthsci-pde-sim-adapter-<binding>`):

```
adapter --manifest <manifest.json> --output <out.json>
```

It loads every fixture and writes, for each, the RHS at each declared probe and
the trajectory at each declared output time, keyed by the **bare** element name
(`u[1]`, `u[2,3]`, … — column-major; the `Model.` namespace is stripped):

```json
{
  "binding": "<name>",
  "fixtures": {
    "<id>": {
      "rhs":        { "<probe_id>": { "u[1]": <f64>, ... } },
      "trajectory": { "<time>":     { "u[1]": <f64>, ... } }
    }
  }
}
```

| Binding | RHS hook | Trajectory hook | Adapter |
|---------|----------|-----------------|---------|
| Julia (reference) | `build_evaluator` → `f!(du,u,p,t)` (tree-walk) | `ODEProblem` + `Tsit5` | `packages/EarthSciSerialization.jl/scripts/pde_simulation_adapter.jl` |
| Python | `earthsci_toolkit.evaluate_rhs` (NumPy interpreter) | `simulate` (SciPy `solve_ivp`) | `packages/earthsci_toolkit/.../cli/pde_simulation_adapter.py` |
| Rust | `ArrayCompiled::debug_eval_rhs` (vectorized) | `simulate` (diffsol) | `packages/earthsci-toolkit-rs/src/bin/earthsci-pde-sim-adapter-rust.rs` |

## Tolerances (manifest `tolerances`)

| Band | rtol | atol | Applies to |
|------|------|------|------------|
| `rhs_*` | 1e-9 | 1e-11 | RHS vs golden **and** vs analytic `L u + b` (pure arithmetic — tight) |
| `traj_golden_*` | 1e-6 | 1e-9 | trajectory vs the Julia golden (cross-binding) |
| `traj_analytic_*` | 1e-4 | 1e-6 | trajectory vs `expm(Lt)` (absorbs integrator truncation) |

## Pinned integrators (manifest `integrators`)

| Binding | Algorithm | reltol | abstol |
|---------|-----------|--------|--------|
| Julia | `Tsit5` | 1e-10 | 1e-12 |
| Python | `RK45` (`solve_ivp`) | 1e-10 | 1e-12 |
| Rust | `Erk` (diffsol Tsitouras 5(4)) | 1e-10 | 1e-12 |

## Scope

**Go and TypeScript are excluded.** They implement only the rewrite half (no
`makearray`/spatial lowering, no simulator) and cannot run PDEs. Extending this
tier to them would first require their own PDE-simulation tiers (a future
extension, explicitly out of scope here).

## Running

```bash
# Always-on regression guard: committed Julia golden vs the independent
# analytic anchors + negative controls (no live bindings needed).
python3 scripts/run-pde-simulation-conformance.py --self-test

# Full cross-binding gate (drives Julia/Python/Rust adapters):
./scripts/test-conformance.sh            # runs the three producers + self-test

# Regenerate the Julia-reference goldens (e.g. after changing a fixture):
EARTHSCI_PDE_SIM_ADAPTER_JULIA="julia packages/EarthSciSerialization.jl/scripts/pde_simulation_adapter.jl" \
  python3 scripts/run-pde-simulation-conformance.py --write-golden --bindings julia
```

The suite **fails loudly** (non-zero exit) if any in-scope binding diverges
beyond tolerance — the regression guard that keeps the three PDE simulators from
drifting apart. See `CONFORMANCE_SPEC.md` §5.9.
