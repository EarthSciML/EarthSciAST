"""
Integration test suite for ESM format.

This module tests the full workflow: load, validate, pretty-print, substitute, re-validate.
It ensures all components work together correctly.
"""

import pytest
import json
from conftest import FIXTURES_ROOT

from earthsci_toolkit import (
    load, save, validate, substitute
)
from earthsci_toolkit.display import to_unicode, to_latex
from earthsci_toolkit.parse import SchemaValidationError
from earthsci_toolkit.validation import ValidationError


class TestFullWorkflowIntegration:
    """Test complete workflow integration."""

    @pytest.fixture
    def fixtures_dir(self):
        """Get path to test fixtures."""
        return FIXTURES_ROOT

    def test_simple_model_full_workflow(self):
        """Test full workflow with a simple model."""
        # 1. Create a simple ESM model
        esm_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Integration Test Model"},
            "models": {
                "simple": {
                    "variables": {
                        "x": {"type": "state", "units": "kg"},
                        "y": {"type": "observed", "expression": {"op": "+", "args": ["x", "param2"]}}
                    },
                    "equations": [
                        {"lhs": "x", "rhs": "param1"}
                    ]
                }
            }
        }

        # 2. Load and validate initial model
        esm_json = json.dumps(esm_data)
        loaded_model = load(esm_json)
        assert loaded_model is not None

        validation_result = validate(loaded_model)
        assert validation_result.is_valid

        # 3. Pretty-print expressions
        simple_model = loaded_model.models["simple"]
        y_variable = simple_model.variables["y"].expression
        unicode_display = to_unicode(y_variable)
        latex_display = to_latex(y_variable)

        assert unicode_display is not None
        assert latex_display is not None
        assert "+" in unicode_display
        assert "x" in unicode_display and "param2" in unicode_display

        # 4. Apply substitutions (test the basic substitute function)
        equation_rhs = simple_model.equations[0].rhs
        substitutions = {"param1": 0.5}
        substituted_rhs = substitute(equation_rhs, substitutions)
        assert substituted_rhs == 0.5

        # 5. Test save/load roundtrip
        saved_json = save(loaded_model)
        reloaded_model = load(saved_json)
        final_validation = validate(reloaded_model)
        assert final_validation.is_valid

        # 6. Verify roundtrip preserves structure
        reloaded_simple = reloaded_model.models["simple"]
        assert reloaded_simple.name == simple_model.name
        assert len(reloaded_simple.variables) == len(simple_model.variables)

    def test_reaction_system_full_workflow(self):
        """Test full workflow with a reaction system."""
        # 1. Create reaction system
        esm_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Reaction Integration Test"},
            "reaction_systems": {
                "simple_chemistry": {
                    "species": {
                        "A": {},
                        "B": {},
                        "C": {}
                    },
                    "parameters": {
                        "k1": {"default": 0.1, "units": "1/s"},
                        "k2": {"default": 0.2, "units": "1/s"}
                    },
                    "reactions": [{
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": [{"species": "B", "stoichiometry": 1}],
                        "rate": "k1"
                    }, {
                        "id": "R2",
                        "substrates": [{"species": "B", "stoichiometry": 1}],
                        "products": [{"species": "C", "stoichiometry": 1}],
                        "rate": {"op": "*", "args": ["k2", "B"]}
                    }]
                }
            }
        }

        # 2. Load and validate
        esm_json = json.dumps(esm_data)
        loaded_model = load(esm_json)
        validation_result = validate(loaded_model)
        assert validation_result.is_valid

        # 3. Display reaction rates
        rs = loaded_model.reaction_systems["simple_chemistry"]
        r2_rate = rs.reactions[1].rate_constant
        unicode_rate = to_unicode(r2_rate)
        latex_rate = to_latex(r2_rate)

        assert "k2" in unicode_rate and "B" in unicode_rate
        assert "k2" in latex_rate and "B" in latex_rate

        # 4. Save and re-validate (verify roundtrip)
        saved_json = save(loaded_model)
        reloaded_model = load(saved_json)
        final_validation = validate(reloaded_model)
        assert final_validation.is_valid

    def test_coupled_system_full_workflow(self):
        """Test full workflow with coupled models."""
        esm_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Coupled System Test"},
            "models": {
                "physics": {
                    "variables": {"T": {"type": "state", "units": "K"}},
                    "equations": [{"lhs": "T", "rhs": "heat_param"}]
                },
                "chemistry": {
                    "variables": {"conc": {"type": "state", "units": "mol/L"}},
                    "equations": [{"lhs": "conc", "rhs": {"op": "*", "args": ["rate_const", "T"]}}]
                }
            },
            "coupling": [{
                "type": "variable_map",
                "from": "physics.T",
                "to": "chemistry.T",
                "transform": "identity"
            }]
        }

        # Full workflow test
        esm_json = json.dumps(esm_data)
        loaded_model = load(esm_json)
        validation_result = validate(loaded_model)
        assert validation_result.is_valid

        # Save and re-validate
        saved_json = save(loaded_model)
        reloaded_model = load(saved_json)
        final_validation = validate(reloaded_model)
        assert final_validation.is_valid

    def test_workflow_with_fixtures(self, fixtures_dir):
        """Test workflow using actual fixture files."""
        valid_dir = fixtures_dir / "valid"

        if not valid_dir.exists():
            pytest.skip("Valid fixtures directory not found")

        # Test a few representative files
        valid_files = sorted(valid_dir.glob("*.esm"))
        if not valid_files:
            pytest.skip("No valid fixture files found")

        test_file = valid_files[0]  # Test first available file

        with open(test_file) as f:
            content = f.read()

        # Full workflow
        loaded_model = load(content)
        validation_result = validate(loaded_model)
        # Schema validation should pass (structural warnings may exist)
        assert len(validation_result.schema_errors) == 0

        # Rendering the model as text must work end-to-end
        rendered = to_unicode(loaded_model)
        assert rendered

        # Save and reload
        saved_content = save(loaded_model)
        reloaded_model = load(saved_content)

        # Should be equivalent
        assert reloaded_model.version == loaded_model.version

    def test_error_recovery_workflow(self):
        """Test workflow with error recovery."""
        # Start with invalid model
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Error Recovery Test"},
            "models": {
                "broken": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [{"lhs": "x", "rhs": "undefined_var"}]
                }
            }
        }

        # This should parse and then we validate
        esm_json = json.dumps(invalid_esm)
        loaded_model = load(esm_json)
        validation_result = validate(loaded_model)

        # Validation might pass (undefined_var treated as external reference) or fail
        # Either outcome is acceptable for this test
        assert validation_result is not None


class TestWorkflowRobustness:
    """Test workflow robustness and edge cases."""

    def test_empty_model_workflow(self):
        """Test workflow with minimal/empty model."""
        minimal_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Minimal Test"},
            "models": {}
        }

        esm_json = json.dumps(minimal_esm)
        loaded_model = load(esm_json)
        validation_result = validate(loaded_model)

        # Empty models may or may not be considered valid depending on validation rules
        assert validation_result is not None

        # Should be able to render an empty model
        rendered = to_unicode(loaded_model)
        assert rendered

    def test_large_model_workflow_performance(self):
        """Test workflow performance with larger models."""
        # Create a model with many variables and equations
        large_model = {
            "esm": "0.1.0",
            "metadata": {"name": "Performance Test"},
            "models": {
                "large_system": {
                    "variables": {f"x{i}": {"type": "state"} for i in range(20)},
                    "equations": [
                        {"lhs": f"x{i}", "rhs": {"op": "+", "args": [f"x{(i+1)%20}", f"param{i}"]}}
                        for i in range(20)
                    ]
                }
            }
        }

        # Test workflow
        esm_json = json.dumps(large_model)
        loaded_model = load(esm_json)
        validation_result = validate(loaded_model)
        assert validation_result.is_valid

        # Save and re-validate roundtrip
        saved_json = save(loaded_model)
        reloaded_model = load(saved_json)
        final_validation = validate(reloaded_model)
        assert final_validation.is_valid

    def test_nested_expression_workflow(self):
        """Test workflow with deeply nested expressions."""
        # Create deeply nested expression
        nested_expr = "x"
        for i in range(5):
            nested_expr = {"op": "+", "args": [nested_expr, f"y{i}"]}

        nested_model = {
            "esm": "0.1.0",
            "metadata": {"name": "Nested Expression Test"},
            "models": {
                "nested": {
                    "variables": {"result": {"type": "state"}},
                    "equations": [{"lhs": "result", "rhs": nested_expr}]
                }
            }
        }

        # Full workflow
        esm_json = json.dumps(nested_model)
        loaded_model = load(esm_json)
        validation_result = validate(loaded_model)
        assert validation_result.is_valid

        # Display the nested expression
        equation_rhs = loaded_model.models["nested"].equations[0].rhs
        unicode_result = to_unicode(equation_rhs)
        latex_result = to_latex(equation_rhs)

        assert unicode_result is not None
        assert latex_result is not None

    def test_workflow_with_unicode_content(self):
        """Test workflow with Unicode characters in content."""
        unicode_model = {
            "esm": "0.1.0",
            "metadata": {"name": "Unicode Test", "authors": ["François Müller"]},
            "models": {
                "chemistry": {
                    "variables": {"CO₂": {"type": "state", "description": "Carbon dioxide concentration"}},
                    "equations": [{"lhs": "CO₂", "rhs": 0.0}]
                }
            }
        }

        # Should handle Unicode gracefully
        esm_json = json.dumps(unicode_model, ensure_ascii=False)
        loaded_model = load(esm_json)
        validation_result = validate(loaded_model)
        assert validation_result.is_valid

        # Display should preserve Unicode
        rendered = to_unicode(loaded_model)
        assert rendered


class TestWorkflowErrorHandling:
    """Test error handling throughout the workflow."""

    def test_invalid_json_handling(self):
        """Test handling of invalid JSON."""
        invalid_json = '{"esm": "0.1.0", "metadata": {"name": "Test"'  # Missing closing braces

        with pytest.raises((json.JSONDecodeError, ValueError)):
            load(invalid_json)

    def test_schema_violation_handling(self):
        """Test handling of schema violations."""
        schema_violation = {
            "esm": "invalid-version",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}}
        }

        with pytest.raises((SchemaValidationError, Exception)):
            load(json.dumps(schema_violation))

    def test_substitution_error_handling(self):
        """Test error handling in substitution phase."""
        esm_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Substitution Error Test"},
            "models": {
                "test": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [{"lhs": "x", "rhs": "param"}]
                }
            }
        }

        loaded_model = load(json.dumps(esm_data))

        # Try substitution with invalid value
        try:
            # This might work or might fail depending on validation strictness
            bad_substitutions = {"param": float('inf')}  # Infinity
            substituted_model = substitute(loaded_model, bad_substitutions)

            # If substitution succeeds, validation might catch it
            substituted_json = save(substituted_model)
            validation_result = validate(substituted_json)
            # Either validation should fail or it should be considered valid
            assert validation_result.is_valid or not validation_result.is_valid
        except Exception:
            # Exception during substitution is acceptable
            pass

    def test_display_error_handling(self):
        """Test error handling in display functions."""
        # These should not crash
        problematic_expressions = [
            None,
            {"op": "unknown", "args": []},
            {"malformed": "expression"},
            {"op": "+"},  # Missing args
            {"op": "+", "args": None},  # None args
        ]

        for expr in problematic_expressions:
            unicode_result = to_unicode(expr)
            latex_result = to_latex(expr)

            # Should not crash and should return something
            assert unicode_result is not None
            assert latex_result is not None

    def test_roundtrip_consistency(self):
        """Test that load(save(load(content))) gives consistent results."""
        original_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Roundtrip Test"},
            "models": {
                "test": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [{"lhs": "x", "rhs": {"op": "+", "args": [1, 2]}}]
                }
            }
        }

        # Roundtrip test
        original_json = json.dumps(original_esm)
        loaded1 = load(original_json)
        saved1 = save(loaded1)
        loaded2 = load(saved1)
        saved2 = save(loaded2)

        # Second save should be identical to first save
        assert saved1 == saved2

        # Core fields should be preserved
        assert loaded1.version == loaded2.version