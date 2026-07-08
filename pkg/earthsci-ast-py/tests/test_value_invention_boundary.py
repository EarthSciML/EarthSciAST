"""Const-array boundary policy for value-invention gathers — Python binding
(bead ess-gj4).

Port-parity counterpart of the Julia reference test
``tree_walk_const_array_boundary_test.jl``. A const-array stencil gather at an
out-of-range 1-based index resolves declaratively per a declared per-dimension
boundary policy instead of raising a bare ``IndexError``:

  - ``"periodic"`` — wrap the index into 1..N via 1-based modulo (matches the
    state-var periodic fold / Julia ``mod1``).
  - ``"clamp"``    — edge-extend (clamp to 1..N); the correct finite policy for a
    metric/geometry factor at a non-periodic boundary (NOT zero-ghost).
  - absent / ``"error"`` — raise a structured :class:`ValueInventionError`, so
    genuine out-of-bounds bugs in connectivity / stencil-weight factors stay
    caught.

The numerics mirror the Julia reference exactly: M = [10, 20, 30, 40] (1-based),
clamp(index 5) = 40, periodic(index 5) = 10, periodic(index 0) = 40.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast.value_invention import (
    ValueInventionError,
    _ViCtx,
    _vi_index,
)


def _ctx(const_arrays: dict, boundaries: dict | None = None) -> _ViCtx:
    """A minimal value-invention context wrapping const arrays + an optional
    per-array boundary policy (the only fields ``_vi_index`` consumes)."""
    return _ViCtx(
        const_arrays={k: np.asarray(v, dtype=float) for k, v in const_arrays.items()},
        params={},
        index_sets={},
        variables={},
        const_array_boundaries=boundaries or {},
    )


def _gather(ctx: _ViCtx, name: str, *idxs: int) -> float:
    """Evaluate ``index(name, *idxs)`` (1-based) against ``ctx``."""
    node = {"op": "index", "args": [name, *idxs]}
    return _vi_index(node, ctx, {})


# The shared reference array (1-based: M[1]=10 … M[4]=40).
_M = [10.0, 20.0, 30.0, 40.0]


# --------------------------------------------------------------------------- #
# in-range behavior is identical regardless of (or absent) policy
# --------------------------------------------------------------------------- #


def test_in_range_gather_unchanged_without_policy() -> None:
    ctx = _ctx({"M": _M})
    assert _gather(ctx, "M", 1) == 10.0
    assert _gather(ctx, "M", 4) == 40.0


@pytest.mark.parametrize("policy", ["clamp", "periodic", "error"])
def test_in_range_gather_unchanged_with_policy(policy: str) -> None:
    ctx = _ctx({"M": _M}, {"M": [policy]})
    assert _gather(ctx, "M", 1) == 10.0
    assert _gather(ctx, "M", 2) == 20.0
    assert _gather(ctx, "M", 4) == 40.0


# --------------------------------------------------------------------------- #
# clamp — edge-extend at both boundaries
# --------------------------------------------------------------------------- #


def test_clamp_low_oob_returns_first_element() -> None:
    ctx = _ctx({"M": _M}, {"M": ["clamp"]})
    assert _gather(ctx, "M", 0) == 10.0  # clamp 0 -> 1 -> M[1]
    assert _gather(ctx, "M", -3) == 10.0  # clamp far-low -> M[1]


def test_clamp_high_oob_returns_last_element() -> None:
    ctx = _ctx({"M": _M}, {"M": ["clamp"]})
    assert _gather(ctx, "M", 5) == 40.0  # clamp 5 -> 4 -> M[4] (reference)
    assert _gather(ctx, "M", 99) == 40.0  # clamp far-high -> M[4]


# --------------------------------------------------------------------------- #
# periodic — 1-based modulo wrap at both boundaries (size 4)
# --------------------------------------------------------------------------- #


def test_periodic_wraps_high_and_low() -> None:
    ctx = _ctx({"M": _M}, {"M": ["periodic"]})
    # size 4: index 5 -> element 1 (== 10), index 0 -> element 4 (== 40)
    assert _gather(ctx, "M", 5) == 10.0
    assert _gather(ctx, "M", 0) == 40.0
    # further wraps: 6 -> 2 (20), -1 -> 3 (30) [mod1(-1, 4) == 3]
    assert _gather(ctx, "M", 6) == 20.0
    assert _gather(ctx, "M", -1) == 30.0


# --------------------------------------------------------------------------- #
# no declared policy (or "error") -> structured ValueInventionError, NOT IndexError
# --------------------------------------------------------------------------- #


def test_no_policy_raises_value_invention_error_not_index_error() -> None:
    ctx = _ctx({"M": _M})
    with pytest.raises(ValueInventionError, match=r"out of range 1\.\.4 in dim 0"):
        _gather(ctx, "M", 5)
    # a NEGATIVE index (which previously silently wrapped via numpy) now also
    # raises rather than returning M[-1].
    with pytest.raises(ValueInventionError):
        _gather(ctx, "M", 0)


def test_explicit_error_policy_raises() -> None:
    ctx = _ctx({"M": _M}, {"M": ["error"]})
    with pytest.raises(ValueInventionError, match="out of range"):
        _gather(ctx, "M", 5)


def test_unknown_policy_falls_back_to_error() -> None:
    """An unrecognised policy string is treated strictly (raises on OOB)."""
    ctx = _ctx({"M": _M}, {"M": ["reflect"]})
    with pytest.raises(ValueInventionError, match="out of range"):
        _gather(ctx, "M", 5)


def test_empty_dimension_raises_even_with_policy() -> None:
    """An n == 0 axis cannot resolve any index — guard to a structured error."""
    ctx = _ctx({"E": np.zeros((0,))}, {"E": ["periodic"]})
    with pytest.raises(ValueInventionError, match="out of range"):
        _gather(ctx, "E", 1)


# --------------------------------------------------------------------------- #
# 2D mixed policy — resolved per dimension
# --------------------------------------------------------------------------- #


def test_2d_mixed_policy_resolves_per_dimension() -> None:
    # 2x3 array, values 1..6 row-major: A[r, c] (1-based).
    arr = np.arange(1.0, 7.0).reshape(2, 3)
    ctx = _ctx({"A": arr}, {"A": ["clamp", "periodic"]})

    # in range: A[1,1] == 1, A[2,3] == 6
    assert _gather(ctx, "A", 1, 1) == 1.0
    assert _gather(ctx, "A", 2, 3) == 6.0

    # dim 0 clamp: row 0 -> 1, row 5 -> 2
    assert _gather(ctx, "A", 0, 1) == 1.0  # clamp row -> A[1,1]
    assert _gather(ctx, "A", 5, 1) == arr[1, 0]  # clamp row -> A[2,1] == 4

    # dim 1 periodic (size 3): col 4 -> 1, col 0 -> 3
    assert _gather(ctx, "A", 1, 4) == arr[0, 0]  # mod1(4,3)=1 -> A[1,1] == 1
    assert _gather(ctx, "A", 1, 0) == arr[0, 2]  # mod1(0,3)=3 -> A[1,3] == 3

    # both OOB at once: row clamp + col periodic
    assert _gather(ctx, "A", 9, 4) == arr[1, 0]  # row->2, col mod1(4,3)=1 -> A[2,1] == 4
