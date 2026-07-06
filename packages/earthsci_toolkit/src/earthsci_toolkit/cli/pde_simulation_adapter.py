"""Python adapter for the cross-language PDE-simulation conformance tier (ess-fmw).

Drives the shared, pre-discretized method-of-lines fixtures listed in
``tests/conformance/pde_simulation/manifest.json``. For every fixture it:

  * evaluates the discretized RHS f(u, t) at each declared probe state via
    :func:`earthsci_toolkit.evaluate_rhs` (the NumPy-interpreter RHS, no
    integrator), and
  * integrates the trajectory from the declared initial conditions with the
    pinned integrator (SciPy ``solve_ivp`` + the manifest's method/rtol/atol),
    sampling at the declared output times.

The runner discovers it via ``$EARTHSCI_PDE_SIM_ADAPTER_PYTHON`` or on PATH:

    earthsci-pde-sim-adapter-python --manifest <manifest.json> --output <out.json>

Emits ``{"binding":"python","fixtures":{<id>:{"rhs":{<probe>:{name:val}},
"trajectory":{<tstr>:{name:val}}}}}`` with bare ``u[i]`` element names.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict

import numpy as np

import earthsci_toolkit as et
from earthsci_toolkit import evaluate_rhs, simulate
from earthsci_toolkit.cli._adapter_main import adapter_main
from earthsci_toolkit.simulation import _build_numpy_rhs, _provider_sample_field


def _bare(name: str) -> str:
    return name.split(".", 1)[1] if "." in name else name


class _StubLoaderProvider:
    """Static CONST stub Provider (DESIGN pde_simulation_pipeline §2). Serves one
    declared loader variable's field from the manifest ``inputs`` array; sampled
    once at build time. Mirrors the Phase-1 gate test
    (``tests/test_loaded_ic_bc_simulation.py``)."""

    def __init__(self, field: Any) -> None:
        self.field = np.asarray(field, dtype=float)

    def sample(self, t: float) -> "np.ndarray":  # noqa: ARG002 - const provider
        return self.field


def _time_key(t: float) -> str:
    return f"{float(t):g}"


def _sample_trajectory(result, out_times) -> Dict[str, Dict[str, float]]:
    """Interpolate every state element of a SimulationResult at each output
    time, keyed by bare element name."""
    traj: Dict[str, Dict[str, float]] = {}
    for t in out_times:
        col: Dict[str, float] = {}
        for row, name in enumerate(result.vars):
            col[_bare(name)] = float(np.interp(float(t), result.t, result.y[row]))
        traj[_time_key(t)] = col
    return traj


def run_fixture(fixture: dict, base: Path, integ: dict) -> Dict[str, Any]:
    esm = et.load(str(base / fixture["path"]))

    rhs: Dict[str, Dict[str, float]] = {}
    for probe in fixture["rhs_probes"]:
        raw = evaluate_rhs(esm, dict(probe["state"]), t=float(probe.get("t", 0.0)))
        rhs[probe["id"]] = {_bare(k): float(v) for k, v in raw.items()}

    tr = fixture["trajectory"]
    tspan = (float(tr["time_span"]["start"]), float(tr["time_span"]["end"]))
    result = simulate(
        esm,
        tspan,
        initial_conditions=dict(tr["initial_conditions"]),
        method=integ.get("method", "RK45"),
        rtol=float(integ.get("rtol", 1e-10)),
        atol=float(integ.get("atol", 1e-12)),
    )
    traj = _sample_trajectory(result, tr["output_times"])
    return {"rhs": rhs, "trajectory": traj}


def run_fixture_full(fixture: dict, base: Path, integ: dict) -> Dict[str, Any]:
    """Full-pipeline path (DESIGN pde_simulation_pipeline §7): load the fixture,
    install a static stub provider serving the manifest ``inputs`` (keyed
    ``<Loader>.<var>``), run the whole lowering pipeline (reaction-gen → template
    ``match`` → ``operator_compose`` → pointwise-lift → scoped-``ic``) with the
    loaded fields injected ONLY through the provider seam, and emit the RHS at
    each probe state and the trajectory at each checkpoint. Reuses the exact
    Phase-1 machinery of ``tests/test_loaded_ic_bc_simulation.py``."""
    esm = et.load(str(base / fixture["path"]))
    flat = et.flatten(esm)

    # Every loaded field enters through the provider seam, keyed by its declared
    # loader name; materialized ONCE at build time (t0) into loader_arrays (R2).
    providers = {name: _StubLoaderProvider(field) for name, field in fixture["inputs"].items()}
    checkpoints = [float(c) for c in fixture["trajectory"]["checkpoints"]]
    t0 = checkpoints[0]
    loaded_arrays = {
        name: np.asarray(_provider_sample_field(prov, t0), dtype=float)
        for name, prov in providers.items()
    }

    # --- RHS at each probe via the provider-folded NumPy interpreter ----------
    # The probe state supplies every element as an explicit initial condition
    # (applied AFTER the scoped-`ic` fold, so it is the evaluated state); the
    # loaded wind/inflow forcing reaches the stencil through loader_arrays.
    rhs: Dict[str, Dict[str, float]] = {}
    for probe in fixture["rhs_probes"]:
        build = _build_numpy_rhs(flat, {}, dict(probe["state"]), loader_arrays=loaded_arrays)
        dy = build.rhs_function(float(probe.get("t", 0.0)), build.y0)
        rhs[probe["id"]] = {_bare(n): float(v) for n, v in zip(build.elem_names, dy)}

    # --- Trajectory via the sanctioned provider-injected simulate path --------
    tspan = (checkpoints[0], checkpoints[-1])
    result = simulate(
        esm,
        tspan,
        providers=providers,
        method=integ.get("method", "RK45"),
        rtol=float(integ.get("rtol", 1e-10)),
        atol=float(integ.get("atol", 1e-12)),
    )
    if not result.success:
        raise RuntimeError(f"simulate failed: {result.message}")
    traj = _sample_trajectory(result, checkpoints)
    return {"rhs": rhs, "trajectory": traj}


def _run_fixture(
    fixture: Dict[str, Any], manifest: Dict[str, Any], manifest_path: Path
) -> Dict[str, Any]:
    integ = manifest.get("integrators", {}).get("python", {})
    base = manifest_path.parent
    runner = run_fixture_full if fixture.get("pipeline") == "full" else run_fixture
    return runner(fixture, base, integ)


def main(argv=None) -> int:
    return adapter_main(
        argv, description="Python PDE-simulation conformance adapter", run_fixture=_run_fixture
    )


if __name__ == "__main__":
    sys.exit(main())
