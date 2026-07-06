#!/usr/bin/env python3
"""
Test cases for integer stoichiometry validation (issue EarthSciSerialization-g9qi).

These tests verify that the validation correctly enforces that stoichiometries
in reactions must be positive integers, not arbitrary floating point values.
"""

import pytest
from earthsci_toolkit.esm_types import (
    EsmFile,
    Metadata,
    ReactionSystem,
    Species,
    Parameter,
    Reaction,
)
from earthsci_toolkit.validation import validate


@pytest.mark.skip(
    reason="Integer-only stoichiometry policy was replaced by positive-finite "
    "fractional stoichiometry (gt-1e96). Tests preserved for context; the "
    "contract they encode no longer matches the spec."
)
class TestStoichiometryIntegerValidation:
    """Test stoichiometry validation for positive integer requirement."""

    def test_integer_stoichiometries_pass(self):
        """Test that integer stoichiometries pass validation."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        k_param = Parameter(name="k", value=0.1, units="1/s")

        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 1},  # Integer stoichiometry
            products={"B": 2},  # Integer stoichiometry
            rate_constant="k",
        )

        reaction_system = ReactionSystem(
            name="test_rs",
            species=[species_A, species_B],
            parameters=[k_param],
            reactions=[reaction],
        )

        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Test Integer Stoichiometry"),
            reaction_systems={"test_rs": reaction_system},
        )

        result = validate(esm_file)
        assert result.is_valid, (
            f"Integer stoichiometries should pass validation. Errors: {result.structural_errors}"
        )

    def test_float_integers_pass(self):
        """Test that float values that are integers (1.0, 2.0) pass validation."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        k_param = Parameter(name="k", value=0.1, units="1/s")

        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 1.0},  # Float but integer value
            products={"B": 2.0},  # Float but integer value
            rate_constant="k",
        )

        reaction_system = ReactionSystem(
            name="test_rs",
            species=[species_A, species_B],
            parameters=[k_param],
            reactions=[reaction],
        )

        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Test Float Integer Stoichiometry"),
            reaction_systems={"test_rs": reaction_system},
        )

        result = validate(esm_file)
        assert result.is_valid, (
            f"Float integer stoichiometries should pass validation. Errors: {result.structural_errors}"
        )

    def test_fractional_stoichiometries_fail(self):
        """Test that fractional stoichiometries fail validation."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        species_C = Species(name="C", units="mol/L")
        k_param = Parameter(name="k", value=0.1, units="1/s")

        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 1.5},  # Fractional stoichiometry
            products={"B": 2.7, "C": 0.3},  # More fractional stoichiometries
            rate_constant="k",
        )

        reaction_system = ReactionSystem(
            name="test_rs",
            species=[species_A, species_B, species_C],
            parameters=[k_param],
            reactions=[reaction],
        )

        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Test Fractional Stoichiometry"),
            reaction_systems={"test_rs": reaction_system},
        )

        result = validate(esm_file)
        assert not result.is_valid, "Fractional stoichiometries should fail validation"

        # Check for specific error codes
        non_integer_errors = [
            error for error in result.structural_errors if error.code == "non_integer_stoichiometry"
        ]

        assert len(non_integer_errors) == 3, (
            f"Expected 3 non-integer stoichiometry errors, got {len(non_integer_errors)}"
        )

        # Verify error details
        error_species = {error.details["species"] for error in non_integer_errors}
        assert error_species == {"A", "B", "C"}, (
            f"Expected errors for species A, B, C, got {error_species}"
        )

    def test_mixed_integer_and_fractional(self):
        """Test reaction with mix of integer and fractional stoichiometries."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        k_param = Parameter(name="k", value=0.1, units="1/s")

        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 1},  # Integer (good)
            products={"B": 2.5},  # Fractional (bad)
            rate_constant="k",
        )

        reaction_system = ReactionSystem(
            name="test_rs",
            species=[species_A, species_B],
            parameters=[k_param],
            reactions=[reaction],
        )

        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Test Mixed Stoichiometry"),
            reaction_systems={"test_rs": reaction_system},
        )

        result = validate(esm_file)
        assert not result.is_valid, (
            "Mixed integer/fractional stoichiometries should fail validation"
        )

        # Should have exactly one error for the fractional stoichiometry
        non_integer_errors = [
            error for error in result.structural_errors if error.code == "non_integer_stoichiometry"
        ]

        assert len(non_integer_errors) == 1, (
            f"Expected 1 non-integer stoichiometry error, got {len(non_integer_errors)}"
        )
        assert non_integer_errors[0].details["species"] == "B"
        assert non_integer_errors[0].details["stoichiometry"] == 2.5

    def test_negative_stoichiometry_still_works(self):
        """Test that existing negative stoichiometry validation still works."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        k_param = Parameter(name="k", value=0.1, units="1/s")

        reaction = Reaction(
            name="test_reaction",
            reactants={"A": -1},  # Negative stoichiometry
            products={"B": 1},  # Valid positive integer
            rate_constant="k",
        )

        reaction_system = ReactionSystem(
            name="test_rs",
            species=[species_A, species_B],
            parameters=[k_param],
            reactions=[reaction],
        )

        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Test Negative Stoichiometry"),
            reaction_systems={"test_rs": reaction_system},
        )

        result = validate(esm_file)
        assert not result.is_valid, "Negative stoichiometries should fail validation"

        # Check for negative stoichiometry error
        negative_errors = [
            error for error in result.structural_errors if error.code == "negative_stoichiometry"
        ]

        assert len(negative_errors) == 1, (
            f"Expected 1 negative stoichiometry error, got {len(negative_errors)}"
        )
        assert negative_errors[0].details["species"] == "A"

    def test_zero_stoichiometry_fails(self):
        """Test that zero stoichiometry fails validation (not positive)."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        k_param = Parameter(name="k", value=0.1, units="1/s")

        reaction = Reaction(
            name="test_reaction",
            reactants={"A": 0},  # Zero stoichiometry
            products={"B": 1},  # Valid positive integer
            rate_constant="k",
        )

        reaction_system = ReactionSystem(
            name="test_rs",
            species=[species_A, species_B],
            parameters=[k_param],
            reactions=[reaction],
        )

        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Test Zero Stoichiometry"),
            reaction_systems={"test_rs": reaction_system},
        )

        result = validate(esm_file)
        assert not result.is_valid, "Zero stoichiometries should fail validation"

        # Check for negative stoichiometry error (zero is caught by <= 0 check)
        negative_errors = [
            error for error in result.structural_errors if error.code == "negative_stoichiometry"
        ]

        assert len(negative_errors) == 1, (
            f"Expected 1 negative stoichiometry error for zero, got {len(negative_errors)}"
        )
        assert negative_errors[0].details["species"] == "A"

    def test_multiple_reactions_validation(self):
        """Test validation across multiple reactions in a system."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        species_C = Species(name="C", units="mol/L")
        k1_param = Parameter(name="k1", value=0.1, units="1/s")
        k2_param = Parameter(name="k2", value=0.2, units="1/s")

        reaction1 = Reaction(
            name="reaction1",
            reactants={"A": 1},  # Valid integer
            products={"B": 1.5},  # Invalid fractional
            rate_constant="k1",
        )

        reaction2 = Reaction(
            name="reaction2",
            reactants={"B": 2.0},  # Valid float integer
            products={"C": 3},  # Valid integer
            rate_constant="k2",
        )

        reaction_system = ReactionSystem(
            name="test_rs",
            species=[species_A, species_B, species_C],
            parameters=[k1_param, k2_param],
            reactions=[reaction1, reaction2],
        )

        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Test Multiple Reactions"),
            reaction_systems={"test_rs": reaction_system},
        )

        result = validate(esm_file)
        assert not result.is_valid, "Should fail due to one fractional stoichiometry"

        # Should have exactly one error for the fractional stoichiometry in reaction1
        non_integer_errors = [
            error for error in result.structural_errors if error.code == "non_integer_stoichiometry"
        ]

        assert len(non_integer_errors) == 1, (
            f"Expected 1 non-integer stoichiometry error, got {len(non_integer_errors)}"
        )
        assert non_integer_errors[0].details["species"] == "B"
        assert non_integer_errors[0].details["stoichiometry"] == 1.5
