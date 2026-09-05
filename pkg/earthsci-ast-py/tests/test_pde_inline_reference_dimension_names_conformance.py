"""Cross-language conformance: esm-spec §6.6.5 inline ``reference`` scope — the
field's DIMENSION NAMES are free variables of the reference (CONFORMANCE_SPEC
category ``pde_inline_reference_dimension_names``).

The shared fixture, the declared assertions and the Julia-minted goldens live
under ``tests/conformance/pde_inline_reference_dimension_names/`` (repo root);
the Julia runner (``conformance_pde_inline_reference_dimension_names_test.jl``)
and the Rust runner (``pde_inline_reference_dimension_names_conformance.rs``)
gate the same manifest.

The defect it closes: §6.6.5 says an inline ``reference`` is "an Expression
whose free variables are the domain dimension names", but every binding
evaluated the reference as ONE build-time array expression and sampled it per
cell, so a dimension name mentioned free was unbound ("Unresolved symbol: 'x'"
here) and authors had to spell every reference as an explicit
``aggregate(i from x; ...)`` gather. For a field shaped over index sets the
dimension names are the asserted variable's ``shape`` entries, bound per cell
to the 1-based position along the axis (the index space ``coords`` reads). The
fixture spells one exact decay field through the free-name analytic form, a
table lookup by the dimension name, the explicit gather, and a gather that
rebinds the dimension name as its own loop symbol (which must NOT be wrapped a
second time), plus a reference-free ``mean``.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.pde_inline_tests import run_pde_tests

_ROOT = (
    Path(__file__).resolve().parents[3]
    / "tests"
    / "conformance"
    / "pde_inline_reference_dimension_names"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "pde_inline_reference_dimension_names"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_reference_dimension_names_are_bound_per_cell(fixture: dict) -> None:
    manifest = _manifest()
    integ = manifest["integrators"]["python"]
    rtol = float(manifest["tolerances"]["assertion_rtol"])
    atol = float(manifest["tolerances"]["assertion_atol"])
    golden = json.loads((_ROOT / fixture["golden"]).read_text())
    assert golden["reference_binding"] == "julia"

    results = run_pde_tests(
        str(_ROOT / fixture["path"]),
        model_name=fixture["model"],
        method=integ["method"],
        rtol=float(integ["rtol"]),
        atol=float(integ["atol"]),
    )
    assert len(results) == len(golden["assertions"])
    by_idx = {r.assertion_idx: r for r in results}

    # Gate each assertion against BOTH the golden actual (the cross-binding
    # anchor) and the fixture's own declared `expected` (author intent).
    for g in golden["assertions"]:
        gi = int(g["assertion_idx"])
        assert gi in by_idx, f"missing assertion {gi}"
        r = by_idx[gi]
        assert r.variable == g["variable"]
        assert r.passed, f"assertion {gi} ({r.variable}): {r.message}"
        assert r.actual is not None
        assert float(r.actual) == pytest.approx(float(g["actual"]), rel=rtol, abs=atol)

    for decl in fixture["assertions"]:
        r = by_idx[int(decl["assertion_idx"])]
        assert r.variable == decl["variable"]
        assert r.reduce == decl.get("reduce")
        assert float(r.expected) == pytest.approx(float(decl["expected"]), rel=1e-12)
