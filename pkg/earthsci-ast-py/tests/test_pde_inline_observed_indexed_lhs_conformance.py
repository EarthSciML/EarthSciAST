"""Cross-language conformance: the INDEXED LHS spelling of an ARRAY-shaped
observed (CONFORMANCE_SPEC — category ``pde_inline_observed_indexed_lhs``).

The shared fixture, the declared assertions and the Julia-minted goldens live
under ``tests/conformance/pde_inline_observed_indexed_lhs/`` (repo root); the
Julia runner (``conformance_pde_inline_observed_indexed_lhs_test.jl``) and the
Rust runner (``pde_inline_observed_indexed_lhs_conformance.rs``) gate the same
manifest.

The defect it closes: esm-spec §6.3.1 admits TWO LHS spellings for the equation
that DEFINES an unknown — bare (``y ~ f(...)``) and indexed (``y[i] ~ f(...)``,
which defines the whole array ``y``) — and neither is restricted by rank, since
the defining form is read through the LHS's BASE NAME. Julia's tree-walk build
classified equations by the SYNTACTIC ``lhs isa VarExpr`` instead, so an
array-shaped observed written the indexed way matched no owner bucket and was
refused outright with ``E_TREEWALK_UNSUPPORTED_SHAPE`` on a document Rust and
Python both ran (issue #232).

Both array observeds here use the indexed spelling and are asserted DIRECTLY —
that is what makes the category state the §6.3.1 contract rather than the
intersection the bindings happen to agree on. They are a controlled pair:
``wf`` is STATE-FREE and ``ws`` is STATE-DEPENDENT, the two classes a binding
routes differently, so fixing one path only does not pass. The states they drive
are asserted alongside, so answering the observeds while dropping them out of
the dynamics (or the reverse) still fails.

.. warning::

   **This binding is expected to FAIL this category today, and that is
   deliberate.** Python is kept in ``bindings_required`` rather than
   ``scope_excluded`` because it has a real runner: a conformance category
   states the contract and lets a non-conforming binding be red against it,
   instead of being defined down to what already passes.

   Python currently answers ``0.0`` for both indexed-LHS observeds (failing the
   six non-zero observed assertions) and passes the seven state assertions.
   Three divergences are involved — an indexed-LHS array observed is not
   readable by an assertion; one whose rhs is a PER-CELL body is silently
   dropped from the ODE RHS; and one feeding a WHOLE-ARRAY derivative
   (``D(u) ~ wf``) is dropped the same way. All three are being folded into
   PR #237 (issue #231), the last likely being the very defect that PR already
   fixes. Reproducers are in the body of PR #250, which introduced this
   category. See ``tests/conformance/pde_inline_observed_indexed_lhs/README.md``
   and CONFORMANCE_SPEC §5.30.1.
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
    / "pde_inline_observed_indexed_lhs"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "pde_inline_observed_indexed_lhs"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_indexed_lhs_array_observed_runs(fixture: dict) -> None:
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
