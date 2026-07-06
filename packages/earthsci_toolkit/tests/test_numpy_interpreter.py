"""
Unit tests for :mod:`earthsci_toolkit.numpy_interpreter`.

These exercise each array op (arrayop, makearray, index, broadcast, reshape,
transpose, concat) and a sampling of scalar ops in isolation, using a
synthetic :class:`EvalContext` that binds a handful of state variables to a
flat numpy vector. The goal is to catch regressions in individual ops
without relying on the end-to-end ``simulate()`` pipeline.
"""

from __future__ import annotations

from typing import Dict, Tuple

import numpy as np
import pytest

from earthsci_toolkit.esm_types import ExprNode
from earthsci_toolkit.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    UnreachableSpatialOperatorError,
    eval_expr,
    expr_contains_array_op,
)


def _ctx(
    values: Dict[str, np.ndarray],
    params: Dict[str, float] | None = None,
    t: float = 0.0,
    index_sets: Dict[str, object] | None = None,
) -> EvalContext:
    """Build an :class:`EvalContext` from a dict of ``{name: ndarray}``.

    Variables are laid out in insertion order, each taking
    ``int(np.prod(arr.shape))`` slots in a shared flat state vector.
    ``index_sets`` supplies the document-scoped index-set registry (RFC §5.2).
    """
    state_layout: Dict[str, slice] = {}
    state_shapes: Dict[str, Tuple[int, ...]] = {}
    pieces: list[np.ndarray] = []
    offset = 0
    for name, arr in values.items():
        flat = np.asarray(arr, dtype=float).ravel()
        size = flat.size
        state_layout[name] = slice(offset, offset + size)
        state_shapes[name] = tuple(np.asarray(arr).shape) if np.asarray(arr).ndim else ()
        pieces.append(flat)
        offset += size
    y = np.concatenate(pieces) if pieces else np.zeros(0, dtype=float)
    return EvalContext(
        state_layout=state_layout,
        state_shapes=state_shapes,
        param_values=params or {},
        observed_values={},
        y=y,
        t=t,
        index_sets=index_sets or {},
    )


def test_scalar_arithmetic_and_elementary_funcs() -> None:
    ctx = _ctx({"x": np.asarray(2.0)})
    expr = ExprNode(
        op="+",
        args=[
            ExprNode(op="*", args=[3.0, "x"]),
            ExprNode(op="sin", args=[0.0]),
            ExprNode(op="^", args=["x", 2]),
        ],
    )
    assert eval_expr(expr, ctx) == pytest.approx(3.0 * 2.0 + 0.0 + 4.0)


def test_max_min_broadcast_array_and_scalar() -> None:
    """``max``/``min`` of an array field against a scalar broadcast elementwise.

    Regression: the interpreter used ``np.maximum.reduce(vals)`` /
    ``np.minimum.reduce(vals)``, which stack the operand list into one array
    first and fail with "setting an array element with a sequence
    (inhomogeneous shape)" when operands have mixed shapes — exactly the
    ``max(h[l], h_min)`` floor a multi-array-state PDE RHS evaluates every
    step. Pairwise reduction broadcasts instead, keeping the field array-valued.
    """
    ctx = _ctx({"h": np.array([1.0e-6, 2.0e-3, 5.0e-4])})
    np.testing.assert_allclose(
        eval_expr(ExprNode(op="max", args=["h", 1.0e-5]), ctx),
        [1.0e-5, 2.0e-3, 5.0e-4],
    )
    np.testing.assert_allclose(
        eval_expr(ExprNode(op="min", args=["h", 1.0e-5]), ctx),
        [1.0e-6, 1.0e-5, 1.0e-5],
    )
    # Three operands (scalar, array, array) still reduce pairwise.
    ctx2 = _ctx({"a": np.array([1.0, 9.0]), "b": np.array([4.0, 4.0])})
    np.testing.assert_allclose(
        eval_expr(ExprNode(op="max", args=[3.0, "a", "b"]), ctx2),
        [4.0, 9.0],
    )
    # All-scalar and all-same-shape-array cases are unchanged.
    assert eval_expr(ExprNode(op="max", args=[2.0, 5.0, 3.0]), _ctx({})) == 5.0


def test_index_1d_and_2d() -> None:
    ctx = _ctx({"u": np.array([1.0, 2.0, 3.0, 4.0])})
    assert eval_expr(ExprNode(op="index", args=["u", 3]), ctx) == pytest.approx(3.0)

    ctx2 = _ctx({"M": np.array([[11.0, 12.0, 13.0], [21.0, 22.0, 23.0]])})
    assert eval_expr(ExprNode(op="index", args=["M", 2, 3]), ctx2) == pytest.approx(23.0)


def test_arrayop_elementwise_1d() -> None:
    """``arrayop[i](u[i] * 2, ranges={i:1..3})`` returns ``[2u_1, 2u_2, 2u_3]``."""
    ctx = _ctx({"u": np.array([5.0, 6.0, 7.0])})
    expr = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr=ExprNode(op="*", args=[2.0, ExprNode(op="index", args=["u", "i"])]),
        ranges={"i": [1, 3]},
    )
    out = eval_expr(expr, ctx)
    assert isinstance(out, np.ndarray)
    np.testing.assert_allclose(out, [10.0, 12.0, 14.0])


def test_arrayop_offset_index() -> None:
    """Stencil-style offset index: ``u[i-1] + u[i+1]`` for ``i in 2..4``."""
    ctx = _ctx({"u": np.array([1.0, 10.0, 100.0, 1000.0, 10000.0])})
    expr = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr=ExprNode(
            op="+",
            args=[
                ExprNode(
                    op="index",
                    args=[
                        "u",
                        ExprNode(op="-", args=["i", 1]),
                    ],
                ),
                ExprNode(
                    op="index",
                    args=[
                        "u",
                        ExprNode(op="+", args=["i", 1]),
                    ],
                ),
            ],
        ),
        ranges={"i": [2, 4]},
    )
    out = eval_expr(expr, ctx)
    np.testing.assert_allclose(out, [1.0 + 100.0, 10.0 + 1000.0, 100.0 + 10000.0])


def test_makearray_overlapping_regions() -> None:
    expr = ExprNode(
        op="makearray",
        args=[],
        regions=[[[1, 3], [1, 3]], [[2, 3], [2, 3]]],
        values=[1.0, 2.0],
    )
    out = eval_expr(expr, _ctx({}))
    assert out.shape == (3, 3)
    # Top row and left column from region 1.
    assert out[0, 0] == 1.0
    assert out[0, 2] == 1.0
    assert out[2, 0] == 1.0
    # Overlap region from region 2.
    assert out[1, 1] == 2.0
    assert out[2, 2] == 2.0


def test_reshape_column_major_matches_julia() -> None:
    """``reshape([1..6], [2, 3])`` uses column-major order so ``M[1,2] == 3``."""
    ctx = _ctx({"u": np.array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])})
    expr = ExprNode(op="reshape", args=["u"], shape=[2, 3])
    out = eval_expr(expr, ctx)
    assert out.shape == (2, 3)
    # Julia column-major: element (1,2) == u[3] == 3.0
    assert out[0, 1] == pytest.approx(3.0)


def test_transpose_default_and_perm() -> None:
    ctx = _ctx({"M": np.array([[12.0, 13.0, 14.0], [23.0, 24.0, 25.0]])})
    out = eval_expr(ExprNode(op="transpose", args=["M"]), ctx)
    assert out.shape == (3, 2)
    assert out[0, 1] == pytest.approx(23.0)

    perm_out = eval_expr(ExprNode(op="transpose", args=["M"], perm=[1, 0]), ctx)
    np.testing.assert_allclose(perm_out, np.transpose(ctx.y.reshape(2, 3)))


def test_concat_1d_default_axis() -> None:
    ctx = _ctx(
        {
            "a": np.array([10.0, 20.0, 30.0]),
            "b": np.array([100.0, 200.0]),
        }
    )
    expr = ExprNode(op="concat", args=["a", "b"], axis=0)
    out = eval_expr(expr, ctx)
    np.testing.assert_allclose(out, [10.0, 20.0, 30.0, 100.0, 200.0])


def test_broadcast_julia_left_alignment() -> None:
    """``(3,) .+ (1,3)`` must produce shape ``(3, 3)`` like Julia, not ``(1, 3)``."""
    ctx = _ctx(
        {
            "a": np.array([1.0, 2.0, 3.0]),
            "b": np.array([100.0, 200.0, 300.0]),
        }
    )
    expr = ExprNode(
        op="broadcast",
        args=["a", ExprNode(op="reshape", args=["b"], shape=[1, 3])],
        fn="+",
    )
    out = eval_expr(expr, ctx)
    assert out.shape == (3, 3)
    assert out[0, 0] == pytest.approx(101.0)
    assert out[1, 2] == pytest.approx(302.0)
    assert out[2, 1] == pytest.approx(203.0)


def test_unsupported_op_raises() -> None:
    with pytest.raises(NumpyInterpreterError):
        eval_expr(ExprNode(op="bogus_op", args=[1.0]), _ctx({}))


@pytest.mark.parametrize("spatial_op", ["grad", "div", "laplacian", "D"])
def test_spatial_operator_in_simulator_rejected(spatial_op: str) -> None:
    """A non-lowered rewrite-target op — a spatial/RHS `D` or a
    `grad`/`div`/`laplacian` sugar op — fed to the simulator's RHS evaluator
    must raise the uniform `unlowered_operator` diagnostic (esm-spec §4.2 /
    §9.6.8) rather than silently returning zero or evaluating its inner arg (the
    historical stub behaviour). Supersedes the old per-binding code."""
    ctx = _ctx({"u": np.asarray(1.0)})
    kw = {"wrt": "x"} if spatial_op == "D" else {"dim": "x"}
    expr = ExprNode(op=spatial_op, args=["u"], **kw)
    with pytest.raises(UnreachableSpatialOperatorError) as excinfo:
        eval_expr(expr, ctx)
    msg = str(excinfo.value)
    assert "unlowered_operator" in msg
    assert spatial_op in msg
    assert excinfo.value.code == "unlowered_operator"
    assert excinfo.value.op == spatial_op


def test_expr_contains_array_op_recursion() -> None:
    inner = ExprNode(op="index", args=["u", 1])
    outer = ExprNode(op="+", args=[inner, 2.0])
    assert expr_contains_array_op(outer)
    assert not expr_contains_array_op(ExprNode(op="+", args=[1.0, 2.0]))


def test_arrayop_contraction_plus_matvec() -> None:
    """out[i] = Σ_j A[i,j] * x[j]  (matrix–vector product via fast einsum path)."""
    A = np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])  # 2×3
    x = np.array([10.0, 1.0, 0.1])  # shape (3,)
    ctx = _ctx({"A": A, "x": x})
    expr = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr=ExprNode(
            op="*",
            args=[
                ExprNode(op="index", args=["A", "i", "j"]),
                ExprNode(op="index", args=["x", "j"]),
            ],
        ),
        reduce="+",
        ranges={"i": [1, 2], "j": [1, 3]},
    )
    out = eval_expr(expr, ctx)
    expected = A @ x  # [12.3, 40.6]
    np.testing.assert_allclose(out, expected)


def test_arrayop_contraction_max_row() -> None:
    """out[i] = max_j A[i,j]  (row-wise max via fast outer-reduce path)."""
    A = np.array([[3.0, 1.0, 4.0], [1.0, 5.0, 9.0]])  # 2×3
    ctx = _ctx({"A": A})
    expr = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr=ExprNode(op="index", args=["A", "i", "j"]),
        reduce="max",
        ranges={"i": [1, 2], "j": [1, 3]},
    )
    out = eval_expr(expr, ctx)
    np.testing.assert_allclose(out, [4.0, 9.0])


def test_arrayop_contraction_min_row() -> None:
    """out[i] = min_j A[i,j]  (row-wise min via fast outer-reduce path)."""
    A = np.array([[3.0, 1.0, 4.0], [1.0, 5.0, 9.0]])  # 2×3
    ctx = _ctx({"A": A})
    expr = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr=ExprNode(op="index", args=["A", "i", "j"]),
        reduce="min",
        ranges={"i": [1, 2], "j": [1, 3]},
    )
    out = eval_expr(expr, ctx)
    np.testing.assert_allclose(out, [1.0, 1.0])


def test_arrayop_contraction_plus_scalar_coeff() -> None:
    """out[i] = Σ_j 2 * A[i,j] * x[j]  (scalar coefficient in fast path)."""
    A = np.array([[1.0, 2.0], [3.0, 4.0]])  # 2×2
    x = np.array([5.0, 6.0])
    ctx = _ctx({"A": A, "x": x})
    expr = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr=ExprNode(
            op="*",
            args=[
                2.0,
                ExprNode(op="index", args=["A", "i", "j"]),
                ExprNode(op="index", args=["x", "j"]),
            ],
        ),
        reduce="+",
        ranges={"i": [1, 2], "j": [1, 2]},
    )
    out = eval_expr(expr, ctx)
    expected = 2.0 * (A @ x)  # [2*(1*5+2*6), 2*(3*5+4*6)] = [34, 78]
    np.testing.assert_allclose(out, expected)


def test_arrayop_stencil_fallback_unchanged() -> None:
    """Stencil with offset subscripts still works via scalar fallback."""
    ctx = _ctx({"u": np.array([1.0, 10.0, 100.0, 1000.0, 10000.0])})
    expr = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr=ExprNode(
            op="+",
            args=[
                ExprNode(op="index", args=["u", ExprNode(op="-", args=["i", 1])]),
                ExprNode(op="index", args=["u", ExprNode(op="+", args=["i", 1])]),
            ],
        ),
        ranges={"i": [2, 4]},
    )
    out = eval_expr(expr, ctx)
    np.testing.assert_allclose(out, [1.0 + 100.0, 10.0 + 1000.0, 100.0 + 10000.0])


# ---------------------------------------------------------------------------
# M1: semiring parameterization, index-set registry, aggregate dispatch
# (RFC semiring-faq-unified-ir §5.1 / §5.2 / §5.4 / §5.6; bead ess-my4.1.4)
# ---------------------------------------------------------------------------


def _scalar_aggregate(semiring, body, ranges, reduce=None, op="aggregate"):
    return ExprNode(
        op=op, args=[], output_idx=[], semiring=semiring, reduce=reduce, expr=body, ranges=ranges
    )


def test_five_semirings_evaluate_with_correct_values() -> None:
    """Each registry semiring contracts a body with its (⊕, ⊗) pair (§5.1)."""
    # a = [3, 1, 4], b = [2, 5, 1]; index i over [1,3].
    ctx = _ctx({"a": np.array([3.0, 1.0, 4.0]), "b": np.array([2.0, 5.0, 1.0])})
    ia = ExprNode(op="index", args=["a", "i"])
    ib = ExprNode(op="index", args=["b", "i"])
    prod = ExprNode(op="*", args=[ia, ib])  # ⊗ = × body
    summ = ExprNode(op="+", args=[ia, ib])  # ⊗ = + body
    rng = {"i": [1, 3]}

    # sum_product: Σ a_i·b_i = 6 + 5 + 4 = 15
    assert eval_expr(_scalar_aggregate("sum_product", prod, rng), ctx) == pytest.approx(15.0)
    # max_product: max a_i·b_i = max(6, 5, 4) = 6
    assert eval_expr(_scalar_aggregate("max_product", prod, rng), ctx) == pytest.approx(6.0)
    # min_sum (tropical): min a_i+b_i = min(5, 6, 5) = 5
    assert eval_expr(_scalar_aggregate("min_sum", summ, rng), ctx) == pytest.approx(5.0)
    # max_sum: max a_i+b_i = max(5, 6, 5) = 6
    assert eval_expr(_scalar_aggregate("max_sum", summ, rng), ctx) == pytest.approx(6.0)
    # bool_and_or: ⋁ (a_i>2 ∧ b_i>2). a>2:[T,F,T], b>2:[F,T,F] → all F → 0
    bool_body = ExprNode(
        op="and", args=[ExprNode(op=">", args=[ia, 2]), ExprNode(op=">", args=[ib, 2])]
    )
    assert eval_expr(_scalar_aggregate("bool_and_or", bool_body, rng), ctx) == pytest.approx(0.0)
    # bool_and_or true case: ⋁ (a_i>2 ∧ b_i>0). a>2:[T,F,T], b>0:[T,T,T] → [T,F,T] → 1
    bool_true = ExprNode(
        op="and", args=[ExprNode(op=">", args=[ia, 2]), ExprNode(op=">", args=[ib, 0])]
    )
    assert eval_expr(_scalar_aggregate("bool_and_or", bool_true, rng), ctx) == pytest.approx(1.0)


@pytest.mark.parametrize(
    "semiring,expected",
    [
        ("sum_product", 0.0),
        ("max_product", -np.inf),
        ("min_sum", np.inf),
        ("max_sum", -np.inf),
        ("bool_and_or", 0.0),
    ],
)
def test_empty_reduction_returns_semiring_identity(semiring, expected) -> None:
    """An empty contraction returns the semiring's 0̄ identity (§5.1)."""
    ctx = _ctx({"a": np.array([3.0, 1.0, 4.0])})
    body = ExprNode(op="index", args=["a", "i"])
    out = eval_expr(_scalar_aggregate(semiring, body, {"i": [1, 0]}), ctx)
    assert out == expected


def test_no_semiring_defaults_to_sum_product_unchanged() -> None:
    """Absent semiring reproduces today's sum-of-products semantics (§9)."""
    ctx = _ctx({"a": np.array([3.0, 1.0, 4.0]), "b": np.array([2.0, 5.0, 1.0])})
    prod = ExprNode(
        op="*", args=[ExprNode(op="index", args=["a", "i"]), ExprNode(op="index", args=["b", "i"])]
    )
    # No semiring, no reduce → "+" over products = 15.
    assert eval_expr(_scalar_aggregate(None, prod, {"i": [1, 3]}), ctx) == pytest.approx(15.0)


def test_semiring_supersedes_reduce_field() -> None:
    """When both are present the semiring's ⊕ wins over `reduce` (§5.1)."""
    ctx = _ctx({"a": np.array([3.0, 1.0, 4.0])})
    body = ExprNode(op="index", args=["a", "i"])
    # reduce says "+" but semiring max_product ⊕ = max → 4, not 8.
    node = _scalar_aggregate("max_product", body, {"i": [1, 3]}, reduce="+")
    assert eval_expr(node, ctx) == pytest.approx(4.0)


def test_unregistered_semiring_raises() -> None:
    ctx = _ctx({"a": np.array([1.0, 2.0])})
    body = ExprNode(op="index", args=["a", "i"])
    node = _scalar_aggregate("tropical_max", body, {"i": [1, 2]})
    with pytest.raises(NumpyInterpreterError, match="unregistered semiring"):
        eval_expr(node, ctx)


def test_index_set_interval_and_categorical_resolution() -> None:
    """A {"from": name} range resolves an interval / categorical set (§5.2)."""
    idx = {
        "cells": {"kind": "interval", "size": 3},
        "county": {"kind": "categorical", "members": ["X", "Y", "Z"]},
    }
    ctx = _ctx({"a": np.array([3.0, 1.0, 4.0])}, index_sets=idx)
    body = ExprNode(op="index", args=["a", "i"])
    assert eval_expr(_scalar_aggregate(None, body, {"i": {"from": "cells"}}), ctx) == pytest.approx(
        8.0
    )
    assert eval_expr(
        _scalar_aggregate(None, body, {"i": {"from": "county"}}), ctx
    ) == pytest.approx(8.0)


def test_undeclared_from_name_errors() -> None:
    """A range 'from' an undeclared set errors — no implicit interval (§5.2)."""
    ctx = _ctx({"a": np.array([1.0, 2.0])}, index_sets={"cells": {"kind": "interval", "size": 2}})
    body = ExprNode(op="index", args=["a", "i"])
    node = _scalar_aggregate(None, body, {"i": {"from": "typo"}})
    with pytest.raises(NumpyInterpreterError, match="undeclared index set"):
        eval_expr(node, ctx)


def test_derived_index_set_not_supported_in_m1() -> None:
    ctx = _ctx({"a": np.array([1.0])}, index_sets={"e": {"kind": "derived", "from_faq": "x"}})
    body = ExprNode(op="index", args=["a", "i"])
    with pytest.raises(NumpyInterpreterError, match="derived"):
        eval_expr(_scalar_aggregate(None, body, {"i": {"from": "e"}}), ctx)


def test_ragged_index_set_dynamic_per_parent_bound() -> None:
    """A ragged inner set iterates [1..offsets[parent]] per parent (§5.2)."""
    idx = {
        "cells": {"kind": "interval", "size": 2},
        "edges_of_cell": {"kind": "ragged", "of": ["i"], "offsets": "nedges", "values": "edges"},
    }
    # cell 1 has 2 edges, cell 2 has 3 edges.
    ctx = _ctx({"nedges": np.array([2.0, 3.0])}, index_sets=idx)
    # out[i] = Σ_{k=1..nedges[i]} k  → [1+2, 1+2+3] = [3, 6]
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        expr="k",
        ranges={"i": {"from": "cells"}, "k": {"from": "edges_of_cell", "of": ["i"]}},
    )
    np.testing.assert_allclose(eval_expr(node, ctx), [3.0, 6.0])


def test_ragged_output_index_rejected() -> None:
    idx = {"edges_of_cell": {"kind": "ragged", "of": ["i"], "offsets": "nedges", "values": "edges"}}
    ctx = _ctx({"nedges": np.array([2.0])}, index_sets=idx)
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["k"],
        expr="k",
        ranges={"k": {"from": "edges_of_cell", "of": ["i"]}},
    )
    with pytest.raises(NumpyInterpreterError, match="ragged"):
        eval_expr(node, ctx)


def test_array_output_with_semiring_and_from() -> None:
    """Array-producing aggregate: out[i] over an index set, no contraction."""
    idx = {"cells": {"kind": "interval", "size": 3}}
    ctx = _ctx({"a": np.array([3.0, 1.0, 4.0]), "b": np.array([2.0, 5.0, 1.0])}, index_sets=idx)
    prod = ExprNode(
        op="*", args=[ExprNode(op="index", args=["a", "i"]), ExprNode(op="index", args=["b", "i"])]
    )
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        semiring="sum_product",
        expr=prod,
        ranges={"i": {"from": "cells"}},
    )
    np.testing.assert_allclose(eval_expr(node, ctx), [6.0, 5.0, 4.0])


def test_expr_contains_array_op_recognizes_aggregate() -> None:
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=[],
        expr=ExprNode(op="index", args=["a", "i"]),
        ranges={"i": [1, 2]},
    )
    assert expr_contains_array_op(node) is True


def test_matvec_contraction_with_two_indices_sum_product() -> None:
    """y[i] = Σ_k A[i,k]·x[k] via sum_product over a 2D factor."""
    A = np.array([[1.0, 2.0], [3.0, 4.0]])
    ctx = _ctx({"A": A, "x": np.array([5.0, 6.0])})
    body = ExprNode(
        op="*",
        args=[ExprNode(op="index", args=["A", "i", "k"]), ExprNode(op="index", args=["x", "k"])],
    )
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        semiring="sum_product",
        expr=body,
        ranges={"i": [1, 2], "k": [1, 2]},
    )
    # [1*5+2*6, 3*5+4*6] = [17, 39]
    np.testing.assert_allclose(eval_expr(node, ctx), [17.0, 39.0])


def test_closed_fn_lifts_over_grid_point_arg() -> None:
    """A scalar closed function (interp.linear) lifts element-wise over a grid-
    valued point argument — a per-cell LANDFIRE fuel code into a table lookup —
    while keeping the 0-D float result for scalar args. Regression for the
    'only size-1 arrays can be converted to Python scalars' coupled-RHS failure."""
    from earthsci_toolkit.numpy_interpreter import _eval_fn_lifted

    table, axis = [10.0, 20.0, 30.0], [1.0, 2.0, 3.0]  # interp.linear const args (0,1)
    # scalar point -> Python float (0-D contract preserved)
    out = _eval_fn_lifted("interp.linear", [table, axis, 2.5], (0, 1))
    assert isinstance(out, float) and abs(out - 25.0) < 1e-9
    # grid point -> per-element array (interp at 1->10, 2->20, 2.5->25, 3->30)
    x = np.array([[1.0, 2.0], [2.5, 3.0]])
    g = _eval_fn_lifted("interp.linear", [table, axis, x], (0, 1))
    assert isinstance(g, np.ndarray) and g.shape == (2, 2)
    np.testing.assert_allclose(g, [[10.0, 20.0], [25.0, 30.0]])
