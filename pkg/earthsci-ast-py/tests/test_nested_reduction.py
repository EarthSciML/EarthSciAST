"""A rank-0 reduction nested in an array body that reads the enclosing index.

``W[i] = Σ_{j ≥ i} g[j]`` written as an outer ``faq`` over ``i`` whose body is a
rank-0 ``faq`` over ``j``. An enclosing whole-box tier binds ``i`` to an array
over its box, and the nested node used to lay its own ``j`` axis out on that same
axis, so the filter compared ``j`` with ``i`` elementwise: every cell got the
diagonal window, the wrong answer, with no error. The nested window is fixed per
enclosing cell and folds ASCENDING whatever its comparison (esm-spec §4.3.1: the
nested node has no output index to scan). Each case here must equal a hand fold
and the reference evaluator bit for bit, under ``native`` and with no compiler
policy at all (the path observed outputs are rebuilt on).
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast.compiler import CompilerPolicy, use_policy
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import EvalContext, eval_expr

# Separates fold orders: ascending, descending and pairwise sums all differ.
G = np.tile([1.0, -1e16, 1.0, 1e16, 3.0, -2e16, 1.0, 2e16], 2)
N = G.size
H = np.linspace(0.5, 2.0, 3)


def _ctx() -> EvalContext:
    layout, shapes, pieces, off = {}, {}, [], 0
    for name, arr in {"g": G, "h": H, "kg": np.arange(N) % 3.0}.items():
        layout[name] = slice(off, off + arr.size)
        shapes[name] = arr.shape
        pieces.append(arr)
        off += arr.size
    return EvalContext(
        state_layout=layout,
        state_shapes=shapes,
        param_values={},
        observed_values={},
        y=np.concatenate(pieces),
        t=0.0,
        index_sets={
            "lev": {"kind": "interval", "size": N},
            "lev2": {"kind": "interval", "size": N},
            "col": {"kind": "interval", "size": 3},
        },
        var_index_sets={"kg": "lev2"},
    )


def _ix(name, *idx):
    return ExprNode(op="index", args=[name, *idx])


def _nested(cmp: str, rhs, reduce_op: str = "+", body=None, two_d: bool = False):
    inner = ExprNode(
        op="faq",
        output_idx=[],
        reduce=reduce_op,
        ranges={"j": {"from": "lev"}},
        filter=ExprNode(op=cmp, args=["j", rhs]),
        expr=body if body is not None else _ix("g", "j"),
    )
    ranges = {"i": {"from": "lev"}}
    out = ["i"]
    if two_d:
        ranges["c"] = {"from": "col"}
        out = ["i", "c"]
    return ExprNode(op="faq", output_idx=out, ranges=ranges, expr=inner)


def _hand(cmp: str, rhs, reduce_op: str = "+", weight=None) -> np.ndarray:
    admits = {">=": np.greater_equal, ">": np.greater, "<=": np.less_equal, "<": np.less}[cmp]
    ident = {"+": 0.0, "*": 1.0, "max": -np.inf, "min": np.inf}[reduce_op]
    step = {"+": lambda a, b: a + b, "*": lambda a, b: a * b, "max": max, "min": min}[reduce_op]
    out = []
    for i in range(1, N + 1):
        bound = i if rhs == "i" else rhs
        acc = None
        for j in range(1, N + 1):  # ascending: the window is fixed per cell
            if admits(j, bound):
                v = float(G[j - 1]) * (1.0 if weight is None else weight(i, j))
                acc = v if acc is None else step(acc, v)
        out.append(ident if acc is None else acc)
    return np.asarray(out)


def _run(node_fn, mode: str) -> tuple[np.ndarray, dict]:
    if mode == "none":
        return np.asarray(eval_expr(node_fn(), _ctx()), dtype=float), {}
    policy = CompilerPolicy(compiler=mode, every_tier_off=mode == "interpreter")
    with use_policy(policy):
        got = np.asarray(eval_expr(node_fn(), _ctx()), dtype=float)
    return got, policy.report.tiers()


def _same(a, b) -> bool:
    a, b = np.asarray(a, float), np.asarray(b, float)
    return a.shape == b.shape and np.array_equal(a.view(np.uint64), b.view(np.uint64))


@pytest.mark.parametrize("cmp", [">=", ">", "<=", "<"])
@pytest.mark.parametrize("rhs", ["i", 5])
@pytest.mark.parametrize("reduce_op", ["+", "*", "max", "min"])
@pytest.mark.parametrize("mode", ["native", "none"])
def test_nested_window_is_fixed_per_cell_and_folds_ascending(cmp, rhs, reduce_op, mode):
    got, tiers = _run(lambda: _nested(cmp, rhs, reduce_op), mode)
    want = _hand(cmp, rhs, reduce_op)
    ref, _ = _run(lambda: _nested(cmp, rhs, reduce_op), "interpreter")
    assert _same(ref, want)
    assert _same(got, want), (got, want)
    if mode == "native":
        assert tiers.get("nested-reduce") or rhs != "i", tiers


def test_the_fixture_values():
    """``g = 1, -1e16, 1, 1e16``: the nested sums are exactly 0, 0, 1e16, 1e16
    (a top-down fold would give 1 at i = 1)."""
    g = np.array([1.0, -1e16, 1.0, 1e16])
    out = []
    for i in range(4):
        acc = None
        for v in g[i:]:
            acc = v if acc is None else acc + v
        out.append(acc)
    assert out == [0.0, 0.0, 1e16, 1e16]
    full, _ = _run(lambda: _nested(">=", "i"), "native")
    assert _same(full, _hand(">=", "i"))


@pytest.mark.parametrize("mode", ["native", "none"])
def test_a_nested_body_reading_two_enclosing_axes(mode):
    """Over a 2-D enclosing box (i, c) the nested body reads both enclosing
    symbols; each enclosing cell keeps its own window and weight."""
    body = ExprNode(op="*", args=[_ix("g", "j"), _ix("h", "c")])
    got, _ = _run(lambda: _nested(">=", "i", body=body, two_d=True), mode)
    ref, _ = _run(lambda: _nested(">=", "i", body=body, two_d=True), "interpreter")
    assert got.shape == (N, 3)
    assert _same(got, ref)


@pytest.mark.parametrize("mode", ["native", "none"])
def test_a_nested_body_that_reads_the_enclosing_index(mode):
    body = ExprNode(op="*", args=[_ix("g", "j"), ExprNode(op="+", args=["i", 0.25])])
    got, _ = _run(lambda: _nested("<=", "i", body=body), mode)
    want = _hand("<=", "i", weight=lambda i, j: i + 0.25)
    assert _same(got, want)
