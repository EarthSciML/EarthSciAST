"""Tests for the parse module."""

import json
import pytest

from earthsci_ast import load
from earthsci_ast.parse import _parse_expression, SchemaValidationError
from earthsci_ast.esm_types import ExprNode, EsmFile


def test_load_invalid_json():
    """Test that invalid JSON raises JSONDecodeError."""
    invalid_json = '{"invalid": json,}'
    with pytest.raises(json.JSONDecodeError):
        load(invalid_json)


def test_load_invalid_schema():
    """Test that JSON not matching schema raises SchemaValidationError."""
    invalid_esm = '{"invalid": "schema"}'
    with pytest.raises(SchemaValidationError):
        load(invalid_esm)


def test_parse_simple_expression():
    """Test parsing of simple expressions."""
    # Test number
    assert _parse_expression(42) == 42
    assert _parse_expression(3.14) == 3.14

    # Test string
    assert _parse_expression("x") == "x"

    # Test expression node
    expr_data = {"op": "+", "args": [1, 2]}
    expr = _parse_expression(expr_data)
    assert isinstance(expr, ExprNode)
    assert expr.op == "+"
    assert expr.args == [1, 2]


def test_parse_nested_expression():
    """Test parsing of nested expressions."""
    expr_data = {"op": "*", "args": [{"op": "+", "args": ["x", 1]}, 2]}
    expr = _parse_expression(expr_data)
    assert isinstance(expr, ExprNode)
    assert expr.op == "*"
    assert len(expr.args) == 2
    assert expr.args[1] == 2

    nested_expr = expr.args[0]
    assert isinstance(nested_expr, ExprNode)
    assert nested_expr.op == "+"
    assert nested_expr.args == ["x", 1]


def test_load_minimal_valid_esm():
    """Test loading a minimal valid ESM file."""
    minimal_esm = {
        "esm": "0.1.0",
        "metadata": {"name": "Test Model"},
        "models": {
            "test_model": {
                "variables": {"x": {"type": "state"}},
                "equations": [{"lhs": "x", "rhs": 1}],
            }
        },
    }

    json_str = json.dumps(minimal_esm)
    esm_file = load(json_str)

    assert isinstance(esm_file, EsmFile)
    assert esm_file.version == "0.1.0"
    assert esm_file.metadata.title == "Test Model"
    assert len(esm_file.models) == 1

    model = esm_file.models["test_model"]
    assert model.name == "test_model"
    assert len(model.variables) == 1
    assert "x" in model.variables
    assert model.variables["x"].type == "state"
    assert len(model.equations) == 1


def test_load_reaction_system():
    """Test loading an ESM file with reaction system."""
    rs_esm = {
        "esm": "0.1.0",
        "metadata": {"name": "Reaction Test"},
        "reaction_systems": {
            "test_reactions": {
                "species": {"A": {"units": "mol"}, "B": {"units": "mol"}, "C": {"units": "mol"}},
                "parameters": {"k1": {"units": "1/(mol*s)", "default": 0.1}},
                "reactions": [
                    {
                        "id": "R1",
                        "name": "A + B -> C",
                        "substrates": [
                            {"species": "A", "stoichiometry": 1},
                            {"species": "B", "stoichiometry": 1},
                        ],
                        "products": [{"species": "C", "stoichiometry": 1}],
                        "rate": "k1",
                    }
                ],
            }
        },
    }

    json_str = json.dumps(rs_esm)
    esm_file = load(json_str)

    assert len(esm_file.reaction_systems) == 1
    rs = esm_file.reaction_systems["test_reactions"]
    assert rs.name == "test_reactions"

    # Check species
    assert len(rs.species) == 3
    species_names = [sp.name for sp in rs.species]
    assert "A" in species_names
    assert "B" in species_names
    assert "C" in species_names

    # Check parameters
    assert len(rs.parameters) == 1
    param = rs.parameters[0]
    assert param.name == "k1"
    assert param.units == "1/(mol*s)"
    assert param.value == 0.1

    # Check reactions
    assert len(rs.reactions) == 1
    reaction = rs.reactions[0]
    assert reaction.name == "A + B -> C"
    assert reaction.reactants == {"A": 1.0, "B": 1.0}
    assert reaction.products == {"C": 1.0}


def test_expression_with_metadata():
    """Test parsing expressions with wrt and dim metadata."""
    expr_data = {"op": "D", "args": ["x"], "wrt": "t"}
    expr = _parse_expression(expr_data)
    assert isinstance(expr, ExprNode)
    assert expr.op == "D"
    assert expr.args == ["x"]
    assert expr.wrt == "t"
    assert expr.dim is None

    expr_data_with_dim = {"op": "grad", "args": ["T"], "dim": "x"}
    expr = _parse_expression(expr_data_with_dim)
    assert expr.dim == "x"


def test_operator_field_requirements():
    """Test that operators enforce required field requirements."""
    # Test that D operator requires wrt field
    expr_data_d_no_wrt = {
        "op": "D",
        "args": ["x"],
        # Missing wrt field
    }
    with pytest.raises(ValueError, match="Operator 'D' requires 'wrt' field to be specified"):
        _parse_expression(expr_data_d_no_wrt)

    # Test that grad operator requires dim field
    expr_data_grad_no_dim = {
        "op": "grad",
        "args": ["T"],
        # Missing dim field
    }
    with pytest.raises(ValueError, match="Operator 'grad' requires 'dim' field to be specified"):
        _parse_expression(expr_data_grad_no_dim)

    # Test that other operators work without these fields
    expr_data_other = {"op": "+", "args": [1, 2]}
    expr = _parse_expression(expr_data_other)
    assert isinstance(expr, ExprNode)
    assert expr.op == "+"
    assert expr.wrt is None
    assert expr.dim is None


def test_load_comprehensive_fields():
    """Test loading ESM file with events, data_loaders, and coupling."""
    comprehensive_esm = {
        "esm": "0.1.0",
        "metadata": {"name": "Comprehensive Test"},
        "models": {
            "test_model": {
                "variables": {"x": {"type": "state"}},
                "equations": [{"lhs": "x", "rhs": 1}],
                "discrete_events": [
                    {
                        "name": "reset_event",
                        "trigger": {"type": "periodic", "interval": 100},
                        "affects": [{"lhs": "x", "rhs": 0}],
                    }
                ],
                "continuous_events": [
                    {
                        "name": "threshold_event",
                        "conditions": [{"op": ">", "args": ["x", 10]}],
                        "affects": [{"lhs": "x", "rhs": 5}],
                    }
                ],
            }
        },
        "data_loaders": {
            "weather": {
                "kind": "grid",
                "source": {"url_template": "file:///data/era5_{date:%Y%m}.nc"},
                "variables": {
                    "temperature": {
                        "file_variable": "t",
                        "units": "K",
                        "description": "Air temperature",
                    },
                    "pressure": {
                        "file_variable": "p",
                        "units": "Pa",
                        "description": "Air pressure",
                    },
                },
            }
        },
        "coupling": [
            {
                "type": "operator_compose",
                # `model1`/`model2` were declared NOWHERE in this document — the
                # only systems it defines are `test_model` and the `weather`
                # loader. A coupling entry naming a nonexistent system is now
                # caught (`undefined_system`, tests/invalid/undefined_system.esm);
                # this fixture exercises FIELD PARSING, so point it at real ones.
                "systems": ["test_model", "weather"],
                "description": "Compose two models",
            },
            {
                "type": "variable_map",
                "from": "weather.temperature",
                "to": "test_model.T",
                "transform": "param_to_var",
                "description": "Map temperature",
            },
        ],
    }

    json_str = json.dumps(comprehensive_esm)
    esm_file = load(json_str)

    # Verify all fields are parsed correctly
    assert len(esm_file.events) == 2
    assert len(esm_file.data_loaders) == 1
    assert len(esm_file.coupling) == 2

    # Check events
    event_names = {event.name for event in esm_file.events}
    assert "reset_event" in event_names
    assert "threshold_event" in event_names

    # Check data loader
    assert "weather" in esm_file.data_loaders
    data_loader = esm_file.data_loaders["weather"]
    assert data_loader.name == "weather"
    assert len(data_loader.variables) == 2
    assert "temperature" in data_loader.variables
    assert "pressure" in data_loader.variables
    assert data_loader.variables["temperature"].file_variable == "t"
    assert data_loader.variables["temperature"].units == "K"

    # Check coupling
    assert len(esm_file.coupling) == 2
