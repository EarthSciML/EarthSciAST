"""Unit checking across mount edges, inside an faq filter, and through constant
exponents (esm-spec §4.8.3, §4.8.4; EarthSciAST#414).
"""

from __future__ import annotations

from fractions import Fraction
from pathlib import Path

import pytest

from earthsci_ast import validate_path
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.units import (
    PINT_AVAILABLE,
    DimensionalMismatchError,
    UnitValidator,
    constant_exponent_value,
    parse_unit,
    unit_exact_scale,
)

pytestmark = pytest.mark.skipif(not PINT_AVAILABLE, reason="pint not installed")

REPO = Path(__file__).resolve().parents[3]


def _validator(units: dict[str, str]) -> UnitValidator:
    v = UnitValidator()
    v.known_units = {name: parse_unit(u) for name, u in units.items()}
    return v


def _const(value, units=None) -> ExprNode:
    return ExprNode(op="const", args=[], value=value, units=units)


def _op(op, *args) -> ExprNode:
    return ExprNode(op=op, args=list(args))


@pytest.mark.parametrize(
    "expr, expected",
    [
        (2, Fraction(2)),
        (0.5, Fraction(1, 2)),
        (_op("/", 3, 2), Fraction(3, 2)),
        (_op("-", 1), Fraction(-1)),
        (_op("-", 5, 3), Fraction(2)),
        (_op("/", _op("+", 1, 2), _op("*", 4, 2)), Fraction(3, 8)),
        (_const(1.5), Fraction(3, 2)),
        (_const(0.5, "1"), Fraction(1, 2)),
        (_op("-", _const(2, "dimensionless")), Fraction(-2)),
    ],
)
def test_constant_exponents_fold(expr, expected):
    assert constant_exponent_value(expr) == expected


@pytest.mark.parametrize(
    "expr",
    [
        "n",
        _op("+", "n", 1),
        _const(50.0, "%"),
        _const(2.0, "m"),
        _op("/", 1, 0),
        _op("/", 1, 2, 3),
        _op("sqrt", 4),
        True,
    ],
)
def test_symbolic_exponents_do_not_fold(expr):
    assert constant_exponent_value(expr) is None


def test_a_folded_exponent_raises_dimension_and_scale():
    v = _validator({"L": "km"})
    typed = v._type(_op("^", "L", _op("/", 3, 2)))
    assert typed is not None
    assert typed.dim == parse_unit("km^(3/2)").dimensionality
    assert typed.scale == unit_exact_scale("km^(3/2)")


def test_a_symbolic_exponent_stays_undeterminable():
    v = _validator({"L": "m", "n": "1"})
    assert v._type(_op("^", "L", "n")) is None
    assert v._type(_op("^", "L", _op("+", "n", 1))) is None
    assert v._type(_op("^", "L", _const(50.0, "%"))) is None


def test_an_faq_filter_is_walked():
    v = _validator({"x": "m", "z": "kg"})
    node = ExprNode(
        op="faq",
        args=[],
        filter=_op("<=", "x", "z"),
        expr=_const(1.0, "1"),
    )
    with pytest.raises(DimensionalMismatchError):
        v._type(node)


def test_an_faq_body_is_walked_and_has_its_body_unit():
    v = _validator({"x": "m", "y": "m", "z": "kg"})
    bad = ExprNode(op="faq", args=[], expr=_op("+", "x", "z"))
    with pytest.raises(DimensionalMismatchError):
        v._type(bad)
    ok = ExprNode(op="faq", args=[], filter=_op("<=", "x", "y"), expr="x")
    assert v._type(ok).dim == parse_unit("m").dimensionality


def _faq(body, **kw) -> ExprNode:
    return ExprNode(op="faq", args=[], expr=body, **kw)


def test_array_operators_carry_their_element_unit():
    v = _validator({"v": "h", "w": "1", "a": "m", "b": "kg"})
    h = parse_unit("h").dimensionality
    idx = _op("index", "v", "i")
    assert v._type(idx).dim == h
    assert v._type(ExprNode(op="index", args=[])) is None
    for kw in (
        {"semiring": "sum_product"},
        {"semiring": "max_product"},
        {"semiring": "min_sum"},
        {"reduce": "max"},
        {},
    ):
        assert v._type(_faq(idx, **kw)).dim == h, kw
    assert v._type(_faq(idx, reduce="*")) is None
    assert v._type(_faq(_op("index", "w", "i"), reduce="*")).scale.is_one()
    assert v._type(_faq(idx, semiring="bool_and_or")).dim == parse_unit("1").dimensionality
    assert v._type(_faq(idx, distinct=True)) is None
    assert v._type(ExprNode(op="faq", args=[])) is None
    mk = lambda *vals: ExprNode(op="makearray", args=[], values=list(vals))  # noqa: E731
    assert v._type(mk("v", 0.0)).dim == h
    assert v._type(mk()) is None
    with pytest.raises(DimensionalMismatchError):
        v._type(mk("a", "b"))
    with pytest.raises(DimensionalMismatchError):
        v._type(_op("concat", "a", "b"))
    assert (
        v._type(ExprNode(op="reshape", args=["a"], shape=[1])).dim == parse_unit("m").dimensionality
    )
    assert v._type(_op("transpose", "a")).dim == parse_unit("m").dimensionality
    assert (
        v._type(ExprNode(op="broadcast", args=["a", "a"], fn="*")).dim
        == parse_unit("m^2").dimensionality
    )
    with pytest.raises(DimensionalMismatchError):
        v._type(ExprNode(op="broadcast", args=["a", "b"], fn="+"))


VALID = [
    "units_array_mount_leaf.esm",
    "units_array_mount_index_faq_consistent.esm",
    "units_array_operators_consistent.esm",
    "makearray_empty_region_min_extent.esm",
    "units_mount_leaf.esm",
    "units_mount_subsystem_consistent.esm",
    "units_mount_toplevel_consistent.esm",
    "units_faq_filter_consistent.esm",
    "units_constant_exponent_folding.esm",
    "units_symbolic_exponent_undeterminable.esm",
]

INVALID = {
    "units_array_index_filter_mismatch.esm": ["/models/Probe/variables/p_count"],
    "units_array_mount_index_faq_mismatch.esm": ["/models/Mount/variables/total"],
    "units_array_concat_mismatch.esm": ["/models/Probe/variables/joined"],
    "units_array_makearray_mismatch.esm": ["/models/Probe/variables/mixed"],
    "units_array_reshape_mismatch.esm": ["/models/Probe/variables/out"],
    "units_array_transpose_mismatch.esm": ["/models/Probe/variables/out"],
    "units_array_broadcast_mismatch.esm": ["/models/Probe/variables/out"],
    "units_mount_subsystem_wrong_dimension.esm": ["/models/Probe/variables/probe"],
    "units_mount_subsystem_scale_mismatch.esm": ["/models/Probe/variables/probe"],
    "units_mount_toplevel_wrong_dimension.esm": ["/models/Probe/variables/probe"],
    "units_mount_toplevel_scale_mismatch.esm": ["/models/Probe/variables/probe"],
    "units_faq_filter_mismatch.esm": ["/models/Probe/variables/n_short"],
    "units_faq_body_mismatch.esm": ["/models/Probe/variables/total"],
    "units_constant_exponent_mismatch.esm": [
        "/models/Powers/variables/T_32",
        "/models/Powers/variables/L_const",
    ],
}


@pytest.mark.parametrize("name", VALID)
def test_valid_fixture(name):
    result = validate_path(str(REPO / "tests" / "valid" / name))
    assert result.is_valid, [(e.code, e.path, e.message) for e in result.structural_errors]


@pytest.mark.parametrize("name, paths", sorted(INVALID.items()))
def test_invalid_fixture(name, paths):
    result = validate_path(str(REPO / "tests" / "invalid" / name))
    assert not result.is_valid
    found = {(e.code, e.path) for e in result.structural_errors}
    for path in paths:
        assert ("unit_inconsistency", path) in found, found
