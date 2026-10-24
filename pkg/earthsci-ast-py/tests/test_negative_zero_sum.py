"""A non-empty ``+`` reduction of ``-0.0`` terms is ``+0.0`` (esm-spec §4.3.1).

The fold is seeded from the identity 0̄ = +0.0, so ``0̄ + (-0.0) + (-0.0)`` is
``+0.0``; a fold seeded from its first term would give ``-0.0``. That is the one
input on which the two seedings differ, so every tier that answers a ``+`` node
is checked on it here, native against the interpreter bit for bit.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast.compiler import CompilerPolicy, use_policy
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import EvalContext, eval_expr

N = 6


def _ctx() -> EvalContext:
    u = np.full(N, -0.0)
    return EvalContext(
        state_layout={"u": slice(0, N)},
        state_shapes={"u": (N,)},
        param_values={},
        observed_values={},
        y=u,
        t=0.0,
        index_sets={"lev": {"kind": "interval", "size": N}},
    )


def _u(j: str) -> ExprNode:
    return ExprNode(op="index", args=["u", j])


def _scan(cmp: str) -> ExprNode:
    return ExprNode(
        op="faq",
        output_idx=["i"],
        reduce="+",
        ranges={"i": [1, N], "j": [1, N]},
        filter=ExprNode(op=cmp, args=["j", "i"]),
        expr=_u("j"),
    )


def _contraction() -> ExprNode:
    return ExprNode(op="faq", output_idx=[], reduce="+", ranges={"j": [1, N]}, expr=_u("j"))


def _gated() -> ExprNode:
    # The body reads `i`, so the scan tier declines and the dense gated reduce answers.
    node = _scan(">=")
    node.expr = ExprNode(op="*", args=[_u("j"), ExprNode(op="+", args=["i", 0.5])])
    return node


def _nested() -> ExprNode:
    inner = ExprNode(
        op="faq",
        output_idx=[],
        reduce="+",
        ranges={"j": {"from": "lev"}},
        filter=ExprNode(op=">=", args=["j", "i"]),
        expr=_u("j"),
    )
    return ExprNode(op="faq", output_idx=["i"], ranges={"i": {"from": "lev"}}, expr=inner)


_CASES = {
    "contraction": (_contraction, None),
    "inclusive-scan": (lambda: _scan("<="), "prefix-scan"),
    "reverse-scan": (lambda: _scan(">="), "prefix-scan"),
    "exclusive-reverse-scan": (lambda: _scan(">"), "prefix-scan"),
    "gated-reduce": (_gated, "gated-reduce"),
    "nested-reduce": (_nested, "nested-reduce"),
}


def _bits(a) -> np.ndarray:
    return np.ascontiguousarray(np.asarray(a, dtype=float)).view(np.uint64)


@pytest.mark.parametrize("case", sorted(_CASES))
def test_a_sum_of_negative_zeros_is_positive_zero(case):
    make, tier = _CASES[case]
    with use_policy(CompilerPolicy(compiler="interpreter", every_tier_off=True)):
        ref = np.asarray(eval_expr(make(), _ctx()), dtype=float)
    policy = CompilerPolicy(compiler="native")
    with use_policy(policy):
        got = np.asarray(eval_expr(make(), _ctx()), dtype=float)
    if tier is not None:
        assert policy.report.tiers().get(tier), policy.report.tiers()
    assert not np.signbit(ref).any(), ref
    assert np.array_equal(_bits(got), _bits(ref)), (got, ref)
    assert (got == 0.0).all()


def test_a_map_keeps_its_negative_zero():
    """No contracted index means no fold: the body's ``-0.0`` passes through."""
    node = ExprNode(op="faq", output_idx=["j"], ranges={"j": [1, N]}, expr=_u("j"))
    got = np.asarray(eval_expr(node, _ctx()), dtype=float)
    assert np.signbit(got).all()
