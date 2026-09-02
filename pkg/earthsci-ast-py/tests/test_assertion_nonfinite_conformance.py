"""Cross-language conformance: esm-spec §6.6.3's assertion comparison when the
ACTUAL value is NOT FINITE (CONFORMANCE_SPEC §5.19).

The shared fixture and the per-assertion verdicts live under
``tests/conformance/assertion_nonfinite/`` (repo root); the Julia runner
(``conformance_assertion_nonfinite_test.jl``) and the Rust runner
(``assertion_nonfinite_conformance.rs``) gate the same manifest.

This category pins VERDICTS rather than actuals, because ±Inf and NaN are not
JSON-representable: each case declares the class of the actual value (``+inf`` /
``-inf`` / ``nan`` / ``finite``) and the pass/fail the §6.6.3 rule requires. An
assertion passes only when ``actual == expected``, or both are finite and within
the resolved tolerance — so a non-finite actual fails against every finite
``expected``, whatever the tolerance.

The defect it closes: ``_check_assertion`` applied the tolerance bound with no
finiteness guard, and with ``actual = ±Inf`` both sides of
``|actual − expected| <= max(atol, rtol*max(|actual|, |expected|))`` are ``inf``,
so EVERY expected value passed. Julia's ``isapprox`` — the semantics this
predicate's docstring claims — carries the guard
(``x == y or (isfinite(x) and isfinite(y) and ...)``); the Python and Rust
re-implementations dropped it.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import pytest

from earthsci_ast.pde_inline_tests import _check_assertion, run_pde_tests

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "assertion_nonfinite"
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def _class_of(v: float) -> str:
    if math.isnan(v):
        return "nan"
    if v == math.inf:
        return "+inf"
    if v == -math.inf:
        return "-inf"
    return "finite"


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "assertion_nonfinite"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_nonfinite_actuals_fail_every_finite_expectation(fixture: dict) -> None:
    manifest = _manifest()
    integ = manifest["integrators"]["python"]
    results = run_pde_tests(
        str(_ROOT / fixture["path"]),
        model_name=fixture["model"],
        method=integ["method"],
        rtol=float(integ["rtol"]),
        atol=float(integ["atol"]),
    )
    cases = fixture["cases"]
    assert len(results) == len(cases)
    by_key = {(r.test_id, r.assertion_idx): r for r in results}
    for case in cases:
        key = (fixture["test_id"], int(case["assertion_idx"]))
        assert key in by_key, f"missing assertion {key}"
        r = by_key[key]
        assert r.variable == case["variable"]
        assert r.actual is not None, f"{key}: no actual ({r.message})"
        assert _class_of(float(r.actual)) == case["actual_class"], f"{key}: actual {r.actual}"
        # The verdict IS the contract.
        assert r.passed is bool(case["passed"]), (
            f"{key}: verdict {r.passed} (actual={r.actual}, expected={r.expected}, "
            f"rtol={r.rtol}, atol={r.atol}) — {case.get('note', '')}"
        )
        if "actual" in case:
            assert float(r.actual) == pytest.approx(float(case["actual"]), rel=1e-9)


def test_check_assertion_judges_finiteness_before_tolerance() -> None:
    """The predicate itself, at the boundary the fixture cannot spell: JSON has
    no infinite literal, so ``expected = ±Inf`` is only reachable through the
    API. The same infinity matches; a different one, or a NaN, does not."""
    inf = math.inf
    nan = math.nan
    for rtol, atol in ((1e-9, 0.0), (0.0, 1e300), (1e-9, 1e300), (0.0, 0.0)):
        assert not _check_assertion(inf, 42.0, rtol, atol)
        assert not _check_assertion(inf, 0.0, rtol, atol)
        assert not _check_assertion(-inf, -42.0, rtol, atol)
        assert not _check_assertion(nan, 0.0, rtol, atol)
        assert not _check_assertion(nan, nan, rtol, atol)
        assert not _check_assertion(1e300, inf, rtol, atol)
        # The one legitimate non-finite match, and only with the same sign.
        assert _check_assertion(inf, inf, rtol, atol)
        assert _check_assertion(-inf, -inf, rtol, atol)
        assert not _check_assertion(inf, -inf, rtol, atol)
        assert not _check_assertion(-inf, inf, rtol, atol)
    # Unchanged for finite values, signed zero included.
    assert _check_assertion(1.0, 1.0 + 1e-12, 1e-9, 0.0)
    assert not _check_assertion(1.0, 1.1, 1e-9, 0.0)
    assert _check_assertion(-0.0, 0.0, 0.0, 0.0)
    assert _check_assertion(2.0, 2.0, 0.0, 0.0)
    assert not _check_assertion(2.0, 2.0000001, 0.0, 0.0)
