"""Two silent-wrong-answer defects in the array evaluator, and their fixes.

Both were found by a cross-binding audit of GitHub issues #100 / #101 (filed
against Rust; Python was affected too, and for #100 it corrupted in the OPPOSITE
direction from Rust).

**#101 — a one-operand ``broadcast`` discarded its ``fn``.** ``_eval_broadcast``
folded pairwise starting from ``args[0]``, so a single-element ``args`` never
entered the loop and the node evaluated to its operand UNCHANGED.
``{"op": "broadcast", "fn": "-", "args": ["x"]}`` was therefore ``+x`` — a
dropped sign, silently. Nothing validated ``fn`` either: it lived in a FIELD, and
every arity/vocabulary check read ``args`` only, so ``fn: "not_a_real_op"``
returned ``is_valid=True`` and became a run-time table miss much later.

**#100 — array-level operands were aligned POSITIONALLY.** NumPy right-aligns
shapes, so a ``[lat]`` field used in a ``[lon, lat, lev]`` result was replicated
along ``lon``/``lat`` and varied along ``lev`` — an axis it was never declared
over — with ``valid=True``, ``success=True`` and zero warnings. Whether the
mistake was even visible depended on arithmetic luck: a mismatched element count
raised, a matching one corrupted. The equal-rank case silently TRANSPOSED.

The oracle throughout is the explicit ``aggregate`` spelling with written-out
indices, which was already correct and is not changed by any of this. Every
Bug-2 test below asserts the bare array-level form equals its aggregate form
exactly.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.numpy_interpreter import EvalContext, NumpyInterpreterError, eval_expr
from earthsci_ast.parse import load
from earthsci_ast.simulation import simulate
from earthsci_ast.validation import validate

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

#: lon=3, lat=2, lev=2 — the grid the audit measured both defects on. The axis
#: extents are deliberately DIFFERENT from one another where it matters and
#: EQUAL (lat/lev = 2) where a positional rule could silently "work", which is
#: what let the #100 mis-broadcast go unnoticed.
GRID = {
    "lon": {"kind": "interval", "size": 3},
    "lat": {"kind": "interval", "size": 2},
    "lev": {"kind": "interval", "size": 2},
}


def _ctx(values: dict[str, np.ndarray]) -> EvalContext:
    return EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.zeros(0),
        t=0.0,
        derived_rings={k: v for k, v in values.items() if isinstance(v, np.ndarray)},
    )


def _const(value) -> dict:
    return {"op": "const", "args": [], "value": value}


def _makearray(regions, value) -> dict:
    return {"op": "makearray", "args": [], "regions": [regions], "values": [_const(value)]}


def _doc(variables: dict, equations: list, index_sets: dict | None = None) -> str:
    return json.dumps(
        {
            "esm": "0.8.0",
            "metadata": {"name": "AlignmentFixture"},
            "index_sets": dict(index_sets or GRID),
            "models": {"M": {"variables": variables, "equations": equations}},
        }
    )


def _run(doc: str, shape: tuple[int, ...]) -> np.ndarray:
    """Integrate ``doc`` over t in [0, 1] and return the final state, reshaped.

    Every fixture here uses a constant RHS from a zero initial condition, so the
    final state IS the RHS — which makes the assertions read as direct
    comparisons of the two spellings' values.
    """
    result = simulate(load(doc), (0.0, 1.0), method="LSODA", rtol=1e-10, atol=1e-12)
    assert result.success, result.message
    return np.asarray(result.y[: int(np.prod(shape)), -1]).reshape(shape)


def _errors(doc: str) -> list[str]:
    report = validate(doc)
    return [e.message for e in (report.schema_errors or []) + (report.structural_errors or [])]


def _codes(doc: str) -> set[str]:
    report = validate(doc)
    return {e.code for e in (report.schema_errors or []) + (report.structural_errors or [])}


# ===========================================================================
# BUG 1 (#101) — `broadcast` with one operand must APPLY `fn`
# ===========================================================================

#: Unary ops a one-operand `broadcast` must apply. `-` and `neg` are the two
#: spellings of negation (`canonicalize()` rewrites the former into the latter);
#: the rest are elementary functions. `0.7` is chosen so every one of them —
#: including `log`, `sqrt` and the inverse trig — is defined on it.
UNARY_FNS = ["-", "neg", "log", "exp", "sqrt", "abs", "sin", "cos"]


@pytest.mark.parametrize("fn", UNARY_FNS)
def test_one_operand_broadcast_equals_the_bare_op(fn: str) -> None:
    """``broadcast(fn=F, [x])`` computes exactly ``{"op": F, "args": [x]}``.

    The regression: with one operand the old pairwise fold never ran, so the
    node returned ``x`` and ``F`` was silently discarded.
    """
    x = np.array([0.7, 1.3, 2.5])
    ctx = _ctx({"x": x})
    broadcast = eval_expr(ExprNode(op="broadcast", args=["x"], fn=fn), ctx)
    direct = eval_expr(ExprNode(op=fn, args=["x"]), ctx)
    np.testing.assert_array_equal(broadcast, np.asarray(direct, dtype=float))
    # ...and is genuinely the operator applied, not a pass-through of the
    # operand. (`abs` is the identity on this all-positive input, so the
    # equality above is the only claim that can be made for it.)
    if fn != "abs":
        assert not np.array_equal(broadcast, x)


def test_one_operand_broadcast_negation_is_not_the_identity() -> None:
    """The exact shape of issue #101: ``fn: "-"`` over one operand must NEGATE.

    Pinned separately from the parametrized case because this is the spelling
    the issue reported and the one whose failure was invisible: a dropped sign
    keeps the magnitudes plausible.
    """
    ctx = _ctx({"x": np.array([0.25, -4.0])})
    out = eval_expr(ExprNode(op="broadcast", args=["x"], fn="-"), ctx)
    np.testing.assert_array_equal(out, np.array([-0.25, 4.0]))


@pytest.mark.parametrize("fn", ["+", "*", "min", "max"])
def test_nary_broadcast_still_folds(fn: str) -> None:
    """Making one operand work must not stop n-ary ``fn``s from folding."""
    ctx = _ctx({"a": np.array([1.0, 5.0]), "b": np.array([2.0, 3.0]), "c": np.array([7.0, 4.0])})
    args = ["a", "b", "c"]
    got = eval_expr(ExprNode(op="broadcast", args=args, fn=fn), ctx)
    want = eval_expr(ExprNode(op=fn, args=args), ctx)
    np.testing.assert_array_equal(got, np.asarray(want, dtype=float))


def test_broadcast_end_to_end_matches_the_bare_operator() -> None:
    """The audit's measured case: ``D(dp) = -div_h`` with ``div_h = a*dp``,
    ``a = -0.3``, so ``dp(1) = exp(0.3)``.

    Spelled as ``{"op": "-"}`` this was always right; spelled as
    ``broadcast(fn="-")`` it returned ``exp(-0.3) = 0.741`` — the sign dropped.
    """
    variables = {
        "dp": {"type": "state", "shape": ["lon", "lat", "lev"], "default": 1.0},
        "a": {"type": "parameter", "default": -0.3},
        "div_h": {
            "type": "observed",
            "shape": ["lon", "lat", "lev"],
            "expression": {"op": "*", "args": ["a", "dp"]},
        },
    }

    def final(rhs):
        doc = _doc(variables, [{"lhs": {"op": "D", "args": ["dp"], "wrt": "t"}, "rhs": rhs}])
        result = simulate(load(doc), (0.0, 1.0), method="LSODA", rtol=1e-10, atol=1e-12)
        assert result.success, result.message
        return float(result.y[0, -1])

    bare = final({"op": "-", "args": ["div_h"]})
    broadcast = final({"op": "broadcast", "fn": "-", "args": ["div_h"]})
    assert broadcast == pytest.approx(bare, rel=1e-9)
    assert broadcast == pytest.approx(np.exp(0.3), rel=1e-7)
    # The old answer was exp(-0.3) = 0.7408 — the sign silently dropped.
    assert broadcast != pytest.approx(np.exp(-0.3), rel=1e-3)


# --- `fn` is now VALIDATED, not discovered at run time ---------------------


def _broadcast_doc(node: dict) -> str:
    return _doc(
        {
            "dp": {"type": "state", "shape": ["lon", "lat", "lev"], "default": 1.0},
            "q": {
                "type": "observed",
                "shape": ["lon", "lat", "lev"],
                "expression": {"op": "*", "args": [2.0, "dp"]},
            },
        },
        [{"lhs": {"op": "D", "args": ["dp"], "wrt": "t"}, "rhs": node}],
    )


def test_unregistered_broadcast_fn_is_a_validation_error() -> None:
    """``fn: "not_a_real_op"`` used to validate CLEAN and fail only at run time."""
    doc = _broadcast_doc({"op": "broadcast", "fn": "not_a_real_op", "args": ["q"]})
    report = validate(doc)
    assert not report.is_valid
    assert "broadcast_fn_invalid" in _codes(doc)
    assert any("not_a_real_op" in e and "not a registered operator" in e for e in _errors(doc))


def test_missing_broadcast_fn_is_a_validation_error() -> None:
    """A ``broadcast`` with no ``fn`` names no operator at all.

    The JSON Schema already makes ``fn`` required on a ``broadcast`` node, so
    this one is caught before the structural pass — which is why the assertion
    is on ``validate()``'s verdict rather than on a particular code. The
    structural check still covers it for callers that reach it with the schema
    gate bypassed, and the evaluator keeps its own backstop.
    """
    doc = _broadcast_doc({"op": "broadcast", "args": ["q"]})
    assert not validate(doc).is_valid
    assert any("fn" in e for e in _errors(doc))


@pytest.mark.parametrize("fn", ["aggregate", "index", "makearray", "reshape", "concat"])
def test_non_scalar_broadcast_fn_is_a_validation_error(fn: str) -> None:
    """``fn`` must name a SCALAR operator (esm-spec §4.3.4).

    An array op reshapes or re-indexes its operands rather than combining them
    cell-wise, so it cannot be the element-wise operator of a ``broadcast``.
    """
    doc = _broadcast_doc({"op": "broadcast", "fn": fn, "args": ["q"]})
    assert not validate(doc).is_valid
    assert any("non-scalar" in e and fn in e for e in _errors(doc))


def test_broadcast_fn_arity_mismatch_is_a_validation_error() -> None:
    """An ``fn``/operand-count mismatch is an error, not a degenerate fold.

    ``min`` is n-ary with a floor of two operands; handed one it used to return
    that operand unchanged, which looks exactly like a correct answer.
    """
    doc = _broadcast_doc({"op": "broadcast", "fn": "min", "args": ["q"]})
    assert not validate(doc).is_valid
    assert any("requires at least 2 operand" in e for e in _errors(doc))


def test_broadcast_fn_over_arity_is_a_validation_error() -> None:
    """``/`` is strictly binary; three operands is a defect, not a fold."""
    doc = _broadcast_doc({"op": "broadcast", "fn": "/", "args": ["q", "q", "q"]})
    assert not validate(doc).is_valid
    assert any("accepts at most 2 operand" in e for e in _errors(doc))


def test_valid_broadcast_still_validates() -> None:
    """The new check must not reject legitimate nodes."""
    for node in (
        {"op": "broadcast", "fn": "-", "args": ["q"]},
        {"op": "broadcast", "fn": "exp", "args": ["q"]},
        {"op": "broadcast", "fn": "*", "args": [-1.0, "q"]},
        {"op": "broadcast", "fn": "min", "args": ["q", "q", "q"]},
        {"op": "broadcast", "fn": "**", "args": ["q", 2.0]},
    ):
        assert validate(_broadcast_doc(node)).is_valid, node


def test_bad_broadcast_fn_still_raises_at_evaluation() -> None:
    """Validation is the primary gate; the evaluator keeps a backstop."""
    ctx = _ctx({"x": np.array([1.0])})
    with pytest.raises(NumpyInterpreterError, match="does not name a scalar operator"):
        eval_expr(ExprNode(op="broadcast", args=["x"], fn="not_a_real_op"), ctx)
    with pytest.raises(NumpyInterpreterError, match="no `fn` field"):
        eval_expr(ExprNode(op="broadcast", args=["x"]), ctx)


# --- `neg` is now part of Python's op vocabulary ---------------------------


def test_canonicalize_output_is_evaluable() -> None:
    """``canonicalize()`` rewrites unary ``-`` into ``neg``; Python's registry
    omitted ``neg``, so its OWN canonicalizer produced trees its OWN evaluator
    rejected as an unlowered rewrite-target. Rust and Julia both register it.
    """
    from earthsci_ast.canonicalize import canonicalize

    node = canonicalize(ExprNode(op="-", args=["x"]))
    assert node.op == "neg"
    ctx = EvalContext(
        state_layout={},
        state_shapes={},
        param_values={"x": 3.0},
        observed_values={},
        y=np.zeros(0),
        t=0.0,
    )
    assert eval_expr(node, ctx) == pytest.approx(-3.0)


def test_neg_renders_exactly_like_unary_minus() -> None:
    """Canonicalizing must not change how a document reads."""
    from earthsci_ast import display

    for build in (
        lambda op: ExprNode(op=op, args=["x"]),
        lambda op: ExprNode(op="*", args=[2.0, ExprNode(op=op, args=["x"])]),
        lambda op: ExprNode(op="+", args=["a", ExprNode(op=op, args=["b"])]),
    ):
        for render in (display.to_ascii, display.to_unicode, display.to_latex):
            assert render(build("neg")) == render(build("-"))


# ===========================================================================
# BUG 2 (#100) — array-level operands align by index-set NAME
# ===========================================================================

_ONES3 = {
    "type": "observed",
    "shape": ["lon", "lat", "lev"],
    "expression": _makearray([[1, 3], [1, 2], [1, 2]], 1.0),
}
#: w1 over `lat` only: [10, 20].
_W1 = {"type": "observed", "shape": ["lat"], "expression": _makearray([[1, 2]], [10.0, 20.0])}
#: w2 over `[lon, lat]`.
_W2 = {
    "type": "observed",
    "shape": ["lon", "lat"],
    "expression": _makearray([[1, 3], [1, 2]], [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]),
}
#: z1 over `lev` only.
_Z1 = {"type": "observed", "shape": ["lev"], "expression": _makearray([[1, 2]], [100.0, 200.0])}

_STATE3 = {"type": "state", "shape": ["lon", "lat", "lev"], "default": 0.0}


def _bare_eq(rhs):
    return [{"lhs": {"op": "D", "args": ["dp"], "wrt": "t"}, "rhs": rhs}]


def _agg_eq(expr):
    """The ORACLE spelling: an explicit per-cell aggregate over ``[i, j, k]``."""
    frame = {
        "op": "aggregate",
        "args": [],
        "output_idx": ["i", "j", "k"],
        "ranges": {"i": {"from": "lon"}, "j": {"from": "lat"}, "k": {"from": "lev"}},
    }
    return [
        {
            "lhs": {
                **frame,
                "expr": {
                    "op": "D",
                    "args": [{"op": "index", "args": ["dp", "i", "j", "k"]}],
                    "wrt": "t",
                },
            },
            "rhs": {**frame, "expr": expr},
        }
    ]


def test_case_a_subset_operand_replicates_like_the_aggregate() -> None:
    """A ``[lat]`` operand in a ``[lon, lat, lev]`` result.

    The measured corruption: ``w1`` came out varying along ``lev`` — so
    ``dp[1,1,2]`` was 20 where the oracle says 10, and ``dp[1,2,1]`` was 10
    where the oracle says 20. Same element count, so nothing raised.
    """
    variables = {"dp": _STATE3, "w1": _W1, "ones3": _ONES3}
    bare = _run(_doc(variables, _bare_eq({"op": "*", "args": ["w1", "ones3"]})), (3, 2, 2))
    oracle = _run(
        _doc(
            variables,
            _agg_eq(
                {
                    "op": "*",
                    "args": [
                        {"op": "index", "args": ["w1", "j"]},
                        {"op": "index", "args": ["ones3", "i", "j", "k"]},
                    ],
                }
            ),
        ),
        (3, 2, 2),
    )
    np.testing.assert_array_equal(bare, oracle)
    # The concrete numbers the audit pinned: w1 varies along `lat`, never `lev`.
    np.testing.assert_allclose(
        [bare[0, 0, 0], bare[0, 0, 1], bare[0, 1, 0], bare[0, 1, 1]], [10, 10, 20, 20]
    )


def test_case_a_bare_operand_alone_broadcasts_to_the_state() -> None:
    """``D(dp) = w1`` with no sibling to broadcast against.

    This used to raise ``RHS produced 2 elements for a state of shape (3,2,2)``.
    The operand IS meaningful — it is constant along the axes it does not name —
    so it must integrate, and agree with the aggregate spelling.
    """
    variables = {"dp": _STATE3, "w1": _W1}
    bare = _run(_doc(variables, _bare_eq("w1")), (3, 2, 2))
    oracle = _run(_doc(variables, _agg_eq({"op": "index", "args": ["w1", "j"]})), (3, 2, 2))
    np.testing.assert_array_equal(bare, oracle)
    np.testing.assert_allclose([bare[0, 0, 0], bare[0, 1, 0]], [10, 20])


def test_case_b_disjoint_subsets_form_the_outer_product() -> None:
    """``[lon, lat]`` times ``[lev]`` into ``[lon, lat, lev]``.

    Six elements against twelve cells, so this one at least RAISED before — but
    it raised a run-time size error for an expression that is perfectly
    well-defined under name alignment.
    """
    variables = {"dp": _STATE3, "w2": _W2, "z1": _Z1}
    bare = _run(_doc(variables, _bare_eq({"op": "*", "args": ["w2", "z1"]})), (3, 2, 2))
    oracle = _run(
        _doc(
            variables,
            _agg_eq(
                {
                    "op": "*",
                    "args": [
                        {"op": "index", "args": ["w2", "i", "j"]},
                        {"op": "index", "args": ["z1", "k"]},
                    ],
                }
            ),
        ),
        (3, 2, 2),
    )
    np.testing.assert_array_equal(bare, oracle)
    np.testing.assert_allclose([bare[2, 1, 0], bare[2, 1, 1]], [600.0, 1200.0])


def test_equal_rank_name_permuted_operand_transposes_not_reinterprets() -> None:
    """An operand declared ``[lat, lon]`` used in a ``[lon, lat]`` result.

    Not in the filed issue but the same defect: equal ranks meant NumPy lined
    the axes up positionally, so the operand was silently TRANSPOSED —
    ``dp[1,2]`` and ``dp[2,1]`` swapped. Square extents made it undetectable by
    any shape check.
    """
    square = {"lon": {"kind": "interval", "size": 3}, "lat": {"kind": "interval", "size": 3}}
    # wt[lat][lon] = 10*lat + lon, so wt is asymmetric and a transpose shows up.
    wt_values = [[10 * a + b for b in (1, 2, 3)] for a in (1, 2, 3)]
    variables = {
        "dp": {"type": "state", "shape": ["lon", "lat"], "default": 0.0},
        "wt": {
            "type": "observed",
            "shape": ["lat", "lon"],
            "expression": _makearray([[1, 3], [1, 3]], wt_values),
        },
    }
    bare = _run(_doc(variables, _bare_eq("wt"), square), (3, 3))
    oracle_eq = [
        {
            "lhs": {
                "op": "aggregate",
                "args": [],
                "output_idx": ["i", "j"],
                "ranges": {"i": {"from": "lon"}, "j": {"from": "lat"}},
                "expr": {
                    "op": "D",
                    "args": [{"op": "index", "args": ["dp", "i", "j"]}],
                    "wrt": "t",
                },
            },
            "rhs": {
                "op": "aggregate",
                "args": [],
                "output_idx": ["i", "j"],
                "ranges": {"i": {"from": "lon"}, "j": {"from": "lat"}},
                # wt is indexed [lat, lon] = [j, i].
                "expr": {"op": "index", "args": ["wt", "j", "i"]},
            },
        }
    ]
    oracle = _run(_doc(variables, oracle_eq, square), (3, 3))
    np.testing.assert_array_equal(bare, oracle)
    # dp[lon=1, lat=2] reads wt[lat=2, lon=1] = 21, NOT wt[1][2] = 12.
    np.testing.assert_allclose([bare[0, 1], bare[1, 0]], [21, 12])


def test_observed_expression_is_aligned_too() -> None:
    """The result frame of an OBSERVED is its own declared shape.

    An observed is as much an array-level result as a state derivative, and its
    body was mis-aligned the same way.
    """
    variables = {
        "dp": _STATE3,
        "w1": _W1,
        "ones3": _ONES3,
        "q": {
            "type": "observed",
            "shape": ["lon", "lat", "lev"],
            "expression": {"op": "*", "args": ["w1", "ones3"]},
        },
    }
    bare = _run(_doc(variables, _bare_eq("q")), (3, 2, 2))
    np.testing.assert_allclose(
        [bare[0, 0, 0], bare[0, 0, 1], bare[0, 1, 0], bare[0, 1, 1]], [10, 10, 20, 20]
    )


def test_operand_with_an_index_set_absent_from_the_result_is_rejected() -> None:
    """A ``[lev]`` operand in a ``[lon, lat]`` result cannot be aligned at all.

    There is no replication, transpose or reshape that gives it meaning, and
    that is decidable STATICALLY — so it is a validation error, not the run-time
    size error it used to be (and not a warning).
    """
    doc = _doc(
        {"dp": {"type": "state", "shape": ["lon", "lat"], "default": 0.0}, "z1": _Z1},
        _bare_eq("z1"),
    )
    report = validate(doc)
    assert not report.is_valid
    assert "index_set_misalignment" in _codes(doc)
    message = "\n".join(_errors(doc))
    assert "'z1'" in message and "lev" in message


def test_unalignable_operand_is_rejected_inside_a_compound_expression() -> None:
    """The check follows the element-wise layer, not just the root."""
    doc = _doc(
        {
            "dp": {"type": "state", "shape": ["lon", "lat"], "default": 0.0},
            "z1": _Z1,
            "w2": _W2,
        },
        _bare_eq({"op": "+", "args": [{"op": "*", "args": ["w2", 2.0]}, "z1"]}),
    )
    assert not validate(doc).is_valid
    assert any("'z1'" in e for e in _errors(doc))


def test_alignable_operands_do_not_trigger_the_error() -> None:
    """Subsets and permutations are LEGAL — only the unalignable case errors."""
    for variables, rhs in (
        ({"dp": _STATE3, "w1": _W1, "ones3": _ONES3}, {"op": "*", "args": ["w1", "ones3"]}),
        ({"dp": _STATE3, "w2": _W2, "z1": _Z1}, {"op": "*", "args": ["w2", "z1"]}),
        ({"dp": _STATE3, "w1": _W1}, "w1"),
    ):
        assert validate(_doc(variables, _bare_eq(rhs))).is_valid


def test_an_index_use_of_a_foreign_index_set_is_not_flagged() -> None:
    """``index(z1, k)`` inside an aggregate is NOT an array-level operand.

    The walk must stop at ``index``/``aggregate``: those name their own axes
    explicitly, so a ``[lev]`` field read there is correct, not misaligned. A
    check that flagged it would break every correct aggregate in the corpus.
    """
    doc = _doc(
        {"dp": _STATE3, "z1": _Z1},
        _agg_eq({"op": "index", "args": ["z1", "k"]}),
    )
    assert validate(doc).is_valid
    out = _run(doc, (3, 2, 2))
    np.testing.assert_allclose([out[0, 0, 0], out[0, 0, 1]], [100, 200])


# ===========================================================================
# The scope boundary: ANONYMOUS shapes keep POSITIONAL semantics
# ===========================================================================


def test_broadcast_keeps_julia_left_alignment_for_anonymous_operands() -> None:
    """``reshape`` results carry no index-set names, so ``broadcast`` keeps its
    established left-align rule for them: ``(3,) .+ (1,3) -> (3,3)``.

    This is the boundary of name-based alignment. It only applies where names
    exist; anonymous shapes are unchanged by this work.
    """
    ctx = _ctx({"a": np.array([1.0, 2.0, 3.0]), "b": np.array([100.0, 200.0, 300.0])})
    out = eval_expr(
        ExprNode(
            op="broadcast",
            args=["a", ExprNode(op="reshape", args=["b"], shape=[1, 3])],
            fn="+",
        ),
        ctx,
    )
    assert out.shape == (3, 3)
    assert out[0, 0] == pytest.approx(101.0)
    assert out[2, 1] == pytest.approx(203.0)


@pytest.mark.parametrize("wrapper", ["reshape", "transpose", "concat"])
def test_anonymous_shape_operands_are_left_positional(wrapper: str) -> None:
    """A named operand wrapped in ``reshape``/``transpose``/``concat`` loses its
    names, and the alignment pass must not reach through the wrapper.

    ``align_expression`` descends the element-wise layer ONLY; a shape op's
    operand is that op's business. Pinned so a future widening of the walk is
    caught here rather than by silently re-shaping somebody's ``concat``.
    """
    from earthsci_ast.index_alignment import align_expression

    var_axes = {"w1": ("lat",)}
    sizes = {"lon": 3, "lat": 2, "lev": 2}
    inner = {"op": wrapper, "args": ["w1"], "shape": [2], "perm": [0], "axis": 0}
    expr = {"op": "*", "args": [inner, "ones3"]}
    assert align_expression(expr, ("lon", "lat", "lev"), var_axes, sizes) == expr


def test_alignment_is_a_no_op_when_the_operand_is_already_in_frame() -> None:
    """The overwhelmingly common case must produce an IDENTICAL tree, so a
    document that was already unambiguous keeps byte-identical numerics."""
    from earthsci_ast.index_alignment import align_expression

    var_axes = {"a": ("lon", "lat"), "b": ("lon", "lat")}
    expr = {"op": "+", "args": ["a", "b"]}
    assert align_expression(expr, ("lon", "lat"), var_axes, {"lon": 3, "lat": 2}) is expr


def test_alignment_declines_on_a_derived_index_set() -> None:
    """A ``derived`` set's extent is data-dependent, so no static rank-lift is
    possible; the operand is left positional rather than guessed at."""
    from earthsci_ast.index_alignment import align_expression, axis_sizes

    sizes = axis_sizes({"lat": {"kind": "interval", "size": 2}, "cells": {"kind": "derived"}})
    assert "cells" not in sizes
    expr = {"op": "*", "args": ["w1", "x"]}
    assert align_expression(expr, ("cells", "lat"), {"w1": ("lat",)}, sizes) is expr
