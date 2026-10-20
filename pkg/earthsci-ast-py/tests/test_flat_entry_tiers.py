"""The flat-entry whole-array tiers: a contraction over a RAGGED range
(``ragged-csr``, issue #534) and an aggregate gated by a spatial OVERLAP join
(``overlap-driven``, issue #535).

Neither shape has a dense ``out × reduce`` box, so before these tiers both
walked per output cell and strict ``native`` refused them. Each test here runs
one node under ``native`` and under the reference evaluator
(``compiler='interpreter'``) and requires the two answers to be equal BIT FOR
BIT — the tiers lay the per-cell walk's terms out flat and fold each cell's in
its own order, so there is no tolerance to hide behind — and requires ``native``
to have landed on the tier under test.
"""

from __future__ import annotations

from typing import Dict, Tuple

import numpy as np
import pytest

from earthsci_ast import numpy_interpreter as ni
from earthsci_ast.compiler import CompilerPolicy, use_policy
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import EvalContext, eval_expr


def _ctx(
    values: Dict[str, np.ndarray],
    index_sets: Dict[str, object] | None = None,
    var_index_sets: Dict[str, str] | None = None,
) -> EvalContext:
    state_layout: Dict[str, slice] = {}
    state_shapes: Dict[str, Tuple[int, ...]] = {}
    pieces: list[np.ndarray] = []
    offset = 0
    for name, arr in values.items():
        flat = np.asarray(arr, dtype=float).ravel()
        state_layout[name] = slice(offset, offset + flat.size)
        state_shapes[name] = tuple(np.asarray(arr).shape)
        pieces.append(flat)
        offset += flat.size
    return EvalContext(
        state_layout=state_layout,
        state_shapes=state_shapes,
        param_values={},
        observed_values={},
        y=np.concatenate(pieces) if pieces else np.zeros(0),
        t=0.0,
        index_sets=index_sets or {},
        var_index_sets=var_index_sets or {},
    )


def _ix(name: str, *idx: object) -> ExprNode:
    return ExprNode(op="index", args=[name, *idx])


def _op(op: str, *args: object) -> ExprNode:
    return ExprNode(op=op, args=list(args))


def _native(node: ExprNode, ctx: EvalContext) -> tuple[np.ndarray, dict[str, int]]:
    policy = CompilerPolicy(compiler="native")
    with use_policy(policy):
        got = np.asarray(eval_expr(node, ctx), dtype=float)
    return got, policy.report.tiers()


def _oracle(node: ExprNode, ctx: EvalContext) -> np.ndarray:
    with use_policy(CompilerPolicy(compiler="interpreter", every_tier_off=True)):
        return np.asarray(eval_expr(node, ctx), dtype=float)


def _bitwise(a: np.ndarray, b: np.ndarray) -> bool:
    return a.shape == b.shape and np.array_equal(a.view(np.uint64), b.view(np.uint64))


# ---------------------------------------------------------------------------
# Ragged contraction (#534)
# ---------------------------------------------------------------------------


def _mesh(n_cells: int, seed: int = 534, max_edges: int = 7, min_edges: int = 0):
    """An MPAS-like unstructured mesh: a per-cell edge count, a padded
    ``edgesOnCell`` table into ``n_edges`` edges, signs and lengths."""
    rng = np.random.default_rng(seed)
    n_edges = 3 * n_cells
    n_e = rng.integers(min_edges, max_edges + 1, n_cells)
    edges = rng.integers(1, n_edges + 1, (n_cells, max_edges))
    sign = rng.choice([-1.0, 1.0], (n_cells, max_edges))
    return {
        "nEdgesOnCell": n_e.astype(float),
        "edgesOnCell": edges.astype(float),
        "edgeSignOnCell": sign,
        "F": np.sqrt(np.arange(1.0, n_edges + 1.0)) * np.pi,
        "dvEdge": rng.uniform(0.5, 1.5, n_edges),
        "areaCell": rng.uniform(1.0, 2.0, n_cells),
    }, n_edges


def _mesh_sets(n_cells: int, n_edges: int) -> dict:
    return {
        "cells": {"kind": "interval", "size": n_cells},
        "edges": {"kind": "interval", "size": n_edges},
        "dense": {"kind": "interval", "size": 3},
        "edges_of_cell": {
            "kind": "ragged",
            "of": ["cells"],
            "offsets": "nEdgesOnCell",
            "values": "edgesOnCell",
        },
    }


def _divergence(semiring: str | None = "sum_product", reduce: str | None = None) -> ExprNode:
    """``div[i] = ⊕_{k ∈ edges_of_cell(i)} sign[i,k] · F[e] · dv[e] / area[i]``,
    ``e = edgesOnCell[i,k]`` — the ESD ``fv_divergence_cell`` body."""
    e = _ix("edgesOnCell", "i", "k")
    body = _op(
        "/",
        _op("*", _ix("edgeSignOnCell", "i", "k"), _ix("F", e), _ix("dvEdge", e)),
        _ix("areaCell", "i"),
    )
    node = ExprNode(
        op="faq",
        output_idx=["i"],
        expr=body,
        ranges={"i": {"from": "cells"}, "k": {"from": "edges_of_cell", "of": ["i"]}},
    )
    if semiring is not None:
        node.semiring = semiring
    if reduce is not None:
        node.reduce = reduce
    return node


@pytest.mark.parametrize(
    ("semiring", "reduce"),
    [("sum_product", None), ("max_product", None), ("min_sum", None), (None, "*")],
)
def test_ragged_contraction_is_bitwise_the_per_cell_walk(semiring, reduce) -> None:
    vals, n_edges = _mesh(200)
    ctx = _ctx(vals, _mesh_sets(200, n_edges))
    got, tiers = _native(_divergence(semiring, reduce), ctx)
    want = _oracle(_divergence(semiring, reduce), ctx)
    assert tiers.get("ragged-csr"), f"the ragged tier did not serve the node: {tiers}"
    assert _bitwise(got, want)


def test_a_cell_with_no_edges_is_the_semiring_identity() -> None:
    vals, n_edges = _mesh(40)
    vals["nEdgesOnCell"][[0, 7, 39]] = 0.0
    ctx = _ctx(vals, _mesh_sets(40, n_edges))
    for semiring, zero in (("sum_product", 0.0), ("max_product", -np.inf)):
        got, _ = _native(_divergence(semiring), ctx)
        assert _bitwise(got, _oracle(_divergence(semiring), ctx))
        assert (got[[0, 7, 39]] == zero).all()


@pytest.mark.parametrize("dense_first", [True, False])
def test_a_ragged_range_beside_a_dense_one_keeps_the_cartesian_term_order(dense_first) -> None:
    """With a dense contracted symbol too, each cell's terms run in the per-cell
    walk's cartesian order (last declared symbol fastest), whichever is first."""
    vals, n_edges = _mesh(60)
    vals["w"] = np.random.default_rng(5).standard_normal((60, 3))
    ragged = {"from": "edges_of_cell", "of": ["i"]}
    ranges = {"i": {"from": "cells"}}
    ranges.update({"d": {"from": "dense"}, "k": ragged} if dense_first else {"k": ragged})
    if not dense_first:
        ranges["d"] = {"from": "dense"}
    node = ExprNode(
        op="faq",
        output_idx=["i"],
        semiring="sum_product",
        expr=_op("*", _ix("F", _ix("edgesOnCell", "i", "k")), _ix("w", "i", "d")),
        ranges=ranges,
    )
    ctx = _ctx(vals, _mesh_sets(60, n_edges))
    got, tiers = _native(node, ctx)
    assert tiers.get("ragged-csr")
    assert _bitwise(got, _oracle(node, ctx))


def test_the_ragged_tier_folds_block_by_block_at_any_size(monkeypatch) -> None:
    """A small materialization cap splits the cells into blocks; the answer
    does not move."""
    vals, n_edges = _mesh(300, min_edges=5)
    ctx = _ctx(vals, _mesh_sets(300, n_edges))
    want = _oracle(_divergence(), ctx)
    monkeypatch.setattr(ni, "_CONTRACTION_BOX_CAP", 13)
    got, tiers = _native(_divergence(), ctx)
    assert tiers.get("ragged-csr")
    assert _bitwise(got, want)


@pytest.mark.parametrize("reducer", ["+", "*", "max", "min", "or"])
@pytest.mark.parametrize("shape", ["many-short", "few-long"])
def test_segmented_fold_is_the_sequential_left_fold(reducer, shape) -> None:
    """Both fold strategies (term position by term position, and one
    sequential ``accumulate`` per group) equal the scalar :func:`_reduce_step`
    chain."""
    rng = np.random.default_rng(7)
    if shape == "many-short":
        counts = rng.integers(0, 6, 400)
    else:
        counts = np.array([700, 0, 3, 900])
    vals = rng.standard_normal(int(counts.sum())) * np.exp(rng.uniform(-30, 30, counts.sum()))
    if reducer == "or":
        vals[rng.random(vals.size) < 0.7] = 0.0
    if reducer == "*":
        vals = 1.0 + vals * 1e-20
    got = ni._segmented_fold(reducer, vals, counts.astype(np.int64), -7.0)
    want = []
    pos = 0
    for c in counts:
        acc = None
        for v in vals[pos : pos + c]:
            acc = ni._reduce_step(reducer, acc, float(v))
        pos += c
        want.append(-7.0 if acc is None else acc)
    assert _bitwise(got, np.asarray(want, dtype=float))


# ---------------------------------------------------------------------------
# Overlap-gated aggregate (#535)
# ---------------------------------------------------------------------------

GX, GY = 12, 6


def _overlap_geometry(n_pts: int = 300, seed: int = 535) -> dict:
    """``GX x GY`` unit cells (rectangle factors W/S/E/N) and points (X/Y)
    scattered over them, some exactly on cell edges (so a point is a candidate
    of up to four cells) and some outside every cell."""
    rng = np.random.default_rng(seed)
    k = np.arange(GX * GY)
    a = (k // GY).astype(float)
    b = (k % GY).astype(float)
    x = rng.uniform(-0.5, GX + 0.5, n_pts)
    y = rng.uniform(-0.5, GY + 0.5, n_pts)
    on_edge = rng.random(n_pts) < 0.2
    x[on_edge] = np.round(x[on_edge])
    return {
        "W": a,
        "S": b,
        "E": a + 1.0,
        "N": b + 1.0,
        "X": x,
        "Y": y,
        "V": np.sqrt(np.arange(1.0, n_pts + 1.0)) * np.pi,
        "Cw": rng.standard_normal(GX * GY),
        "Pk": rng.integers(0, 3, n_pts).astype(float),
        "Ck": rng.integers(0, 3, GX * GY).astype(float),
    }


def _overlap_ctx(geom: dict) -> EvalContext:
    n_pts = geom["X"].size
    sets = {
        "points": {"kind": "interval", "size": n_pts},
        "cells": {"kind": "interval", "size": GX * GY},
    }
    var_sets = {n: "cells" for n in ("W", "S", "E", "N", "Cw", "Ck")}
    var_sets.update({n: "points" for n in ("X", "Y", "V", "Pk")})
    return _ctx(geom, sets, var_sets)


def _gate() -> list:
    return [{"overlap": {"src_env": ["X", "Y"], "tgt_env": ["W", "S", "E", "N"], "eps": 0.0}}]


def _inside(c: str, p: str) -> ExprNode:
    return _op(
        "and",
        _op("<=", _ix("W", c), _ix("X", p)),
        _op("<", _ix("X", p), _ix("E", c)),
        _op("<=", _ix("S", c), _ix("Y", p)),
        _op("<", _ix("Y", p), _ix("N", c)),
    )


def _binning(output_idx: list[str], semiring: str = "sum_product", filt: bool = False) -> ExprNode:
    """``⊕_{(p,c) gated} [inside(c, p)] · V[p] · Cw[c]`` with output ``output_idx``."""
    node = ExprNode(
        op="faq",
        output_idx=output_idx,
        semiring=semiring,
        expr=_op("*", _op("ifelse", _inside("c", "p"), 1.0, 0.0), _ix("V", "p"), _ix("Cw", "c")),
        ranges={"p": {"from": "points"}, "c": {"from": "cells"}},
        join=_gate(),
    )
    if filt:
        node.filter = _op(">", _ix("V", "p"), 9.0)
    return node


@pytest.mark.parametrize(
    "output_idx",
    [["c"], ["p"], [], ["p", "c"], ["c", "p"]],
    ids=["restrict-cells", "restrict-points", "pairs", "map-pc", "map-cp"],
)
@pytest.mark.parametrize("semiring", ["sum_product", "max_product", "min_sum"])
@pytest.mark.parametrize("filt", [False, True])
def test_overlap_gated_aggregate_is_bitwise_the_per_cell_walk(output_idx, semiring, filt) -> None:
    geom = _overlap_geometry()
    got, tiers = _native(_binning(output_idx, semiring, filt), _overlap_ctx(geom))
    want = _oracle(_binning(output_idx, semiring, filt), _overlap_ctx(geom))
    assert tiers.get("overlap-driven"), f"the overlap tier did not serve the node: {tiers}"
    assert _bitwise(got, want)


def test_overlap_gate_beside_an_equi_join_applies_both() -> None:
    geom = _overlap_geometry()
    node = _binning(["c"])
    node.join = _gate() + [{"on": [["Pk", "Ck"]]}]
    want = _oracle(node, _overlap_ctx(geom))
    got, tiers = _native(node, _overlap_ctx(geom))
    assert tiers.get("overlap-driven")
    assert _bitwise(got, want)
    # The key gate does remove terms the overlap gate admits.
    assert not _bitwise(got, _oracle(_binning(["c"]), _overlap_ctx(geom)))


def test_an_output_cell_no_candidate_reaches_is_the_semiring_identity() -> None:
    geom = _overlap_geometry()
    geom["X"][:5] = 1e6  # outside every cell
    got, _ = _native(_binning(["p"], "max_product"), _overlap_ctx(geom))
    assert (got[:5] == -np.inf).all()
    assert _bitwise(got, _oracle(_binning(["p"], "max_product"), _overlap_ctx(geom)))


def test_the_overlap_tier_drives_from_the_candidates() -> None:
    """The entries are the candidate pairs, never the dense product."""
    from earthsci_ast import broad_phase

    geom = _overlap_geometry(n_pts=400)
    broad_phase.ENUM_VISITS[0] = 0
    _native(_binning(["c"]), _overlap_ctx(geom))
    visits = broad_phase.ENUM_VISITS[0]
    assert 0 < visits <= 4 * 400, visits
    assert visits < 400 * GX * GY // 10


def test_overlap_gated_polygon_leaf_runs_through_the_batched_clip() -> None:
    """The regrid narrow phase ``A[i,j] = polygon_intersection_area(src_i,
    tgt_j)`` behind an overlap gate on the ring factors themselves."""

    def rings(nx, ny, dx, dy):
        out = []
        for a in range(nx):
            for b in range(ny):
                x0, y0 = a * dx, b * dy
                out.append([[x0, y0], [x0 + dx, y0], [x0 + dx, y0 + dy], [x0, y0 + dy]])
        return np.asarray(out, dtype=float)

    src = rings(6, 6, 1.0, 1.0)
    tgt = rings(4, 4, 1.5, 1.5)
    ctx = _ctx(
        {"src_poly": src, "tgt_poly": tgt},
        {
            "src_cells": {"kind": "interval", "size": 36},
            "tgt_cells": {"kind": "interval", "size": 16},
        },
        {"src_poly": "src_cells", "tgt_poly": "tgt_cells"},
    )

    def node() -> ExprNode:
        return ExprNode(
            op="faq",
            semiring="sum_product",
            output_idx=["i", "j"],
            ranges={"i": {"from": "src_cells"}, "j": {"from": "tgt_cells"}},
            join=[{"overlap": {"src_env": ["src_poly"], "tgt_env": ["tgt_poly"], "eps": 1e-9}}],
            expr=ExprNode(
                op="polygon_intersection_area",
                manifold="planar",
                args=[_ix("src_poly", "i"), _ix("tgt_poly", "j")],
            ),
        )

    got, tiers = _native(node(), ctx)
    assert tiers.get("overlap-driven")
    assert _bitwise(got, _oracle(node(), ctx))
    assert got.sum() == pytest.approx(36.0, rel=1e-12)
