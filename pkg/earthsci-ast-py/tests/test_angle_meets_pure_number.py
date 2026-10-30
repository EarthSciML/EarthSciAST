"""esm-spec §4.8.3 "An angle meets a pure number": where a pure angle meets a
pure number the ``[angle]`` axis is removed and the scale kept. The rule never
makes two different angles agree with each other."""

from __future__ import annotations

import json

import pytest

from earthsci_ast import validate_text
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.structural_checks import _pure_angle_scale_is_one
from earthsci_ast.units import DimensionalMismatchError, UnitValidator, parse_unit


def _typer(**units: str) -> UnitValidator:
    v = UnitValidator()
    v.known_units = {name: parse_unit(u) for name, u in units.items()}
    return v


def _node(op: str, *args) -> ExprNode:
    return ExprNode(op=op, args=list(args))


ANGLES = {"theta": "rad", "omega": "sr", "n": "1"}


@pytest.mark.parametrize(
    "expr",
    [
        _node("+", "theta", "omega", "n"),
        _node("+", "n", "theta", "omega"),
        _node("min", "theta", "omega", "n"),
        _node("max", "n", "omega", "theta"),
    ],
    ids=["sum", "sum-number-first", "min", "max"],
)
def test_two_different_angles_disagree_beside_a_pure_number(expr):
    with pytest.raises(DimensionalMismatchError):
        _typer(**ANGLES)._type(expr)


def test_an_angle_still_cancels_against_a_pure_number():
    typed = _typer(**ANGLES)._type(_node("+", "theta", "n"))
    assert typed is not None and not typed.dim


def test_like_angles_beside_a_pure_number_cancel():
    typed = _typer(theta="rad", phi="rad", n="1")._type(_node("min", "theta", "phi", "n"))
    assert typed is not None and not typed.dim


def _doc(units: dict[str, str], equations: list[dict]) -> dict:
    variables = {
        name: (
            {"type": "parameter", "units": u, "default": 1.0}
            if name not in ("psi", "y")
            else {"type": "unknown", "units": u}
        )
        for name, u in units.items()
    }
    return {
        "esm": "1.2.0",
        "metadata": {"name": "angles"},
        "models": {"M": {"variables": variables, "equations": equations}},
    }


def test_structural_sum_pairs_every_operand():
    # `n` first: every operand agrees with `n`, but rad and sr disagree.
    doc = _doc(
        {"theta": "rad", "omega": "sr", "n": "1", "psi": "1"},
        [{"lhs": "psi", "rhs": {"op": "+", "args": ["n", "theta", "omega"]}}],
    )
    result = validate_text(json.dumps(doc))
    assert any("'rad' + 'sr'" in e.message for e in result.structural_errors)


@pytest.mark.parametrize(
    ("unit", "scale_is_one"),
    [("rad", True), ("deg", False), ("degree", False), (" deg", False), ("radians", None)],
)
def test_the_pure_angle_helper_never_raises(unit, scale_is_one):
    assert _pure_angle_scale_is_one(unit) is scale_is_one


@pytest.mark.parametrize("unit", ["degree", "degrees", " deg", "radians"])
def test_an_angle_spelling_as_exp_argument_is_a_finding_not_a_crash(unit):
    doc = _doc(
        {"x": unit, "y": "1"},
        [{"lhs": "y", "rhs": {"op": "exp", "args": ["x"]}}],
    )
    result = validate_text(json.dumps(doc))
    assert not result.is_valid


def test_an_observed_scale_mismatch_names_the_declared_angle_unit():
    doc = _doc({"theta": "deg", "psi": "1"}, [{"lhs": "psi", "rhs": "theta"}])
    result = validate_text(json.dumps(doc))
    messages = [e.message for e in result.structural_errors if e.code == "unit_inconsistency"]
    assert len(messages) == 1
    assert "deg" in messages[0]
    assert "[angle]" in messages[0]


def test_an_equation_scale_mismatch_names_the_declared_angle_unit():
    v = _typer(theta="deg", x="s", t="s")
    eq = type("Eq", (), {"lhs": ExprNode(op="D", args=["x"], wrt="t"), "rhs": "theta"})()
    result = v.validate_equation(eq, "eq_0")
    assert len(result.findings) == 1
    message = result.findings[0].message
    assert "Scale mismatch" in message
    assert "'theta' [deg]" in message
    assert "[angle]" in message
    assert result.findings[0].rhs_units == "[angle]"
