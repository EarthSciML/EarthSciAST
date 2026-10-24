"""Cumulative (prefix) reductions — esm-spec §4.3.1.

A prefix reduction is an ordinary ``faq`` whose ``filter`` compares the
contracted index against an output index. Evaluated literally it is a triangular
double loop; the native compiler collapses it to one ``ufunc.accumulate`` sweep.

The rewrite is only legitimate because it is **bit-identical** to the fold order
the spec pins as normative, so that is what these tests assert — not "close
enough". A FORWARD window (``<=``, ``<``) folds ascending from its low end. A
REVERSE window (``>=``, ``>``) folds DESCENDING from its high end,
``((b_N ⊕ b_{N-1}) ⊕ …) ⊕ b_i``, under every ⊕, so one right-to-left
accumulator is exactly the definition. Both the interpreter and native must
produce those bits.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast.compiler import CompilerPolicy, use_policy
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import EvalContext, eval_expr


def _make_ctx(values: dict[str, np.ndarray]) -> EvalContext:
    """Lay the named arrays out in a shared flat state vector, exactly as
    ``tests/test_numpy_interpreter._ctx`` does."""
    state_layout: dict[str, slice] = {}
    state_shapes: dict[str, tuple[int, ...]] = {}
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
        y=np.concatenate(pieces) if pieces else np.zeros(0, dtype=float),
        t=0.0,
        index_sets={},
    )


def _prefix_agg(cmp: str, n: int, reduce_op: str) -> ExprNode:
    """``result[i] = REDUCE_{j CMP i} u[j]`` over a dense 1..n interval."""
    return ExprNode(
        op="faq",
        args=["u"],
        output_idx=["i"],
        reduce=reduce_op,
        ranges={"i": [1, n], "j": [1, n]},
        filter=ExprNode(op=cmp, args=["j", "i"]),
        expr=ExprNode(op="index", args=["u", "j"]),
    )


def _ctx(u: np.ndarray) -> EvalContext:
    return _make_ctx({"u": np.asarray(u, dtype=float)})


_IDENTITY = {"+": 0.0, "*": 1.0, "max": -np.inf, "min": np.inf}
_COMBINE = {
    "+": lambda a, b: a + b,
    "*": lambda a, b: a * b,
    "max": max,
    "min": min,
}


def _oracle(u: np.ndarray, cmp: str, reduce_op: str) -> np.ndarray:
    """The triangular double loop written out literally, folding the admitted
    window in the order the spec defines: ascending ``j``, except a reverse
    window, which folds descending."""
    n = len(u)
    admits = {
        "<=": lambda j, i: j <= i,
        "<": lambda j, i: j < i,
        ">=": lambda j, i: j >= i,
        ">": lambda j, i: j > i,
    }[cmp]
    combine = _COMBINE[reduce_op]
    descending = cmp in (">=", ">")
    order = range(n, 0, -1) if descending else range(1, n + 1)
    out = []
    for i in range(1, n + 1):
        acc = _IDENTITY[reduce_op]
        for j in order:
            if admits(j, i):
                acc = combine(acc, float(u[j - 1]))
        out.append(acc)
    return np.array(out, dtype=float)


def _catastrophic(n: int) -> np.ndarray:
    """Magnitudes many orders apart, so ``(a+b)+c`` differs from ``a+(b+c)`` in
    the low bits and a mis-associated scan cannot pass by luck."""
    return np.array(
        [(-1.0 if k % 3 == 0 else 1.0) * (1.0 + k) * 10.0 ** ((k % 17) - 8) for k in range(n)],
        dtype=float,
    )


def _assert_bit_identical(got: np.ndarray, want: np.ndarray, label: str) -> None:
    g = np.asarray(got, dtype=float).ravel()
    w = np.asarray(want, dtype=float).ravel()
    assert g.shape == w.shape, f"{label}: shape {g.shape} != {w.shape}"
    # Compare bit patterns, not approximately: re-association is exactly what a
    # wrong scan produces, and it hides inside any tolerance.
    bad = [
        (k, float(gv), float(wv))
        for k, (gv, wv) in enumerate(zip(g, w))
        if np.float64(gv).tobytes() != np.float64(wv).tobytes()
    ]
    assert not bad, f"{label}: cells differ in the low bits: {bad[:4]}"


@pytest.mark.parametrize("n", [1, 2, 3, 8, 33, 64, 257])
@pytest.mark.parametrize("cmp", ["<=", "<"])
@pytest.mark.parametrize("reduce_op", ["+", "*", "max", "min"])
def test_forward_scans_are_bit_identical_to_the_triangular_oracle(n, cmp, reduce_op):
    u = _catastrophic(n)
    got = eval_expr(_prefix_agg(cmp, n, reduce_op), _ctx(u))
    _assert_bit_identical(got, _oracle(u, cmp, reduce_op), f"n={n} {cmp} {reduce_op}")


@pytest.mark.parametrize("n", [1, 2, 5, 40, 257])
@pytest.mark.parametrize("cmp", [">=", ">"])
@pytest.mark.parametrize("reduce_op", ["+", "*"])
@pytest.mark.parametrize("compiler", ["native", "interpreter"])
def test_reverse_scans_fold_descending_bit_for_bit(n, cmp, reduce_op, compiler):
    """A reverse window under ``+`` / ``*`` folds from its high end, in the
    reference evaluator and in native's right-to-left accumulate alike."""
    u = _catastrophic(n)
    policy = CompilerPolicy(compiler=compiler, every_tier_off=compiler == "interpreter")
    with use_policy(policy):
        got = eval_expr(_prefix_agg(cmp, n, reduce_op), _ctx(u))
    _assert_bit_identical(got, _oracle(u, cmp, reduce_op), f"{compiler} n={n} {cmp} {reduce_op}")
    if compiler == "native":
        assert policy.report.tiers().get("prefix-scan")


def test_a_reverse_sum_is_not_the_ascending_fold():
    """The catastrophic input separates the two orders, so the test above bites."""
    u = _catastrophic(40)
    got = np.asarray(eval_expr(_prefix_agg(">=", 40, "+"), _ctx(u)), dtype=float).ravel()
    ascending = [sum(float(x) for x in u[i:]) for i in range(40)]
    assert any(np.float64(g).tobytes() != np.float64(a).tobytes() for g, a in zip(got, ascending))


@pytest.mark.parametrize("n", [1, 5, 40])
@pytest.mark.parametrize("cmp", [">=", ">"])
@pytest.mark.parametrize("reduce_op", ["max", "min"])
@pytest.mark.parametrize("compiler", ["native", "interpreter"])
def test_reverse_extremum_scans_fold_descending_bit_for_bit(n, cmp, reduce_op, compiler):
    """``max`` / ``min`` reverse windows fold from the top too, and native takes
    them on the scan tier."""
    u = _catastrophic(n)
    policy = CompilerPolicy(compiler=compiler, every_tier_off=compiler == "interpreter")
    with use_policy(policy):
        got = eval_expr(_prefix_agg(cmp, n, reduce_op), _ctx(u))
    _assert_bit_identical(got, _oracle(u, cmp, reduce_op), f"{compiler} n={n} {cmp} {reduce_op}")
    if compiler == "native":
        assert policy.report.tiers().get("prefix-scan")


@pytest.mark.parametrize(
    "reduce_op,u,want",
    [
        ("max", [1.0, np.nan, 3.0], [3.0, 3.0, 3.0]),
        ("min", [3.0, np.nan, 1.0], [1.0, 1.0, 1.0]),
    ],
)
@pytest.mark.parametrize("compiler", ["native", "interpreter"])
def test_a_reverse_extremum_over_a_nan_folds_from_the_top(reduce_op, u, want, compiler):
    """A ``max`` / ``min`` step keeps its accumulator unless the term beats it,
    so a NaN is skipped once the accumulator holds a number and sticks when it
    comes first: order decides the answer. Folded from the top, cell 2's window
    ``[NaN, 3]`` starts at 3; folded ascending it would start at the NaN."""
    policy = CompilerPolicy(compiler=compiler, every_tier_off=compiler == "interpreter")
    with use_policy(policy):
        got = eval_expr(_prefix_agg(">=", 3, reduce_op), _ctx(np.array(u)))
    _assert_bit_identical(got, np.array(want), f"{compiler} {reduce_op}")


# Signed zeros and NaNs, leading and interior: the inputs on which a max / min
# accumulate that is not the per-cell step (np.maximum keeps the later of two
# equal zeros and propagates a NaN) gives different bits.
_EXTREMUM_EDGES = {
    "zeros": [0.0, -0.0, -0.0, 0.0, -1.0, 0.0, -0.0],
    "neg-zeros": [-0.0, 0.0, 0.0, -0.0, 1.0, -0.0, 0.0],
    "interior-nan": [2.0, np.nan, 1.0, 3.0, np.nan, 3.0, -0.0],
    "leading-nan": [np.nan, 1.0, -0.0, 0.0, 5.0, np.nan, 2.0],
    "trailing-nan": [0.0, -0.0, 4.0, 1.0, -2.0, 0.0, np.nan],
}


@pytest.mark.parametrize("case", sorted(_EXTREMUM_EDGES))
@pytest.mark.parametrize("cmp", ["<=", "<", ">=", ">"])
@pytest.mark.parametrize("reduce_op", ["max", "min"])
def test_extremum_scans_match_the_per_cell_walk_on_zeros_and_nans(case, cmp, reduce_op):
    u = np.array(_EXTREMUM_EDGES[case])
    node = _prefix_agg(cmp, u.size, reduce_op)
    want = _per_cell(node, _ctx(u))
    policy = CompilerPolicy(compiler="native")
    with use_policy(policy):
        got = eval_expr(node, _ctx(u))
    assert policy.report.tiers().get("prefix-scan")
    _assert_bit_identical(got, want, f"{case} {cmp} {reduce_op}")


@pytest.mark.parametrize(
    "reduce_op,expected",
    [("+", 0.0), ("*", 1.0), ("max", -np.inf), ("min", np.inf)],
)
def test_exclusive_first_cell_is_the_additive_identity(reduce_op, expected):
    """An empty reduction takes the semiring's 0̄; it is not an error."""
    u = np.array([1.0, 2.0, 4.0, 8.0])
    got = np.asarray(eval_expr(_prefix_agg("<", 4, reduce_op), _ctx(u)), dtype=float).ravel()
    assert got[0] == expected


def test_running_totals_have_the_expected_values():
    u = np.array([1.0, 2.0, 4.0, 8.0])
    inc = np.asarray(eval_expr(_prefix_agg("<=", 4, "+"), _ctx(u)), dtype=float).ravel()
    exc = np.asarray(eval_expr(_prefix_agg("<", 4, "+"), _ctx(u)), dtype=float).ravel()
    rev = np.asarray(eval_expr(_prefix_agg(">=", 4, "+"), _ctx(u)), dtype=float).ravel()
    assert inc.tolist() == [1.0, 3.0, 7.0, 15.0]
    assert exc.tolist() == [0.0, 1.0, 3.0, 7.0]
    assert rev.tolist() == [15.0, 14.0, 12.0, 8.0]


def test_body_referencing_the_scanned_symbol_is_declined_and_still_correct():
    """``sum_{j<=i} u[j]*i`` — each cell's summand differs, so no partial result
    can be reused. The detector must decline rather than scan."""
    n = 6
    u = np.array([1.0, 2.0, 4.0, 8.0, 16.0, 32.0])
    node = ExprNode(
        op="faq",
        args=["u"],
        output_idx=["i"],
        reduce="+",
        ranges={"i": [1, n], "j": [1, n]},
        filter=ExprNode(op="<=", args=["j", "i"]),
        expr=ExprNode(op="*", args=[ExprNode(op="index", args=["u", "j"]), "i"]),
    )
    got = np.asarray(eval_expr(node, _ctx(u)), dtype=float).ravel()
    want = np.array([i * u[:i].sum() for i in range(1, n + 1)])
    assert got == pytest.approx(want)


def test_measure_weighted_cumulative_integral():
    """The Riemann-sum form: the measure is an ordinary factor in the body, never
    supplied by the evaluator (esm-spec §4.3.1)."""
    n = 4
    u = np.array([0.5, 1.25, 1.625, 1.875])  # 2x at the midpoints
    dx = np.array([0.5, 0.25, 0.125, 0.125])  # non-uniform cells
    node = ExprNode(
        op="faq",
        args=["u", "dx"],
        output_idx=["i"],
        reduce="+",
        ranges={"i": [1, n], "j": [1, n]},
        filter=ExprNode(op="<=", args=["j", "i"]),
        expr=ExprNode(
            op="*",
            args=[
                ExprNode(op="index", args=["u", "j"]),
                ExprNode(op="index", args=["dx", "j"]),
            ],
        ),
    )
    ctx = _make_ctx({"u": u, "dx": dx})
    got = np.asarray(eval_expr(node, ctx), dtype=float).ravel()
    # x^2 at each cell's right edge — the midpoint rule is exact for a linear
    # integrand, so this is an equality, not a discretization-error check.
    assert got == pytest.approx([0.25, 0.5625, 0.765625, 1.0])


def test_forward_scan_work_grows_linearly_not_quadratically():
    """The whole point of recognizing the pattern. A 16x increase in N should
    cost ~16x, not ~256x. The ceiling is deliberately loose so this fails only on
    a genuine regression to the triangular form, never on a contended machine."""
    import time

    def best(n: int) -> float:
        u = np.ones(n)
        node = _prefix_agg("<=", n, "+")
        ctx = _ctx(u)
        eval_expr(node, ctx)  # warm up
        return min(
            (lambda t0: (eval_expr(node, _ctx(u)), time.perf_counter() - t0)[1])(
                time.perf_counter()
            )
            for _ in range(5)
        )

    small, large = best(256), best(4096)
    ratio = large / max(small, 1e-9)
    assert ratio < 64.0, (
        f"prefix scan looks quadratic: N=256 took {small:.6f}s, N=4096 took "
        f"{large:.6f}s (ratio {ratio:.1f}x for a 16x increase in N)"
    )


def test_rank_2_output_scans_one_axis_and_leaves_the_other_independent():
    """The scan sweeps ONE axis while the other is an independent family of scans.

    This exercises the axis bookkeeping — moving the scanned axis to the end for
    ``accumulate`` and back afterwards — which the rank-1 tests cannot reach. A
    transposed or mis-strided result shows up here and nowhere else.
    """
    nr, nc = 3, 4
    m = np.array([[r * 10 + j for j in range(1, nc + 1)] for r in range(1, nr + 1)], dtype=float)
    node = ExprNode(
        op="faq",
        args=["m"],
        output_idx=["r", "i"],
        reduce="+",
        ranges={"r": [1, nr], "i": [1, nc], "j": [1, nc]},
        filter=ExprNode(op="<=", args=["j", "i"]),
        expr=ExprNode(op="index", args=["m", "r", "j"]),
    )
    got = np.asarray(eval_expr(node, _make_ctx({"m": m})), dtype=float)
    assert got.shape == (nr, nc)
    assert got == pytest.approx(np.cumsum(m, axis=1))


# ---------------------------------------------------------------------------
# Scan-like windows the scan tier cannot take: the dense gated reduce must fold
# them in the same order as the per-cell walk, bit for bit.
# ---------------------------------------------------------------------------

# 1, -1e16, 1, 1e16 separates every fold order: ascending gives 0 + 1e16 ... and
# descending, pairwise and ascending sums all differ in where the 1s are lost.
_SEPARATING = np.tile([1.0, -1e16, 1.0, 1e16, 3.0, -2e16, 1.0, 2e16], 4)


def _window(cmp: str, reduce_op: str, *, body_reads_i: bool, other_range: bool, join: bool):
    n = _SEPARATING.size
    body = ExprNode(op="index", args=["u", "j"])
    if body_reads_i:
        body = ExprNode(op="*", args=[body, ExprNode(op="+", args=["i", 0.5])])
    node = ExprNode(
        op="faq",
        args=["u"],
        output_idx=["i"],
        reduce=reduce_op,
        ranges={"i": [1, n - 3] if other_range else [1, n], "j": [1, n]},
        filter=ExprNode(op=cmp, args=["j", "i"]),
        expr=body,
    )
    if join:
        # Key columns over two declared index sets: a term enters the window
        # only when the two cells' keys match, so the gate thins each window.
        node.ranges = {"i": {"from": "rows"}, "j": {"from": "cols"}}
        node.join = [{"on": [["ki", "kj"]]}]
    return node


def _window_ctx() -> EvalContext:
    n = _SEPARATING.size
    keys = (np.arange(n) % 3).astype(float)
    ctx = _make_ctx({"u": _SEPARATING, "ki": keys, "kj": keys})
    ctx.index_sets = {
        "rows": {"kind": "interval", "size": n},
        "cols": {"kind": "interval", "size": n},
    }
    ctx.var_index_sets = {"ki": "rows", "kj": "cols", "u": "cols"}
    return ctx


_SHAPES = {
    "body-reads-i": dict(body_reads_i=True, other_range=False, join=False),
    "other-range": dict(body_reads_i=False, other_range=True, join=False),
    "join": dict(body_reads_i=False, other_range=False, join=True),
}


@pytest.mark.parametrize("shape", sorted(_SHAPES))
@pytest.mark.parametrize("cmp", ["<=", "<", ">=", ">"])
@pytest.mark.parametrize("reduce_op", ["+", "*", "max", "min"])
def test_windows_the_scan_tier_declines_fold_like_the_per_cell_walk(shape, cmp, reduce_op):
    kw = _SHAPES[shape]
    want = _per_cell(_window(cmp, reduce_op, **kw), _window_ctx())
    policy = CompilerPolicy(compiler="native")
    with use_policy(policy):
        got = eval_expr(_window(cmp, reduce_op, **kw), _window_ctx())
    assert policy.report.tiers().get("gated-reduce"), policy.report.tiers()
    _assert_bit_identical(got, want, f"{shape} {cmp} {reduce_op}")


def _per_cell(node: ExprNode, ctx: EvalContext) -> np.ndarray:
    with use_policy(CompilerPolicy(compiler="interpreter", every_tier_off=True)):
        return np.asarray(eval_expr(node, ctx), dtype=float)


@pytest.mark.parametrize("cmp", [">=", ">"])
def test_a_declined_reverse_window_folds_from_the_top(cmp):
    """Against a hand fold: the other-range reverse sum is descending, and the
    input makes ascending, descending and pairwise sums disagree."""
    node = _window(cmp, "+", body_reads_i=False, other_range=True, join=False)
    policy = CompilerPolicy(compiler="native")
    with use_policy(policy):
        got = np.asarray(eval_expr(node, _window_ctx()), dtype=float).ravel()
    u = _SEPARATING
    n = u.size
    want, asc = [], []
    for i in range(1, n - 2):
        window = [u[j - 1] for j in range(1, n + 1) if (j >= i if cmp == ">=" else j > i)]
        d = a = None
        for v in reversed(window):
            d = v if d is None else d + v
        for v in window:
            a = v if a is None else a + v
        want.append(0.0 if d is None else d)
        asc.append(0.0 if a is None else a)
    _assert_bit_identical(got, np.asarray(want), f"declined reverse {cmp}")
    assert want != asc
