# `pde_simulation_pipeline` conformance

Cross-binding conformance for **full-pipeline** PDE simulations — the class of
fixtures the existing [`pde_simulation`](../pde_simulation/) set can't cover.
See [`DESIGN.md`](DESIGN.md) for the full contract; this README is the Phase 0
status.

## What this category is

`pde_simulation` fixtures are self-contained, linear, and already discretized,
so each carries a matrix-exponential analytic anchor. The driver fixture here —
[`advection_reaction_loaded_ic_bc`](../../valid/advection_reaction_loaded_ic_bc.esm)
— breaks all three assumptions:

- **loaded data**: initial fields, per-species western inflow BCs, and wind
  arrive through data loaders (injected via each binding's data-**Provider** seam
  from the manifest `inputs`, never as raw internal-name constants — DESIGN §2);
- **nonlinear**: mass-action `k1·NO·O3` chemistry, so **no matrix-exponential
  trajectory exists**;
- **full lowering**: reaction-gen → template `match` → `operator_compose` →
  pointwise-lift → scoped-`ic` must all run before an RHS exists.

The physical system: 3 species (O3, NO, NO2) on a 4×2 `[lon,lat]` grid (24
states). Per cell, the 0-D O3–NOx mass-action reactions (`k1=0.018`,
`jNO2=0.005`) plus a per-species longitudinal advection `−u_wind·grad`, with the
fixture's `grad_lon_inflow` stencil (west-face Dirichlet from the loaded
`*_inflow`, interior central difference, east-face one-sided; `dx=100`).

## The independence rule (critical)

The reference layer in [`reference/reference_integrator.py`](reference/reference_integrator.py)
re-implements the discretized 24-state RHS **from the fixture's declared math
only** — its `Chemistry` reactions/parameters and the `Advection`
`grad_lon_inflow` template regions. It does **not** read, import, or mirror any
binding's evaluator (Julia `flatten.jl`/`tree_walk.jl`/`simulate*.jl`, or the
Python/Rust flatten/simulate modules). That independence is the point: it is the
anchor each binding's RHS and trajectory are gated against, so a shared bug in
the bindings cannot hide behind a shared reference.

It does double duty (DESIGN §5):
1. `rhs(u, t)` at each probe state **is** that probe's `analytic_rhs`;
2. integrated tightly (hand-rolled adaptive DOPRI5, `rtol=1e-11`, `atol=1e-13`,
   numpy-only) to the checkpoints, it is the `trajectory.reference` anchor.

## Gate G0 status: **PASS**

The reference integrator reproduces the fixture's committed inline `tests`
values (`0 → 600 s`) within the design band (abs `1e-4` / rel `1e-5`); every
element matched to abs error ≤ ~1e-11:

| element | t | committed | max abs err |
|---|---|---|---|
| O3[1,1]  | 600 | 34.797506781720664  | ~2e-13 |
| O3[4,2]  | 600 | 35.66089795504217   | ~8e-12 |
| NO[1,1]  | 600 | 0.01641470334161223 | ~6e-13 |
| NO2[1,1] | 600 | 1.6832850160453867  | ~4e-13 |
| NO2[3,1] | 600 | 1.7093366875798413  | ~4e-13 |

(t=0 assertions are the loaded ICs and match exactly.) The hand-rolled DOPRI5
and a scipy `RK45` cross-check agree with each other and with the committed
numbers, so both the committed values and the discretization are confirmed
correct. Regenerate / re-check with:

```bash
python reference/reference_integrator.py   # prints Gate G0 table, rewrites the reference JSON
```

## Files (Phase 0)

- `DESIGN.md` — the design contract (pre-existing).
- `reference/reference_integrator.py` — the independent, numpy-only reference:
  `STATE_ORDER`, `rhs(u,t)`, `u0()`, `analytic_rhs(state)`,
  `trajectory(checkpoints)`; run as a script to regenerate the JSON and print
  Gate G0.
- `reference/advection_reaction_loaded_ic_bc.json` — committed reference:
  `state_order`, three `rhs_probes` (loaded u0, constant field, lon ramp) each
  with `analytic_rhs`, and `trajectory.reference` at checkpoints `[0.0, 600.0]`.
- `manifest.json` — draft manifest (one fixture, `pipeline:"full"`, the `inputs`
  provider dataset, `state_order`, inline `rhs_probes`, `trajectory`
  checkpoints + reference pointer, `golden` placeholder). Same top-level shape as
  `../pde_simulation/manifest.json`.

## Not yet done (later phases)

Additive, non-breaking scaffold only. Deferred:

- **Fixture placement/migration** (DESIGN §3): the driver fixture currently lives
  at `tests/valid/advection_reaction_loaded_ic_bc.esm` (referenced by the
  manifest's `source_fixture`); the loader→consumer binding completion and its
  placement under `fixtures/` (the manifest's `path`) are Phase 1/2.
- **Adapters** (`pipeline:"full"` path in each `earthsci-pde-sim-adapter-*`),
  **golden** regeneration (`golden/advection_reaction_loaded_ic_bc.json`), and
  **`test-conformance.sh`** wiring — all Phase 2 (DESIGN §7–§10).
