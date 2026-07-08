"""Tests for ``canonicalize`` per discretization RFC §5.4."""

from __future__ import annotations


import pytest

from earthsci_ast.canonicalize import (
    DivByZeroError,
    NonFiniteError,
    canonical_json,
    canonicalize,
    format_canonical_float,
)
from earthsci_ast.esm_types import ExprNode


def op(name, args):
    return ExprNode(op=name, args=list(args))


def test_float_format_table():
    cases = [
        (1.0, "1.0"),
        (-3.0, "-3.0"),
        (0.0, "0.0"),
        (-0.0, "-0.0"),
        (2.5, "2.5"),
        (1e25, "1e25"),
        (5e-324, "5e-324"),
        (1e-7, "1e-7"),
    ]
    for v, want in cases:
        assert format_canonical_float(v) == want, f"format({v}) -> {format_canonical_float(v)}"
    # Force runtime add (compiler can't constant-fold in Python anyway).
    assert format_canonical_float(0.1 + 0.2) == "0.30000000000000004"


def test_integer_emission():
    for v, want in [(1, "1"), (-42, "-42"), (0, "0")]:
        assert canonical_json(v) == want


def test_nonfinite_errors():
    for f in [float("nan"), float("inf"), float("-inf")]:
        with pytest.raises(NonFiniteError):
            canonicalize(f)


def test_worked_example():
    e = op(
        "+",
        [
            op("*", ["a", 0]),
            "b",
            op("+", ["a", 1]),
        ],
    )
    assert canonical_json(e) == '{"args":[1,"a","b"],"op":"+"}'


def test_flatten_basic():
    e = op("+", [op("+", ["a", "b"]), "c"])
    assert canonical_json(e) == '{"args":["a","b","c"],"op":"+"}'


def test_type_preserving_identity():
    # *(1, x) -> "x"
    assert canonical_json(op("*", [1, "x"])) == '"x"'
    # *(1.0, x) keeps the 1.0
    assert canonical_json(op("*", [1.0, "x"])) == '{"args":[1.0,"x"],"op":"*"}'


def test_zero_annihilation_type_preserve():
    assert canonical_json(op("*", [0, "x"])) == "0"
    assert canonical_json(op("*", [0.0, "x"])) == "0.0"
    assert canonical_json(op("*", [-0.0, "x"])) == "-0.0"


def test_int_float_disambiguation():
    a = op("+", [1.0, 2.5])
    b = op("+", [1, 2.5])
    ja = canonical_json(a)
    jb = canonical_json(b)
    assert ja != jb, f"distinction lost: {ja}"
    assert "1.0" in ja


def test_neg_canonical():
    assert canonical_json(op("neg", [op("neg", ["x"])])) == '"x"'
    assert canonical_json(op("neg", [5])) == "-5"
    assert canonical_json(op("-", [0, "x"])) == '{"args":["x"],"op":"neg"}'


def test_div_zero_by_zero():
    with pytest.raises(DivByZeroError):
        canonicalize(op("/", [0, 0]))
