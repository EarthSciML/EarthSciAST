#!/usr/bin/env python3
"""
Test validation of rate expressions in chemical reactions.

This module tests that rate expressions are properly validated to ensure
they only reference declared parameters and species in reaction systems.
"""

import pytest
from earthsci_toolkit.esm_types import (
    EsmFile,
    Metadata,
    ReactionSystem,
    Species,
    Parameter,
    Reaction,
    ExprNode,
)
from earthsci_toolkit.validation import validate


class TestRateExpressionValidation:
    """Test validation of reaction rate expressions."""

    def create_base_reaction_system(self):
        """Create a basic reaction system with some species and parameters."""
        species_a = Species(name="A", units="mol/L")
        species_b = Species(name="B", units="mol/L")
        param_k1 = Parameter(name="k1", value=0.1, units="1/s")
        param_k2 = Parameter(name="k2", value=0.2, units="1/s")

        return [species_a, species_b], [param_k1, param_k2]

    def create_esm_file_with_reaction(self, reaction):
        """Helper to create an ESM file with a single reaction."""
        species, parameters = self.create_base_reaction_system()

        rs = ReactionSystem(
            name="test_system", species=species, parameters=parameters, reactions=[reaction]
        )

        return EsmFile(
            version="1.0",
            metadata=Metadata(title="Test", description="Rate expression validation test"),
            models={},
            reaction_systems={"test_system": rs},
            operators=[],
            coupling=[],
            events=[],
        )

    def test_simple_string_rate_constant_valid(self):
        """Test that simple string rate constants referencing declared parameters are valid."""
        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 1.0},
            products={"B": 1.0},
            rate_constant="k1",  # k1 is declared in parameters
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert result.is_valid, (
            f"Expected validation to pass, but got errors: {[e.message for e in result.structural_errors]}"
        )
        assert len(result.structural_errors) == 0

    def test_simple_string_rate_constant_undeclared(self):
        """Test that simple string rate constants referencing undeclared parameters fail validation."""
        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 1.0},
            products={"B": 1.0},
            rate_constant="k_undefined",  # k_undefined is not declared
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert not result.is_valid
        assert len(result.structural_errors) == 1
        error = result.structural_errors[0]
        assert error.code == "undeclared_parameter"
        assert "k_undefined" in error.message
        assert "not declared" in error.message.lower()

    def test_numeric_rate_constant_valid(self):
        """Test that numeric rate constants are always valid."""
        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 1.0},
            products={"B": 1.0},
            rate_constant=0.5,  # Numeric constant
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert result.is_valid
        assert len(result.structural_errors) == 0

    def test_complex_expression_all_declared_valid(self):
        """Test that complex expressions referencing only declared parameters are valid."""
        # Rate expression: k1 * k2 (both k1 and k2 are declared)
        rate_expr = ExprNode(op="*", args=["k1", "k2"])

        reaction = Reaction(
            name="test_reaction", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant=rate_expr
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert result.is_valid, (
            f"Expected validation to pass, but got errors: {[e.message for e in result.structural_errors]}"
        )
        assert len(result.structural_errors) == 0

    def test_complex_expression_with_undeclared_parameter(self):
        """Test that complex expressions with undeclared parameters fail validation."""
        # Rate expression: k1 * k_undefined (k_undefined is not declared)
        rate_expr = ExprNode(op="*", args=["k1", "k_undefined"])

        reaction = Reaction(
            name="test_reaction", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant=rate_expr
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert not result.is_valid
        assert len(result.structural_errors) == 1
        error = result.structural_errors[0]
        assert error.code == "undeclared_rate_variable"
        assert "k_undefined" in error.message
        assert "undeclared variable" in error.message.lower()

    def test_nested_complex_expression_with_mixed_validity(self):
        """Test deeply nested expressions with mix of valid and invalid references."""
        # Rate expression: (k1 + k2) * k_bad (k_bad is not declared)
        inner_expr = ExprNode(op="+", args=["k1", "k2"])
        rate_expr = ExprNode(op="*", args=[inner_expr, "k_bad"])

        reaction = Reaction(
            name="test_reaction", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant=rate_expr
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert not result.is_valid
        assert len(result.structural_errors) == 1
        error = result.structural_errors[0]
        assert error.code == "undeclared_rate_variable"
        assert "k_bad" in error.message

    def test_expression_referencing_species_valid(self):
        """Test that rate expressions can reference species concentrations."""
        # Rate expression: k1 * A (A is a declared species)
        rate_expr = ExprNode(op="*", args=["k1", "A"])

        reaction = Reaction(
            name="test_reaction", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant=rate_expr
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert result.is_valid, (
            f"Expected validation to pass, but got errors: {[e.message for e in result.structural_errors]}"
        )
        assert len(result.structural_errors) == 0

    def test_multiple_reactions_independent_validation(self):
        """Test that multiple reactions are validated independently."""
        species, parameters = self.create_base_reaction_system()

        # First reaction: valid
        reaction1 = Reaction(
            name="reaction1", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant="k1"
        )

        # Second reaction: invalid
        reaction2 = Reaction(
            name="reaction2", reactants={"B": 1.0}, products={"A": 1.0}, rate_constant="k_invalid"
        )

        rs = ReactionSystem(
            name="test_system",
            species=species,
            parameters=parameters,
            reactions=[reaction1, reaction2],
        )

        esm_file = EsmFile(
            version="1.0",
            metadata=Metadata(title="Test", description="Multiple reactions test"),
            models={},
            reaction_systems={"test_system": rs},
            operators=[],
            coupling=[],
            events=[],
        )

        result = validate(esm_file)

        assert not result.is_valid
        assert len(result.structural_errors) == 1
        error = result.structural_errors[0]
        assert error.code == "undeclared_parameter"
        assert "k_invalid" in error.message
        assert "reaction2" in error.path or "/reactions/1/" in error.path

    def test_error_details_contain_helpful_information(self):
        """Test that error details contain helpful debugging information."""
        rate_expr = ExprNode(op="*", args=["k1", "k_missing"])

        reaction = Reaction(
            name="test_reaction", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant=rate_expr
        )

        esm_file = self.create_esm_file_with_reaction(reaction)
        result = validate(esm_file)

        assert not result.is_valid
        error = result.structural_errors[0]

        # Check that error details contain helpful information
        assert "variable" in error.details
        assert error.details["variable"] == "k_missing"
        assert "reaction_system" in error.details
        assert error.details["reaction_system"] == "test_system"
        assert "available_parameters" in error.details
        assert "k1" in error.details["available_parameters"]
        assert "k2" in error.details["available_parameters"]
        assert "available_species" in error.details
        assert "A" in error.details["available_species"]
        assert "B" in error.details["available_species"]


if __name__ == "__main__":
    pytest.main([__file__])
