"""Cross-language conformance: build-time value invention over a derived index set
(``tests/conformance/value_invention_materialize/``, issue #266).

The Julia runner (``value_invention_materialize_conformance_test.jl``) and the
Rust runner (``value_invention_materialize_conformance.rs``) gate the same
manifest. ``outcome: "value"`` pins the member count a contraction over the
derived axis must read; ``outcome: "refused"`` pins that a producer which cannot
run is refused under the manifest's code, with no actual -- in particular not
the 0 an empty range would contract to.
"""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.inline_tests import run_inline_tests

CATEGORY = FIXTURES_ROOT / "conformance" / "value_invention_materialize"


def _manifest() -> dict:
    return json.loads((CATEGORY / "manifest.json").read_text())


def test_manifest_shape() -> None:
    m = _manifest()
    assert m["category"] == "value_invention_materialize"
    for binding in ("julia", "python", "rust"):
        assert binding in m["bindings_required"], binding
    for binding, reason in m["scope_excluded"].items():
        assert reason.strip(), f"{binding} is excluded with no reason"
    outcomes = {c["outcome"] for fx in m["fixtures"] for c in fx["cases"]}
    assert outcomes == {"value", "refused"}


def _load_refusal_codes(exc: Exception) -> set[str]:
    """The finding codes a load-time structural refusal carries."""
    codes = {str(r.get("code")) for r in getattr(exc, "records", []) if isinstance(r, dict)}
    codes.update(str(code) for code, _ in getattr(exc, "findings", []))
    return codes


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda fx: fx["id"])
def test_value_invention_materialize_outcomes(fixture: dict) -> None:
    path = CATEGORY / fixture["path"]
    cases = fixture["cases"]
    try:
        results = run_inline_tests(str(path), model_name=fixture["model"])
    except Exception as exc:
        # A structural refusal at load is admitted only where the manifest says so.
        for case in cases:
            assert case["outcome"] == "refused", f"{fixture['id']}: refused at load: {exc}"
            assert "load" in case.get("refused_at", []), f"{fixture['id']}: refused at load: {exc}"
            assert case["code"] in _load_refusal_codes(exc), (
                f"{fixture['id']}: load refusal lacks {case['code']!r}: {exc}"
            )
        return
    assert len(results) == len(cases), (
        f"{fixture['id']}: ran {len(results)} assertions, manifest declares {len(cases)}"
    )
    by_idx = {r.assertion_idx: r for r in results if r.test_id == fixture["test_id"]}
    for case in cases:
        r = by_idx.get(case["assertion_idx"])
        assert r is not None, f"{fixture['id']}#{case['assertion_idx']}: no result row"
        assert r.variable == case["variable"]
        if case["outcome"] == "value":
            assert r.passed, f"{fixture['id']}: {r.message}"
            assert r.actual == pytest.approx(case["expected"], rel=1e-12, abs=0.0)
        else:
            assert not r.passed
            assert r.actual is None, f"{fixture['id']}: refused case produced {r.actual!r}"
            assert case["code"] in r.message, f"{fixture['id']}: {r.message}"
            if "names" in case:
                assert case["names"] in r.message, f"{fixture['id']}: {r.message}"
