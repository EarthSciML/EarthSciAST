"""CONFORMANCE_SPEC §5.6.1: a scalar ``bool_and_or`` reduction runs under both
compilers (``tests/conformance/bool_and_or_reductions`` gates its values); an
array-valued one is rejected."""

from __future__ import annotations

import json

import pytest

from earthsci_ast.parse import load_string
from earthsci_ast.problem import esm_problem, solve


def _doc(rhs_output_idx: list[str]) -> dict:
    faq = lambda out, ranges, expr, **kw: {  # noqa: E731
        "op": "faq", "args": [], "output_idx": out, "ranges": ranges, "expr": expr, **kw
    }
    u_k = {"op": "index", "args": ["u", "k"]}
    u_i = {"op": "index", "args": ["u", "i"]}
    d_u = {"op": "D", "args": [u_i], "wrt": "t"}
    if rhs_output_idx:
        rhs = faq(["i"], {"i": [1, 3], "k": [1, 3]}, {"op": ">", "args": [u_k, u_i]},
                  semiring="bool_and_or")
        eqs = [{"lhs": faq(["i"], {"i": [1, 3]}, d_u), "rhs": rhs}]
        variables = {"u": {"type": "unknown", "shape": ["x"], "default": [1.0, 2.0, 3.0]}}
    else:
        any_big = faq([], {"k": [1, 3]}, {"op": ">", "args": [u_k, 2.5]}, semiring="bool_and_or")
        eqs = [
            {"lhs": "b", "rhs": any_big},
            {"lhs": faq(["i"], {"i": [1, 3]}, d_u),
             "rhs": faq(["i"], {"i": [1, 3]}, {"op": "*", "args": ["b", u_i]})},
        ]
        variables = {
            "u": {"type": "unknown", "shape": ["x"], "default": [1.0, 2.0, 3.0]},
            "b": {"type": "unknown"},
        }
    return {
        "esm": "1.1.0",
        "metadata": {"name": "bool_and_or"},
        "index_sets": {"x": {"kind": "interval", "size": 3}},
        "models": {"M": {"variables": variables, "equations": eqs}},
    }


@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_scalar_bool_and_or_runs(compiler: str) -> None:
    prob = esm_problem(load_string(json.dumps(_doc([]))), (0.0, 1.0), compiler=compiler)
    r = solve(prob, alg="RK45", reltol=1e-10, abstol=1e-12)
    idx = {n: k for k, n in enumerate(r.vars)}
    # b = 1 (u[3] = 3 > 2.5), so u grows as e^t.
    assert float(r.y[idx["M.u[1]"]][-1]) == pytest.approx(2.718281828, rel=1e-6)


@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_array_valued_bool_and_or_is_rejected(compiler: str) -> None:
    with pytest.raises(Exception, match=r"bool_and_or.*5\.6\.1"):
        prob = esm_problem(load_string(json.dumps(_doc(["i"]))), (0.0, 1.0), compiler=compiler)
        solve(prob, alg="RK45")
