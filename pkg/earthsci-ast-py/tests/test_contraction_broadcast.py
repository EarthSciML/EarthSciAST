"""Whole-box broadcast contraction path (:func:`_eval_arrayop_contraction_broadcast`).

The Python mirror of EarthSciAST.jl's affine-stencilizer contraction unroll
(fd81e922f): a PLAIN contraction (no join / filter / ragged range) whose body
the einsum decomposer rejects — affine subscripts, tent-weight ``max``/``min``
gates — must evaluate over the combined ``out × reduce`` box in one body walk
and ⊕-fold the reduce axes in ``_cartesian`` term order, bit-for-bit the
scalar loop's answer. The fixtures are duo-shaped: the esm-spec §9.6.8
halo-strip remap (reduced-rank ``output_idx`` with a literal-pinned singleton
axis, output ranges that do not start at 1, contracted ranges that start at 0,
a tent-basis ``max(0, min(...))`` body over affine gathers).
"""

from __future__ import annotations

import numpy as np
import pytest

import earthsci_ast.numpy_interpreter as NI
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import eval_expr

from test_numpy_interpreter import _ctx


def _idx(name, *subs):
    return ExprNode(op="index", args=[name, *subs])


def _aff(sym, off):
    return ExprNode(op="+", args=[sym, off])


def _duo_strip_node(reduce_op: str | None = None) -> ExprNode:
    """A duo-halo-strip-shaped contraction: reduced-rank ``output_idx``
    ``[1, gi, gj]``; ``gi`` in 1..3, ``gj`` in 4..7 (not 1-based); ``k``, ``l``
    contracted over 0..5 (0-based); tent-weight body over affine gathers into
    the 1-D reference coordinates ``refx``/``refy`` and the donor field ``dt``.
    """
    # weight(c, ref, s) = max(0, 1 - |c - ref[s+2]|)  — a hat basis centred on
    # ref[s+2], nonzero for at most two consecutive s: a genuine gather-gate.
    def tent(coord, ref, sym):
        dist = ExprNode(op="abs", args=[ExprNode(op="-", args=[coord, _idx(ref, _aff(sym, 2))])])
        return ExprNode(op="max", args=[0.0, ExprNode(op="-", args=[1.0, dist])])

    body = ExprNode(
        op="*",
        args=[
            tent(ExprNode(op="-", args=["gj", 3]), "refx", "k"),
            tent("gi", "refy", "l"),
            _idx("dt", _aff("k", 1), _aff("l", 1)),
        ],
    )
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=[1, "gi", "gj"],
        ranges={"gi": [1, 3], "gj": [4, 7], "k": [0, 5], "l": [0, 5]},
        expr=body,
    )
    if reduce_op is not None:
        node.reduce = reduce_op
    return node


def _strip_ctx():
    rng = np.random.default_rng(20260829)
    return _ctx(
        {
            "dt": rng.uniform(-2.0, 2.0, size=(6, 6)),
            "refx": np.linspace(0.3, 4.9, 8),
            "refy": np.linspace(0.1, 3.7, 8),
        }
    )


def _scalar_reference(node: ExprNode, ctx_factory) -> np.ndarray:
    """The scalar loop's answer for ``node`` (broadcast path disabled)."""
    prev = NI._CONTRACT_DISABLE
    NI._CONTRACT_DISABLE = True
    try:
        return eval_expr(node, ctx_factory())
    finally:
        NI._CONTRACT_DISABLE = prev


def _spy_broadcast(monkeypatch):
    """Record every non-``None`` broadcast-contraction evaluation."""
    hits: list[tuple[int, ...]] = []
    orig = NI._eval_arrayop_contraction_broadcast

    def spy(*args, **kwargs):
        out = orig(*args, **kwargs)
        if out is not None:
            hits.append(tuple(np.shape(out)))
        return out

    monkeypatch.setattr(NI, "_eval_arrayop_contraction_broadcast", spy)
    return hits


def test_duo_strip_sum_bitwise_vs_scalar(monkeypatch) -> None:
    """⊕ = + : the broadcast path runs, and is bit-for-bit the scalar loop."""
    hits = _spy_broadcast(monkeypatch)
    node = _duo_strip_node()
    fast = eval_expr(node, _strip_ctx())
    assert hits == [(3, 4)], "broadcast contraction path did not serve the node"
    ref = _scalar_reference(node, _strip_ctx)
    assert fast.shape == ref.shape == (3, 4)
    assert np.array_equal(np.asarray(fast).view(np.uint64), np.asarray(ref).view(np.uint64))
    assert np.any(fast != 0.0)  # the tent gates admit real donor values


def test_duo_strip_max_bitwise_vs_scalar(monkeypatch) -> None:
    """⊕ = max (the duo ua/va rules' reducer): bit-for-bit the scalar loop."""
    hits = _spy_broadcast(monkeypatch)
    node = _duo_strip_node(reduce_op="max")
    fast = eval_expr(node, _strip_ctx())
    assert hits == [(3, 4)]
    ref = _scalar_reference(node, _strip_ctx)
    assert np.array_equal(np.asarray(fast).view(np.uint64), np.asarray(ref).view(np.uint64))


def test_duo_strip_hand_computed_value() -> None:
    """The strip equals the independently hand-vectorized tent remap."""
    node = _duo_strip_node()
    ctx = _strip_ctx()
    dt = ctx.y[ctx.state_layout["dt"]].reshape(6, 6)
    refx = ctx.y[ctx.state_layout["refx"]]
    refy = ctx.y[ctx.state_layout["refy"]]
    gi = np.arange(1, 4, dtype=float)[:, None, None, None]
    gj = np.arange(4, 8, dtype=float)[None, :, None, None]
    k = np.arange(0, 6, dtype=float)[None, None, :, None]
    l = np.arange(0, 6, dtype=float)[None, None, None, :]
    # esm `index` is 1-based: ref[s+2] reads 0-based slot s+1, dt[k+1, l+1]
    # reads 0-based (k, l).
    wx = np.maximum(0.0, 1.0 - np.abs((gj - 3.0) - refx[(k + 1).astype(int)]))
    wy = np.maximum(0.0, 1.0 - np.abs(gi - refy[(l + 1).astype(int)]))
    expected = np.sum(wx * wy * dt[k.astype(int), l.astype(int)], axis=(2, 3))
    np.testing.assert_allclose(eval_expr(node, ctx), expected, rtol=0, atol=1e-14)


def test_empty_contracted_range_is_identity_fill(monkeypatch) -> None:
    """An empty reduce range fills with the semiring identity, as the scalar
    path does (RFC §5.1)."""
    hits = _spy_broadcast(monkeypatch)
    node = ExprNode(
        op="aggregate",
        args=[],
        output_idx=["i"],
        ranges={"i": [1, 3], "k": [2, 1]},  # k: hi < lo — empty
        expr=_idx("u", "k"),
    )
    out = eval_expr(node, _ctx({"u": np.array([5.0, 6.0, 7.0])}))
    assert hits == [(3,)]
    np.testing.assert_array_equal(out, np.zeros(3))


def test_over_cap_declines_to_scalar(monkeypatch) -> None:
    """A combined box over the cap declines; the scalar loop still answers."""
    hits = _spy_broadcast(monkeypatch)
    monkeypatch.setattr(NI, "_CONTRACTION_BOX_CAP", 8)  # (3,4) out × 36 reduce ≫ 8
    node = _duo_strip_node()
    out = eval_expr(node, _strip_ctx())
    assert hits == []  # declined — never returned a value
    ref = _scalar_reference(node, _strip_ctx)
    assert np.array_equal(np.asarray(out).view(np.uint64), np.asarray(ref).view(np.uint64))
