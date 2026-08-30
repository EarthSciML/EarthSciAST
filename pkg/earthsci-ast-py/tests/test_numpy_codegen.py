"""Tier-1 source codegen for box-bound arrayop bodies (:mod:`numpy_codegen`).

The generated flat functions must be BIT-IDENTICAL to the compiled-closure
tier on every path they specialize — the pure-map stencils, the makearray
region values, and the broadcast contraction — because the conformance suite's
discipline for interpreter changes is bitwise equivalence, not tolerance. Each
test evaluates the same node shape twice on fresh trees (the codegen result is
cached on the node): once with codegen enabled, once with the
``_CODEGEN_DISABLE`` kill-switch oracle, and compares uint64 views.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast import numpy_codegen as NC
from earthsci_ast import numpy_interpreter as NI
from earthsci_ast.esm_types import ExprNode


def _idx(name, *subs):
    return ExprNode(op="index", args=[name, *subs])


def _add(*args):
    return ExprNode(op="+", args=list(args))


def _sub(*args):
    return ExprNode(op="-", args=list(args))


def _mul(*args):
    return ExprNode(op="*", args=list(args))


def _ctx(arrays=None, params=None):
    return NI.EvalContext(
        state_layout={},
        state_shapes={},
        param_values=dict(params or {}),
        observed_values={},
        y=np.empty(0),
        t=0.0,
        input_arrays=dict(arrays or {}),
    )


def _eval_both(make_agg, arrays=None, params=None):
    """(codegen result, kill-switch oracle result) on fresh trees each."""
    fast = NI._eval_arrayop(make_agg(), _ctx(arrays, params))
    prev = NI._CODEGEN_DISABLE
    NI._CODEGEN_DISABLE = True
    try:
        ref = NI._eval_arrayop(make_agg(), _ctx(arrays, params))
    finally:
        NI._CODEGEN_DISABLE = prev
    return fast, ref


def _assert_bitwise(fast, ref):
    assert fast.shape == ref.shape
    assert np.array_equal(fast.view(np.uint64), ref.view(np.uint64))


@pytest.fixture
def u():
    return np.random.default_rng(7).standard_normal((8, 5))


def test_stencil_map_is_bitwise_and_codegens(u) -> None:
    """A second-difference stencil map — affine gathers, a scalar param — takes
    the generated function (``_cg_map`` set) and matches the closures bitwise."""

    def make():
        body = ExprNode(
            op="/",
            args=[
                _add(
                    _idx("u", _add("i", 1), "j"),
                    _mul(-2.0, _idx("u", "i", "j")),
                    _idx("u", _sub("i", 1), "j"),
                ),
                "h2",
            ],
        )
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i", "j"],
            ranges={"i": [2, 7], "j": [1, 5]},
            expr=body,
        )

    node = make()
    res = NI._eval_arrayop(node, _ctx({"u": u}, {"h2": 0.25}))
    assert callable(node._cg_map)
    fast, ref = _eval_both(make, {"u": u}, {"h2": 0.25})
    _assert_bitwise(fast, ref)
    _assert_bitwise(res, ref)


def test_makearray_regions_are_bitwise(u) -> None:
    """The region-wise makearray identity gather (the discretized-RHS shape):
    interior stencil + boundary rows, last-wins overwrite, per-region codegen."""

    def make():
        interior = _mul(0.5, _add(_idx("u", _add("i", 1), "j"), _idx("u", _sub("i", 1), "j")))
        edge = _mul("i", 2.0)
        ma = ExprNode(
            op="makearray",
            args=[],
            regions=[[[1, 8], [1, 5]], [[2, 7], [2, 4]]],
            values=[edge, interior],
        )
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i", "j"],
            ranges={"i": [1, 8], "j": [1, 5]},
            expr=_idx(ma, "i", "j"),
        )

    node = make()
    NI._eval_arrayop(node, _ctx({"u": u}))
    ma_node = node.expr.args[0]
    fns = ma_node._cg_regions[(("i", "j"), (8, 5))]
    assert len(fns) == 2 and all(f is not None for f in fns)
    fast, ref = _eval_both(make, {"u": u})
    _assert_bitwise(fast, ref)


def test_const_body_does_not_alias_across_calls(u) -> None:
    """A map body that folds ENTIRELY to a constant (a pure function of the box
    indices) must not let the cached fold leak: mutating one evaluation's
    output must not perturb the next (the generated fn returns a fresh copy)."""

    def make():
        return ExprNode(
            op="aggregate", args=[], output_idx=["i"], ranges={"i": [1, 6]}, expr=_mul("i", 3.0)
        )

    node = make()
    first = NI._eval_arrayop(node, _ctx())
    expected = first.copy()
    first += 1e9  # simulate a downstream in-place consumer
    second = NI._eval_arrayop(node, _ctx())
    _assert_bitwise(second, expected)


def test_contraction_broadcast_is_bitwise(u) -> None:
    """An affine-subscript contraction (einsum-decomposer-rejected, the §9.6.8
    shape) takes ``_cg_contract`` and folds bitwise like the closure tier."""

    def make():
        body = _mul(_idx("u", _add("k", 1), "j"), _idx("w", _sub(_add("k", 8), "k"), "k"))
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["j"],
            ranges={"j": [1, 5], "k": [1, 6]},
            expr=body,
        )

    w = np.random.default_rng(11).standard_normal((9, 6))
    node = make()
    NI._eval_arrayop(node, _ctx({"u": u, "w": w}))
    assert callable(node._cg_contract)
    fast, ref = _eval_both(make, {"u": u, "w": w})
    _assert_bitwise(fast, ref)


def test_nested_aggregate_delegates_and_matches(u) -> None:
    """An inner aggregate inside the map body is delegated to eval_expr; it
    resolves the OUTER box symbol through ctx.locals (still bound by the
    wrapper) and the whole result matches the closures bitwise."""

    def make():
        inner = ExprNode(
            op="aggregate",
            args=[],
            output_idx=[],
            ranges={"k": [1, 3]},
            expr=_idx("u", _add("i", "k"), 1),
        )
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i"],
            ranges={"i": [1, 4]},
            expr=_add(inner, _idx("u", "i", 2)),
        )

    fast, ref = _eval_both(make, {"u": u})
    _assert_bitwise(fast, ref)


def test_data_dependent_subscript_stays_dynamic(u) -> None:
    """A gather through a runtime map (``u[tile[i], j]``) cannot hoist its
    index tuple; the generated `_gather_index` call matches the closures."""

    def make():
        body = _idx("u", _idx("tile", "i"), "j")
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i", "j"],
            ranges={"i": [1, 4], "j": [1, 5]},
            expr=body,
        )

    tile = np.asarray([3.0, 1.0, 4.0, 2.0])
    fast, ref = _eval_both(make, {"u": u, "tile": tile})
    _assert_bitwise(fast, ref)


def test_scalar_const_subscript_partial_index(u) -> None:
    """A constant scalar subscript keeps `_gather_index`'s scalar branch —
    including partial-index (row) semantics — inside a generated body."""

    def make():
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["j"],
            ranges={"j": [1, 5]},
            expr=_mul(_idx(_idx("u", 3), "j"), 2.0),
        )

    fast, ref = _eval_both(make, {"u": u})
    _assert_bitwise(fast, ref)


def test_repeated_symbols_and_scalar_funcs(u) -> None:
    """Symbol occurrence-CSE and the scalar-function/ifelse/cmp kernels all
    match the closures bitwise on one body."""

    def make():
        s = _idx("u", "i", "j")
        body = ExprNode(
            op="ifelse",
            args=[
                ExprNode(op=">", args=[s, 0.0]),
                ExprNode(op="sqrt", args=[ExprNode(op="abs", args=[s])]),
                ExprNode(op="min", args=[s, _mul(s, 0.5)]),
            ],
        )
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i", "j"],
            ranges={"i": [1, 8], "j": [1, 5]},
            expr=body,
        )

    fast, ref = _eval_both(make, {"u": u})
    _assert_bitwise(fast, ref)


def test_kill_switch_leaves_node_unmarked(u) -> None:
    """Under ``_CODEGEN_DISABLE`` no codegen attribute is stored on the node
    (the closure tier runs untouched, so the oracle really is the old path)."""

    def make():
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i"],
            ranges={"i": [1, 8]},
            expr=_mul(_idx("u", "i", 1), 2.0),
        )

    node = make()
    prev = NI._CODEGEN_DISABLE
    NI._CODEGEN_DISABLE = True
    try:
        NI._eval_arrayop(node, _ctx({"u": u}))
    finally:
        NI._CODEGEN_DISABLE = prev
    assert not hasattr(node, "_cg_map")


def test_error_parity_unresolved_symbol(u) -> None:
    """A body naming an unknown symbol raises the same error class with and
    without codegen (both paths decline the map and fail in the scalar loop)."""

    def make():
        return ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i"],
            ranges={"i": [1, 4]},
            expr=_mul(_idx("u", "i", 1), "nonexistent"),
        )

    with pytest.raises(NI.NumpyInterpreterError, match="Unresolved symbol"):
        NI._eval_arrayop(make(), _ctx({"u": u}))
    prev = NI._CODEGEN_DISABLE
    NI._CODEGEN_DISABLE = True
    try:
        with pytest.raises(NI.NumpyInterpreterError, match="Unresolved symbol"):
            NI._eval_arrayop(make(), _ctx({"u": u}))
    finally:
        NI._CODEGEN_DISABLE = prev


def test_compile_box_body_declines_on_bad_static_subtree() -> None:
    """A static subtree that raises at fold time declines codegen entirely
    (None), leaving the closure tier to reproduce the error per call."""
    bad = ExprNode(op="-", args=[])  # _apply_sub([]) raises IndexError
    body = _mul(bad, _idx("u", "i"))
    env = {"i": np.asarray([1.0, 2.0, 3.0]).reshape(3)}
    assert NC.compile_box_body(body, env) is None


def test_gather_hoisted_matches_gather_index_errors() -> None:
    """`_gather_hoisted` reproduces `_gather_index`'s vectorized-branch errors
    verbatim (scalar array value; rank mismatch)."""
    zi = (np.asarray([0, 1], dtype=np.intp),)
    with pytest.raises(NI.NumpyInterpreterError, match="index applied to scalar value"):
        NC._gather_hoisted(3.0, zi)
    with pytest.raises(NI.NumpyInterpreterError, match="index got 1 indices"):
        NC._gather_hoisted(np.zeros((2, 2)), zi)
