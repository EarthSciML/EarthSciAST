"""Cross-language conformance: esm-spec §6.6.5 assertions on a STATE-DEPENDENT
array OBSERVED (CONFORMANCE_SPEC — category
``pde_inline_observed_state_dependent``).

The shared fixture, the declared assertions and the Julia-minted goldens live
under ``tests/conformance/pde_inline_observed_state_dependent/`` (repo root);
the Julia runner (``conformance_pde_inline_observed_state_dependent_test.jl``)
and the Rust runner (``pde_inline_observed_state_dependent_conformance.rs``)
gate the same manifest.

The defect it closes: an array-shaped observed whose value depends on the
integrated state (``g = 2*u + rate``) is in NO build-time product — only
STATE-FREE observeds hoist into a build inspection's setup arrays — and is not
a scalar output row either, so every binding refused such an assertion outright
with "array state 'g' has no cells in var_map". §6.6.5 admits any shaped
variable in a ``coords`` / ``reduce`` assertion and §5.23 makes a reference
denote its expansion, so the observed must be evaluated at the SAMPLED STATE.
The fixture's ``rate`` is the state-free array observed of the same document,
asserted alongside so the build-materialized path stays pinned too.
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
    / "pde_inline_observed_state_dependent"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "pde_inline_observed_state_dependent"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_state_dependent_array_observed_is_assertable(fixture: dict) -> None:
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
