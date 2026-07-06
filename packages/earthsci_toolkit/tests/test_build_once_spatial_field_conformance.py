"""Cross-language conformance: a BUILD-ONCE SPATIAL FIELD materialized once at
setup (a ``const``-derived array, differentiated build-once) and consumed
elementwise by an ODE (CONFORMANCE_SPEC.md §5.12).

Shared fixture + analytic golden live under
``tests/conformance/build_once_spatial_field/`` (repo root); the Julia runner
(``build_once_spatial_field_conformance_test.jl``) reproduces the same golden.

Model ``Field`` declares three const polygon cells (``poly``), derives a per-cell
``area[c] = polygon_intersection_area(poly[c], poly[c], planar) = [10, 30, 60]``
(a geometry leaf), takes a build-once centered first difference authored as the
periodic ``makearray`` stencil a discretization rule lowers ``D`` to
(``darea = [-15, 25, -10]``), and integrates the per-cell ODE
``D(u[c]) = darea[c] - u[c]``, u(0)=0. The forcing is CONST, so
``u_c(t) = darea_c (1 - e^-t)`` is analytic and network-free.

Python evaluates ``polygon_intersection_area`` + ``makearray`` + the array ODE
end-to-end (it resolves the build-once field at the RHS rather than at a separate
setup pass, so the numeric result matches the Julia setup-materialized path)."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "build_once_spatial_field"
_FIXTURE = _ROOT / "fixtures" / "build_once_spatial_ode.esm"
_GOLDEN = _ROOT / "golden" / "build_once_spatial_ode.json"


def _golden() -> dict:
    return json.loads(_GOLDEN.read_text())


def test_flatten_keeps_field_observeds_and_single_state() -> None:
    from earthsci_toolkit.flatten import flatten

    flat = flatten(load(str(_FIXTURE)))
    assert "Field.area" in flat.observed_variables
    assert "Field.darea" in flat.observed_variables
    # `u` is the only integrated state; area/darea are observeds, not slots.
    assert "Field.u" in flat.state_variables
    assert "Field.area" not in flat.state_variables


def test_build_once_spatial_field_trajectory_matches_golden() -> None:
    golden = _golden()
    esm = load(str(_FIXTURE))
    t0, t1 = golden["cadence"]["tspan"]
    result = simulate(esm, tspan=(float(t0), float(t1)), method="LSODA",
                      rtol=1e-10, atol=1e-12)
    assert result.success, result.message

    idx = {name: k for k, name in enumerate(result.vars)}
    traj = golden["trajectory"]
    for tk, expected in traj.items():
        if tk == "comment":
            continue
        t = float(tk)
        for cell, want in expected.items():
            got = float(np.interp(t, result.t, result.y[idx[cell]]))
            assert got == pytest.approx(want, rel=1e-4, abs=1e-6)
