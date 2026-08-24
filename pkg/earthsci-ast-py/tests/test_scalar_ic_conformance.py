"""Cross-language conformance: 0-D (`scalar`) ``ic`` equations seed their state
(esm-spec §11.4 "Initial conditions (the `ic` op)", §11.4's "Run-time
overrides", §6.6.5 "Build-time evaluation scope").

Shared fixtures + Julia-minted goldens live under
``tests/conformance/scalar_ic/`` (repo root); the Julia runner
(``conformance_scalar_ic_test.jl``) and the Rust runner
(``scalar_ic_conformance.rs``) gate the same goldens.

Python used to drop every 0-D ``ic`` on BOTH of its pathways — the scalar-SymPy
one lowers only ``D(x)/dt`` and algebraic equations, and the array-NumPy one
folded only ARRAY-shaped ``ic`` targets while ``_apply_equation_to_dy`` no-op'd
the rest — so ``ic(u) ~ 3.0`` silently ran from ``u``'s declared ``default`` and
the inline test still reported a verdict. Every state in ``scalar_ic.esm``
declares a ``default`` that DIFFERS from its ``ic`` so the substitution cannot
hide, and ``y`` integrates ``D(y)/dt = u`` so the seeded value must reach the
trajectory too. ``scalar_ic_in_array_model.esm`` re-runs the contract for a 0-D
state inside an ARRAY model, which routes through the NumPy pathway instead.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.pde_inline_tests import run_pde_tests

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "scalar_ic"
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "scalar_ic"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_scalar_ic_matches_golden(fixture: dict) -> None:
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

    by_key = {(r.test_id, r.assertion_idx): r for r in results}
    for g in golden["assertions"]:
        key = (g["test_id"], int(g["assertion_idx"]))
        assert key in by_key, f"missing assertion {key}"
        r = by_key[key]
        assert r.passed, f"{key}: {r.message}"
        assert r.actual is not None
        assert r.actual == pytest.approx(float(g["actual"]), rel=rtol, abs=atol)


def test_scalar_ic_seeding_precedence() -> None:
    """Direct coverage of the esm-spec §11.4 precedence the category gates: an
    explicit ``initial_conditions`` entry wins, else the state's own ``ic``
    equation (parameters bound to their override-or-default values, §6.6.5),
    else the declared ``default``."""
    from earthsci_ast.parse import load_path
    from earthsci_ast.problem import ReturnCode, esm_problem, solve

    esm = load_path(str(_ROOT / "fixtures" / "scalar_ic.esm"))

    def at0(result, name: str) -> float:
        idx = {n: k for k, n in enumerate(result.vars)}
        return float(result.y[idx[name]][0])

    kw = {"alg": "RK45", "reltol": 1e-12, "abstol": 1e-14}

    # (1) Defaults: each state takes its own ic; `z` declares none and takes 7.
    res = solve(esm_problem(esm, (0.0, 1.0)), **kw)
    assert (res.retcode is ReturnCode.Success), res.message
    assert at0(res, "M.u") == 3.0
    assert at0(res, "M.q") == 2.0
    assert at0(res, "M.w") == 4.0
    assert at0(res, "M.z") == 7.0

    # (2) A parameter override reaches the ic's build-time scope, under either
    # spelling of the key (§6.6.2).
    for key in ("A", "M.A"):
        res = solve(esm_problem(esm, (0.0, 1.0), p={key: 10.0}), **kw)
        assert (res.retcode is ReturnCode.Success), res.message
        assert at0(res, "M.w") == 20.0
        assert at0(res, "M.u") == 3.0  # parameter-free ic unmoved

    # (3) A run-time `initial_conditions` entry beats the ic equation.
    for key in ("u", "M.u"):
        res = solve(esm_problem(esm, (0.0, 1.0), u0={key: 9.0}), **kw)
        assert (res.retcode is ReturnCode.Success), res.message
        assert at0(res, "M.u") == 9.0
        assert at0(res, "M.w") == 4.0  # a state the override does not name keeps its ic


def test_scalar_ic_inside_an_array_model_routes_through_the_numpy_path() -> None:
    """The mixed-rank fixture must reach the ARRAY runtime — otherwise the
    second fixture would be a duplicate of the first rather than independent
    coverage of the pathway that folded only array-shaped ic targets."""
    from earthsci_ast.parse import load_path
    from earthsci_ast.problem import ReturnCode, esm_problem, solve

    esm = load_path(str(_ROOT / "fixtures" / "scalar_ic_in_array_model.esm"))
    res = solve(esm_problem(esm, (0.0, 1.0)), alg="RK45", reltol=1e-12, abstol=1e-14)
    assert (res.retcode is ReturnCode.Success), res.message
    # Per-cell names are the array runtime's signature; the scalar-SymPy path
    # would report a single `N.f` row.
    assert "N.f[1]" in res.vars
    idx = {n: k for k, n in enumerate(res.vars)}
    assert float(res.y[idx["N.s"]][0]) == 6.0
