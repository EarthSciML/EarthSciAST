"""Execution runner for inline ``tests`` blocks on tests/simulation/*.esm (gt-l1fk).

Mirrors the Julia reference at
``packages/EarthSciSerialization.jl/test/tests_blocks_execution_test.jl``.

For each model that carries an inline ``tests`` block the runner builds a
single-model subset :class:`EsmFile`, drives it through
:func:`earthsci_toolkit.simulation.simulate`, and asserts each
``(variable, time, expected)`` triple against the interpolated solution with
tolerance precedence ``assertion → test → model`` (fallback ``rtol=1e-6``).

The ``SIMULATION_SKIP`` map records fixtures that cannot yet execute in the
Python binding. Each entry points at the bead tracking the underlying gap so
the skip is self-documenting — remove the entry once the bead closes.

Fixtures without any inline ``tests`` block (e.g. spatial_limitation.esm)
are silently passed over by the fixture walk.
"""

from __future__ import annotations

import dataclasses
import json
import os
import warnings
from typing import Any, Dict, Optional, Tuple

import numpy as np
import pytest
from conftest import FIXTURES_ROOT

pytest.importorskip("scipy")

from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate


SIMULATION_DIR = str(FIXTURES_ROOT / "simulation")


# Fixtures skipped from numerical execution in the Python binding. Each entry
# points at the bead tracking the gap so the skip is self-documenting.
SIMULATION_SKIP: Dict[str, str] = {
    # gt-qgui: parse bug — load() on empty domain temporal block crashes.
    "autocatalytic_reaction.esm": "gt-qgui",
    "coupled_oscillators.esm": "gt-qgui",
    "event_chain.esm": "gt-qgui",
    "performance_benchmarks.esm": "gt-qgui",
    "periodic_dosing.esm": "gt-qgui",
    "simple_ode.esm": "gt-qgui",
    "spatial_diffusion.esm": "gt-qgui",
    "spatial_limitation.esm": "gt-qgui",
    "stiff_ode_system.esm": "gt-qgui",
    # gt-i7e1: simulate() treats bare-string RHS ("v") as constant, so the
    # SimpleOscillator model's dx/dt = v never evolves x.
    "julia_mtk_integration.esm": "gt-i7e1",
    # continuous events are parsed but their affect equations don't propagate
    # into the SciPy backend's state-reset step; the ball never actually
    # bounces. Tracked alongside Julia's SymbolicContinuousCallback skip.
    "bouncing_ball.esm": "gt-i7e1",
    # esm-mvc: Python simulate() returns 'Unsupported operation: abs' / 'min' /
    # 'max' / 'pow' on AST RHSes that use these op aliases. The clamp-via-abs,
    # n-ary-min/max, and pow-Bernoulli fixtures (esm-sph) cannot run until the
    # op-alias gap closes. Julia/MTK handles these correctly; the fixtures
    # remain consumed by the Julia and (TBD) Rust runners.
    "clamp_via_abs.esm": "esm-mvc",
    "nary_min_max.esm": "esm-mvc",
    "pow_logistic.esm": "esm-mvc",
    # esm-y3n: Python flatten/simulate silently drops authored algebraic
    # equations (lhs is a bare variable name), leaving the algebraic
    # intermediates pinned at their default values and corrupting the
    # downstream ODE — the diameter-growth-shaped fixture (esm-sph) reproduces
    # nux's audit at 1000x error magnitudes. Closes once esm-y3n lands proper
    # algebraic-elimination support.
    "algebraic_diameter_growth.esm": "esm-y3n",
}


# Per-component skips. Keyed by ``(fixture, "models"|"reaction_systems",
# component_name)``. Use when one component in a multi-component fixture is
# broken but other components should still execute. Each entry points at the
# tracking bead so the skip is self-documenting.
COMPONENT_SKIP: Dict[Tuple[str, str, str], str] = {
    # gt-pcj5: reaction-rate lowering bug in simulate()'s flatten path —
    # explicit rate expressions (e.g. k*A) get multiplied by substrate
    # concentrations again during mass-action lowering, producing k*A*A.
    # Affects every reaction_system in mathematical_correctness.esm.
    # Julia runs the same fixtures correctly.
    (
        "mathematical_correctness.esm",
        "reaction_systems",
        "MassConservationTest",
    ): "gt-pcj5",
    (
        "mathematical_correctness.esm",
        "reaction_systems",
        "LinearChain",
    ): "gt-pcj5",
}


def _list_simulation_fixtures() -> list[str]:
    if not os.path.isdir(SIMULATION_DIR):
        return []
    return sorted(fn for fn in os.listdir(SIMULATION_DIR) if fn.endswith(".esm"))


def _resolve_tol(
    model_tol: Optional[Dict[str, Any]],
    test_tol: Optional[Dict[str, Any]],
    assertion_tol: Optional[Dict[str, Any]],
) -> Tuple[float, float]:
    for cand in (assertion_tol, test_tol, model_tol):
        if cand is None:
            continue
        rel = cand.get("rel")
        abs_ = cand.get("abs")
        return (
            float(rel) if rel is not None else 0.0,
            float(abs_) if abs_ is not None else 0.0,
        )
    return (1e-6, 0.0)


def _single_model_subset(file, model_name: str):
    """Build a file containing only ``model_name`` so simulate() runs the
    model in isolation — Python's simulate flattens every model/reaction
    system into one combined system, which couples unrelated dynamics and
    corrupts results for multi-component fixtures.
    """
    models = file.models or {}
    return dataclasses.replace(
        file,
        models={model_name: models[model_name]},
        reaction_systems={},
        coupling=[],
    )


def _single_rs_subset(file, rs_name: str):
    rsys = file.reaction_systems or {}
    return dataclasses.replace(
        file,
        models={},
        reaction_systems={rs_name: rsys[rs_name]},
        coupling=[],
    )


def _resolve_var_index(result_vars: list, component: str, local: str) -> int:
    namespaced = f"{component}.{local}"
    if namespaced in result_vars:
        return result_vars.index(namespaced)
    if local in result_vars:
        return result_vars.index(local)
    raise AssertionError(f"variable {local!r} not in result vars ({result_vars}) for {component!r}")


def _execute_component_tests(
    label: str,
    file_subset,
    component_name: str,
    tests: list,
    model_tol: Optional[Dict[str, Any]],
) -> None:
    """Execute every inline test on the given subset file and assert."""
    for test in tests:
        ts = test["time_span"]
        tspan = (float(ts["start"]), float(ts["end"]))
        params = {k: float(v) for k, v in (test.get("parameter_overrides") or {}).items()}
        ics = {k: float(v) for k, v in (test.get("initial_conditions") or {}).items()}

        result = simulate(
            file_subset,
            tspan=tspan,
            parameters=params,
            initial_conditions=ics,
        )
        assert result.success, f"{label}/{test['id']}: simulate() failed: {result.message}"

        test_tol = test.get("tolerance")
        for a in test["assertions"]:
            idx = _resolve_var_index(list(result.vars), component_name, a["variable"])
            t_eval = float(a["time"])
            expected = float(a["expected"])
            # np.interp requires a sorted x array; solve_ivp returns t sorted.
            actual = float(np.interp(t_eval, result.t, result.y[idx]))
            rel, abs_ = _resolve_tol(model_tol, test_tol, a.get("tolerance"))
            diff = abs(actual - expected)
            bound = abs_
            if rel > 0:
                bound = max(bound, rel * max(abs(expected), np.finfo(float).tiny))
            if rel == 0.0 and abs_ == 0.0:
                # Default rtol=1e-6, matching the Julia runner.
                bound = 1e-6 * max(abs(expected), np.finfo(float).tiny)
            assert diff <= bound, (
                f"{label}/{test['id']} var={a['variable']} t={t_eval}: "
                f"actual={actual:g} expected={expected:g} "
                f"diff={diff:g} bound={bound:g} (rel={rel}, abs={abs_})"
            )


@pytest.mark.parametrize("fixture", _list_simulation_fixtures())
def test_simulation_fixture_tests_blocks(fixture: str) -> None:
    """For every model/reaction_system with a tests block in
    ``tests/simulation/<fixture>``, run simulate() and verify assertions.

    Fixtures in ``SIMULATION_SKIP`` are xfail-marked — the bead ID in the map
    value identifies the blocker.
    """
    if fixture in SIMULATION_SKIP:
        pytest.xfail(f"{fixture}: blocked by {SIMULATION_SKIP[fixture]} (Python binding gap)")

    path = os.path.join(SIMULATION_DIR, fixture)
    with open(path) as fp:
        raw = json.load(fp)
    file = load(path)

    any_executed = False
    xfail_reasons: list[str] = []

    for mname, mraw in (raw.get("models") or {}).items():
        tests = mraw.get("tests") or []
        if not tests:
            continue
        skip_bead = COMPONENT_SKIP.get((fixture, "models", mname))
        if skip_bead is not None:
            xfail_reasons.append(f"models/{mname}: {skip_bead}")
            continue
        subset = _single_model_subset(file, mname)
        _execute_component_tests(
            label=f"{fixture}/models/{mname}",
            file_subset=subset,
            component_name=mname,
            tests=tests,
            model_tol=mraw.get("tolerance"),
        )
        any_executed = True

    for rsname, rraw in (raw.get("reaction_systems") or {}).items():
        tests = rraw.get("tests") or []
        if not tests:
            continue
        skip_bead = COMPONENT_SKIP.get((fixture, "reaction_systems", rsname))
        if skip_bead is not None:
            xfail_reasons.append(f"reaction_systems/{rsname}: {skip_bead}")
            continue
        subset = _single_rs_subset(file, rsname)
        _execute_component_tests(
            label=f"{fixture}/reaction_systems/{rsname}",
            file_subset=subset,
            component_name=rsname,
            tests=tests,
            model_tol=rraw.get("tolerance"),
        )
        any_executed = True

    for reason in xfail_reasons:
        warnings.warn(
            f"{fixture}: component skipped ({reason})",
            stacklevel=1,
        )
    if xfail_reasons and not any_executed:
        pytest.xfail(f"{fixture}: all components blocked — " + "; ".join(xfail_reasons))
    if not any_executed:
        pytest.skip(f"{fixture}: no inline tests blocks to execute")


def test_simulation_fixtures_present() -> None:
    """Guard against the simulation fixture directory going empty — a
    regression that would silently pass the parametrized test because no
    cases would be collected.
    """
    fixtures = _list_simulation_fixtures()
    assert fixtures, f"no .esm fixtures in {SIMULATION_DIR}"
