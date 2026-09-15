"""Cross-language conformance: a SHAPED observed whose right-hand side is a
SCALAR fills every cell of its declared shape (esm-spec §4.3.4).

Shared fixture + Julia-minted golden live under
``tests/conformance/shaped_observed_scalar_broadcast/`` (repo root); the Julia
runner (``conformance_shaped_observed_scalar_broadcast_test.jl``) and the Rust
runner (``shaped_observed_scalar_broadcast_conformance.rs``) gate the same
golden.

A scalar operand replicates along every axis of a shaped result, and a
right-hand side that is a scalar is the one-operand case of that rule. The
fixture writes it three ways: a literal (``literal ~ 1.5``), a scalar parameter
(``from_param ~ level``), and an ``ifelse`` whose predicate is a constant, so it
evaluates to its scalar branch (``folded``, issue #262). Python stored a scalar
value as a scalar observed whatever the declared shape, so an assertion on
``literal`` or ``from_param`` failed with ``array state '<name>' has no cells in
var_map``.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.inline_tests import run_inline_tests

_ROOT = (
    Path(__file__).resolve().parents[3]
    / "tests"
    / "conformance"
    / "shaped_observed_scalar_broadcast"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "shaped_observed_scalar_broadcast"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_scalar_rhs_broadcast_matches_golden(fixture: dict) -> None:
    manifest = _manifest()
    rtol = float(manifest["tolerances"]["assertion_rtol"])
    atol = float(manifest["tolerances"]["assertion_atol"])
    integ = manifest["integrators"]["python"]

    esm_path = _ROOT / fixture["path"]
    golden = json.loads((_ROOT / fixture["golden"]).read_text())
    assert golden["reference_binding"] == "julia"

    results = run_inline_tests(
        str(esm_path),
        model_name=fixture["model"],
        method=integ["method"],
        rtol=float(integ["rtol"]),
        atol=float(integ["atol"]),
    )
    assert len(results) == len(golden["assertions"])

    # Gate each assertion against BOTH the golden actual (the cross-binding
    # anchor) and the fixture's own declared `expected` (author intent).
    by_idx = {r.assertion_idx: r for r in results}
    for g in golden["assertions"]:
        idx = int(g["assertion_idx"])
        assert idx in by_idx, f"missing assertion {idx}"
        r = by_idx[idx]
        assert r.passed, f"{idx}: {r.message}"
        assert r.actual is not None
        assert r.actual == pytest.approx(float(g["actual"]), rel=rtol, abs=atol)
    for a in fixture["assertions"]:
        r = by_idx[int(a["assertion_idx"])]
        assert r.variable == a["variable"]
        assert r.actual == pytest.approx(float(a["expected"]), rel=rtol, abs=atol)
