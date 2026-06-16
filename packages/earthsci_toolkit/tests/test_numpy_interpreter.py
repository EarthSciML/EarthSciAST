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
) -> EvalContext:
    """Build an :class:`EvalContext` from a dict of ``{name: ndarray}``.

    Variables are laid out in insertion order, each taking
    ``int(np.prod(arr.shape))`` slots in a shared flat state vector.
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
    )


def test_scalar_arithmetic_and_elementary_funcs() -> None:
    ctx = _ctx({"x": np.asarray(2.0)})
    expr = ExprNode(op="+", args=[
        ExprNode(op="*", args=[3.0, "x"]),
        ExprNode(op="sin", args=[0.0]),
        ExprNode(op="^", args=["x", 2]),
    ])
    assert eval_expr(expr, ctx) == pytest.approx(3.0 * 2.0 + 0.0 + 4.0)


def test_index_1d_and_2d() -> None:
    ctx = _ctx({"u": np.array([1.0, 2.0, 3.0, 4.0])})
    assert eval_expr(
        ExprNode(op="index", args=["u", 3]), ctx
    ) == pytest.approx(3.0)

    ctx2 = _ctx({"M": np.array([[11.0, 12.0, 13.0], [21.0, 22.0, 23.0]])})
    assert eval_expr(
        ExprNode(op="index", args=["M", 2, 3]), ctx2
    ) == pytest.approx(23.0)


def test_arrayop_elementwise_1d() -> None:
    """``arrayop[i](u[i] * 2, ranges={i:1..3})`` returns ``[2u_1, 2u_2, 2u_3]``."""
    ctx = _ctx({"u": np.array([5.0, 6.0, 7.0])})
    expr = ExprNode(
        op="arrayop",
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
        op="arrayop",
        args=[],
        output_idx=["i"],
        expr=ExprNode(op="+", args=[
            ExprNode(op="index", args=[
                "u", ExprNode(op="-", args=["i", 1]),
            ]),
            ExprNode(op="index", args=[
                "u", ExprNode(op="+", args=["i", 1]),
            ]),
        ]),
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

    perm_out = eval_expr(
        ExprNode(op="transpose", args=["M"], perm=[1, 0]), ctx
    )
    np.testing.assert_allclose(perm_out, np.transpose(ctx.y.reshape(2, 3)))


def test_concat_1d_default_axis() -> None:
    ctx = _ctx({
        "a": np.array([10.0, 20.0, 30.0]),
        "b": np.array([100.0, 200.0]),
    })
    expr = ExprNode(op="concat", args=["a", "b"], axis=0)
    out = eval_expr(expr, ctx)
    np.testing.assert_allclose(out, [10.0, 20.0, 30.0, 100.0, 200.0])


def test_broadcast_julia_left_alignment() -> None:
    """``(3,) .+ (1,3)`` must produce shape ``(3, 3)`` like Julia, not ``(1, 3)``."""
    ctx = _ctx({
        "a": np.array([1.0, 2.0, 3.0]),
        "b": np.array([100.0, 200.0, 300.0]),
    })
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


@pytest.mark.parametrize("spatial_op", ["grad", "div", "laplacian"])
def test_spatial_operator_in_simulator_rejected(spatial_op: str) -> None:
    """esm-i7b: a non-discretized AST containing `grad`/`div`/`laplacian`
    fed to the simulator's RHS evaluator must raise the canonical
    pipeline-violation error rather than silently returning zero (the
    historical stub-to-zero behaviour)."""
    ctx = _ctx({"u": np.asarray(1.0)})
    expr = ExprNode(op=spatial_op, args=["u"])
    with pytest.raises(UnreachableSpatialOperatorError) as excinfo:
        eval_expr(expr, ctx)
    msg = str(excinfo.value)
    assert "UnreachableSpatialOperatorError" in msg
    assert spatial_op in msg
    assert "Pipeline contract violated" in msg
    assert excinfo.value.op == spatial_op


def test_expr_contains_array_op_recursion() -> None:
    inner = ExprNode(op="index", args=["u", 1])
    outer = ExprNode(op="+", args=[inner, 2.0])
    assert expr_contains_array_op(outer)
    assert not expr_contains_array_op(ExprNode(op="+", args=[1.0, 2.0]))


def test_arrayop_contraction_plus_matvec() -> None:
    """out[i] = Σ_j A[i,j] * x[j]  (matrix–vector product via fast einsum path)."""
    A = np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])   # 2×3
    x = np.array([10.0, 1.0, 0.1])                       # shape (3,)
    ctx = _ctx({"A": A, "x": x})
    expr = ExprNode(
        op="arrayop",
        args=[],
        output_idx=["i"],
        expr=ExprNode(op="*", args=[
            ExprNode(op="index", args=["A", "i", "j"]),
            ExprNode(op="index", args=["x", "j"]),
        ]),
        reduce="+",
        ranges={"i": [1, 2], "j": [1, 3]},
    )
    out = eval_expr(expr, ctx)
    expected = A @ x  # [12.3, 40.6]
    np.testing.assert_allclose(out, expected)


def test_arrayop_contraction_max_row() -> None:
    """out[i] = max_j A[i,j]  (row-wise max via fast outer-reduce path)."""
    A = np.array([[3.0, 1.0, 4.0], [1.0, 5.0, 9.0]])   # 2×3
    ctx = _ctx({"A": A})
    expr = ExprNode(
        op="arrayop",
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
    A = np.array([[3.0, 1.0, 4.0], [1.0, 5.0, 9.0]])   # 2×3
    ctx = _ctx({"A": A})
    expr = ExprNode(
        op="arrayop",
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
    A = np.array([[1.0, 2.0], [3.0, 4.0]])   # 2×2
    x = np.array([5.0, 6.0])
    ctx = _ctx({"A": A, "x": x})
    expr = ExprNode(
        op="arrayop",
        args=[],
        output_idx=["i"],
        expr=ExprNode(op="*", args=[
            2.0,
            ExprNode(op="index", args=["A", "i", "j"]),
            ExprNode(op="index", args=["x", "j"]),
        ]),
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
        op="arrayop",
        args=[],
        output_idx=["i"],
        expr=ExprNode(op="+", args=[
            ExprNode(op="index", args=["u", ExprNode(op="-", args=["i", 1])]),
            ExprNode(op="index", args=["u", ExprNode(op="+", args=["i", 1])]),
        ]),
        ranges={"i": [2, 4]},
    )
    out = eval_expr(expr, ctx)
    np.testing.assert_allclose(out, [1.0 + 100.0, 10.0 + 1000.0, 100.0 + 10000.0])
