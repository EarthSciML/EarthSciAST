"""The dense gated reduce folds each cell's admitted terms in whole-array steps.

The dense tiers (``gated-reduce``, ``nested-reduce``) hold every cell's terms as
a row of an ``[cells, terms]`` box with an admit mask. Folding them must give the
per-cell walk's bits — a left fold of the admitted terms seeded from the first,
an empty row the identity — and must not cost one numpy step per term position,
which is what a long row (``K = 10^4`` terms per cell) made of it.
"""

from __future__ import annotations

import numpy as np
import pytest

import earthsci_ast.numpy_interpreter as ni
from earthsci_ast.compiler import CompilerPolicy, use_policy
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import EvalContext, eval_expr

_REDUCERS = ["+", "*", "max", "min", "or"]
_IDENTITY = {"+": 0.0, "*": 1.0, "max": -np.inf, "min": np.inf, "or": 0.0}


def _adversarial(rng: np.random.Generator, shape: tuple[int, ...]) -> np.ndarray:
    """Signed zeros, NaNs, infinities and magnitudes far apart, so a wrong seed,
    a wrong tie rule or a reassociated sum changes some bit."""
    pool = np.array([0.0, -0.0, np.nan, np.inf, -np.inf, 1.0, -1.0, 1e16, -1e16, 3.0, 0.5])
    vals = rng.choice(pool, size=shape)
    noise = rng.standard_normal(shape) * 10.0 ** rng.integers(-8, 8, shape)
    return np.where(rng.random(shape) < 0.5, vals, noise)


def _same(got: np.ndarray, want: np.ndarray, reducer: str) -> bool:
    """Bit-identical, except that under ``+`` / ``*`` any NaN matches any NaN:
    which operand's sign and payload ``NaN ⊕ NaN`` keeps is up to the hardware
    loop (numpy's answer changes with the array length), so those bits mean
    nothing. ``max`` / ``min`` select a term, so their NaNs must be the term's."""
    g = np.ascontiguousarray(got, dtype=float)
    w = np.ascontiguousarray(want, dtype=float)
    if g.shape != w.shape:
        return False
    same = g.view(np.uint64) == w.view(np.uint64)
    if reducer in ("+", "*"):
        same |= np.isnan(g) & np.isnan(w)
    return bool(same.all())


@pytest.mark.parametrize("reducer", _REDUCERS)
@pytest.mark.parametrize("shape", [(1, 1), (5, 0), (7, 3), (40, 25), (3, 600)])
@pytest.mark.parametrize("density", [0.0, 0.1, 0.6, 1.0])
def test_masked_row_fold_is_the_segmented_fold_bit_for_bit(reducer, shape, density):
    rng = np.random.default_rng(hash((reducer, shape, density)) & 0xFFFF)
    for _ in range(5):
        term = _adversarial(rng, shape)
        admit = rng.random(shape) < density
        with np.errstate(over="ignore", invalid="ignore"):
            counts = admit.sum(axis=1).astype(np.int64)
            want = ni._segmented_fold(reducer, term[admit], counts, _IDENTITY[reducer])
            got = ni._masked_row_fold(reducer, term, admit, _IDENTITY[reducer])
        assert _same(got, want, reducer), (reducer, term, admit, got, want)


def _ctx(u: np.ndarray) -> EvalContext:
    return EvalContext(
        state_layout={"u": slice(0, u.size)},
        state_shapes={"u": u.shape},
        param_values={},
        observed_values={},
        y=np.asarray(u, dtype=float),
        t=0.0,
        index_sets={},
    )


def _gated(n_out: int, k: int, reducer: str, cmp: str) -> ExprNode:
    """``out[i] = ⊕_{j CMP i, j ≠ 3} u[j] · (i + 0.5)``: the body reads ``i``, so
    the scan tier declines and the dense gated reduce answers."""
    body = ExprNode(
        op="*", args=[ExprNode(op="index", args=["u", "j"]), ExprNode(op="+", args=["i", 0.5])]
    )
    window = ExprNode(op=cmp, args=["j", "i"])
    return ExprNode(
        op="faq",
        args=["u"],
        output_idx=["i"],
        reduce=reducer,
        ranges={"i": [1, n_out], "j": [1, k]},
        filter=ExprNode(op="and", args=[window, ExprNode(op="!=", args=["j", 3])]),
        expr=body,
    )


@pytest.mark.parametrize("reducer", ["+", "*", "max", "min"])
@pytest.mark.parametrize("cmp", ["<=", "<", ">=", ">"])
def test_the_gated_reduce_matches_the_per_cell_walk(reducer, cmp):
    u = _adversarial(np.random.default_rng(6), (60,))
    with use_policy(CompilerPolicy(compiler="interpreter", every_tier_off=True)):
        want = np.asarray(eval_expr(_gated(60, 60, reducer, cmp), _ctx(u)), dtype=float)
    policy = CompilerPolicy(compiler="native")
    with use_policy(policy):
        got = np.asarray(eval_expr(_gated(60, 60, reducer, cmp), _ctx(u)), dtype=float)
    assert policy.report.tiers().get("gated-reduce"), policy.report.tiers()
    assert _same(got, want, reducer), (got, want)


@pytest.mark.parametrize("reducer", ["+", "max"])
def test_a_long_row_folds_in_a_fixed_number_of_steps(reducer, monkeypatch):
    """Four cells of 4000 terms: the fold may not step once per term position."""
    calls = {"n": 0}
    step = ni._reduce_step_box

    def counting(*args):
        calls["n"] += 1
        return step(*args)

    monkeypatch.setattr(ni, "_reduce_step_box", counting)
    u = np.linspace(-1.0, 1.0, 4000)
    node = _gated(4, 4000, reducer, ">=")
    policy = CompilerPolicy(compiler="native")
    with use_policy(policy):
        eval_expr(node, _ctx(u))
    assert policy.report.tiers().get("gated-reduce"), policy.report.tiers()
    assert calls["n"] < 10, f"{calls['n']} fold steps for 4000 terms per cell"
