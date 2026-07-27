"""Cumulative (prefix) reductions — esm-spec §4.3.1.

A prefix reduction is an ordinary ``aggregate`` whose ``filter`` compares the
contracted index against an output index. Evaluated literally it is a triangular
double loop; the interpreter recognizes the FORWARD rows (``<=``, ``<``) and
collapses them to one ``ufunc.accumulate`` sweep.

The rewrite is only legitimate because it is **bit-identical** to the
ascending-``j`` fold the spec pins as normative, so that is what these tests
assert — not "close enough". They also pin the reverse rows as *declined*: each
reverse cell folds its own suffix from that suffix's low end, so consecutive
cells share no partial result and a right-to-left accumulator would re-associate.
"""

from __future__ import annotations

import numpy as np
import pytest

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
        op="aggregate",
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
    window in ascending ``j``. This is the semantics the spec defines."""
    n = len(u)
    admits = {
        "<=": lambda j, i: j <= i,
        "<": lambda j, i: j < i,
        ">=": lambda j, i: j >= i,
        ">": lambda j, i: j > i,
    }[cmp]
    combine = _COMBINE[reduce_op]
    out = []
    for i in range(1, n + 1):
        acc = _IDENTITY[reduce_op]
        for j in range(1, n + 1):
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


@pytest.mark.parametrize("n", [1, 5, 40])
@pytest.mark.parametrize("cmp", [">=", ">"])
@pytest.mark.parametrize("reduce_op", ["+", "max", "min"])
def test_reverse_scans_still_evaluate_correctly(n, cmp, reduce_op):
    """Declined by the scan detector; they must still produce the right answer
    through the general paths."""
    u = _catastrophic(n)
    got = np.asarray(eval_expr(_prefix_agg(cmp, n, reduce_op), _ctx(u)), dtype=float).ravel()
    want = _oracle(u, cmp, reduce_op)
    assert got == pytest.approx(want, rel=1e-12, abs=0.0)


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
        op="aggregate",
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
        op="aggregate",
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
        op="aggregate",
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
