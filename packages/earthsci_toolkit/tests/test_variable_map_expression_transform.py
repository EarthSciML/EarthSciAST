"""Tests for the ``variable_map.transform`` expression widening
(in-progress-0.8.0): a coupling ``variable_map``'s ``transform`` may be an
ExpressionNode (operator-node object) instead of one of the legacy enum
strings. The expression must reference the entry's ``from`` variable, takes no
``factor``, and flattens to an observed variable named exactly ``to`` whose
defining equation is the transform expression verbatim.
"""

import copy
import json

import jsonschema
import pytest

from earthsci_toolkit import load, save
from earthsci_toolkit.esm_types import (
    EsmFile,
    Equation,
    ExprNode,
    Metadata,
    Model,
    ModelVariable,
    VariableMapCoupling,
)
from earthsci_toolkit.flatten import FlattenError, flatten
from earthsci_toolkit.lower_expression_templates import (
    ExpressionTemplateError,
    lower_expression_templates,
)
from earthsci_toolkit.parse import _get_schema, _parse_coupling_entry


# The canonical expression transform used throughout: 2 * Src.F + Sink.offset.
TRANSFORM_AST = {
    "op": "+",
    "args": [{"op": "*", "args": [2.0, "Src.F"]}, "Sink.offset"],
}


def _doc() -> dict:
    """A minimal schema-valid two-model document coupled by an expression
    ``variable_map``: Src.F (observed, const 4.0) feeds Sink.F_in through
    ``2 * Src.F + Sink.offset``; Sink integrates d(u)/dt = F_in."""
    return {
        "esm": "0.8.0",
        "metadata": {"name": "vm_expression_transform"},
        "models": {
            "Src": {
                "variables": {
                    "F": {"type": "observed", "units": "1", "expression": 4.0},
                },
                "equations": [],
            },
            "Sink": {
                "variables": {
                    "offset": {"type": "parameter", "default": 1.5},
                    "F_in": {"type": "parameter", "units": "1"},
                    "u": {"type": "state", "default": 0.0},
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "F_in"},
                ],
            },
        },
        "coupling": [
            {
                "type": "variable_map",
                "from": "Src.F",
                "to": "Sink.F_in",
                "transform": copy.deepcopy(TRANSFORM_AST),
            }
        ],
    }


def _transform_expr() -> ExprNode:
    return ExprNode(
        op="+",
        args=[ExprNode(op="*", args=[2.0, "Src.F"]), "Sink.offset"],
    )


def _esm_file(transform) -> EsmFile:
    src = Model(
        name="Src",
        variables={"F": ModelVariable(type="observed", units="1", expression=4.0)},
    )
    sink = Model(
        name="Sink",
        variables={
            "offset": ModelVariable(type="parameter", default=1.5),
            "F_in": ModelVariable(type="parameter", units="1"),
            "u": ModelVariable(type="state", default=0.0),
        },
        equations=[
            Equation(lhs=ExprNode(op="D", args=["u"], wrt="t"), rhs="F_in"),
        ],
    )
    vm = VariableMapCoupling(
        from_var="Src.F",
        to_var="Sink.F_in",
        transform=transform,
    )
    return EsmFile(
        version="0.8.0",
        metadata=Metadata(title="vm expression transform"),
        models={"Src": src, "Sink": sink},
        coupling=[vm],
    )


# ----------------------------------------------------------------------------
# Parse / serialize round-trip
# ----------------------------------------------------------------------------


def test_parse_serialize_roundtrip_expression_transform():
    """A variable_map with an expression transform survives parse -> serialize
    with the coupling entry byte-equal at the dict level."""
    doc = _doc()
    esm_file = load(json.dumps(doc))

    coupling = esm_file.coupling[0]
    assert isinstance(coupling, VariableMapCoupling)
    assert isinstance(coupling.transform, ExprNode)
    assert coupling.transform == _transform_expr()
    assert coupling.factor is None

    reloaded = json.loads(save(esm_file))
    assert reloaded["coupling"][0] == doc["coupling"][0]

    # Second cycle stays stable (lossless round-trip).
    again = json.loads(save(load(json.dumps(reloaded))))
    assert again["coupling"][0] == doc["coupling"][0]


def test_parse_rejects_factor_with_expression_transform():
    """A `factor` alongside an expression transform is rejected at parse time."""
    entry = {
        "type": "variable_map",
        "from": "Src.F",
        "to": "Sink.F_in",
        "transform": copy.deepcopy(TRANSFORM_AST),
        "factor": 2.0,
    }
    with pytest.raises(ValueError, match="takes no 'factor'"):
        _parse_coupling_entry(entry)


def test_parse_string_transform_unchanged():
    """Legacy enum-string transforms keep parsing to plain strings."""
    entry = {
        "type": "variable_map",
        "from": "Src.F",
        "to": "Sink.F_in",
        "transform": "param_to_var",
    }
    coupling = _parse_coupling_entry(entry)
    assert coupling.transform == "param_to_var"


# ----------------------------------------------------------------------------
# Schema validation
# ----------------------------------------------------------------------------


def test_schema_accepts_object_transform():
    jsonschema.validate(_doc(), _get_schema())


def test_schema_rejects_non_enum_string_transform():
    doc = _doc()
    doc["coupling"][0]["transform"] = "not_a_legacy_transform"
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(doc, _get_schema())


def test_schema_rejects_factor_with_expression_transform():
    doc = _doc()
    doc["coupling"][0]["factor"] = 2.0
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(doc, _get_schema())


# ----------------------------------------------------------------------------
# Flatten
# ----------------------------------------------------------------------------


def test_flatten_expression_transform_promotes_target_to_observed():
    transform = _transform_expr()
    flat = flatten(_esm_file(transform))

    # The target parameter is removed (param_to_var-style promotion).
    assert "Sink.F_in" not in flat.parameters

    # It is now an observed variable carrying the removed parameter's metadata.
    assert "Sink.F_in" in flat.observed_variables
    obs = flat.observed_variables["Sink.F_in"]
    assert obs.type == "observed"
    assert obs.units == "1"

    # Its defining equation is the transform expression VERBATIM (no
    # namespacing — the references are already fully scoped).
    defining = [e for e in flat.equations if e.lhs == "Sink.F_in"]
    assert len(defining) == 1
    assert defining[0].rhs == transform

    # The consumer ODE still references Sink.F_in (no substitution).
    u_eqs = [
        e
        for e in flat.equations
        if isinstance(e.lhs, ExprNode) and e.lhs.op == "D" and e.lhs.args == ["Sink.u"]
    ]
    assert len(u_eqs) == 1
    assert u_eqs[0].rhs == "Sink.F_in"


def test_flatten_expression_transform_not_referencing_from_var_raises():
    # 3 * Sink.offset never mentions Src.F.
    transform = ExprNode(op="*", args=[3.0, "Sink.offset"])
    with pytest.raises(FlattenError, match="does not reference"):
        flatten(_esm_file(transform))


# ----------------------------------------------------------------------------
# Template expansion in coupling transforms
# ----------------------------------------------------------------------------


def _template_doc() -> dict:
    doc = _doc()
    doc["models"]["Sink"]["expression_templates"] = {
        "double_plus": {
            "params": ["x", "off"],
            "body": {
                "op": "+",
                "args": [{"op": "*", "args": [2.0, "x"]}, "off"],
            },
        }
    }
    doc["coupling"] = [
        {
            "type": "variable_map",
            "from": "Src.F",
            "to": "Sink.F_in",
            "transform": {
                "op": "apply_expression_template",
                "name": "double_plus",
                "args": [],
                "bindings": {"x": "Src.F", "off": "Sink.offset"},
            },
        }
    ]
    return doc


def test_coupling_transform_expands_with_receiving_component_templates():
    out = lower_expression_templates(_template_doc())
    assert out["coupling"][0]["transform"] == TRANSFORM_AST
    assert "expression_templates" not in out["models"]["Sink"]


def test_coupling_transform_template_expansion_through_load():
    esm_file = load(json.dumps(_template_doc()))
    coupling = esm_file.coupling[0]
    assert isinstance(coupling, VariableMapCoupling)
    assert coupling.transform == _transform_expr()


def test_coupling_transform_apply_without_receiving_templates_is_leftover():
    """A transform apply node whose receiving component lacks templates is left
    unrewritten and caught by the existing leftover-apply diagnostic."""
    doc = _template_doc()
    # Point the entry at a component that does not exist.
    doc["coupling"][0]["to"] = "Nowhere.F_in"
    with pytest.raises(ExpressionTemplateError) as excinfo:
        lower_expression_templates(doc)
    assert excinfo.value.code == "apply_expression_template_unknown_template"


# ----------------------------------------------------------------------------
# End-to-end simulation
# ----------------------------------------------------------------------------


def test_simulate_expression_transform_end_to_end():
    """d(u)/dt = F_in with F_in = 2*Src.F + Sink.offset = 2*4 + 1.5 = 9.5,
    so u(1) = 9.5 from u(0) = 0."""
    pytest.importorskip("scipy")
    import numpy as np
    from earthsci_toolkit.simulation import simulate

    esm_file = load(json.dumps(_doc()))
    result = simulate(
        esm_file,
        tspan=(0.0, 1.0),
        parameters={},
        initial_conditions={"u": 0.0},
    )
    assert result.success, f"simulate() failed: {result.message}"
    u_idx = result.vars.index("Sink.u")
    assert np.isclose(result.y[u_idx, -1], 9.5, rtol=1e-6)
