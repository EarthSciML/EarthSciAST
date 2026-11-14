# Upstream gap — `earthsci-ast-rs` ODE solver hangs (no fail-fast guard) on stiff / non-smooth / large RHS

**Status:** Bug report / upstream gap (filed from the EarthSciDiscretizations conformance work)
**Component:** `pkg/earthsci-ast-rs` — `src/simulate.rs` / `simulate_array.rs` (the diffsol integration loop)
**Severity:** blocks Rust from the numeric conformance categories on a large class of cases

## Symptom

Running the Rust PDE conformance runner (`scripts/runners/run-rust.sh --categories
simulation,convergence`) on the EarthSciDiscretizations suite, **33 cases cannot produce a
gate-passing Rust result** — most **hang the process indefinitely** at the tight tolerance the
conformance gate requires (observed a single solve stuck >2.5 h on one case), rather than
erroring or completing; the rest terminate only at a tolerance too loose to meet the gate (see
the per-case sweep below). This is why a full Rust numeric run never terminates. Julia
(`Tsit5`) and Python (`LSODA`) solve every one of these cases without issue.

## Which cases, and the common factor

The hanging cases are exactly the **stiff**, **non-smooth**, and **large-AST** right-hand
sides:

- **Genuinely-stiff 2-D diffusion** — the full 2-D Laplacian (both axes active):
  `heat_2d_neumann_flux`, `anisotropic_diffusion_2d_periodic`, `laplace_beltrami_band_mms`,
  and (at convergence's N=128) the per-axis `heat_2d_*`, `heat_1d_varcoeff_zero_flux`.
- **Non-smooth RHS** — TVD limiters and Godunov Hamiltonians whose `min`/`max`/`abs` give a
  discontinuous Jacobian: `advection_1d_periodic_{minmod,superbee,ppm}`, `godunov_norm_2d_*`.
- **Large inlined-AST RHS** — WENO-Z reconstructions evaluated per step:
  `advection_1d_periodic_weno5`, `hjweno_norm_1d_*`.

## Root cause

The three `SolverChoice` variants — `Erk` (explicit tsit45), `Bdf` (implicit BDF), and
`Sdirk` (implicit TR-BDF2) — **all hang** on these problems (verified by swapping the
manifest's `integrators.rust.solver` and re-running). Critically, even the *stiff-but-smooth*
`anisotropic_diffusion_2d_periodic` — a linear Laplacian, exactly what an implicit `Bdf`
exists for — hangs under all three. That rules out "wrong solver choice" and points at the
**integration driver**: it appears to lack a **`dtmin` / max-step-count / max-Newton-iteration
guard**, so when the adaptive step controller cannot make progress (stiffness the explicit
method can't step; a discontinuous Jacobian the Newton iteration can't converge; a step that
keeps getting rejected) it drives `dt → 0` and loops forever instead of returning an error.

## Tolerance dependence (per-case sweep)

A per-case sweep (`reltol` 1e-6 … 1e-9, all three solvers) sharpens the diagnosis into a
*fail-fast* gap, not a *can't-solve* gap:

- **22 cases hang at _every_ tolerance**, down to the loosest `reltol 1e-6` — genuinely stiff
  (full 2-D Laplacians), `sqrt(0)`-Jacobian-singular (the Godunov `|∇u|` on a constant field), or
  huge-AST WENO / HJ-WENO.
- **11 cases terminate only at a loose tolerance** (`1e-6`–`1e-8`), but then their temporal error
  no longer matches the Julia (`Tsit5`, `1e-10`) reference within the conformance gate (`1e-9`
  cross-binding-actuals for simulation, `1e-4` errors-vs-golden for convergence); at the tight
  tolerance the gate needs, they hang. So there is **no tolerance that both terminates and passes**
  — the hang lands exactly on the accuracy the gate requires.
- **2 low-order latlon zonal-advection convergence cases *do* pass**, pinned at `reltol 1e-7`
  (loose enough not to hang, tight enough that their spatially-dominated error still matches the
  golden) — un-blocked downstream.

So the driver hangs precisely when asked for the accuracy the conformance model requires: a
fail-fast guard turns that into a clean error (CI never wedges), and genuine coverage of the
blocked cases additionally needs the solver to *reach* tight tolerances on stiff / non-smooth
RHS without the step size collapsing.

## Requested fix

1. **Fail-fast guard (primary):** enforce a `dtmin` and/or a maximum step / rejected-step /
   Newton-iteration count in the diffsol driver, returning a `SimulateError` when hit, so a
   hard problem *errors in seconds* rather than hanging. This alone lets the conformance
   harness record a clean failure instead of wedging CI.
2. **Robustness (secondary):** confirm `Bdf`/`Sdirk` actually converge on stiff-smooth 2-D
   Laplacians (they should); investigate the non-smooth-RHS handling (a limiter-aware or more
   robust step controller).

## Impact / current workaround downstream

EarthSciDiscretizations marks these cases `blocked_upstream_bindings.rust` in their
`tests/conformance/{simulation,convergence}/<case>/manifest.json` (each entry names this gap),
so `run-rust.sh` skips them and the cross-binding compare records a clean `blocked-upstream`
skip. Rust CI runs `ast + numeric` for the solvable subset. Removing those manifest entries
is the acceptance test for this fix.

## References

- `pkg/earthsci-ast-rs/src/simulate.rs` — `SolverChoice { Bdf, Sdirk, Erk }` and the
  `problem.bdf()/tr_bdf2()/tsit45()` step loops (`simulate.rs` ~L684, `simulate_array.rs` ~L1935).
- Downstream evidence: the 33 `blocked_upstream_bindings.rust` manifest entries in
  `../earthscidiscretizations/tests/conformance/`.
