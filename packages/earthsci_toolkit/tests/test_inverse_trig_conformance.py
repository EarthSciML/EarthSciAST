"""Cross-binding conformance tests for the inverse-trigonometric scalar leaf
ops acos / asin / atan / atan2 (bead ess-9x1).

Each shared fixture under ``tests/valid/scalar_leaves/`` that carries inline
``tests`` / ``tolerance`` blocks integrates a CONSTANT inverse-trig RHS from a
zero initial condition, so ``y(t=1) = rate*1 = rate`` exactly. Julia
(``tree_walk``), Python (``simulate``), and Rust (``simulate``) all check the
SAME inline ``expected`` values baked into the shared fixture, so passing here
means the Python binding's inverse-trig leaves agree with the other evaluating
bindings. The fixture deliberately uses ``atan2(1, -1) = 3*pi/4`` (second
quadrant) so the assertion exercises the 2-arg quadrant resolution rather than
a bare ``atan`` of a ratio.

These leaves back the spherical-geometry FAQs (great-circle arc ``R*acos``,
lat/lon ``asin``/``atan2``) consumed by M4 ``polygon_area`` (ess-my4.4.3) and
the ESD-DUO geometry beads.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pytest
from conftest import VALID_DIR

from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate


_FIXTURES_DIR = VALID_DIR / "scalar_leaves"


def _collect_fixtures() -> List[Path]:
    """scalar_leaves fixtures that carry at least one inline model ``tests`` block."""
    if not _FIXTURES_DIR.is_dir():
        return []
    out: List[Path] = []
    for p in sorted(_FIXTURES_DIR.glob("*.esm")):
        raw = json.loads(p.read_text())
        if any(m.get("tests") for m in (raw.get("models") or {}).values()):
            out.append(p)
    return out


def _resolve_expected_tolerance(
    model_tolerance: Dict[str, float],
    test_tolerance: Dict[str, float],
    assertion_tolerance: Dict[str, float],
) -> Tuple[float, float]:
    merged: Dict[str, float] = {}
    for t in (model_tolerance or {}), (test_tolerance or {}), (assertion_tolerance or {}):
        if t:
            merged.update(t)
    return float(merged.get("rel", 0.0)), float(merged.get("abs", 0.0))


def _lookup_element(
    result_vars: List[str],
    result_y: np.ndarray,
    result_t: np.ndarray,
    var_key: str,
    time: float,
) -> float:
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
    diff = abs(actual - expected)
    if ab > 0 and diff <= ab:
        return True
    if rel > 0:
        if diff / max(abs(expected), 1e-12) <= rel:
            return True
    if ab == 0 and rel == 0:
        return diff == 0.0
    return False


def test_inverse_trig_fixture_present() -> None:
    """The inverse-trig worked-example fixture must be present and executable."""
    fixtures = _collect_fixtures()
    assert fixtures, (
        f"expected >= 1 executable scalar-leaf fixture under {_FIXTURES_DIR} "
        "(did inverse_trig_leaves.esm lose its inline `tests`?)"
    )


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_inverse_trig_fixture_conformance(fixture_path: Path) -> None:
    """Run every inline test in a scalar-leaf inverse-trig fixture."""
    raw = json.loads(fixture_path.read_text())
    esm_file = load(fixture_path)

    any_assertions = False
    for model_name, model_raw in (raw.get("models") or {}).items():
        tests = model_raw.get("tests") or []
        model_tolerance = model_raw.get("tolerance") or {}

        for test in tests:
            test_id = test.get("id", "?")
            tspan_raw = test["time_span"]
            tspan = (float(tspan_raw["start"]), float(tspan_raw["end"]))
            ics = {k: float(v) for k, v in (test.get("initial_conditions") or {}).items()}
            params = {k: float(v) for k, v in (test.get("parameter_overrides") or {}).items()}

            result = simulate(
                esm_file, tspan=tspan, initial_conditions=ics, parameters=params
            )
            assert result.success, (
                f"{fixture_path.name}::{model_name}::{test_id} "
                f"simulation failed: {result.message}"
            )

            test_tolerance = test.get("tolerance") or {}
            for assertion in test.get("assertions", []):
                any_assertions = True
                var_key = assertion["variable"]
                time = float(assertion["time"])
                expected = float(assertion["expected"])
                rel, ab = _resolve_expected_tolerance(
                    model_tolerance, test_tolerance, assertion.get("tolerance") or {}
                )
                actual = _lookup_element(
                    result.vars, result.y, result.t, var_key, time
                )
                assert _assertion_passes(actual, expected, rel, ab), (
                    f"{fixture_path.name}::{model_name}::{test_id} "
                    f"assertion {var_key}@t={time} expected={expected} "
                    f"actual={actual} tol(rel={rel}, abs={ab})"
                )

    assert any_assertions, f"{fixture_path.name}: no assertions were checked"
