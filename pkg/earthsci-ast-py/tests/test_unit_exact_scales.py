"""Exact unit scales and scale agreement (esm-spec §4.8.1, §4.8.3).

A scale agreement -- `m + km`, `m/s = mi/h` -- is decided on an EXACT scale, not
on pint's float conversion factor, and the operands of `+`, the two sides of an
equation, and an observed variable against its declared units must agree in scale
as well as dimension.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from earthsci_ast import load_path, validate
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.units import (
    _CONTRACT_SYMBOLS,
    PINT_AVAILABLE,
    DimensionalMismatchError,
    UnitValidator,
    parse_unit,
    unit_exact_scale,
    ureg,
)

pytestmark = pytest.mark.skipif(not PINT_AVAILABLE, reason="pint not installed")

_TESTS = Path(__file__).resolve().parents[3] / "tests"


@pytest.mark.parametrize("symbol", sorted(_CONTRACT_SYMBOLS))
def test_every_registry_symbol_has_a_matching_exact_scale(symbol):
    # A symbol missing from the exact table would silently read as 1 and fail here.
    unit = parse_unit(symbol)
    expected = float(ureg.Quantity(1.0, unit).to_base_units().magnitude)
    assert float(unit_exact_scale(symbol)) == pytest.approx(expected, rel=1e-12)


@pytest.mark.parametrize(
    ("symbol", "exact"),
    [
        ("Torr", "20265/152"),
        ("psi", "8896443230521/1290320000"),
        ("degF", "5/9"),
        ("deg", "1/180*pi"),
        ("mi", "201168/125"),
        ("hp", "37284993579113511/50000000000000"),
        ("DU", "268670000000000000000"),
    ],
)
def test_reconciled_registry_scales_are_exact(symbol, exact):
    assert unit_exact_scale(symbol).ratio_string() == exact


def _validator(units: dict[str, str]) -> UnitValidator:
    v = UnitValidator()
    v.known_units = {name: parse_unit(u) for name, u in units.items()}
    return v


def test_adding_metres_to_kilometres_is_a_scale_mismatch():
    v = _validator({"x": "m", "y": "km", "z": "m"})
    with pytest.raises(DimensionalMismatchError, match="scale"):
        v._type(ExprNode(op="+", args=["x", "y"]))
    assert v._type(ExprNode(op="+", args=["x", "z"])) is not None


def test_an_equation_between_m_per_s_and_mi_per_h_is_a_scale_mismatch():
    from earthsci_ast.esm_types import Equation

    v = _validator({"speed_ms": "m/s", "speed_mph": "mi/h", "ms_per_mph": "m*h/(mi*s)"})
    bare = v.validate_equation(Equation(lhs="speed_ms", rhs="speed_mph"), "eq_0")
    assert not bare.is_valid
    converted = v.validate_equation(
        Equation(lhs="speed_ms", rhs=ExprNode(op="*", args=["speed_mph", "ms_per_mph"])),
        "eq_1",
    )
    assert converted.is_valid, converted.errors


@pytest.mark.parametrize(
    ("fixture", "path"),
    [
        ("invalid/units_scale_mismatch_equation.esm", "/models/BadUnitsModel/variables/speed_ms"),
        (
            "invalid/units_scale_mismatch_addition.esm",
            "/models/BadUnitsModel/variables/total_length",
        ),
    ],
)
def test_scale_mismatch_fixtures_are_rejected_at_the_variable(fixture, path):
    result = validate(load_path(_TESTS / fixture))
    assert not result.is_valid
    assert any(
        e.code == "unit_inconsistency" and e.path == path for e in result.structural_errors
    ), result.structural_errors


def test_scale_conversion_positive_control_is_valid():
    result = validate(load_path(_TESTS / "valid" / "units_scale_conversion.esm"))
    assert result.is_valid, result.structural_errors
