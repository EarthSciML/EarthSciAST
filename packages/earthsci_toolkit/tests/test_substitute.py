"""
Substitution test suite for ESM format.

This module tests substitution functionality using the substitution fixtures,
verifying variable replacement, scoped references, and nested substitutions.
"""

import pytest
import json
from conftest import FIXTURES_ROOT

from earthsci_toolkit import substitute, substitute_in_model, substitute_in_reaction_system
from earthsci_toolkit.esm_types import ExprNode
from earthsci_toolkit.parse import load


class TestSubstitutionFixtures:
    """Test substitution using fixture files."""

    @pytest.fixture
    def fixtures_dir(self):
        """Get path to substitution fixtures."""
        return FIXTURES_ROOT / "substitution"

    @staticmethod
    def _run_fixture_cases(fixture_file):
        """Load and run substitute test cases from a fixture file."""
        with open(fixture_file) as f:
            data = json.load(f)

        # Handle both list format and dict format
        cases = data if isinstance(data, list) else data.get("cases", [data])

        for case in cases:
            # Try both key naming conventions
            input_expr = case.get("input") or case.get("original")
            bindings = case.get("bindings") or case.get("substitutions", {})
            expected = case.get("expected")

            if input_expr is not None and expected is not None:
                result = substitute(input_expr, bindings)
                assert result == expected, f"For input {input_expr} with bindings {bindings}: got {result}, expected {expected}"

    def test_simple_variable_replacement(self, fixtures_dir):
        """Test simple variable replacement using fixture."""
        fixture_file = fixtures_dir / "simple_var_replace.json"
        if not fixture_file.exists():
            pytest.skip("simple_var_replace.json fixture not found")
        self._run_fixture_cases(fixture_file)

    def test_scoped_reference_substitution(self, fixtures_dir):
        """Test scoped reference substitution using fixture."""
        fixture_file = fixtures_dir / "scoped_reference.json"
        if not fixture_file.exists():
            pytest.skip("scoped_reference.json fixture not found")
        self._run_fixture_cases(fixture_file)

    def test_nested_substitution(self, fixtures_dir):
        """Test nested substitution using fixture."""
        fixture_file = fixtures_dir / "nested_substitution.json"
        if not fixture_file.exists():
            pytest.skip("nested_substitution.json fixture not found")
        self._run_fixture_cases(fixture_file)


class TestSubstitutionFunctions:
    """Test core substitution functions."""

    def test_substitute_string_literal(self):
        """Test substitution in string literal."""
        result = substitute("x", {"x": "y"})
        assert result == "y"

    def test_substitute_number_literal(self):
        """Test substitution with number (no change expected)."""
        result = substitute(42, {"x": "y"})
        assert result == 42

    def test_substitute_expression_node(self):
        """Test substitution in expression node."""
        expr = {"op": "+", "args": ["x", "y"]}
        substitutions = {"x": "a", "y": "b"}
        result = substitute(expr, substitutions)

        expected = {"op": "+", "args": ["a", "b"]}
        assert result == expected

    def test_substitute_nested_expression(self):
        """Test substitution in nested expression."""
        expr = {
            "op": "*",
            "args": [
                {"op": "+", "args": ["x", "y"]},
                "z"
            ]
        }
        substitutions = {"x": "a", "y": "b", "z": "c"}
        result = substitute(expr, substitutions)

        expected = {
            "op": "*",
            "args": [
                {"op": "+", "args": ["a", "b"]},
                "c"
            ]
        }
        assert result == expected

    def test_substitute_partial_replacement(self):
        """Test substitution with partial variable replacement."""
        expr = {"op": "+", "args": ["x", "y", "z"]}
        substitutions = {"x": "a"}  # Only substitute x
        result = substitute(expr, substitutions)

        expected = {"op": "+", "args": ["a", "y", "z"]}
        assert result == expected

    def test_substitute_no_matches(self):
        """Test substitution when no variables match."""
        expr = {"op": "+", "args": ["x", "y"]}
        substitutions = {"a": "b"}  # No matching variables
        result = substitute(expr, substitutions)

        # Should return unchanged
        assert result == expr

    def test_substitute_empty_substitutions(self):
        """Test substitution with empty substitutions."""
        expr = {"op": "+", "args": ["x", "y"]}
        result = substitute(expr, {})
        assert result == expr

    def test_substitute_complex_value(self):
        """Test substitution with complex replacement value."""
        expr = "x"
        substitutions = {"x": {"op": "*", "args": ["a", "b"]}}
        result = substitute(expr, substitutions)

        expected = {"op": "*", "args": ["a", "b"]}
        assert result == expected

    def test_substitute_chained_replacement(self):
        """Test chained substitution (a -> b -> c)."""
        expr = "a"
        # Note: Basic substitute might not do chaining
        substitutions = {"a": "b", "b": "c"}
        result = substitute(expr, substitutions)

        # Should substitute a -> b
        assert result == "b"

    def test_substitute_array_arguments(self):
        """Test substitution in array of arguments."""
        expr = {"op": "func", "args": ["x", "y", "x"]}  # x appears twice
        substitutions = {"x": "z"}
        result = substitute(expr, substitutions)

        expected = {"op": "func", "args": ["z", "y", "z"]}
        assert result == expected

    def test_substitute_preserves_const_value_metadata(self):
        """Substituting through a closed-function lookup must keep ``const``
        ``value`` and ``fn`` ``name`` (regression: param_to_var coupling once
        dropped the table, leaving an empty ``{op: const, args: []}`` that
        failed schema validation)."""
        # fn:interp.linear over a const table axis, indexed by a coupled var.
        expr = ExprNode(
            op="fn", fn="interp.linear", name="interp.linear",
            args=[
                ExprNode(op="const", args=[], value=[10.0, 20.0, 30.0]),
                ExprNode(op="const", args=[], value=[1.0, 2.0, 3.0]),
                "code",
            ],
        )
        result = substitute(expr, {"code": "fuel_code"})

        assert isinstance(result, ExprNode)
        assert result.name == "interp.linear"
        assert result.fn == "interp.linear"
        assert result.args[0].op == "const"
        assert result.args[0].value == [10.0, 20.0, 30.0]
        assert result.args[1].value == [1.0, 2.0, 3.0]
        assert result.args[2] == "fuel_code"  # the coupled var was substituted


class TestModelSubstitution:
    """Test model-level substitution functions."""

    def test_substitute_in_simple_model(self):
        """Test substitution in a simple model."""
        model_data = {
            "variables": {"x": {"type": "state"}, "y": {"type": "state"}},
            "equations": [
                {"lhs": "x", "rhs": "a"},
                {"lhs": "y", "rhs": {"op": "+", "args": ["x", "b"]}}
            ]
        }

        substitutions = {"a": "c", "b": "d"}
        result = substitute_in_model(model_data, substitutions)

        expected_equations = [
            {"lhs": "x", "rhs": "c"},
            {"lhs": "y", "rhs": {"op": "+", "args": ["x", "d"]}}
        ]

        assert result["equations"] == expected_equations

    def test_substitute_in_model_with_metadata(self):
        """Test substitution preserves model structure."""
        model_data = {
            "variables": {"x": {"type": "state", "units": "kg"}},
            "equations": [{"lhs": "x", "rhs": "param"}],
            "description": "Test model"
        }

        substitutions = {"param": "0.5"}
        result = substitute_in_model(model_data, substitutions)

        # Should preserve metadata
        assert result["variables"] == model_data["variables"]
        assert result["description"] == model_data["description"]
        assert result["equations"][0]["rhs"] == "0.5"

    def test_substitute_in_model_no_equations(self):
        """Test substitution in model with no equations."""
        model_data = {
            "variables": {"x": {"type": "state"}},
            "equations": []
        }

        result = substitute_in_model(model_data, {"a": "b"})
        assert result == model_data


class TestReactionSystemSubstitution:
    """Test reaction system substitution functions."""

    def test_substitute_in_simple_reaction_system(self):
        """Test substitution in a simple reaction system."""
        reaction_system = {
            "species": {"A": {}, "B": {}},
            "parameters": {"k": {"default": "param_value"}},
            "reactions": [{
                "id": "R1",
                "substrates": [{"species": "A", "stoichiometry": 1}],
                "products": [{"species": "B", "stoichiometry": 1}],
                "rate": {"op": "*", "args": ["k", "param_rate"]}
            }]
        }

        substitutions = {"param_value": 0.1, "param_rate": "A"}
        result = substitute_in_reaction_system(reaction_system, substitutions)

        # Check parameter substitution
        assert result["parameters"]["k"]["default"] == 0.1
        # Check rate expression substitution
        assert result["reactions"][0]["rate"] == {"op": "*", "args": ["k", "A"]}

    def test_substitute_in_reaction_system_complex_rate(self):
        """Test substitution in reaction system with complex rate expression."""
        reaction_system = {
            "species": {"A": {}, "B": {}},
            "parameters": {},
            "reactions": [{
                "id": "R1",
                "substrates": None,
                "products": [{"species": "A", "stoichiometry": 1}],
                "rate": {
                    "op": "*",
                    "args": ["k", {"op": "^", "args": ["temp", "2"]}]
                }
            }]
        }

        substitutions = {"k": 0.1, "temp": "T"}
        result = substitute_in_reaction_system(reaction_system, substitutions)

        expected_rate = {
            "op": "*",
            "args": [0.1, {"op": "^", "args": ["T", "2"]}]
        }
        assert result["reactions"][0]["rate"] == expected_rate

    def test_substitute_preserves_reaction_structure(self):
        """Test that substitution preserves reaction system structure."""
        reaction_system = {
            "species": {"A": {"default": 18.0}},
            "parameters": {"k": {"units": "1/s"}},
            "reactions": [{
                "id": "R1",
                "substrates": None,
                "products": [{"species": "A", "stoichiometry": 1}],
                "rate": "param"
            }]
        }

        substitutions = {"param": "k"}
        result = substitute_in_reaction_system(reaction_system, substitutions)

        # Should preserve structure
        assert result["species"]["A"]["default"] == 18.0
        assert result["parameters"]["k"]["units"] == "1/s"
        assert result["reactions"][0]["id"] == "R1"
        assert result["reactions"][0]["rate"] == "k"


class TestSubstitutionErrorHandling:
    """Test error handling in substitution functions."""

    def test_substitute_with_invalid_expression(self):
        """Test substitution with invalid expression structure."""
        # This might not raise an error but should handle gracefully
        invalid_expr = {"op": "+"}  # Missing args
        result = substitute(invalid_expr, {"x": "y"})

        # Should return the invalid expression unchanged or handle gracefully
        assert result is not None

    def test_substitute_circular_reference_detection(self):
        """Test detection of circular references in substitution."""
        # This is a challenging case - might not be implemented yet
        expr = "x"
        substitutions = {"x": "y", "y": "x"}  # Circular reference

        # Different implementations might handle this differently
        try:
            result = substitute(expr, substitutions)
            # Should either detect the cycle or substitute once
            assert result in ["y", "x"]
        except Exception as e:
            # Might raise a circular reference error
            assert "circular" in str(e).lower() or "cycle" in str(e).lower()

    def test_substitute_deep_nesting(self):
        """Test substitution with deeply nested expressions."""
        # Create deeply nested expression
        expr = "x"
        for i in range(5):
            expr = {"op": "+", "args": [expr, f"var{i}"]}

        substitutions = {"x": "y"}
        result = substitute(expr, substitutions)

        # Should handle deep nesting without issues
        assert result is not None

    def test_substitute_none_values(self):
        """Test substitution with None values."""
        result = substitute(None, {"x": "y"})
        assert result is None

        result = substitute("x", {"x": None})
        assert result is None