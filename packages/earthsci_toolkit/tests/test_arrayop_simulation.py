"""
Fixture-driven conformance tests for the NumPy array-op simulation path.

Each ``.esm`` file under the cross-language fixture directory declares one
or more models with inline ``tests`` and ``tolerance`` blocks. This module
loads each fixture, runs every declared test through :func:`simulate`, and
asserts every ``(variable, time, expected)`` entry within its tolerance.

The fixtures themselves are produced by the Julia binding (shared across
bindings for cross-language conformance), so passing them here means the
Python binding's trajectories match the Julia binding within tolerance.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pytest
from conftest import FIXTURES_ROOT

from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate


_FIXTURES_DIR = FIXTURES_ROOT / "fixtures" / "arrayop"


def _collect_fixtures() -> List[Path]:
    if not _FIXTURES_DIR.is_dir():
        return []
    return sorted(p for p in _FIXTURES_DIR.glob("*.esm"))


def _resolve_expected_tolerance(
    model_tolerance: Dict[str, float],
    test_tolerance: Dict[str, float],
    assertion_tolerance: Dict[str, float],
) -> Tuple[float, float]:
    """Return ``(rel, abs)`` for an assertion, applying precedence."""
    merged: Dict[str, float] = {}
    for t in (model_tolerance or {}), (test_tolerance or {}), (assertion_tolerance or {}):
        if t:
            merged.update(t)
    rel = float(merged.get("rel", 0.0))
    ab = float(merged.get("abs", 0.0))
    return rel, ab


def _lookup_element(
    result_vars: List[str],
    result_y: np.ndarray,
    result_t: np.ndarray,
    var_key: str,
    time: float,
) -> float:
    """Return the simulated value of ``var_key`` at ``time``.

    Resolves the assertion's variable name (bare, may include ``[i,j]``)
    against the result's namespaced element names by suffix match. Linearly
    interpolates between solver time points.
    """
    match_idx = None
    for i, name in enumerate(result_vars):
        if name == var_key or name.endswith("." + var_key):
            match_idx = i
            break
    if match_idx is None:
        raise AssertionError(f"Variable {var_key!r} not in result vars: {result_vars}")
    y_row = result_y[match_idx, :]
    if len(result_t) == 0:
        raise AssertionError("Result has no time points")
    if time <= result_t[0]:
        return float(y_row[0])
    if time >= result_t[-1]:
        return float(y_row[-1])
    return float(np.interp(time, result_t, y_row))


def _assertion_passes(actual: float, expected: float, rel: float, ab: float) -> bool:
    """Apply the OR-of-two-bounds tolerance check from the schema."""
    diff = abs(actual - expected)
    if ab > 0 and diff <= ab:
        return True
    if rel > 0:
        denom = max(abs(expected), 1e-12)
        if diff / denom <= rel:
            return True
    if ab == 0 and rel == 0:
        return diff == 0.0
    return False


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_arrayop_fixture_conformance(fixture_path: Path) -> None:
    """Run every inline test in an array-op fixture and check all assertions."""
    with open(fixture_path, "r") as fh:
        raw = json.load(fh)

    esm_file = load(fixture_path)

    # Walk models — inline ``tests`` lives at the model level in the raw JSON
    # (the Model dataclass doesn't carry tests yet, so we read them from the
    # parsed dict directly).
    models_raw = raw.get("models", {})
    any_assertions = False
    for model_name, model_raw in models_raw.items():
        tests = model_raw.get("tests") or []
        model_tolerance = model_raw.get("tolerance") or {}

        for test in tests:
            test_id = test.get("id", "?")
            tspan_raw = test["time_span"]
            tspan = (float(tspan_raw["start"]), float(tspan_raw["end"]))
            ics: Dict[str, float] = {}
            for k, v in (test.get("initial_conditions") or {}).items():
                ics[k] = float(v)
            params: Dict[str, float] = {}
            for k, v in (test.get("parameter_overrides") or {}).items():
                params[k] = float(v)

            result = simulate(
                esm_file,
                tspan=tspan,
                initial_conditions=ics,
                parameters=params,
            )
            assert result.success, (
                f"{fixture_path.name}::{model_name}::{test_id} simulation failed: {result.message}"
            )

            test_tolerance = test.get("tolerance") or {}
            for assertion in test.get("assertions", []):
                any_assertions = True
                var_key = assertion["variable"]
                time = float(assertion["time"])
                expected = float(assertion["expected"])
                rel, ab = _resolve_expected_tolerance(
                    model_tolerance,
                    test_tolerance,
                    assertion.get("tolerance") or {},
                )
                actual = _lookup_element(result.vars, result.y, result.t, var_key, time)
                assert _assertion_passes(actual, expected, rel, ab), (
                    f"{fixture_path.name}::{model_name}::{test_id} "
                    f"assertion {var_key}@t={time} expected={expected} "
                    f"actual={actual} tol(rel={rel}, abs={ab})"
                )

    assert any_assertions, f"{fixture_path.name}: no assertions were checked"
