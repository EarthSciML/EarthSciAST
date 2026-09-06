"""Cross-language conformance: an ARRAY-shaped OBSERVED written ELEMENTWISE over
another array and consumed ONLY through an ``index(f, j)`` gather inside an
``aggregate`` body (esm-spec §4.3.4 elementwise broadcast, §6.6.5 assertions).

Shared fixtures + Julia-minted goldens live under
``tests/conformance/elementwise_observed_gather/`` (repo root); the Julia runner
(``conformance_elementwise_observed_gather_test.jl``) and the Rust runner
(``elementwise_observed_gather_conformance.rs``) gate the same goldens.

``zc`` is a const field shaped ``[lev]``; ``f = 1 + cos(pi*zc)`` is the natural
per-level spelling; ``colsum[i] = Σ_{j≤i} f[j]`` and ``total = Σ_j f[j]`` read it
through gathers and nothing else reads it at all. A binding that inlines ``f``
into its readers by name substitution turns the gather into
``index(1 + cos(pi*zc), j)`` and must distribute it over the elementwise
combination down to the array leaf. Julia's tree-walk resolver tested only the
IMMEDIATE operands for array-ness, so the leaf under the ``cos`` matched nothing
and ``zc`` reached the compiler bare (``E_TREEWALK_UNBOUND_VARIABLE``, issue
#175); Python and Rust already evaluated the document. This suite pins Python
against the reference binding so that stays true.

The category carries a controlled PAIR: ``elementwise_gather`` is the shape under
test and ``explicit_gather`` is the identical field written as an explicit
``aggregate(k from lev; 1 + cos(pi*index(zc, k)))``. They share every assertion,
so this suite additionally requires them to agree with each other
actual-for-actual — a divergence is the gather push-down, not the physics.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.pde_inline_tests import run_pde_tests

_ROOT = (
    Path(__file__).resolve().parents[3] / "tests" / "conformance" / "elementwise_observed_gather"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def _run(fixture: dict) -> dict[int, float]:
    """Run one fixture through the official runner, gate it against the golden,
    and return its actuals keyed by ``assertion_idx``."""
    manifest = _manifest()
    rtol = float(manifest["tolerances"]["assertion_rtol"])
    atol = float(manifest["tolerances"]["assertion_atol"])
    integ = manifest["integrators"]["python"]

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
    actuals: dict[int, float] = {}
    for g in golden["assertions"]:
        gi = int(g["assertion_idx"])
        assert gi in by_idx, f"missing assertion {gi}"
        r = by_idx[gi]
        assert r.passed, f"assertion {gi}: {r.message}"
        assert r.actual is not None
        assert r.actual == pytest.approx(float(g["actual"]), rel=rtol, abs=atol)
        actuals[gi] = float(r.actual)
    return actuals


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "elementwise_observed_gather"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_elementwise_observed_gather_matches_golden(fixture: dict) -> None:
    _run(fixture)


def test_both_spellings_agree_actual_for_actual() -> None:
    manifest = _manifest()
    rtol = float(manifest["tolerances"]["assertion_rtol"])
    atol = float(manifest["tolerances"]["assertion_atol"])
    by_id = {f["id"]: f for f in manifest["fixtures"]}
    elementwise = _run(by_id["elementwise_gather"])
    explicit = _run(by_id["explicit_gather"])
    assert sorted(elementwise) == sorted(explicit)
    for idx, value in elementwise.items():
        assert value == pytest.approx(explicit[idx], rel=rtol, abs=atol)
