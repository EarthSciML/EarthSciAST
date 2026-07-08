"""
Unit tests for M2 value-equality joins and filter predicates in the NumPy AST
interpreter (RFC semiring-faq-unified-ir §5.3 / §7.2; bead ess-my4.2.4).

These exercise ``aggregate`` / ``arrayop`` nodes carrying a ``join`` (inner
equi-join of key columns) and/or a ``filter`` predicate against a synthetic
:class:`EvalContext`, covering the spec's fixed semantics: inner-only join,
many-to-many cardinality, ``int``/categorical keys only, unmatched →
additive-identity (0̄), build errors for float / null keys, byte-identity of the
degenerate positional join, and order-independent (deterministic) output.
"""

from __future__ import annotations

import json
from dataclasses import replace
from typing import Dict, Tuple

import numpy as np
import pytest
from conftest import VALID_DIR

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    eval_expr,
)
from earthsci_ast.parse import _parse_expression, load
from earthsci_ast.simulation import simulate


def _ctx(
    values: Dict[str, np.ndarray],
    index_sets: Dict[str, object] | None = None,
) -> EvalContext:
    """Build an :class:`EvalContext` from ``{name: ndarray}`` factors.

    Mirrors the helper in ``test_numpy_interpreter.py``: variables are laid out
    in insertion order into a shared flat state vector; ``index_sets`` supplies
    the document-scoped registry (RFC §5.2).
    """
    state_layout: Dict[str, slice] = {}
    state_shapes: Dict[str, Tuple[int, ...]] = {}
    pieces: list[np.ndarray] = []
    offset = 0
    for name, arr in values.items():
        flat = np.asarray(arr, dtype=float).ravel()
        state_layout[name] = slice(offset, offset + flat.size)
        state_shapes[name] = tuple(np.asarray(arr).shape) if np.asarray(arr).ndim else ()
        pieces.append(flat)
        offset += flat.size
    y = np.concatenate(pieces) if pieces else np.zeros(0, dtype=float)
    return EvalContext(
        state_layout=state_layout,
        state_shapes=state_shapes,
        param_values={},
        observed_values={},
        y=y,
        t=0.0,
        index_sets=index_sets or {},
    )


def _index(name: str, *idx: object) -> ExprNode:
    return ExprNode(op="index", args=[name, *idx])


# ---------------------------------------------------------------------------
# Degenerate / positional join  →  byte-identical to the join-free node
# ---------------------------------------------------------------------------


def test_degenerate_join_byte_identical_to_no_join() -> None:
    """A positional join (each key bound to its own dimension) is a no-op (§5.3).

    The node's dense output must be byte-for-byte identical to the same node
    with ``join`` omitted — the "positional einsum is the degenerate case".
    """
    idx = {"sourceType": {"kind": "categorical", "members": ["onroad", "nonroad"]}}
    ctx = _ctx({"activity": np.array([10.0, 20.0]), "base_rate": np.array([3.0, 5.0])}, idx)
    body = ExprNode(op="*", args=[_index("activity", "src"), _index("base_rate", "src")])
    ranges = {"src": {"from": "sourceType"}}

    no_join = ExprNode(
        op="aggregate", output_idx=[], semiring="sum_product", expr=body, ranges=ranges
    )
    deg_join = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        expr=body,
        ranges=ranges,
        join=[{"on": [["src", "sourceType"]]}],
    )

    r_no = np.asarray(eval_expr(no_join, ctx))
    r_deg = np.asarray(eval_expr(deg_join, ctx))
    assert r_no.tobytes() == r_deg.tobytes()
    assert float(r_deg) == pytest.approx(10.0 * 3.0 + 20.0 * 5.0)


def test_join_key_may_name_the_index_set_or_the_symbol() -> None:
    """A join key resolves a range symbol directly or via its bound index set."""
    idx = {"county": {"kind": "categorical", "members": ["A", "B"]}}
    ctx = _ctx({"w": np.array([[1.0, 2.0], [3.0, 4.0]])}, idx)
    body = _index("w", "i", "j")
    # Naming the symbol "j" and the set "county" (bound only by i) are equivalent.
    by_sym = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        expr=body,
        ranges={"i": {"from": "county"}, "j": {"from": "county"}},
        join=[{"on": [["i", "j"]]}],
    )
    assert float(eval_expr(by_sym, ctx)) == pytest.approx(1.0 + 4.0)


# ---------------------------------------------------------------------------
# Inner equi-join semantics + cardinality (m·n)
# ---------------------------------------------------------------------------


def test_inner_equijoin_is_diagonal_over_shared_keys() -> None:
    """i,j over one set, joined on value, keeps only the matched (equal) tuples."""
    idx = {"county": {"kind": "categorical", "members": ["A", "B", "C"]}}
    w = np.array([[1.0, 9.0, 9.0], [9.0, 2.0, 9.0], [9.0, 9.0, 3.0]])
    ctx = _ctx({"w": w}, idx)
    body = _index("w", "i", "j")
    joined = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        expr=body,
        ranges={"i": {"from": "county"}, "j": {"from": "county"}},
        join=[{"on": [["i", "j"]]}],
    )
    # Only i==j contributes: w[A,A]+w[B,B]+w[C,C] = 1+2+3.
    assert float(eval_expr(joined, ctx)) == pytest.approx(6.0)


def test_many_to_many_cardinality_is_defined() -> None:
    """A key value occurring m times left and n times right yields m·n terms (§5.3)."""
    idx = {
        "A": {"kind": "categorical", "members": ["x", "y", "y"]},  # 'y' twice
        "B": {"kind": "categorical", "members": ["y", "y"]},  # 'y' twice
    }
    ctx = _ctx({"one": np.ones((3, 2))}, idx)
    body = _index("one", "i", "j")
    joined = ExprNode(
        op="aggregate",
        output_idx=[],
        reduce="+",
        expr=body,
        ranges={"i": {"from": "A"}, "j": {"from": "B"}},
        join=[{"on": [["i", "j"]]}],
    )
    # 'y' matches 'y': 2 (left) × 2 (right) = 4 unit terms; 'x' matches nothing.
    assert float(eval_expr(joined, ctx)) == pytest.approx(4.0)


def test_multiple_clauses_and_pairs_are_all_anded() -> None:
    """All pairs across all join clauses must hold for a term to contribute.

    Counting unit terms distinguishes AND (the spec) from OR: with a constant
    body, the admitted tuples are {i==j} ∩ {k==l} = 2·2 = 4 (an OR would admit
    12 of the 16 tuples).
    """
    idx = {
        "s": {"kind": "categorical", "members": ["p", "q"]},
        "f": {"kind": "categorical", "members": ["p", "q"]},
    }
    ctx = _ctx({}, idx)
    joined = ExprNode(
        op="aggregate",
        output_idx=[],
        reduce="+",
        expr=1.0,
        ranges={"i": {"from": "s"}, "j": {"from": "s"}, "k": {"from": "f"}, "l": {"from": "f"}},
        join=[{"on": [["i", "j"]]}, {"on": [["k", "l"]]}],
    )
    assert float(eval_expr(joined, ctx)) == pytest.approx(4.0)


def test_join_across_two_distinct_categorical_sets_matches_by_value() -> None:
    """An inner join over two different sets keeps only shared member values."""
    idx = {
        "left": {"kind": "categorical", "members": ["a", "b", "c"]},
        "right": {"kind": "categorical", "members": ["b", "c", "d"]},
    }
    # one[i,j] == 1 everywhere; matches are (b,b) and (c,c) → 2 terms.
    ctx = _ctx({"one": np.ones((3, 3))}, idx)
    body = _index("one", "i", "j")
    joined = ExprNode(
        op="aggregate",
        output_idx=[],
        reduce="+",
        expr=body,
        ranges={"i": {"from": "left"}, "j": {"from": "right"}},
        join=[{"on": [["i", "j"]]}],
    )
    assert float(eval_expr(joined, ctx)) == pytest.approx(2.0)


# ---------------------------------------------------------------------------
# Unmatched → additive identity 0̄ (per semiring)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "semiring,expected",
    [
        ("sum_product", 0.0),
        ("max_product", -np.inf),
        ("min_sum", np.inf),
        ("max_sum", -np.inf),
    ],
)
def test_no_match_contributes_semiring_identity(semiring, expected) -> None:
    """A join with no matching tuples reduces to the semiring's 0̄ (§5.1/§5.3)."""
    idx = {
        "A": {"kind": "categorical", "members": ["x"]},
        "B": {"kind": "categorical", "members": ["y"]},
    }
    ctx = _ctx({"one": np.ones((1, 1))}, idx)
    body = _index("one", "i", "j")
    joined = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring=semiring,
        expr=body,
        ranges={"i": {"from": "A"}, "j": {"from": "B"}},
        join=[{"on": [["i", "j"]]}],
    )
    assert float(eval_expr(joined, ctx)) == expected


def test_partial_match_leaves_unmatched_output_cells_at_identity() -> None:
    """Per output cell, an unmatched contraction stays at 0̄ (array output)."""
    idx = {
        "out": {"kind": "categorical", "members": ["A", "B"]},
        "k": {"kind": "categorical", "members": ["A", "C"]},
    }
    # out[i] = Σ_k v[i,k] where member(i)==member(k). i=A matches k=A; i=B matches none.
    ctx = _ctx({"v": np.array([[5.0, 7.0], [8.0, 9.0]])}, idx)
    body = _index("v", "i", "k")
    node = ExprNode(
        op="aggregate",
        output_idx=["i"],
        semiring="sum_product",
        expr=body,
        ranges={"i": {"from": "out"}, "k": {"from": "k"}},
        join=[{"on": [["i", "k"]]}],
    )
    np.testing.assert_array_equal(eval_expr(node, ctx), np.array([5.0, 0.0]))


# ---------------------------------------------------------------------------
# Key-type rejection (build-time errors)
# ---------------------------------------------------------------------------


def test_float_join_key_rejected() -> None:
    """Floating-point join keys are forbidden — not portable across bindings (§5.3)."""
    idx = {"A": {"kind": "categorical", "members": [1.5, 2.5]}}
    ctx = _ctx({"a": np.array([1.0, 2.0])}, idx)
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        expr=_index("a", "i"),
        ranges={"i": {"from": "A"}, "j": {"from": "A"}},
        join=[{"on": [["i", "j"]]}],
    )
    with pytest.raises(NumpyInterpreterError, match="float join keys are forbidden"):
        eval_expr(node, ctx)


def test_null_in_key_column_rejected() -> None:
    """A null member in a join key column is a build-time error (§5.3)."""
    idx = {"A": {"kind": "categorical", "members": ["x", None]}}
    ctx = _ctx({"a": np.array([1.0, 2.0])}, idx)
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        expr=_index("a", "i"),
        ranges={"i": {"from": "A"}, "j": {"from": "A"}},
        join=[{"on": [["i", "j"]]}],
    )
    with pytest.raises(NumpyInterpreterError, match="null member in join key"):
        eval_expr(node, ctx)


def test_incompatible_key_types_rejected() -> None:
    """Joining an integer key column to a string key column is a key-type error."""
    idx = {
        "ints": {"kind": "interval", "size": 2},
        "strs": {"kind": "categorical", "members": ["a", "b"]},
    }
    ctx = _ctx({"one": np.ones((2, 2))}, idx)
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        expr=_index("one", "i", "j"),
        ranges={"i": {"from": "ints"}, "j": {"from": "strs"}},
        join=[{"on": [["i", "j"]]}],
    )
    with pytest.raises(NumpyInterpreterError, match="incompatible key types"):
        eval_expr(node, ctx)


def test_ambiguous_index_set_key_rejected() -> None:
    """A join key naming a set bound by >1 symbol is ambiguous (§5.3)."""
    idx = {"county": {"kind": "categorical", "members": ["A", "B"]}}
    ctx = _ctx({"w": np.ones((2, 2))}, idx)
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        expr=_index("w", "i", "j"),
        ranges={"i": {"from": "county"}, "j": {"from": "county"}},
        join=[{"on": [["county", "i"]]}],
    )
    with pytest.raises(NumpyInterpreterError, match="multiple range symbols"):
        eval_expr(node, ctx)


def test_unknown_join_key_rejected() -> None:
    """A join key that is neither a range symbol nor a bound set errors (§5.3)."""
    idx = {"county": {"kind": "categorical", "members": ["A", "B"]}}
    ctx = _ctx({"w": np.ones((2, 2))}, idx)
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        expr=_index("w", "i", "j"),
        ranges={"i": {"from": "county"}, "j": {"from": "county"}},
        join=[{"on": [["i", "nope"]]}],
    )
    with pytest.raises(NumpyInterpreterError, match="neither a declared range symbol"):
        eval_expr(node, ctx)


# ---------------------------------------------------------------------------
# Determinism — output is order-independent (§5.7 rule 5 / A.5)
# ---------------------------------------------------------------------------


def test_join_output_is_independent_of_declared_member_order() -> None:
    """Permuting the key set's declared order (with data) leaves the join value
    unchanged — the result is a pure function of the key *values* (§5.7)."""
    members = ["A", "B", "C"]
    diag = {"A": 1.0, "B": 2.0, "C": 3.0}

    def diagonal_sum(order: list[str]) -> float:
        # Build w so that w[i,i] = diag[member i]; off-diagonal is noise.
        n = len(order)
        w = np.full((n, n), 99.0)
        for p, m in enumerate(order):
            w[p, p] = diag[m]
        ctx = _ctx({"w": w}, {"county": {"kind": "categorical", "members": order}})
        node = ExprNode(
            op="aggregate",
            output_idx=[],
            semiring="sum_product",
            expr=_index("w", "i", "j"),
            ranges={"i": {"from": "county"}, "j": {"from": "county"}},
            join=[{"on": [["i", "j"]]}],
        )
        return float(eval_expr(node, ctx))

    base = diagonal_sum(members)
    for perm in (["C", "A", "B"], ["B", "C", "A"], ["C", "B", "A"]):
        assert diagonal_sum(perm) == pytest.approx(base)
    assert base == pytest.approx(6.0)


def test_cross_set_join_value_is_permutation_invariant() -> None:
    """An inner join over two sets is invariant to each set's declared order."""

    def matched_count(left: list[str], right: list[str]) -> float:
        ctx = _ctx(
            {"one": np.ones((len(left), len(right)))},
            {
                "L": {"kind": "categorical", "members": left},
                "R": {"kind": "categorical", "members": right},
            },
        )
        node = ExprNode(
            op="aggregate",
            output_idx=[],
            reduce="+",
            expr=_index("one", "i", "j"),
            ranges={"i": {"from": "L"}, "j": {"from": "R"}},
            join=[{"on": [["i", "j"]]}],
        )
        return float(eval_expr(node, ctx))

    base = matched_count(["a", "b", "c"], ["b", "c", "d"])  # matches b,c → 2
    assert base == pytest.approx(2.0)
    assert matched_count(["c", "a", "b"], ["d", "c", "b"]) == pytest.approx(base)
    assert matched_count(["b", "c", "a"], ["c", "b", "d"]) == pytest.approx(base)


# ---------------------------------------------------------------------------
# Filter predicates (§7.2) — share the same gating machinery
# ---------------------------------------------------------------------------


def test_filter_drops_combinations_where_predicate_false() -> None:
    """A filter keeps only combinations whose predicate holds (§7.2)."""
    idx = {"sourceType": {"kind": "categorical", "members": ["onroad", "nonroad"]}}
    ctx = _ctx({"activity": np.array([10.0, 20.0]), "base_rate": np.array([3.0, -1.0])}, idx)
    body = ExprNode(op="*", args=[_index("activity", "src"), _index("base_rate", "src")])
    filt = ExprNode(op=">", args=[_index("base_rate", "src"), 0])
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        expr=body,
        ranges={"src": {"from": "sourceType"}},
        filter=filt,
    )
    # src=2 (base_rate<0) is dropped → only 10·3 contributes.
    assert float(eval_expr(node, ctx)) == pytest.approx(30.0)


def test_filter_all_false_returns_identity() -> None:
    """When the filter rejects every combination the reduction is 0̄."""
    idx = {"c": {"kind": "interval", "size": 3}}
    ctx = _ctx({"a": np.array([1.0, 2.0, 3.0])}, idx)
    filt = ExprNode(op=">", args=[_index("a", "i"), 100])
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        expr=_index("a", "i"),
        ranges={"i": {"from": "c"}},
        filter=filt,
    )
    assert float(eval_expr(node, ctx)) == pytest.approx(0.0)


def test_join_and_filter_compose() -> None:
    """A node may carry both a join and a filter; both gates apply (§7.2)."""
    idx = {"county": {"kind": "categorical", "members": ["A", "B"]}}
    # w diagonal kept by join; filter keeps only diagonal entries > 1.
    ctx = _ctx({"w": np.array([[1.0, 0.0], [0.0, 5.0]])}, idx)
    body = _index("w", "i", "j")
    filt = ExprNode(op=">", args=[body, 1])
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        expr=body,
        ranges={"i": {"from": "county"}, "j": {"from": "county"}},
        join=[{"on": [["i", "j"]]}],
        filter=filt,
    )
    # diagonal = {1, 5}; filter>1 keeps only 5.
    assert float(eval_expr(node, ctx)) == pytest.approx(5.0)


# ---------------------------------------------------------------------------
# Alias + interval-key joins
# ---------------------------------------------------------------------------


def test_canonical_join_filter_fixture_evaluates_as_positional() -> None:
    """The repo's ``valid/aggregate/join_filter.esm`` fixture (the ESI MOVES
    contraction, RFC §7.2) evaluates, and its degenerate join is byte-identical
    to the same node with ``join`` removed — the positional-einsum baseline."""
    fixture = VALID_DIR / "aggregate" / "join_filter.esm"
    doc = json.loads(fixture.read_text())
    model = doc["models"]["EmissionsAggregate"]
    rhs = _parse_expression(model["equations"][0]["rhs"])
    assert rhs.join and rhs.filter is not None  # fixture carries both M2 fields

    ctx = _ctx(
        {"activity": np.array([10.0, 20.0]), "base_rate": np.array([3.0, 5.0])},
        # index_sets is document-scoped (v0.8.0): read it from the top level.
        index_sets=doc["index_sets"],
    )
    with_join = np.asarray(eval_expr(rhs, ctx))
    without_join = np.asarray(eval_expr(replace(rhs, join=None), ctx))
    assert with_join.tobytes() == without_join.tobytes()
    # Σ_src Σ_fuel activity[src]·base_rate[src] (filter base_rate>0 admits both),
    # the inner fuel sum just repeats the src term over fuelType's 2 members.
    assert float(with_join) == pytest.approx((10.0 * 3.0 + 20.0 * 5.0) * 2)


def test_interval_keys_join_on_integer_id() -> None:
    """Interval index sets equi-join on their integer index value (§5.3)."""
    idx = {"n": {"kind": "interval", "size": 3}}
    ctx = _ctx({"w": np.array([[1.0, 0.0, 0.0], [0.0, 2.0, 0.0], [0.0, 0.0, 3.0]])}, idx)
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        expr=_index("w", "i", "j"),
        ranges={"i": {"from": "n"}, "j": {"from": "n"}},
        join=[{"on": [["i", "j"]]}],
    )
    assert float(eval_expr(node, ctx)) == pytest.approx(6.0)


# ---------------------------------------------------------------------------
# End-to-end: the join is applied through the full simulate() pipeline
# ---------------------------------------------------------------------------


def _join_count_model(with_join: bool) -> dict:
    """A scalar state whose derivative counts admitted (i,j) combinations.

    ``du/dt = Σ_{i,j} 1`` over two copies of a 2-member categorical set. With
    the diagonal join (i==j) only 2 combinations contribute; without it all 4 do.
    """
    rhs: dict = {
        "op": "aggregate",
        "reduce": "+",
        "output_idx": [],
        "ranges": {"i": {"from": "county"}, "j": {"from": "county"}},
        "expr": 1.0,
        "args": [],
    }
    if with_join:
        rhs["join"] = [{"on": [["i", "j"]]}]
    return {
        "esm": "0.6.0",
        "metadata": {"name": "join_e2e"},
        "index_sets": {"county": {"kind": "categorical", "members": ["A", "B"]}},
        "models": {
            "M": {
                "variables": {"u": {"type": "state", "default": 0.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                        "rhs": rhs,
                    }
                ],
            }
        },
    }


def test_join_resolved_through_simulate_pipeline() -> None:
    """A join aggregate RHS keeps its join semantics through ``simulate`` — the
    diagonal join yields du/dt=2, vs du/dt=4 with the join removed."""
    res_join = simulate(
        load(_join_count_model(with_join=True)), (0.0, 1.0), initial_conditions={"u": 0.0}
    )
    res_full = simulate(
        load(_join_count_model(with_join=False)), (0.0, 1.0), initial_conditions={"u": 0.0}
    )

    def final_u(res) -> float:
        # The state may be namespaced (e.g. "M.u"); match by bare name.
        idx = next(i for i, v in enumerate(res.vars) if v.split(".")[-1] == "u")
        return float(np.asarray(res.y)[idx, -1])

    assert final_u(res_join) == pytest.approx(2.0, abs=1e-6)
    assert final_u(res_full) == pytest.approx(4.0, abs=1e-6)
