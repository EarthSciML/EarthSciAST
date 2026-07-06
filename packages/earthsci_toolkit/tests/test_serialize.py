"""Tests for the serialize module."""

import json
import tempfile
import os

from earthsci_toolkit import save
from earthsci_toolkit.serialize import _serialize_expression
from earthsci_toolkit.esm_types import (
    EsmFile,
    Metadata,
    Model,
    ModelVariable,
    Equation,
    ExprNode,
    ReactionSystem,
    Species,
    Parameter,
    Reaction,
)


def test_serialize_simple_expression():
    """Test serialization of simple expressions."""
    # Test primitives
    assert _serialize_expression(42) == 42
    assert _serialize_expression(3.14) == 3.14
    assert _serialize_expression("x") == "x"

    # Test expression node
    expr = ExprNode(op="+", args=[1, 2])
    result = _serialize_expression(expr)
    expected = {"op": "+", "args": [1, 2]}
    assert result == expected


def test_serialize_nested_expression():
    """Test serialization of nested expressions."""
    # Create (x + 1) * 2
    inner_expr = ExprNode(op="+", args=["x", 1])
    outer_expr = ExprNode(op="*", args=[inner_expr, 2])

    result = _serialize_expression(outer_expr)
    expected = {"op": "*", "args": [{"op": "+", "args": ["x", 1]}, 2]}
    assert result == expected


def test_serialize_expression_with_metadata():
    """Test serialization of expressions with wrt and dim."""
    expr = ExprNode(op="D", args=["x"], wrt="t")
    result = _serialize_expression(expr)
    expected = {"op": "D", "args": ["x"], "wrt": "t"}
    assert result == expected

    expr_with_dim = ExprNode(op="grad", args=["T"], dim="x")
    result = _serialize_expression(expr_with_dim)
    expected = {"op": "grad", "args": ["T"], "dim": "x"}
    assert result == expected


def test_save_minimal_esm():
    """Test saving a minimal ESM file."""
    metadata = Metadata(title="Test Model")
    variable = ModelVariable(type="state", units="kg")
    equation = Equation(lhs="x", rhs=1)
    model = Model(name="test_model", variables={"x": variable}, equations=[equation])

    esm_file = EsmFile(version="0.1.0", metadata=metadata, models={"test_model": model})

    json_str = save(esm_file)

    # Parse back to verify
    data = json.loads(json_str)
    assert data["esm"] == "0.1.0"
    assert data["metadata"]["name"] == "Test Model"
    assert "test_model" in data["models"]

    model_data = data["models"]["test_model"]
    assert "x" in model_data["variables"]
    assert model_data["variables"]["x"]["type"] == "state"
    assert model_data["variables"]["x"]["units"] == "kg"


def test_save_reaction_system():
    """Test saving an ESM file with reaction system."""
    metadata = Metadata(title="Reaction Test")

    # Create species
    species_a = Species(name="A", units="mol")
    species_b = Species(name="B", units="mol")
    species_c = Species(name="C", units="mol")

    # Create parameter
    param_k1 = Parameter(name="k1", value=0.1, units="1/s")

    # Create reaction A + B -> C
    reaction = Reaction(
        name="R1", reactants={"A": 1.0, "B": 1.0}, products={"C": 1.0}, rate_constant="k1"
    )

    # Create reaction system
    rs = ReactionSystem(
        name="test_reactions",
        species=[species_a, species_b, species_c],
        parameters=[param_k1],
        reactions=[reaction],
    )

    esm_file = EsmFile(version="0.1.0", metadata=metadata, reaction_systems={"test_reactions": rs})

    json_str = save(esm_file)

    # Parse back to verify
    data = json.loads(json_str)
    assert "test_reactions" in data["reaction_systems"]

    rs_data = data["reaction_systems"]["test_reactions"]

    # Check species
    assert "A" in rs_data["species"]
    assert "B" in rs_data["species"]
    assert "C" in rs_data["species"]
    assert rs_data["species"]["A"]["units"] == "mol"

    # Check parameters
    assert "k1" in rs_data["parameters"]
    assert rs_data["parameters"]["k1"]["units"] == "1/s"
    assert rs_data["parameters"]["k1"]["default"] == 0.1

    # Check reactions
    assert len(rs_data["reactions"]) == 1
    reaction_data = rs_data["reactions"][0]
    assert reaction_data["name"] == "R1"
    assert len(reaction_data["substrates"]) == 2
    assert len(reaction_data["products"]) == 1


def test_save_to_file():
    """Test saving ESM file to disk."""
    metadata = Metadata(title="File Test")
    esm_file = EsmFile(version="0.1.0", metadata=metadata)

    # Use temporary file
    with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".json") as tmp_file:
        tmp_path = tmp_file.name

    try:
        # Save to file
        json_str = save(esm_file, tmp_path)

        # Verify file exists and has content
        assert os.path.exists(tmp_path)

        with open(tmp_path, "r") as f:
            file_content = f.read()

        assert file_content == json_str

        # Parse back from file to verify
        data = json.loads(file_content)
        assert data["esm"] == "0.1.0"
        assert data["metadata"]["name"] == "File Test"

    finally:
        # Clean up
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
