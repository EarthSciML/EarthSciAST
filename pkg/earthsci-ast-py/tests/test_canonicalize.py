"""Tests for ``canonicalize`` per discretization RFC §5.4."""

from __future__ import annotations


import pytest

from earthsci_ast.canonicalize import (
    DivByZeroError,
    NonFiniteError,
    UnsupportedFieldError,
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


def test_emissible_fields_emit():
    # The closed 7-field encoding: op/args plus wrt/dim/fn/name/value all emit.
    d = ExprNode(op="D", args=["u"], wrt="t")
    assert canonical_json(d) == '{"args":["u"],"op":"D","wrt":"t"}'
    # `fn` carries the boundary-condition kind on synthetic `bc` nodes — emitting
    # it keeps bc(u,dirichlet,x) distinct from bc(u,neumann,x) (esm-spec §9.2).
    bc = ExprNode(op="bc", args=["u"], fn="dirichlet", dim="x")
    assert canonical_json(bc) == '{"args":["u"],"dim":"x","fn":"dirichlet","op":"bc"}'
    call = ExprNode(op="call", args=["x"], name="datetime.year")
    assert canonical_json(call) == '{"args":["x"],"name":"datetime.year","op":"call"}'
    const = ExprNode(op="const", args=[], value=[1, 2.5])
    assert canonical_json(const) == '{"args":[],"op":"const","value":[1,2.5]}'


def test_fn_kind_disambiguation():
    # Regression: with only op/args emitted, dirichlet vs neumann bc nodes
    # produced byte-identical canonical JSON. `fn` keeps them distinct.
    dirichlet = canonical_json(ExprNode(op="bc", args=["u"], fn="dirichlet", dim="x"))
    neumann = canonical_json(ExprNode(op="bc", args=["u"], fn="neumann", dim="x"))
    assert dirichlet != neumann


def _agg(body):
    return ExprNode(op="aggregate", args=[], expr=body)


def test_non_emissible_field_fails_closed():
    # A node carrying any field outside the emissible set (aggregate body,
    # table selector, geometry id, …) has NO faithful canonical JSON — it
    # raises the pinned coded error rather than emit ambiguous bytes.
    for node in (
        _agg(ExprNode(op="x", args=[])),
        ExprNode(op="aggregate", args=[], semiring="sum_product", output_idx=[]),
        ExprNode(op="table_lookup", args=[], table="tbl", table_axes={"code": "fm"}),
        ExprNode(op="intersect_polygon", args=["a", "b"], id="prod", manifold="planar"),
        # handler_id is NOT emissible (unlike the historical full-coverage emitter).
        ExprNode(op="call", args=["x"], handler_id="h1"),
    ):
        with pytest.raises(UnsupportedFieldError) as excinfo:
            canonical_json(node)
        assert excinfo.value.code == "E_CANONICAL_UNSUPPORTED_FIELD"


def test_non_emissible_nested_in_args_fails_closed():
    # A non-emissible node nested inside an emissible node's args still fails
    # closed — the recursive check walks args.
    a1 = _agg(ExprNode(op="x", args=[]))
    with pytest.raises(UnsupportedFieldError) as excinfo:
        canonical_json(ExprNode(op="sin", args=[a1]))
    assert excinfo.value.code == "E_CANONICAL_UNSUPPORTED_FIELD"


def test_canonicalize_is_field_preserving():
    # `canonicalize` itself stays field-preserving — the fail-closed check lives
    # in `canonical_json`, not `canonicalize`.
    agg = ExprNode(op="aggregate", args=[], semiring="sum_product", table="tbl")
    c = canonicalize(agg)
    assert isinstance(c, ExprNode)
    assert c.semiring == "sum_product"
    assert c.table == "tbl"
