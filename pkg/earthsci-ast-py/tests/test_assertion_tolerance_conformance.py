"""Python adapter for the SHARED ``assertion_tolerance`` conformance category
(CONFORMANCE_SPEC §5.32, ``tests/conformance/assertion_tolerance/``).

The category's subject is the esm-spec §6.6.3 pass predicate as a PURE FUNCTION
of ``(actual, expected, rel, abs)``. Every other assertion category is a
simulation category: it computes an actual and then compares it, so it can only
exercise the predicate at the pairs an integrator happens to produce — and those
all sit in the ``|actual| <= |expected|`` region, where ``rel*max(|a|,|e|)`` and
``rel*|e|`` compute the same number. The two readings differ only on an
OVERSHOOT, which no fixture in any category reaches. This adapter feeds the
discriminating pairs directly.

It calls :func:`earthsci_ast.pde_inline_tests._check_assertion` — the same
function ``run_pde_tests`` calls. An adapter that re-derived the predicate here
would be testing itself, which is the defect the category exists to close.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

from conftest import CONFORMANCE_DIR

from earthsci_ast.pde_inline_tests import _check_assertion

_CATEGORY: Path = CONFORMANCE_DIR / "assertion_tolerance"
_MANIFEST: Path = _CATEGORY / "manifest.json"
_GOLDEN: Path = _CATEGORY / "golden" / "predicate_verdicts.json"

_NON_FINITE = {"+inf": float("inf"), "-inf": float("-inf"), "nan": float("nan")}


def _manifest() -> Dict[str, Any]:
    return json.loads(_MANIFEST.read_text())


def _golden() -> Dict[str, Any]:
    return json.loads(_GOLDEN.read_text())


def _number(value: Any, case_id: str, field: str) -> float:
    """A golden ``actual``/``expected`` is either a JSON number or one of exactly
    three strings. An unrecognised value is a HARD ERROR: silently skipping a
    case would let the category shrink without anything going red."""
    if isinstance(value, bool):  # bool is an int subclass; never a valid entry
        raise AssertionError(f"{case_id}: {field} is a boolean")
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        if value in _NON_FINITE:
            return _NON_FINITE[value]
        raise AssertionError(
            f"{case_id}: {field} is the string {value!r}; the golden's encoding "
            f"admits only {sorted(_NON_FINITE)}"
        )
    raise AssertionError(f"{case_id}: {field} is {value!r}, expected a number or a string")


def test_python_is_required_and_the_manifest_says_so() -> None:
    m = _manifest()
    assert m["category"] == "assertion_tolerance"
    assert m["reference_binding"] == "analytic"
    # Python has a §6.6.3 predicate and a runner that uses it, so it must be
    # required rather than excluded.
    assert "python" in m["bindings_required"]
    assert "python" not in (m.get("scope_excluded") or {})


def test_every_golden_case_matches_the_binding_predicate() -> None:
    golden = _golden()
    cases: List[Dict[str, Any]] = golden["cases"]
    assert cases, "golden carries no cases"

    failures: List[str] = []
    n_pass = 0
    for case in cases:
        cid = case["id"]
        actual = _number(case["actual"], cid, "actual")
        expected = _number(case["expected"], cid, "expected")
        rel = float(case["rel"])
        abs_ = float(case["abs"])
        want = case["passed"]
        assert isinstance(want, bool), f"{cid}: `passed` must be a boolean"
        n_pass += int(want)

        got = _check_assertion(actual, expected, rel, abs_)
        if got is not want:
            failures.append(
                f"{cid}: _check_assertion({actual!r}, {expected!r}, rel={rel}, "
                f"abs={abs_}) = {got}, golden says {want} — {case.get('why', '')}"
            )

    assert not failures, "{} of {} §6.6.3 predicate cases disagree with the golden:\n{}".format(
        len(failures), len(cases), "\n".join(failures)
    )
    # Non-vacuity: a golden of one verdict would be satisfied by a constant.
    assert 0 < n_pass < len(cases)


def test_the_golden_can_still_see_every_known_wrong_reading() -> None:
    """The generator counts, per known WRONG reading of §6.6.3, how many cases
    change verdict under it. A zero would mean the case list had quietly stopped
    being able to see that defect — which is how the ~12 ad-hoc harnesses in
    #223 stayed green for years."""
    d = _golden()["readings_discriminated"]
    for reading in ("asymmetric", "sum_form", "epsilon_floor", "no_finiteness_guard"):
        assert d[reading] > 0, f"no golden case discriminates the `{reading}` reading of §6.6.3"
