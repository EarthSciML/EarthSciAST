"""
Cross-binding conformance tests for the M1 semiring / index-set worked
examples (bead ess-my4.1.5).

Each shared fixture under ``tests/valid/aggregate/`` that carries inline
``tests`` / ``tolerance`` blocks is one M1-expressible worked example — the
default ``sum_product`` FVM diffusion contraction (plus an empty-range 0-bar
identity case), the ``min_sum`` tropical semiring, the ``max_product``
saturation semiring, and a ``categorical`` index-set contraction. This module
loads each, runs every declared test through :func:`simulate`, and asserts
every ``(variable, time, expected)`` entry within tolerance.

Julia, Rust, and Python all check the SAME inline ``expected`` values baked
into these shared fixtures, so passing here means the Python binding's semiring
trajectories agree with the other evaluating bindings. Schema-only aggregate
fixtures in the same directory (no inline ``tests``) are skipped — they are
covered by the validation suites, not this evaluator path.

RFC: ``docs/content/rfcs/semiring-faq-unified-ir.md`` §5.1 / §5.2 / §7.1.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pytest

from earthsci_toolkit.parse import load
from earthsci_toolkit.simulation import simulate


_FIXTURES_DIR = (
    Path(__file__).resolve().parents[3]  # repo root
    / "tests"
    / "valid"
    / "aggregate"
)


def _collect_fixtures() -> List[Path]:
    """Aggregate fixtures that carry at least one inline model ``tests`` block."""
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


def test_at_least_four_worked_examples() -> None:
    """The four M1 worked-example fixtures must be present and executable."""
    assert len(_collect_fixtures()) >= 4, (
        "expected >= 4 executable aggregate worked-example fixtures under "
        f"{_FIXTURES_DIR} (did the shared fixtures lose their inline `tests`?)"
    )


@pytest.mark.parametrize("fixture_path", _collect_fixtures(), ids=lambda p: p.name)
def test_aggregate_fixture_conformance(fixture_path: Path) -> None:
    """Run every inline test in an aggregate worked-example fixture."""
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
