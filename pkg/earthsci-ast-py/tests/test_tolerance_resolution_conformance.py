"""Cross-language conformance: esm-spec §6.6.4 tolerance RESOLUTION
(CONFORMANCE_SPEC §5.21).

The shared cases live in ``tests/conformance/tolerance_resolution/manifest.json``
(repo root); the Julia runner (``conformance_tolerance_resolution_test.jl``) and
the Rust runner (the ``tolerance_resolution_conformance_manifest`` unit test in
``inline_tests.rs``) gate the same file.

The category is DATA-ONLY: resolution is a pure function of the declared
``{abs?, rel?}`` blocks, so there is no ``.esm`` fixture, no integrator and no
numeric golden — each case feeds ``levels`` into ``_resolve_tolerance`` and
compares the returned ``(rel, abs)``.

The defect it closes (#228): all three bindings returned the first non-``None``
block WHOLE and defaulted its missing field to 0, so a model ``{rel: 1e-6}``
plus an assertion ``{abs: 1e-9}`` resolved to ``(0, 1e-9)`` and the assertion
ran with no relative bound at all. No other conformance tier could see this —
every fixture in every other category declares exactly one tolerance block, and
one block merges the same way whether the rule is per-field or wholesale.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.esm_types import Tolerance
from earthsci_ast.inline_tests import _DEFAULT_REL_TOL, _resolve_tolerance

_MANIFEST = (
    Path(__file__).resolve().parents[3]
    / "tests"
    / "conformance"
    / "tolerance_resolution"
    / "manifest.json"
)


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def _tolerance(block: dict | None) -> Tolerance | None:
    """Build a ``Tolerance`` from a manifest ``levels`` entry.

    A missing key and an explicit ``null`` both mean ABSENT, and both arrive
    here as ``None``; a ``0`` is a declared bound and must survive as ``0.0``.
    """
    if block is None:
        return None
    return Tolerance(abs=block.get("abs"), rel=block.get("rel"))


def test_manifest_is_well_formed() -> None:
    m = _manifest()
    assert m["category"] == "tolerance_resolution"
    assert set(m["bindings_required"]) == {"julia", "python", "rust"}
    assert m["integrators"] is None, "data-only category: no integrator may be pinned"
    assert len(m["cases"]) >= 15
    assert len({c["id"] for c in m["cases"]}) == len(m["cases"])
    # The tier must actually exercise the change it exists for.
    assert sum(1 for c in m["cases"] if c["changed_by_228"]) >= 5


@pytest.mark.parametrize("case", _manifest()["cases"], ids=lambda c: c["id"])
def test_tolerance_resolution_case(case: dict) -> None:
    levels = case["levels"]
    got = _resolve_tolerance(
        _tolerance(levels["model"]),
        _tolerance(levels["test"]),
        _tolerance(levels["assertion"]),
    )
    want = (case["resolved"]["rel"], case["resolved"]["abs"])
    assert got == want, f"{case['id']}: {case['note']}"


def test_resolution_is_monotone_and_never_tightens() -> None:
    """Every case must resolve no TIGHTER than the pre-#228 rule did.

    This is the safety argument for changing a shipped comparison rule: per
    field the merged value can only come from a level the wholesale rule
    ignored, never from one it consulted, so each bound is >= what it was and
    the §6.6.3 predicate is monotone in both. An assertion can therefore flip
    fail -> pass under this change, but never pass -> fail.
    """

    def wholesale(model, test, assertion):
        for candidate in (assertion, test, model):
            if candidate is None:
                continue
            return (
                0.0 if candidate.rel is None else float(candidate.rel),
                0.0 if candidate.abs is None else float(candidate.abs),
            )
        return (_DEFAULT_REL_TOL, 0.0)

    for case in _manifest()["cases"]:
        levels = case["levels"]
        args = (
            _tolerance(levels["model"]),
            _tolerance(levels["test"]),
            _tolerance(levels["assertion"]),
        )
        new_rel, new_abs = _resolve_tolerance(*args)
        old_rel, old_abs = wholesale(*args)
        assert new_rel >= old_rel and new_abs >= old_abs, case["id"]
        assert ((old_rel, old_abs) != (new_rel, new_abs)) == case["changed_by_228"], (
            f"{case['id']}: changed_by_228 is stale"
        )
