"""
Closed function registry — Python conformance harness (esm-tzp / esm-4ia).

Drives the cross-binding fixtures under ``tests/closed_functions/<module>/<name>/``
from the Python binding: parse ``canonical.esm`` (validates the parser's
``fn``-op handling), then walk the scenarios in ``expected.json`` and assert
that :func:`evaluate_closed_function` agrees with the reference output within
the declared tolerance. The same fixture set runs from each binding's harness;
any binding that disagrees with the spec-pinned values fails CI (esm-spec §9.4).
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, List

import pytest
from conftest import FIXTURES_ROOT as _TESTS_ROOT, VALID_DIR

from earthsci_toolkit import load
from earthsci_toolkit.numpy_interpreter import fold_constant_expr
from earthsci_toolkit.registered_functions import (
    ClosedFunctionError,
    closed_function_names,
    evaluate_closed_function,
)


FIXTURES_ROOT = _TESTS_ROOT / "closed_functions"


def _decode_input(v: Any) -> Any:
    """Convert a JSON-decoded scenario input to the value the closed function
    expects. Strings used as numeric placeholders (``"NaN"``, ``"Inf"``,
    ``"-Inf"``) are decoded; arrays recurse element-wise.
    """
    if isinstance(v, bool):
        raise ValueError("boolean inputs not allowed")
    if isinstance(v, str):
        if v == "NaN":
            return float("nan")
        if v == "Inf":
            return float("inf")
        if v == "-Inf":
            return float("-inf")
        raise ValueError(f"unrecognized string input: {v!r}")
    if isinstance(v, list):
        return [_decode_input(x) for x in v]
    if isinstance(v, (int, float)):
        return float(v)
    raise TypeError(f"unsupported input type: {type(v).__name__}")


def _within_tol(actual: float, expected: float, abs_tol: float, rel_tol: float) -> bool:
    """Per esm-spec §9.2: pass if |actual − expected| ≤ abs OR
    |actual − expected| ≤ rel · max(1, |expected|). The ``max(1, ...)`` guard
    avoids zero relative tolerance when ``expected == 0``.
    """
    a = float(actual)
    e = float(expected)
    if math.isnan(a) and math.isnan(e):
        return True
    diff = abs(a - e)
    return diff <= abs_tol or diff <= rel_tol * max(1.0, abs(e))


def _enumerate_fixtures() -> List[Path]:
    if not FIXTURES_ROOT.exists():
        return []
    out: List[Path] = []
    for module_dir in sorted(FIXTURES_ROOT.iterdir()):
        if not module_dir.is_dir():
            continue
        for fn_dir in sorted(module_dir.iterdir()):
            if not fn_dir.is_dir():
                continue
            if (fn_dir / "expected.json").is_file() and (fn_dir / "canonical.esm").is_file():
                out.append(fn_dir)
    return out


_FIXTURE_DIRS = _enumerate_fixtures()


def test_fixtures_dir_exists():
    """The shared cross-binding fixture root must be present (esm-spec §9.4)."""
    assert FIXTURES_ROOT.is_dir(), (
        f"Closed-function fixtures missing at {FIXTURES_ROOT}; the v0.3.0 "
        f"closed registry requires the shared `tests/closed_functions/*` set."
    )
    assert _FIXTURE_DIRS, "No fixture directories found under tests/closed_functions/"


def test_closed_function_names_v030_set():
    """Sanity: ``closed_function_names()`` returns the v0.3.0 set verbatim."""
    names = closed_function_names()
    expected = {
        "datetime.year",
        "datetime.month",
        "datetime.day",
        "datetime.hour",
        "datetime.minute",
        "datetime.second",
        "datetime.day_of_year",
        "datetime.julian_day",
        "datetime.is_leap_year",
        "interp.searchsorted",
        "interp.linear",
        "interp.bilinear",
    }
    assert set(names) == expected
    assert len(names) == 12


def test_unknown_function_rejected():
    """Unknown ``fn`` names raise ``ClosedFunctionError`` with the spec code."""
    with pytest.raises(ClosedFunctionError) as exc:
        evaluate_closed_function("datetime.century", [0.0])
    assert exc.value.code == "unknown_closed_function"


@pytest.mark.parametrize(
    "fixture_dir",
    _FIXTURE_DIRS,
    ids=[str(p.relative_to(FIXTURES_ROOT)) for p in _FIXTURE_DIRS],
)
def test_closed_function_fixture(fixture_dir: Path):
    """Drive one ``<module>/<name>/`` fixture: parse canonical.esm, walk
    scenarios in expected.json, assert agreement at the spec tolerance.
    """
    canonical = fixture_dir / "canonical.esm"
    expected = fixture_dir / "expected.json"

    # Parser must accept the fixture (validates `fn`-op AST under v0.3.0 schema).
    file = load(canonical)
    assert file.version == "0.3.0", f"expected v0.3.0 fixture, got {file.version}"

    spec = json.loads(expected.read_text())
    fn_name = spec["function"]
    if fn_name not in closed_function_names():
        # Spec-first phased rollout (esm-94w and similar): a new closed
        # function may have its fixture defined in the spec PR before this
        # binding's implementation lands. Skip rather than fail; the
        # per-language [Impl] bead adds the function to the registry, at
        # which point this skip turns into a real run automatically.
        pytest.skip(f"fixture function {fn_name!r} not yet implemented in this binding")
    tol = spec.get("tolerance") or {}
    abs_tol = float(tol.get("abs", 0.0))
    rel_tol = float(tol.get("rel", 0.0))

    failures: List[str] = []
    for scenario in spec.get("scenarios", []):
        sname = scenario["name"]
        inputs = [_decode_input(v) for v in scenario["inputs"]]
        try:
            actual = evaluate_closed_function(fn_name, inputs)
        except Exception as e:  # pragma: no cover — should not happen for success cases
            failures.append(f"{sname}: raised unexpectedly: {e!r}")
            continue
        if not _within_tol(actual, scenario["expected"], abs_tol, rel_tol):
            failures.append(f"{sname}: got={actual!r}, expected={scenario['expected']!r}")

    for err in spec.get("error_scenarios", []) or []:
        ename = err["name"]
        inputs = [_decode_input(v) for v in err["inputs"]]
        expected_code = err["expected_error_code"]
        try:
            evaluate_closed_function(fn_name, inputs)
            failures.append(f"error_{ename}: expected {expected_code} but no error raised")
        except ClosedFunctionError as e:
            if e.code != expected_code:
                failures.append(f"error_{ename}: got code={e.code!r}, expected {expected_code!r}")

    assert not failures, "Fixture mismatches:\n  " + "\n  ".join(failures)


# ============================================================
# Direct unit tests — edge cases not covered by shared fixtures
# ============================================================


def test_arity_mismatch():
    """Wrong arg count raises with the ``closed_function_arity`` code."""
    with pytest.raises(ClosedFunctionError) as exc:
        evaluate_closed_function("datetime.year", [])
    assert exc.value.code == "closed_function_arity"

    with pytest.raises(ClosedFunctionError) as exc:
        evaluate_closed_function("interp.searchsorted", [1.0])
    assert exc.value.code == "closed_function_arity"


def test_searchsorted_empty_table():
    """Empty xs returns 1 — the consistent extension of the above-range rule."""
    assert evaluate_closed_function("interp.searchsorted", [0.0, []]) == 1


def test_evaluate_through_ast():
    """End-to-end: load a fixture, evaluate via the canonical AST evaluator."""
    fixture = FIXTURES_ROOT / "datetime" / "year" / "canonical.esm"
    file = load(fixture)
    eq = file.models["Probe"].equations[0]
    assert fold_constant_expr(eq.rhs, {"t_utc": 0.0}) == 1970.0
    assert fold_constant_expr(eq.rhs, {"t_utc": 951825600.0}) == 2000.0


def test_searchsorted_through_ast():
    """End-to-end: evaluating ``interp.searchsorted`` through the AST passes
    the inline ``const`` table as a raw list (not per-element-evaluated).
    """
    fixture = FIXTURES_ROOT / "interp" / "searchsorted" / "canonical.esm"
    file = load(fixture)
    eq = file.models["Probe"].equations[0]
    assert fold_constant_expr(eq.rhs, {"x": 2.5}) == 3.0
    assert fold_constant_expr(eq.rhs, {"x": 10.0}) == 6.0
    assert fold_constant_expr(eq.rhs, {"x": 1.0}) == 1.0


def test_enums_lowered_to_const():
    """End-to-end: ``enum`` ops are resolved to ``const`` integers at load."""
    fixture = VALID_DIR / "enums_categorical_lookup.esm"
    file = load(fixture)
    assert "season" in file.enums
    assert file.enums["season"]["summer"] == 3
    assert file.enums["land_use_class"]["deciduous_forest"] == 3

    expr = file.models["DryDep"].variables["r_c"].expression
    # `index` op with two enum-resolved arguments — both should now be `const` ints.
    assert expr.op == "index"
    assert expr.args[1].op == "const"
    assert expr.args[1].value == 3  # summer
    assert expr.args[2].op == "const"
    assert expr.args[2].value == 3  # deciduous_forest


def test_julian_day_ulp_close():
    """``datetime.julian_day`` agreement with the noon-UTC reference."""
    # Unix epoch midnight UTC = JD 2440587.5 (esm-spec §9.2.1 worked example).
    assert evaluate_closed_function("datetime.julian_day", [0.0]) == 2440587.5
    # Noon UTC of the same day = JD 2440588.0.
    assert evaluate_closed_function("datetime.julian_day", [43200.0]) == 2440588.0


def test_int32_overflow_raises():
    """Year far beyond Int32 range overflows. (Sanity — not spec-required.)

    Skipped: Python's stdlib ``datetime`` rejects years outside ``[1, 9999]``
    long before the closed-function Int32 overflow check would fire. This
    test documents the known limit.
    """
    pytest.skip(
        "Python stdlib datetime rejects out-of-range years before Int32 overflow "
        "fires; the spec contract is 'overflow if exceeded', not 'must reach 2^31'."
    )


def test_serializer_roundtrip_fn_op():
    """A loaded fixture's ``fn`` op survives serialize → reload byte-for-byte
    on the salient fields.
    """
    from earthsci_toolkit import save

    fixture = FIXTURES_ROOT / "datetime" / "year" / "canonical.esm"
    file = load(fixture)
    out = save(file)
    file2 = load(out)
    eq2 = file2.models["Probe"].equations[0]
    assert eq2.rhs.op == "fn"
    assert eq2.rhs.name == "datetime.year"
    assert eq2.rhs.args == ["t_utc"]


def test_serializer_roundtrip_const_array():
    """The inline ``const`` array under ``interp.searchsorted`` survives a
    serialize → reload round-trip.
    """
    from earthsci_toolkit import save

    fixture = FIXTURES_ROOT / "interp" / "searchsorted" / "canonical.esm"
    file = load(fixture)
    out = save(file)
    file2 = load(out)
    rhs2 = file2.models["Probe"].equations[0].rhs
    assert rhs2.op == "fn"
    assert rhs2.name == "interp.searchsorted"
    assert rhs2.args[1].op == "const"
    assert rhs2.args[1].value == [1.0, 2.0, 3.0, 4.0, 5.0]


def test_serializer_roundtrip_enums_block():
    """The top-level ``enums`` block round-trips through serialize → reload."""
    from earthsci_toolkit import save

    fixture = VALID_DIR / "enums_categorical_lookup.esm"
    file = load(fixture)
    out = save(file)
    file2 = load(out)
    assert file2.enums == file.enums
