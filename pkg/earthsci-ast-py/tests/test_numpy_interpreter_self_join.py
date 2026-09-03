"""A relation joined to ITSELF: two ``aggregate`` ranges over ONE index set.

CONFORMANCE_SPEC §5.5.8 "Two ranges over one index set".

Two ranges over one index set is already the documented spelling of a prefix
reduction (esm-spec §4.3.1, ``filter: j <= i``). What could not be spelled was
the same shape with a value-equality GATE instead of an inequality filter:
resolving an ``on`` key column to a loop symbol goes through the column's AXIS,
and an axis drawn by two range symbols named neither, so Python raised "join key
'rows' names an index set bound by multiple range symbols" — advice a DATA
COLUMN key cannot take, because the pair has nowhere to put a symbol.

Every assertion is a SPECIFIC value and a SPECIFIC row count. A self-join is
exactly the construct where a wrong side assignment returns a plausible number —
the NEXT row's payload instead of the PREVIOUS row's — so "it ran" proves
nothing. The transposed answer is asserted too, as the thing the default must
NOT produce.
"""

from __future__ import annotations

from typing import Any, Dict, Tuple

import numpy as np
import pytest

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    eval_expr,
)

BACK = 3


def _payload(n: int) -> np.ndarray:
    """``payload[i] = 7i + 4`` for 1-based ``i`` — distinct enough that no wrong
    pairing coincides with the right one."""
    return np.array([7.0 * i + 4.0 for i in range(1, n + 1)])


def _ids(n: int) -> np.ndarray:
    return np.arange(1.0, n + 1.0)


def _shifted(n: int, by: int) -> np.ndarray:
    return np.array([float(i - by) for i in range(1, n + 1)])


def _ctx(n: int) -> EvalContext:
    """One table of ``n`` rows over the single index set ``rows``.

    ``row_prior`` / ``row_back`` are ORDINARY KEY COLUMNS, not a format feature:
    the join learns nothing about "previous", it equi-joins two columns that
    happen to be shifted copies of each other.
    """
    values: Dict[str, np.ndarray] = {
        "row_id": _ids(n),
        "row_prior": _shifted(n, 1),
        "row_back": _shifted(n, BACK),
        "payload": _payload(n),
    }
    layout: Dict[str, slice] = {}
    shapes: Dict[str, Tuple[int, ...]] = {}
    pieces = []
    off = 0
    for name, arr in values.items():
        layout[name] = slice(off, off + arr.size)
        shapes[name] = (arr.size,)
        pieces.append(arr)
        off += arr.size
    return EvalContext(
        state_layout=layout,
        state_shapes=shapes,
        param_values={},
        observed_values={},
        y=np.concatenate(pieces),
        t=0.0,
        index_sets={"rows": {"kind": "interval", "size": n}},
        var_index_sets={k: "rows" for k in values},
    )


def _node(
    n: int,
    key_col: str = "row_prior",
    syms: Any = None,
    range_syms: Tuple[str, ...] = ("a", "b"),
    out_sym: str = "a",
) -> ExprNode:
    """``out[a] = Σ_b payload[b]`` over the pairs where ``key_col[a] == row_id[b]``."""
    clause: Dict[str, Any] = {"on": [[key_col, "row_id"]]}
    if syms is not None:
        clause["syms"] = list(syms)
    return ExprNode(
        op="aggregate",
        output_idx=[out_sym],
        semiring="sum_product",
        reduce="+",
        expr=ExprNode(op="index", args=["payload", "b"]),
        ranges={s: {"from": "rows"} for s in range_syms},
        join=[clause],
    )


def _run(node: ExprNode, n: int) -> np.ndarray:
    return np.asarray(eval_expr(node, _ctx(n)), dtype=float).ravel()


# Independent oracles, so a shared mistake cannot pass.
def _prior_oracle(n: int) -> np.ndarray:
    p = _payload(n)
    return np.array([0.0 if i == 0 else p[i - 1] for i in range(n)])


def _back_oracle(n: int) -> np.ndarray:
    p = _payload(n)
    return np.array([0.0 if i < BACK else p[i - BACK] for i in range(n)])


def _next_oracle(n: int) -> np.ndarray:
    p = _payload(n)
    return np.array([0.0 if i + 1 >= n else p[i + 1] for i in range(n)])


# ---------------------------------------------------------------------------
# The value, and the specific wrong value it must not be
# ---------------------------------------------------------------------------


def test_the_default_side_assignment_reads_the_previous_row() -> None:
    n = 9
    out = _run(_node(n), n)
    assert out.shape == (n,)
    np.testing.assert_array_equal(out, _prior_oracle(n))
    # Named explicitly, because these ARE the numbers: payload[i] = 7i + 4.
    assert out[0] == 0.0  # no predecessor: the inner join's 0-bar, not a hole
    assert out[1] == 11.0  # payload[1] = 11
    assert out[8] == 60.0  # payload[8] = 60
    # …and NOT the transposed reading, which would have been just as plausible.
    assert not np.array_equal(out, _next_oracle(n))


def test_a_bounded_lookback_is_just_another_key_column() -> None:
    """The two sides' key EXPRESSIONS differ — a second shifted column, no new
    feature, and the format learns nothing about time series."""
    n = 9
    out = _run(_node(n, key_col="row_back"), n)
    np.testing.assert_array_equal(out, _back_oracle(n))
    np.testing.assert_array_equal(out[:BACK], np.zeros(BACK))
    assert out[3] == 11.0  # payload[1] = 11
    assert out[8] == 46.0  # payload[6] = 46


def test_explicit_syms_choose_the_orientation() -> None:
    n = 9
    # ``[a, b]`` restates the default and must not change the answer.
    np.testing.assert_array_equal(_run(_node(n, syms=("a", "b")), n), _prior_oracle(n))

    # ``[b, a]`` reads the key at the CONTRACTED symbol instead: the row whose
    # predecessor is ``a``, i.e. the NEXT row. A different, specific answer —
    # which is the proof ``syms`` is consulted rather than ignored.
    flipped = _run(_node(n, syms=("b", "a")), n)
    np.testing.assert_array_equal(flipped, _next_oracle(n))
    assert flipped[0] == 18.0  # payload[2] = 18
    assert flipped[8] == 0.0  # no successor


def test_the_self_join_is_deterministic_under_row_permutation_of_the_keys() -> None:
    """§5.7 rule 5: hashing buckets only, and the emitted result is ordered by
    the canonical key — so the answer is a function of the key VALUES, not of the
    order they were stored in.

    Reversing both key columns and the payload together relabels row ``i`` as
    row ``n+1−i``; the predecessor of a row is then its SUCCESSOR in the stored
    order, and the answer must be exactly the reversed successor lookup.
    """
    n = 9
    ctx = _ctx(n)
    fwd = np.asarray(eval_expr(_node(n), ctx), dtype=float).ravel()

    rev = _ctx(n)
    rev.y[rev.state_layout["row_id"]] = _ids(n)[::-1]
    rev.y[rev.state_layout["row_prior"]] = _shifted(n, 1)[::-1]
    rev.y[rev.state_layout["payload"]] = _payload(n)[::-1]
    out = np.asarray(eval_expr(_node(n), rev), dtype=float).ravel()
    np.testing.assert_array_equal(out, fwd[::-1])


# ---------------------------------------------------------------------------
# The refusals: what the format cannot determine, it must not guess
# ---------------------------------------------------------------------------


def test_three_ranges_over_one_index_set_are_refused_by_name() -> None:
    with pytest.raises(NumpyInterpreterError, match="drawn by 3 range symbols") as e:
        _run(_node(6, range_syms=("a", "b", "c")), 6)
    assert "syms" in str(e.value)


def test_three_ranges_are_spellable_with_explicit_syms() -> None:
    """Once the two sides are named, the third range is an ordinary ungated
    axis: the gated pair is unchanged and the answer is multiplied by its
    extent, exactly as the join-free reduction would be."""
    n = 6
    out = _run(_node(n, range_syms=("a", "b", "c"), syms=("a", "b")), n)
    np.testing.assert_array_equal(out, _prior_oracle(n) * n)
    assert out[1] == 66.0  # payload[1] = 11, times the 6-wide free axis


def test_syms_naming_a_symbol_the_node_does_not_bind_is_refused() -> None:
    with pytest.raises(NumpyInterpreterError, match="not a range symbol"):
        _run(_node(5, syms=("a", "zzz")), 5)


def test_a_key_naming_an_ambiguous_index_set_still_says_name_the_symbol() -> None:
    """The DEFAULT assignment applies to a DATA COLUMN's axis only. A key that
    NAMES the index set can already say which side it means by naming the range
    symbol instead, so that ambiguity stays an error — losing the diagnostic
    would trade a build failure for a plausible number."""
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        expr=ExprNode(op="index", args=["payload", "b"]),
        ranges={"a": {"from": "rows"}, "b": {"from": "rows"}},
        join=[{"on": [["rows", "row_id"]]}],
    )
    with pytest.raises(NumpyInterpreterError, match="multiple range symbols"):
        eval_expr(node, _ctx(5))


def test_an_ambiguous_index_set_key_is_resolvable_with_syms() -> None:
    """…and `syms` is the escape hatch there too: the key values are then the
    interval IDs 1…n on the left and the `row_id` column on the right, which
    match on the diagonal — n terms, one per row."""
    n = 5
    node = ExprNode(
        op="aggregate",
        output_idx=[],
        semiring="sum_product",
        reduce="+",
        expr=1.0,
        ranges={"a": {"from": "rows"}, "b": {"from": "rows"}},
        join=[{"on": [["rows", "row_id"]], "syms": ["a", "b"]}],
    )
    assert float(np.asarray(eval_expr(node, _ctx(n)))) == float(n)
