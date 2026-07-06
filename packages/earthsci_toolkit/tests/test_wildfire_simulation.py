"""End-to-end simulation of the coupled wildfire-atmosphere-ocean fixture
``tests/valid/wildfire_atmosphere_ocean.esm`` through the Python NumPy runner
(:func:`earthsci_toolkit.simulation.simulate`).

Python counterpart of the Julia reference. What this exercises:

  * A REAL INLINE CONSERVATIVE REGRID (esm-spec §8.6.1): the atmosphere-grid
    sensible-flux field ``flux_field=[50,150,250,350]`` is remapped onto the
    3-cell ocean grid by overlap weights ``W[a,o] = A[a,o]/A_o`` computed inline
    from cell geometry — a bin-skolem BROAD PHASE (``rg_src_bin``/``rg_tgt_bin``
    materialized via ``skolem``+``floor``, joined on ``[[rg_src_bin,rg_tgt_bin]]``)
    plus a fused ``polygon_intersection_area`` NARROW PHASE. The weights are
    computed, not supplied, giving ``surface_heat_flux=[100, 283.333, 350]``.
  * WHOLE-ARRAY ``D(SST) = surface_heat_flux/4.18e6`` integrated per cell over the
    declared ``shape:["ocean_cells"]`` (resolved to 3 cells), with ``u_ocean``
    (ic-only array) and ``phi``/``wind`` (ic-only scalars) held at their ic — a
    no-``D`` state has a zero derivative.
  * VALUE-INVENTION state vars (the bins + the ``distinct`` candidate-set
    membership ``rg_pairs``) dropped from the ODE, materialized at setup.

The fixture's OceanDynamics inline ``tests`` block is the source of truth: this
runner executes every assertion in it (SST at t=0 and t=3600), and additionally
pins the constant atmosphere / fire states.
"""

from __future__ import annotations

import json
import os
from typing import Any, Dict, Optional, Tuple

import numpy as np
import pytest
from conftest import VALID_DIR

pytest.importorskip("scipy")

from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate


FIXTURE = str(VALID_DIR / "wildfire_atmosphere_ocean.esm")


def _resolve_tol(
    model_tol: Optional[Dict[str, Any]],
    test_tol: Optional[Dict[str, Any]],
    assertion_tol: Optional[Dict[str, Any]],
) -> Tuple[float, float]:
    """Resolve (rel, abs) precedence assertion -> test -> model (fallback rtol=1e-6),
    matching the Julia runner and test_loaded_ic_bc_simulation."""
    for cand in (assertion_tol, test_tol, model_tol):
        if cand is None:
            continue
        rel = cand.get("rel")
        abs_ = cand.get("abs")
        return (float(rel) if rel is not None else 0.0,
                float(abs_) if abs_ is not None else 0.0)
    return (1e-6, 0.0)


def test_wildfire_atmosphere_ocean_simulation() -> None:
    """Run the coupled system and assert every inline OceanDynamics test plus the
    constant atmosphere / fire states."""
    assert os.path.isfile(FIXTURE), FIXTURE

    with open(FIXTURE) as fp:
        raw = json.load(fp)
    ocean = raw["models"]["OceanDynamics"]
    model_tol = ocean.get("tolerance")
    tests = ocean.get("tests") or []
    assert tests, "fixture OceanDynamics model carries no inline tests block"

    file = load(FIXTURE)

    passed = 0
    total = 0
    for test in tests:
        ts = test["time_span"]
        tspan = (float(ts["start"]), float(ts["end"]))
        test_tol = test.get("tolerance")

        result = simulate(file, tspan=tspan, rtol=1e-10, atol=1e-12)
        assert result.success, f"simulate() failed: {result.message}"

        for a in test["assertions"]:
            total += 1
            # Assertion variables are model-local ("SST[1]"); the simulated
            # element is namespaced under the OceanDynamics model.
            local = a["variable"]
            key = f"OceanDynamics.{local}"
            assert key in result.vars, (
                f"element {key!r} not in result vars ({result.vars})"
            )
            idx = result.vars.index(key)
            t_eval = float(a["time"])
            expected = float(a["expected"])
            actual = float(np.interp(t_eval, result.t, result.y[idx]))
            rel, abs_ = _resolve_tol(model_tol, test_tol, a.get("tolerance"))
            diff = abs(actual - expected)
            if rel == 0.0 and abs_ == 0.0:
                bound = 1e-6 * max(abs(expected), np.finfo(float).tiny)
            else:
                bound = abs_
                if rel > 0:
                    bound = max(bound, rel * max(abs(expected), np.finfo(float).tiny))
            assert diff <= bound, (
                f"{test['id']} var={local} t={t_eval}: actual={actual:g} "
                f"expected={expected:g} diff={diff:g} bound={bound:g} "
                f"(rel={rel}, abs={abs_})"
            )
            passed += 1

    assert passed == total and total > 0
    # 3 SST cells at t=0 and t=3600 = 6 assertions.
    assert total == 6, f"expected 6 inline assertions, got {total}"


def test_wildfire_constant_and_regrid_states() -> None:
    """The atmosphere / fire 0-D states stay at their ic (no-D states have zero
    derivative), and the regridded SST trajectory matches the closed form
    SST(t)=290 + t*surface_heat_flux/4.18e6 with the inline conservative
    weights giving surface_heat_flux=[100, 283.333, 350]."""
    file = load(FIXTURE)
    result = simulate(file, tspan=(0.0, 3600.0), rtol=1e-10, atol=1e-12)
    assert result.success, result.message

    def final(name: str) -> float:
        assert name in result.vars, f"{name} not in {result.vars}"
        return float(result.y[result.vars.index(name), -1])

    # 0-D states held at ic (phi feeds heat_release; any drift would corrupt T).
    assert final("AtmosphericDynamics.T") == pytest.approx(288.0, abs=1e-9)
    assert final("AtmosphericDynamics.wind_u") == pytest.approx(0.0, abs=1e-12)
    assert final("AtmosphericDynamics.wind_v") == pytest.approx(0.0, abs=1e-12)
    assert final("WildfirePropagation.phi") == pytest.approx(1.0, abs=1e-12)
    assert final("WildfirePropagation.fuel") == pytest.approx(10.0, abs=1e-9)

    # u_ocean (ic-only array) held at 0 across all 3 cells.
    for o in (1, 2, 3):
        assert final(f"OceanDynamics.u_ocean[{o}]") == pytest.approx(0.0, abs=1e-12)

    # Regridded SST closed form: 290 + 3600*shf/4.18e6.
    shf = np.array([100.0, 850.0 / 3.0, 350.0])
    expected = 290.0 + 3600.0 * shf / 4_180_000.0
    got = np.array([final(f"OceanDynamics.SST[{o}]") for o in (1, 2, 3)])
    assert np.allclose(got, expected, rtol=1e-6), (got, expected)
