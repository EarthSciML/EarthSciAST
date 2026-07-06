"""Python side of the cross-language PDE-simulation conformance tier (ess-fmw).

Drives every fixture in ``tests/conformance/pde_simulation/`` through the Python
binding and asserts it reproduces the fixture's INDEPENDENT analytic anchors:

  * ``evaluate_rhs`` (the discretized RHS hook) == ``L u + b`` at each probe, and
  * ``simulate`` (SciPy ``solve_ivp``) == the exact matrix-exponential trajectory.

This guards the ``_simulate_with_numpy`` refactor + the new ``evaluate_rhs``
public hook in the normal pytest suite; the cross-binding Julia/Rust comparison
lives in ``scripts/run-pde-simulation-conformance.py`` (run from
``scripts/test-conformance.sh``).
"""

from __future__ import annotations

import numpy as np
import pytest
from conftest import CONFORMANCE_DIR, load_fixture

import earthsci_toolkit as et
from earthsci_toolkit import evaluate_rhs, simulate

_MANIFEST = CONFORMANCE_DIR / "pde_simulation" / "manifest.json"


def _load_manifest() -> dict:
    return load_fixture(_MANIFEST)


def _bare(name: str) -> str:
    return name.split(".", 1)[1] if "." in name else name


_MAN = _load_manifest()
_FIXTURES = _MAN["fixtures"]
_TOL = _MAN["tolerances"]
_INTEG = _MAN["integrators"]["python"]


def _ids(fx):
    return fx["id"]


@pytest.mark.parametrize("fixture", _FIXTURES, ids=_ids)
def test_pde_rhs_matches_analytic(fixture):
    """evaluate_rhs reproduces the independent L·u + b anchor at every probe."""
    esm = et.load(str(_MANIFEST.parent / fixture["path"]))
    rtol, atol = _TOL["rhs_rtol"], _TOL["rhs_atol"]
    for probe in fixture["rhs_probes"]:
        got = {
            _bare(k): v
            for k, v in evaluate_rhs(esm, dict(probe["state"]), t=float(probe["t"])).items()
        }
        for name, expected in probe["analytic_rhs"].items():
            actual = got[name]
            assert abs(actual - expected) <= atol + rtol * abs(expected), (
                f"{fixture['id']} probe {probe['id']} {name}: {actual!r} != {expected!r}"
            )


@pytest.mark.parametrize("fixture", _FIXTURES, ids=_ids)
def test_pde_trajectory_matches_analytic(fixture):
    """simulate reproduces the exact matrix-exponential trajectory at the
    declared output times."""
    esm = et.load(str(_MANIFEST.parent / fixture["path"]))
    tr = fixture["trajectory"]
    tspan = (float(tr["time_span"]["start"]), float(tr["time_span"]["end"]))
    result = simulate(
        esm,
        tspan,
        initial_conditions=dict(tr["initial_conditions"]),
        method=_INTEG["method"],
        rtol=float(_INTEG["rtol"]),
        atol=float(_INTEG["atol"]),
    )
    assert result.success
    rtol, atol = _TOL["traj_analytic_rtol"], _TOL["traj_analytic_atol"]
    rows = {_bare(name): row for row, name in enumerate(result.vars)}
    for tstr, expected_state in tr["analytic"].items():
        tq = float(tstr)
        for name, expected in expected_state.items():
            actual = float(np.interp(tq, result.t, result.y[rows[name]]))
            assert abs(actual - expected) <= atol + rtol * abs(expected), (
                f"{fixture['id']} t={tstr} {name}: {actual!r} != {expected!r}"
            )
