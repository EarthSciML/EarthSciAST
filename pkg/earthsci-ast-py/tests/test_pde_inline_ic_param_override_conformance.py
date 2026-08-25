"""Cross-language conformance: a test's ``parameter_overrides`` reach the
BUILD-TIME evaluation scope (esm-spec §6.6.5 "Build-time evaluation scope",
§11.4.1 coordinate-expression ``ic``, §6.6 "keyed by local parameter name").

Shared fixture + Julia-minted golden live under
``tests/conformance/pde_inline_ic_param_override/`` (repo root); the Julia
runner (``conformance_pde_inline_ic_param_override_test.jl``) and the Rust
runner (``pde_inline_ic_param_override_conformance.rs``) gate the same golden.

Model ``M`` carries a parameter ``A`` (default 1.0) that appears ONLY inside
``ic(u) = A cos(pi x)`` and inside the analytic ``reference`` of two assertions
— never in an equation. So an inline test overriding ``A`` can change the answer
through the build-time scope and through nothing else, which is what makes the
three tests (``A`` defaulted / overridden to 0 / overridden to 2) discriminate.
State ``v`` is seeded by the parameter-FREE ``ic(v) = cos(pi x)`` and is the
independent anchor the ``A``-dependent reference is measured against, so a
binding that ignored the override in BOTH the ic and the reference cannot have
the two errors cancel and still pass.

Python resolves each parameter with :func:`earthsci_ast.simulation_common.
_resolve_override` (exact dot-namespaced key, then the bare trailing segment),
so the local spelling already bound here; this suite pins that against the
reference binding.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast.pde_inline_tests import run_pde_tests

_ROOT = (
    Path(__file__).resolve().parents[3] / "tests" / "conformance" / "pde_inline_ic_param_override"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "pde_inline_ic_param_override"
    assert manifest["reference_binding"] == "julia"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["fixtures"]


@pytest.mark.parametrize("fixture", _manifest()["fixtures"], ids=lambda f: f["id"])
def test_ic_param_override_matches_golden(fixture: dict) -> None:
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

    # Keyed by (test_id, assertion_idx): this category has THREE tests in one
    # model, distinguished only by their `parameter_overrides`.
    by_key = {(r.test_id, r.assertion_idx): r for r in results}
    for g in golden["assertions"]:
        key = (g["test_id"], int(g["assertion_idx"]))
        assert key in by_key, f"missing assertion {key}"
        r = by_key[key]
        assert r.passed, f"{key}: {r.message}"
        assert r.actual is not None
        assert r.actual == pytest.approx(float(g["actual"]), rel=rtol, abs=atol)


def test_local_and_qualified_override_keys_both_bind_the_build_scope() -> None:
    """Direct coverage of the naming contract the category gates: esm-spec §6.6
    keys `parameter_overrides` by LOCAL parameter name, while flattening
    qualifies it (``M.A``). Both spellings must reach the coordinate-expression
    `ic` seed; an override naming no parameter is REJECTED (§6.6.2)."""
    from earthsci_ast.parse import load_path
    from earthsci_ast.problem import ReturnCode, esm_problem, solve

    esm = load_path(str(_ROOT / "fixtures" / "ic_param_override.esm"))
    cells = [f"M.u[{i}]" for i in range(1, 6)]

    for key in ("A", "M.A"):
        result = solve(esm_problem(esm, (0.0, 1.0), p={key: 0.0}), alg="RK45", reltol=1e-12, abstol=1e-14)
        assert (result.retcode is ReturnCode.Success), result.message
        idx = {name: k for k, name in enumerate(result.vars)}
        for cell in cells:
            assert result.y[idx[cell]][0] == 0.0, f"{key}: {cell} not zeroed"

    # No parameter named `not_a_param`: esm-spec §6.6.2 makes that an ERROR.
    # This assertion previously pinned the opposite — that the default 1.0
    # simply stood — which is the same silent-wrong-answer shape the category
    # exists to close, one level up: the override does nothing and the run
    # still reports a verdict.
    from earthsci_ast.errors import UnknownParameterError

    with pytest.raises(UnknownParameterError, match="not_a_param"):
        solve(esm_problem(esm, (0.0, 1.0), p={"not_a_param": 7.0}), alg="RK45", reltol=1e-12, abstol=1e-14)
