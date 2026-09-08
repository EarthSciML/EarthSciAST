"""Cross-language conformance: esm-spec §4.2's right-hand-side structural ``D``
rule, in both halves (``tests/conformance/rhs_time_derivative/``).

The Rust runner (``rhs_time_derivative_conformance.rs``) and the Julia runner
(``conformance_rhs_time_derivative_test.jl``) gate the same manifest.

The category pins OUTCOME CLASSES rather than a numeric golden, because half of
it has no number to record:

* ``outcome: "value"`` — the ``D`` named an unknown carrying a differential
  equation, so it resolves to that unknown's tendency and the assertion has an
  actual to compare;
* ``outcome: "refused"`` — the ``D`` named an observed, a parameter or a
  compound, resolves to nothing, and the run MUST be refused with the
  ``unlowered_operator`` diagnostic. There is no actual, and inventing one —
  **in particular ``0``** — is the defect this half exists to catch.

The refusal half is the fragile one, which is why ``d_of_parameter`` asserts
``expected: 0.0``: a constant's derivative really is 0, and 0 is what every
pre-fix Rust evaluator returned for *every* unresolvable ``D``. A binding that
answers it would pass on the arithmetic and fail here, which is the only way
round to catch it.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.pde_inline_tests import run_pde_tests

CATEGORY = FIXTURES_ROOT / "conformance" / "rhs_time_derivative"


def _manifest() -> dict:
    return json.loads((CATEGORY / "manifest.json").read_text())


def test_manifest_shape() -> None:
    """The manifest is the contract; a binding must not silently drop out of it."""
    m = _manifest()
    assert m["category"] == "rhs_time_derivative"
    for binding in ("julia", "python", "rust"):
        assert binding in m["bindings_required"], binding
    # Every excluded binding must say WHY, so a gap cannot masquerade as a
    # design decision.
    for binding, reason in m["scope_excluded"].items():
        assert reason.strip(), f"{binding} is excluded with no reason"
    # Both halves are present: dropping the refusal half would leave the
    # "in particular not 0" sentence ungated.
    outcomes = {
        c["outcome"] for fx in m["fixtures"] for c in fx["cases"]
    }
    assert outcomes == {"value", "refused"}


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda fx: fx["id"])
def test_rhs_time_derivative_outcomes(fixture: dict) -> None:
    path = CATEGORY / fixture["path"]
    results = run_pde_tests(str(path), model_name=fixture["model"])
    cases = fixture["cases"]
    assert len(results) == len(cases), (
        f"{fixture['id']}: ran {len(results)} assertions, manifest declares {len(cases)}"
    )

    by_idx = {r.assertion_idx: r for r in results if r.test_id == fixture["test_id"]}
    for case in cases:
        idx = case["assertion_idx"]
        r = by_idx.get(idx)
        assert r is not None, f"{fixture['id']}#{idx}: no result row"
        assert r.variable == case["variable"], (
            f"{fixture['id']}#{idx}: manifest and fixture disagree on the variable"
        )
        assert r.passed == case["passed"], (
            f"{fixture['id']}#{idx}: verdict {r.passed} — {case['note']} ({r.message})"
        )

        if case["outcome"] == "value":
            assert r.actual is not None, f"{fixture['id']}#{idx}: no actual ({r.message})"
            want = case["expected"]
            assert abs(r.actual - want) <= 1e-8 * max(1.0, abs(want)), (
                f"{fixture['id']}#{idx}: actual {r.actual} vs expected {want} — {case['note']}"
            )
        else:
            # A refusal carries NO number. This is the assertion that catches a
            # binding inventing 0.
            assert r.actual is None, (
                f"{fixture['id']}#{idx}: an unresolvable D must be refused, not "
                f"answered — got {r.actual}. {case['note']}"
            )
            assert case["diagnostic"] in r.message, (
                f"{fixture['id']}#{idx}: the refusal must carry the "
                f"{case['diagnostic']!r} code (esm-spec §9.6.3 constraint 6); got: {r.message}"
            )


def test_resolution_is_not_vacuous() -> None:
    """Guard the RESOLVE half against passing for the wrong reason: every
    tendency assertion must be non-zero, so a binding that still answers
    ``D(anything) = 0`` cannot satisfy it."""
    fx = next(f for f in _manifest()["fixtures"] if f["id"] == "tendency_resolution")
    tendencies = [c for c in fx["cases"] if c["variable"] in ("dxdt", "dAdt")]
    assert tendencies, "the resolve half must assert at least one tendency directly"
    for c in tendencies:
        assert c["expected"] != 0.0, f"{c['variable']}: a zero expectation gates nothing"


def test_fixture_paths_resolve() -> None:
    for fx in _manifest()["fixtures"]:
        assert (CATEGORY / fx["path"]).is_file(), fx["path"]
    assert isinstance(Path(CATEGORY), Path)
