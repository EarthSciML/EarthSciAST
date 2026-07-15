"""Property-based tests for expression parsing/serialization round-trips (gt-72z).

Phase 1 of the cross-binding fuzzing initiative: generate syntactically-valid
expression ASTs with hypothesis and assert the round-trip + idempotence
invariants on them.

Invariants asserted (per gt-72z):
  - For any expression e, ``parse(serialize(e)) == e`` structurally.
  - Serialization is idempotent: ``serialize(parse(serialize(e))) == serialize(e)``.
  - The full JSON round-trip ``parse(json.loads(json.dumps(serialize(e)))) == e``
    also holds (catches JSON-encoding-induced lossiness).

Scope notes:
  - Expressions generated here cover the scalar operators plus the array-op
    extensions (``aggregate``, ``makearray``, ``reshape``, ``transpose``,
    ``concat``, ``index``, ``broadcast``). The array ops were added once the
    serializer was fixed (gt-4009) to emit their auxiliary fields.
"""

from __future__ import annotations

import json
import math

import pytest

hypothesis = pytest.importorskip("hypothesis")
from hypothesis import HealthCheck, given, settings, strategies as st

from earthsci_ast.esm_types import ExprNode
from earthsci_ast.parse import _parse_expression
from earthsci_ast.serialize import _serialize_expression


# ---------------------------------------------------------------------------
# Atomic strategies
# ---------------------------------------------------------------------------

# Variable names: lowercase ASCII letter followed by 0-7 alphanumerics.
# We avoid leading digits / punctuation so the names don't collide with the
# numeric / operator interpretation paths.
_var_names = st.from_regex(r"\A[a-z][a-zA-Z0-9_]{0,7}\Z", fullmatch=True)

# Finite numeric literals. JSON has no representation for NaN / +-Inf, so we
# exclude them — those values would not survive a JSON round-trip anyway.
_int_literals = st.integers(min_value=-1_000_000, max_value=1_000_000)
_float_literals = st.floats(
    allow_nan=False,
    allow_infinity=False,
    width=64,
    min_value=-1e9,
    max_value=1e9,
)


def _leaf() -> st.SearchStrategy:
    """Atom for an expression tree: a number or a variable name."""
    return st.one_of(_int_literals, _float_literals, _var_names)


# ---------------------------------------------------------------------------
# Operator-shape strategies
# ---------------------------------------------------------------------------
#
# Each entry returns a strategy that produces a fully-formed ExprNode whose
# argument count matches the operator's expected arity. ``child`` is a
# strategy that yields recursively-generated child expressions.


def _op_nary(op: str, child: st.SearchStrategy, min_size: int = 2, max_size: int = 4):
    return st.lists(child, min_size=min_size, max_size=max_size).map(
        lambda args: ExprNode(op=op, args=args)
    )


def _op_unary(op: str, child: st.SearchStrategy):
    return child.map(lambda a: ExprNode(op=op, args=[a]))


def _op_binary(op: str, child: st.SearchStrategy):
    return st.tuples(child, child).map(lambda ab: ExprNode(op=op, args=list(ab)))


def _op_unary_or_binary(op: str, child: st.SearchStrategy):
    return st.one_of(_op_unary(op, child), _op_binary(op, child))


def _op_derivative(child: st.SearchStrategy):
    return st.tuples(child, _var_names).map(lambda av: ExprNode(op="D", args=[av[0]], wrt=av[1]))


def _op_grad(child: st.SearchStrategy):
    return st.tuples(child, _var_names).map(lambda av: ExprNode(op="grad", args=[av[0]], dim=av[1]))


def _op_ifelse(child: st.SearchStrategy):
    return st.tuples(child, child, child).map(lambda abc: ExprNode(op="ifelse", args=list(abc)))


# ---------------------------------------------------------------------------
# Array-op strategies (gt-4009).
# ---------------------------------------------------------------------------
# These exercise the auxiliary fields on ExprNode (output_idx, expr, reduce,
# ranges, regions, values, shape, perm, axis, fn) that the serializer must
# emit and the parser must read back. We don't try to generate semantically
# valid array programs — we just need syntactic shapes that survive the
# serialize/parse round-trip.

_index_names = st.from_regex(r"\A[a-z]\Z", fullmatch=True)
_small_int = st.integers(min_value=0, max_value=8)
_shape_entry = st.one_of(st.integers(min_value=1, max_value=16), _var_names)


def _op_reshape(child: st.SearchStrategy):
    shape_strategy = st.lists(_shape_entry, min_size=1, max_size=4)
    return st.tuples(child, shape_strategy).map(
        lambda cs: ExprNode(op="reshape", args=[cs[0]], shape=cs[1])
    )


def _op_transpose(child: st.SearchStrategy):
    # perm is optional on transpose; cover both the with-perm and without-perm
    # shapes because the serializer and parser handle them separately.
    perm_strategy = st.lists(_small_int, min_size=1, max_size=4, unique=True)
    with_perm = st.tuples(child, perm_strategy).map(
        lambda cp: ExprNode(op="transpose", args=[cp[0]], perm=cp[1])
    )
    without_perm = child.map(lambda a: ExprNode(op="transpose", args=[a]))
    return st.one_of(with_perm, without_perm)


def _op_concat(child: st.SearchStrategy):
    # axis is required on concat and may be 0 — a falsy value that an
    # ``if expr.axis:`` check would incorrectly drop. Include 0 explicitly.
    return st.tuples(
        st.lists(child, min_size=2, max_size=3),
        st.integers(min_value=0, max_value=3),
    ).map(lambda ca: ExprNode(op="concat", args=ca[0], axis=ca[1]))


def _op_broadcast(child: st.SearchStrategy):
    fn_strategy = st.sampled_from(["+", "-", "*", "/", "max", "min"])
    return st.tuples(
        st.lists(child, min_size=1, max_size=3),
        fn_strategy,
    ).map(lambda cf: ExprNode(op="broadcast", args=cf[0], fn=cf[1]))


def _op_index(child: st.SearchStrategy):
    # The 'index' op has no required auxiliary fields in the schema; treat it
    # as a plain n-ary op over its args.
    return st.lists(child, min_size=1, max_size=3).map(lambda args: ExprNode(op="index", args=args))


def _op_aggregate(child: st.SearchStrategy):
    output_idx_strategy = st.lists(st.one_of(_index_names, st.just(1)), min_size=1, max_size=3)
    reduce_strategy = st.sampled_from(["+", "*", "max", "min"])
    range_strategy = st.one_of(
        st.lists(_small_int, min_size=2, max_size=2),
        st.lists(_small_int, min_size=3, max_size=3),
    )
    ranges_strategy = st.dictionaries(_index_names, range_strategy, max_size=3)

    @st.composite
    def build(draw):
        args = draw(st.lists(child, min_size=1, max_size=2))
        output_idx = draw(output_idx_strategy)
        body = draw(child)
        include_reduce = draw(st.booleans())
        include_ranges = draw(st.booleans())
        return ExprNode(
            op="aggregate",
            args=args,
            output_idx=output_idx,
            expr=body,
            reduce=draw(reduce_strategy) if include_reduce else None,
            ranges=draw(ranges_strategy) if include_ranges else None,
        )

    return build()


def _op_makearray(child: st.SearchStrategy):
    region_strategy = st.lists(
        st.lists(_small_int, min_size=2, max_size=2),
        min_size=1,
        max_size=3,
    )

    @st.composite
    def build(draw):
        n = draw(st.integers(min_value=1, max_value=3))
        regions = [draw(region_strategy) for _ in range(n)]
        values = [draw(child) for _ in range(n)]
        return ExprNode(op="makearray", args=[], regions=regions, values=values)

    return build()


def _node_strategy(child: st.SearchStrategy) -> st.SearchStrategy:
    """All ExprNode shapes that the parse/serialize round-trip must support."""
    return st.one_of(
        # n-ary arithmetic
        _op_nary("+", child),
        _op_nary("*", child),
        # subtraction supports both unary (negate) and binary forms
        _op_unary_or_binary("-", child),
        _op_binary("/", child),
        _op_binary("^", child),
        # transcendentals (single argument)
        _op_unary("log", child),
        _op_unary("exp", child),
        _op_unary("sin", child),
        _op_unary("cos", child),
        _op_unary("tan", child),
        _op_unary("asin", child),
        _op_unary("acos", child),
        _op_unary("atan", child),
        _op_binary("atan2", child),
        # misc scalar
        _op_unary("abs", child),
        _op_unary("sign", child),
        _op_unary("sqrt", child),
        _op_unary("log10", child),
        _op_unary("floor", child),
        _op_unary("ceil", child),
        _op_nary("min", child, min_size=1, max_size=4),
        _op_nary("max", child, min_size=1, max_size=4),
        # logical
        _op_nary("and", child, min_size=2, max_size=4),
        _op_nary("or", child, min_size=2, max_size=4),
        _op_unary("not", child),
        # control flow
        _op_ifelse(child),
        # operator nodes that carry auxiliary scalar fields
        _op_derivative(child),
        _op_grad(child),
        # array-op extensions (gt-4009)
        _op_reshape(child),
        _op_transpose(child),
        _op_concat(child),
        _op_broadcast(child),
        _op_index(child),
        _op_aggregate(child),
        _op_makearray(child),
    )


_expr_strategy = st.recursive(
    _leaf(),
    _node_strategy,
    max_leaves=6,
)


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------


# 50 examples per property keeps the file under ~30s. Hypothesis's database
# accumulates failing cases across runs, so coverage grows with use even at
# this budget. Bump locally with ``--hypothesis-seed`` or PYTEST flags when
# investigating a specific class of input.
_settings = settings(
    max_examples=50,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)


def _serialized_equal(a, b) -> bool:
    """Compare serialized expressions through JSON to normalize numeric forms."""
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


@given(_expr_strategy)
@_settings
def test_parse_serialize_round_trip_in_memory(expr):
    """For any generated expression e, ``parse(serialize(e)) == e``."""
    serialized = _serialize_expression(expr)
    parsed = _parse_expression(serialized)
    assert parsed == expr


@given(_expr_strategy)
@_settings
def test_serialize_idempotent(expr):
    """``serialize(parse(serialize(e))) == serialize(e)`` (JSON-equal)."""
    once = _serialize_expression(expr)
    twice = _serialize_expression(_parse_expression(once))
    assert _serialized_equal(once, twice)


@given(_expr_strategy)
@_settings
def test_round_trip_through_json(expr):
    """The full JSON round-trip preserves the expression structurally."""
    payload = json.dumps(_serialize_expression(expr))
    reparsed = _parse_expression(json.loads(payload))
    # JSON has no integer/float distinction for whole-valued floats, so we
    # compare via the canonical serialized form rather than ``==`` directly.
    assert _serialized_equal(
        _serialize_expression(reparsed),
        _serialize_expression(expr),
    )


# ---------------------------------------------------------------------------
# Targeted edge-case regressions found by the strategies above
# ---------------------------------------------------------------------------


def test_round_trip_serializes_negative_zero_as_integer_zero():
    """Canonical number contract (CONFORMANCE_SPEC §5.5.3.1): ``-0.0`` is an
    integral value, so it normalizes to the integer literal ``0`` on serialize —
    sign and float-ness are both dropped (`-0.0` -> `0.0` -> `0`). This matches
    the other bindings byte-for-byte; a binding that preserved the negative-zero
    sign was the divergence."""
    expr = ExprNode(op="+", args=[-0.0, 0.0])
    serialized = _serialize_expression(expr)
    assert serialized["args"] == [0, 0]
    assert all(type(a) is int for a in serialized["args"])


def test_round_trip_preserves_unary_minus():
    """Subtraction with a single argument must remain unary after a round-trip."""
    expr = ExprNode(op="-", args=["x"])
    parsed = _parse_expression(_serialize_expression(expr))
    assert parsed == expr
    assert len(parsed.args) == 1
