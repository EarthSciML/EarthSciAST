"""Interval-arithmetic fast path for shape inference (:func:`_collect_index_uses_interval`).

:func:`infer_variable_shapes` only consumes per-dimension index MAXIMA (and
tuple arity), so an aggregate's Cartesian box need not be enumerated pointwise
— binding each index symbol to its ``(min, max)`` hull and evaluating each
subscript once with interval arithmetic yields the identical maxima whenever
no bound symbol repeats inside a subscript (the shipped rules' subscripts are
all single-occurrence affine). These tests pin that equivalence against the
enumerating walk (the ``_SHAPE_INTERVAL_DISABLE`` kill-switch is the A/B
oracle), the exact-fallback on repeated symbols, and the range-shape edge
cases (stepped, descending, empty, nested boxes).
"""

from __future__ import annotations

import importlib
from collections import OrderedDict

import pytest

from earthsci_ast.esm_types import ExprNode

# ``import earthsci_ast.flatten as FL`` would resolve to the ``flatten``
# FUNCTION the package __init__ re-exports (it shadows the submodule
# attribute); go through importlib to get the module itself.
FL = importlib.import_module("earthsci_ast.flatten")
from earthsci_ast.flatten import (  # noqa: E402
    FlattenedEquation,
    FlattenedSystem,
    FlattenedVariable,
    infer_variable_shapes,
)


def _idx(name, *subs):
    return ExprNode(op="index", args=[name, *subs])


def _add(*args):
    return ExprNode(op="+", args=list(args))


def _sub(*args):
    return ExprNode(op="-", args=list(args))


def _mul(*args):
    return ExprNode(op="*", args=list(args))


def _system(rhs, state_names) -> FlattenedSystem:
    states = OrderedDict(
        (n, FlattenedVariable(name=n, type="state")) for n in ["M.out", *state_names]
    )
    return FlattenedSystem(
        state_variables=states,
        equations=[FlattenedEquation(lhs="M.out", rhs=rhs, source_system="M")],
    )


def _shapes_both_paths(rhs, state_names):
    """(interval-path shapes, enumeration-path shapes) for the same system."""
    fast = infer_variable_shapes(_system(rhs, state_names))
    prev = FL._SHAPE_INTERVAL_DISABLE
    FL._SHAPE_INTERVAL_DISABLE = True
    try:
        ref = infer_variable_shapes(_system(rhs, state_names))
    finally:
        FL._SHAPE_INTERVAL_DISABLE = prev
    return fast, ref


def _duo_strip_rhs() -> ExprNode:
    """A duo-halo-strip-shaped contraction: reduced-rank ``output_idx``,
    ranges not starting at 1, contracted 0-based symbols, affine gathers."""
    body = _mul(
        _idx("M.halo", _add("gi", 2), _sub("gj", 3), _add("k", 1)),
        _idx("M.dt", _add("k", 1), _add("l", 1)),
        _idx("M.refx", "gi"),
    )
    return ExprNode(
        op="aggregate",
        args=[],
        output_idx=[1, "gi", "gj"],
        ranges={"gi": [1, 3], "gj": [4, 7], "k": [0, 5], "l": [0, 5]},
        expr=body,
    )


def test_duo_strip_interval_matches_enumeration_without_pointwise_eval(monkeypatch) -> None:
    """The duo-shaped box is served by the interval path alone — the pointwise
    subscript evaluator must never run — and the shapes are identical."""

    def _forbidden(*_a, **_k):
        raise AssertionError("pointwise _eval_index_expr ran on an interval-servable box")

    fast = None
    with monkeypatch.context() as m:
        m.setattr(FL, "_eval_index_expr", _forbidden)
        fast = infer_variable_shapes(_system(_duo_strip_rhs(), ["M.halo", "M.dt", "M.refx"]))
    prev = FL._SHAPE_INTERVAL_DISABLE
    FL._SHAPE_INTERVAL_DISABLE = True
    try:
        ref = infer_variable_shapes(_system(_duo_strip_rhs(), ["M.halo", "M.dt", "M.refx"]))
    finally:
        FL._SHAPE_INTERVAL_DISABLE = prev
    assert fast == ref
    # gi+2 -> 5, gj-3 -> 4, k+1 -> 6; dt[k+1, l+1] -> (6, 6); refx[gi] -> (3,)
    assert fast["M.halo"] == (5, 4, 6)
    assert fast["M.dt"] == (6, 6)
    assert fast["M.refx"] == (3,)


def test_repeated_symbol_falls_back_exactly() -> None:
    """``u[i - i + 3]`` is pointwise always 3; the interval hull would
    over-cover to [3 - 4, 3 + 4]. The walker must decline and the enumeration
    must answer — identically to the kill-switch path."""
    body = _idx("M.u", _add(_sub("i", "i"), 3))
    assert not FL._collect_index_uses_interval(body, {"M.u"}, {}, {"i": (1, 5)})
    rhs = ExprNode(op="aggregate", args=[], output_idx=["i"], ranges={"i": [1, 5]}, expr=body)
    fast, ref = _shapes_both_paths(rhs, ["M.u"])
    assert fast == ref
    assert fast["M.u"] == (3,)


def test_stepped_and_descending_ranges() -> None:
    """Stepped ([1,2,7] -> {1,3,5,7}) and descending ([7,-2,1]) ranges hull to
    the same per-dimension maxima the enumeration finds."""
    rhs = _add(
        ExprNode(
            op="aggregate",
            args=[],
            output_idx=["i"],
            ranges={"i": [1, 2, 7]},
            expr=_idx("M.u", _sub(_mul(2, "i"), 1)),
        ),
        ExprNode(
            op="aggregate",
            args=[],
            output_idx=["j"],
            ranges={"j": [7, -2, 1]},
            expr=_idx("M.w", _add("j", 1)),
        ),
    )
    fast, ref = _shapes_both_paths(rhs, ["M.u", "M.w"])
    assert fast == ref
    assert fast["M.u"] == (13,)  # 2*7 - 1
    assert fast["M.w"] == (8,)  # 7 + 1


def test_empty_box_records_nothing() -> None:
    """An empty range ([3, 2]) means the enumeration visits no points; the
    interval path must record nothing either, leaving the variable scalar."""
    rhs = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        ranges={"i": [3, 2]},
        expr=_idx("M.u", "i"),
    )
    fast, ref = _shapes_both_paths(rhs, ["M.u"])
    assert fast == ref
    assert fast["M.u"] == ()


def test_nested_aggregate_boxes_compose() -> None:
    """An inner aggregate inherits the outer hull: ``u[i + k]`` with i in 1..4
    and k in 0..3 maxes at 7 on both paths."""
    inner = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["k"],
        ranges={"k": [0, 3]},
        expr=_idx("M.u", _add("i", "k")),
    )
    rhs = ExprNode(op="aggregate", args=[], output_idx=["i"], ranges={"i": [1, 4]}, expr=inner)
    fast, ref = _shapes_both_paths(rhs, ["M.u"])
    assert fast == ref
    assert fast["M.u"] == (7,)


def test_unbound_symbol_skips_site_on_both_paths() -> None:
    """A subscript naming a symbol bound by no box is skipped by the pointwise
    evaluator; the interval path must skip it identically (variable stays
    scalar), not fall back or invent a bound."""
    rhs = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        ranges={"i": [1, 4]},
        expr=_add(_idx("M.u", "unbound_sym"), _idx("M.w", "i")),
    )
    fast, ref = _shapes_both_paths(rhs, ["M.u", "M.w"])
    assert fast == ref
    assert fast["M.u"] == ()
    assert fast["M.w"] == (4,)


@pytest.mark.parametrize(
    ("expr", "bounds", "expected"),
    [
        (_add("i", 2), {"i": (1, 3)}, (3, 5)),
        (_sub(10, "i", "j"), {"i": (1, 3), "j": (0, 5)}, (2, 9)),
        (_sub("i"), {"i": (1, 3)}, (-3, -1)),
        (_mul("i", "j"), {"i": (-2, 3), "j": (-1, 4)}, (-8, 12)),
        (_mul(-1, "i"), {"i": (1, 3)}, (-3, -1)),
        ("free", {"i": (1, 3)}, None),
        (True, {"i": (1, 3)}, None),
        (2.0, {}, (2, 2)),
    ],
)
def test_interval_index_expr_hulls(expr, bounds, expected) -> None:
    assert FL._interval_index_expr(expr, bounds) == expected
