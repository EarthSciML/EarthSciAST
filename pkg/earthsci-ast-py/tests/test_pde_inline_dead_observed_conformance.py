"""Cross-language conformance: a §6.6.5 assertion may read an array OBSERVED
that NO LIVE EQUATION CONSUMES (esm-spec §6.6.5, §5.23).

Shared fixture + Julia-minted golden live under
``tests/conformance/pde_inline_dead_observed/`` (repo root); the Julia runner
(``conformance_pde_inline_dead_observed_test.jl``) and the Rust runner
(``pde_inline_dead_observed_conformance.rs``) gate the same golden.

An inline test's natural target is a quantity computed FOR the test — a
tendency, a flux, a diagnostic — which by construction nothing else reads.
Model ``M`` declares two such dead observeds: ``diag = 2*base``, and ``chain =
diag + base``, which is dead AND reads a dead observed. Julia refused both
(``array state 'diag' has no cells in var_map``) because its build inlines an
elementwise array observed into its readers and drops the equation, and a dead
one has no readers to be inlined into; Python evaluates the ordered observed
graph on demand, so it already answered them. This suite pins that against the
reference binding.

The only state is ``u``, integrated with a zero right-hand side, so the
trajectory is constant and every assertion is exact under any pinned solver
family: a divergence here is a semantics divergence, never an integrator one.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.pde_inline_tests import run_pde_tests

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "pde_inline_dead_observed"
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "pde_inline_dead_observed"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_dead_observed_matches_golden(fixture: dict) -> None:
    manifest = _manifest()
    rtol = float(manifest["tolerances"]["assertion_rtol"])
    atol = float(manifest["tolerances"]["assertion_atol"])
    integ = manifest["integrators"]["python"]

    esm_path = _ROOT / fixture["path"]
    golden = json.loads((_ROOT / fixture["golden"]).read_text())
    assert golden["reference_binding"] == "julia"

    results = run_pde_tests(
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
