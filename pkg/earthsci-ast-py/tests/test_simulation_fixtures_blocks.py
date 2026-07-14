"""Execution runner for inline ``tests`` blocks on tests/simulation/*.esm (gt-l1fk).

Mirrors the Julia reference at
``pkg/EarthSciAST.jl/test/tests_blocks_execution_test.jl``.

For each model that carries an inline ``tests`` block the runner builds a
single-model subset :class:`EsmFile`, drives it through
:func:`earthsci_ast.simulation.simulate`, and asserts each
``(variable, time, expected)`` triple against the interpolated solution with
tolerance precedence ``assertion → test → model`` (fallback ``rtol=1e-6``).

The ``SIMULATION_SKIP`` map records fixtures that cannot yet execute in the
Python binding. Each entry points at the bead tracking the underlying gap so
the skip is self-documenting.

Entries are enforced STRICTLY and are self-cleaning: fixture-level blocks are
declarative ``xfail(strict=True)`` marks and component-level blocks are still
executed (:func:`_run_component`), so the moment a blocker is fixed the entry
reports XPASS / raises ``STALE COMPONENT_SKIP`` and the suite fails until it is
removed. Do NOT reintroduce an imperative ``pytest.xfail()`` in the test body:
it raises before the body runs, XPASS becomes structurally impossible, and the
map silently rots (it had accumulated twelve dead entries this way).

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

from earthsci_ast.parse import load
from earthsci_ast.simulation import simulate


SIMULATION_DIR = str(FIXTURES_ROOT / "simulation")


# Fixtures skipped from numerical execution in the Python binding. Each entry
# points at the bead tracking the gap so the skip is self-documenting.
SIMULATION_SKIP: Dict[str, str] = {
    # gt-qgui: parse bug — load() on empty domain temporal block crashes.
    "periodic_dosing.esm": "gt-qgui",
    "spatial_limitation.esm": "gt-qgui",
    # gt-i7e1: continuous events are parsed but their affect equations don't
    # propagate into the SciPy backend's state-reset step; the ball never
    # actually bounces. Tracked alongside Julia's SymbolicContinuousCallback
    # skip.
    "bouncing_ball.esm": "gt-i7e1",
}
# NOTE: twelve entries were deleted here, not fixed — they were ALREADY passing.
# The map was maintained with an imperative `pytest.xfail()` inside the test
# body, which aborts before the body runs, so a blocker that had since been
# fixed kept reporting `xfailed` forever and no one could see it was stale.
# Switching to a declarative `xfail(strict=True)` mark (see `_fixture_params`)
# ran the bodies and reported XPASS for: autocatalytic_reaction,
# coupled_oscillators, event_chain, performance_benchmarks, simple_ode,
# stiff_ode_system (gt-qgui); julia_mtk_integration (gt-i7e1); clamp_via_abs,
# nary_min_max, pow_logistic (esm-mvc); algebraic_diameter_growth (esm-y3n);
# plus spatial_diffusion, whose gt-qgui load crash is gone and which carries no
# inline tests anyway. The three entries above are the only ones still real.


# Per-component skips. Keyed by ``(fixture, "models"|"reaction_systems",
# component_name)``. Use when one component in a multi-component fixture is
# broken but other components should still execute. Each entry points at the
# tracking bead so the skip is self-documenting.
#
# Currently EMPTY. Both entries it held (`mathematical_correctness.esm`'s
# `MassConservationTest` and `LinearChain`, both blocked on the gt-pcj5
# mass-action rate-lowering bug) turned out to be STALE: once `_run_component`
# started actually RUNNING skipped components instead of jumping over them, both
# passed. gt-pcj5 is fixed. Nothing was silently dropped — the old code merely
# warned and moved on, so the fix went unnoticed.
COMPONENT_SKIP: Dict[Tuple[str, str, str], str] = {}


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


def _fixture_params():
    """Parametrization for the fixture walk, with blocked fixtures carried as
    DECLARATIVE ``xfail(strict=True)`` marks.

    This must not be ``pytest.xfail(...)`` called from inside the test body.
    The imperative form raises immediately, so the body NEVER RUNS: a blocker
    that has since been fixed keeps reporting ``xfailed`` forever and the entry
    can never be seen to be stale. XPASS was structurally impossible, and the
    map rotted — most entries were dead.

    The declarative mark runs the body and compares the outcome to the claim.
    ``strict=True`` turns an unexpected PASS into a FAILURE, so the moment a
    blocker is fixed the suite demands the entry be deleted. A skip map is only
    honest if a stale entry breaks the build.
    """
    params = []
    for fixture in _list_simulation_fixtures():
        bead = SIMULATION_SKIP.get(fixture)
        marks = (
            pytest.mark.xfail(
                reason=f"{fixture}: blocked by {bead} (Python binding gap)",
                strict=True,
            )
            if bead is not None
            else ()
        )
        params.append(pytest.param(fixture, marks=marks))
    return params


@pytest.mark.parametrize("fixture", _fixture_params())
def test_simulation_fixture_tests_blocks(fixture: str) -> None:
    """For every model/reaction_system with a tests block in
    ``tests/simulation/<fixture>``, run simulate() and verify assertions.

    Fixtures in ``SIMULATION_SKIP`` are xfail-marked (strict) — the bead ID in
    the map value identifies the blocker.
    """
    path = os.path.join(SIMULATION_DIR, fixture)
    with open(path) as fp:
        raw = json.load(fp)
    file = load(path)

    any_executed = False
    xfail_reasons: list[str] = []

    def _run_component(kind: str, name: str, subset, tests, tol) -> bool:
        """Execute one component's inline tests. Returns True if it EXECUTED.

        A component listed in ``COMPONENT_SKIP`` is still RUN — it is never
        silently jumped over. If it fails, the recorded blocker is confirmed and
        the skip stands. If it PASSES, the entry is stale and this raises: the
        same strictness the declarative ``xfail(strict=True)`` gives the
        fixture-level map. Otherwise a fixed blocker would sit in the map
        forever, unnoticed, exactly as the imperative `pytest.xfail` allowed.
        """
        skip_bead = COMPONENT_SKIP.get((fixture, kind, name))
        label = f"{fixture}/{kind}/{name}"
        if skip_bead is None:
            _execute_component_tests(
                label=label,
                file_subset=subset(),
                component_name=name,
                tests=tests,
                model_tol=tol,
            )
            return True
        try:
            _execute_component_tests(
                label=label,
                file_subset=subset(),
                component_name=name,
                tests=tests,
                model_tol=tol,
            )
        except Exception:
            # Still blocked, as recorded — the skip is doing real work.
            xfail_reasons.append(f"{kind}/{name}: {skip_bead}")
            return False
        raise AssertionError(
            f"STALE COMPONENT_SKIP: ({fixture!r}, {kind!r}, {name!r}) is recorded as "
            f"blocked by {skip_bead}, but its inline tests now PASS. Remove the entry."
        )

    for mname, mraw in (raw.get("models") or {}).items():
        tests = mraw.get("tests") or []
        if not tests:
            continue
        if _run_component(
            "models",
            mname,
            lambda: _single_model_subset(file, mname),
            tests,
            mraw.get("tolerance"),
        ):
            any_executed = True

    for rsname, rraw in (raw.get("reaction_systems") or {}).items():
        tests = rraw.get("tests") or []
        if not tests:
            continue
        if _run_component(
            "reaction_systems",
            rsname,
            lambda: _single_rs_subset(file, rsname),
            tests,
            rraw.get("tolerance"),
        ):
            any_executed = True

    for reason in xfail_reasons:
        warnings.warn(
            f"{fixture}: component skipped ({reason})",
            stacklevel=1,
        )
    if xfail_reasons and not any_executed:
        # Every component is blocked and each was RUN and confirmed still
        # failing (see `_run_component`), so failing here is honest: the fixture
        # carries a strict xfail mark, which this satisfies.
        raise AssertionError(f"{fixture}: all components blocked — " + "; ".join(xfail_reasons))
    if not any_executed:
        pytest.skip(f"{fixture}: no inline tests blocks to execute")


def test_simulation_fixtures_present() -> None:
    """Guard against the simulation fixture directory going empty — a
    regression that would silently pass the parametrized test because no
    cases would be collected.
    """
    fixtures = _list_simulation_fixtures()
    assert fixtures, f"no .esm fixtures in {SIMULATION_DIR}"
