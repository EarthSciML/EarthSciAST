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

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict

import numpy as np

import earthsci_toolkit as et
from earthsci_toolkit import evaluate_rhs, simulate


def _bare(name: str) -> str:
    return name.split(".", 1)[1] if "." in name else name


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
        esm, tspan,
        initial_conditions=dict(tr["initial_conditions"]),
        method=integ.get("method", "RK45"),
        rtol=float(integ.get("rtol", 1e-10)),
        atol=float(integ.get("atol", 1e-12)),
    )
    traj = _sample_trajectory(result, tr["output_times"])
    return {"rhs": rhs, "trajectory": traj}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Python PDE-simulation conformance adapter")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)

    manifest = json.loads(args.manifest.read_text())
    integ = manifest.get("integrators", {}).get("python", {})
    base = args.manifest.parent

    fixtures: Dict[str, Any] = {}
    for fixture in manifest["fixtures"]:
        try:
            fixtures[fixture["id"]] = run_fixture(fixture, base, integ)
        except Exception as exc:  # noqa: BLE001 - surface per-fixture failure to the runner
            fixtures[fixture["id"]] = {"error": f"{type(exc).__name__}: {exc}"}

    payload = {"binding": "python", "fixtures": fixtures}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
