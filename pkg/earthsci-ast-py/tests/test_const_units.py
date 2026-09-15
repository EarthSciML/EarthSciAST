"""Declared units on a ``const`` node (esm-spec §4.8.5).

A ``const`` that declares its units has that unit, a ``const`` without units
stays undeterminable, an unresolvable declared unit is listed for the structural
layer, the field survives parse and emit, and it is gated at esm 1.2.0.
"""

from __future__ import annotations

import json

import pytest

import earthsci_ast
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.units import (
    PINT_AVAILABLE,
    ConstUnitsError,
    UnitValidator,
    parse_unit,
    reject_const_units_pre_v12,
    unit_exact_scale,
    unresolvable_const_units,
)

pytestmark = pytest.mark.skipif(not PINT_AVAILABLE, reason="pint not installed")


def _validator(units: dict[str, str]) -> UnitValidator:
    v = UnitValidator()
    v.known_units = {name: parse_unit(u) for name, u in units.items()}
    return v


def _konst(units: str | None) -> ExprNode:
    return ExprNode(op="const", args=[], value=0.44704, units=units)


def test_a_const_with_declared_units_has_that_unit():
    v = _validator({"speed_mph": "mi/h"})
    typed = v._type(ExprNode(op="*", args=["speed_mph", _konst("m*h/(mi*s)")]))
    assert typed is not None
    assert typed.scale == unit_exact_scale("m/s")


def test_a_const_without_units_stays_undeterminable():
    v = _validator({"speed_mph": "mi/h"})
    assert v._type(ExprNode(op="*", args=["speed_mph", _konst(None)])) is None


def test_unresolvable_const_units_are_listed():
    raw = {
        "op": "*",
        "args": ["speed_mph", {"op": "const", "args": [], "value": 1.0, "units": "mph"}],
    }
    assert unresolvable_const_units(raw) == ["mph"]
    raw["args"][1]["units"] = "m*h/(mi*s)"
    assert unresolvable_const_units(raw) == []


def test_unresolvable_const_units_in_a_called_template_body_are_reported():
    """A call has the unit of its expansion (esm-spec §4.8.5 item 5), so an
    unresolvable declared unit in the called body is ``unit_parse_error`` at the
    calling equation's field, as the other four bindings report it."""
    doc = {
        "esm": "1.2.0",
        "metadata": {"name": "ConstUnits", "description": "probe"},
        "models": {
            "M": {
                "expression_templates": {
                    "to_ms": {
                        "params": ["x"],
                        "body": {
                            "op": "*",
                            "args": [
                                "x",
                                {"op": "const", "args": [], "value": 1.0, "units": "mph"},
                            ],
                        },
                    }
                },
                "variables": {
                    "speed_mph": {"type": "parameter", "units": "mi/h", "default": 30.0},
                    "speed_ms": {"type": "unknown", "units": "m/s"},
                },
                "equations": [
                    {
                        "lhs": "speed_ms",
                        "rhs": {
                            "op": "apply_expression_template",
                            "args": [],
                            "name": "to_ms",
                            "bindings": {"x": "speed_mph"},
                        },
                    }
                ],
            }
        },
    }
    with pytest.raises(earthsci_ast.SchemaValidationError) as excinfo:
        earthsci_ast.load_string(json.dumps(doc))
    records = getattr(excinfo.value, "records", [])
    assert any(
        r.get("code") == "unit_parse_error" and r.get("path") == "/models/M/equations/0/rhs"
        for r in records
    ), records


def _doc(esm: str) -> dict:
    return {
        "esm": esm,
        "metadata": {"name": "ConstUnits", "description": "probe"},
        "models": {
            "M": {
                "variables": {
                    "speed_mph": {"type": "parameter", "units": "mi/h", "default": 30.0},
                    "speed_ms": {"type": "unknown", "units": "m/s"},
                },
                "equations": [
                    {
                        "lhs": "speed_ms",
                        "rhs": {
                            "op": "*",
                            "args": [
                                "speed_mph",
                                {
                                    "op": "const",
                                    "args": [],
                                    "value": 0.44704,
                                    "units": "m*h/(mi*s)",
                                },
                            ],
                        },
                    }
                ],
            }
        },
    }


def test_const_units_are_gated_at_esm_1_2_0():
    with pytest.raises(ConstUnitsError, match=r"/models/M/equations/0/rhs"):
        reject_const_units_pre_v12(_doc("1.1.0"))
    reject_const_units_pre_v12(_doc("1.2.0"))


def test_const_units_survive_parse_and_emit():
    doc = earthsci_ast.load_string(json.dumps(_doc("1.2.0")))
    assert "m*h/(mi*s)" in json.dumps(json.loads(earthsci_ast.to_json(doc)))
