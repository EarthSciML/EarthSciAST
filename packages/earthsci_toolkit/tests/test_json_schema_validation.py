"""
Comprehensive JSON Schema validation test suite for ESM format.

This module provides exhaustive tests for JSON Schema validation including:
- Validation of required fields and their absence
- Type validation errors (wrong types for all schema fields)
- Format validation errors (invalid date-time, URI, email formats)
- Constraint validation errors (minimum/maximum values, string lengths, array sizes)
- Enum validation errors (invalid values for enumerated fields)
- Pattern validation errors (regex patterns like version strings)
- Conditional schema validation (if/then/else rules)
- Reference validation ($ref resolution errors)
- Additional properties validation
- Cross-field validation dependencies
- Complex nested object validation errors
- Array item validation errors
- All edge cases and corner cases for comprehensive coverage
"""

import json
import pytest
import jsonschema
from jsonschema import ValidationError

from earthsci_toolkit import load
from earthsci_toolkit.parse import _get_schema


def _all_error_messages(error: ValidationError):
    """Flatten a ValidationError and all its nested sub-errors into messages.

    Top-level ``models`` validates against ``oneOf[Model, SubsystemRef]``, so a
    model that fails for a concrete reason (missing ``variables``, a wrong field
    type, …) surfaces that reason inside ``error.context`` under the umbrella
    "is not valid under any of the given schemas" message. Collecting the whole
    tree lets a test assert on the specific cause regardless of nesting.
    """
    messages = [error.message]
    for sub in error.context or []:
        messages.extend(_all_error_messages(sub))
    return messages


def _assert_rejected_with(schema, data, cause_substring):
    """Assert ``data`` fails schema validation and ``cause_substring`` appears
    somewhere in the (possibly nested) validation error tree."""
    with pytest.raises(ValidationError) as excinfo:
        jsonschema.validate(data, schema)
    messages = _all_error_messages(excinfo.value)
    assert any(cause_substring in m for m in messages), (
        f"expected {cause_substring!r} among validation errors, got: {messages}"
    )


class TestRequiredFieldValidation:
    """Test validation of required fields in all schema objects."""

    def test_missing_top_level_required_fields(self):
        """Test validation when top-level required fields are missing."""
        schema = _get_schema()

        # Missing esm field
        invalid_data = {"metadata": {"name": "Test"}}
        with pytest.raises(ValidationError, match="'esm' is a required property"):
            jsonschema.validate(invalid_data, schema)

        # Missing metadata field
        invalid_data = {"esm": "0.1.0"}
        with pytest.raises(ValidationError, match="'metadata' is a required property"):
            jsonschema.validate(invalid_data, schema)

        # Missing both models and reaction_systems (violates anyOf)
        invalid_data = {"esm": "0.1.0", "metadata": {"name": "Test"}}
        with pytest.raises(ValidationError):
            jsonschema.validate(invalid_data, schema)

    def test_missing_metadata_required_fields(self):
        """Test validation when metadata required fields are missing."""
        schema = _get_schema()

        # Missing name field in metadata
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="'name' is a required property"):
            jsonschema.validate(invalid_data, schema)

    def test_missing_model_required_fields(self):
        """Test validation when model required fields are missing."""
        schema = _get_schema()

        # Missing variables in model. Top-level `models` is
        # oneOf[Model, SubsystemRef]; the concrete cause is nested under the
        # oneOf umbrella error, so assert on the whole error tree.
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test_model": {"equations": []}},
        }
        _assert_rejected_with(schema, invalid_data, "'variables' is a required property")

        # Missing equations in model
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test_model": {"variables": {}}},
        }
        _assert_rejected_with(schema, invalid_data, "'equations' is a required property")

    def test_missing_reaction_system_required_fields(self):
        """Test validation when reaction system required fields are missing."""
        schema = _get_schema()

        # Missing species
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {"test_rs": {"parameters": {}, "reactions": []}},
        }
        with pytest.raises(ValidationError, match="'species' is a required property"):
            jsonschema.validate(invalid_data, schema)

        # Missing parameters
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {"test_rs": {"species": {}, "reactions": []}},
        }
        with pytest.raises(ValidationError, match="'parameters' is a required property"):
            jsonschema.validate(invalid_data, schema)

        # Missing reactions
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {"test_rs": {"species": {}, "parameters": {}}},
        }
        with pytest.raises(ValidationError, match="'reactions' is a required property"):
            jsonschema.validate(invalid_data, schema)

    def test_missing_equation_required_fields(self):
        """Test validation when equation required fields are missing."""
        schema = _get_schema()

        # Missing lhs
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {"variables": {"x": {"type": "state"}}, "equations": [{"rhs": 1}]}
            },
        }
        with pytest.raises(ValidationError, match="'lhs' is a required property"):
            jsonschema.validate(invalid_data, schema)

        # Missing rhs
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {"variables": {"x": {"type": "state"}}, "equations": [{"lhs": "x"}]}
            },
        }
        with pytest.raises(ValidationError, match="'rhs' is a required property"):
            jsonschema.validate(invalid_data, schema)


class TestTypeValidation:
    """Test validation of incorrect types for all schema fields."""

    def test_incorrect_top_level_types(self):
        """Test validation when top-level fields have incorrect types."""
        schema = _get_schema()

        # esm should be string, not number
        invalid_data = {
            "esm": 0.1,
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="0.1 is not of type 'string'"):
            jsonschema.validate(invalid_data, schema)

        # metadata should be object, not string
        invalid_data = {
            "esm": "0.1.0",
            "metadata": "not an object",
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="'not an object' is not of type 'object'"):
            jsonschema.validate(invalid_data, schema)

        # models should be object, not array
        invalid_data = {"esm": "0.1.0", "metadata": {"name": "Test"}, "models": []}
        with pytest.raises(ValidationError, match="\\[\\] is not of type 'object'"):
            jsonschema.validate(invalid_data, schema)

    def test_incorrect_expression_types(self):
        """Test validation of incorrect expression types."""
        schema = _get_schema()

        # Expression can be number, string, or object - test invalid array
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [{"lhs": "x", "rhs": []}],  # Array is invalid
                }
            },
        }
        with pytest.raises(ValidationError):
            jsonschema.validate(invalid_data, schema)

    def test_incorrect_model_variable_types(self):
        """Test validation of incorrect model variable field types."""
        schema = _get_schema()

        # type should be string, not number. (Top-level `models` is
        # oneOf[Model, SubsystemRef]; the concrete type error is nested under
        # the oneOf umbrella.)
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test_model": {"variables": {"x": {"type": 123}}, "equations": []}},
        }
        _assert_rejected_with(schema, invalid_data, "123 is not of type 'string'")

        # units should be string, not boolean
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state", "units": True}},
                    "equations": [],
                }
            },
        }
        _assert_rejected_with(schema, invalid_data, "True is not of type 'string'")

        # default should be number, not string (when present)
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state", "default": "not a number"}},
                    "equations": [],
                }
            },
        }
        _assert_rejected_with(schema, invalid_data, "'not a number' is not of type 'number'")

    def test_incorrect_reaction_types(self):
        """Test validation of incorrect reaction field types."""
        schema = _get_schema()

        # substrates should be array or null, not string
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {
                "test_rs": {
                    "species": {"A": {}},
                    "parameters": {},
                    "reactions": [
                        {"id": "R1", "substrates": "invalid", "products": None, "rate": "k1"}
                    ],
                }
            },
        }
        with pytest.raises(ValidationError):
            jsonschema.validate(invalid_data, schema)


class TestEnumValidation:
    """Test validation of enumerated field values."""

    def test_invalid_model_variable_type_enum(self):
        """Test validation of invalid model variable type values."""
        schema = _get_schema()

        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {"variables": {"x": {"type": "invalid_type"}}, "equations": []}
            },
        }
        with pytest.raises(ValidationError, match="'invalid_type' is not one of"):
            jsonschema.validate(invalid_data, schema)

    def test_malformed_expression_operator_pattern(self):
        """Schema rejects a MALFORMED op string via the `op` pattern.

        As of esm 0.8.0 the `op` field is an open two-tier namespace (esm-spec §4.2): the
        schema no longer enumerates operators. An unknown-but-well-formed op is a valid
        open-tier rewrite-target — accepted here and rejected later with `unlowered_operator`
        at lowering (§9.6.6) if no rule eliminates it. Only a *malformed* op string (one that
        violates the identifier/operator-symbol pattern) is a schema-level error.
        """
        schema = _get_schema()

        def _doc(op):
            return {
                "esm": "0.1.0",
                "metadata": {"name": "Test"},
                "models": {
                    "test_model": {
                        "variables": {"x": {"type": "state"}},
                        "equations": [{"lhs": "x", "rhs": {"op": op, "args": [1, 2]}}],
                    }
                },
            }

        # Malformed (embedded space) → rejected by the `op` pattern.
        with pytest.raises(ValidationError, match="does not match"):
            jsonschema.validate(_doc("bad op"), schema)

        # Unknown but well-formed → NOT a schema error (open-tier rewrite-target).
        jsonschema.validate(_doc("godunov_hamiltonian"), schema)

    def test_invalid_coupling_type_enum(self):
        """Test validation of invalid coupling type values."""
        schema = _get_schema()

        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "coupling": [{"type": "invalid_coupling_type", "systems": ["sys1", "sys2"]}],
        }
        with pytest.raises(ValidationError):
            jsonschema.validate(invalid_data, schema)

    def test_invalid_data_loader_kind_enum(self):
        """Test validation of invalid data loader kind values."""
        schema = _get_schema()

        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "data_loaders": {
                "test_loader": {
                    "kind": "invalid_kind",
                    "source": {"url_template": "file:///data/test.nc"},
                    "variables": {"x": {"file_variable": "x", "units": "1"}},
                }
            },
        }
        with pytest.raises(ValidationError, match="'invalid_kind' is not one of"):
            jsonschema.validate(invalid_data, schema)


class TestPatternValidation:
    """Test validation of pattern-constrained fields."""

    def test_invalid_version_pattern(self):
        """Test validation of invalid version string patterns."""
        schema = _get_schema()

        # Invalid semver pattern - missing patch version
        invalid_data = {
            "esm": "0.1",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="does not match"):
            jsonschema.validate(invalid_data, schema)

        # Invalid semver pattern - non-numeric
        invalid_data = {
            "esm": "v0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="does not match"):
            jsonschema.validate(invalid_data, schema)

        # Invalid semver pattern - extra characters
        invalid_data = {
            "esm": "0.1.0-beta",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="does not match"):
            jsonschema.validate(invalid_data, schema)


class TestFormatValidation:
    """Test validation of format-constrained fields."""

    def test_invalid_datetime_format(self):
        """Test validation of invalid date-time format strings."""
        schema = _get_schema()
        format_checker = jsonschema.FormatChecker()
        # `date-time` format assertion needs an optional backend
        # (e.g. rfc3339-validator); without it FormatChecker is a no-op and
        # cannot reject bad timestamps. Skip rather than silently pass.
        if format_checker.conforms("invalid-datetime", "date-time"):
            pytest.skip(
                "jsonschema 'date-time' format assertion unavailable (install rfc3339-validator)"
            )

        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test", "created": "invalid-datetime"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="date-time|format"):
            jsonschema.validate(invalid_data, schema, format_checker=format_checker)

        # Test modified field as well
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {
                "name": "Test",
                "modified": "2023-13-01T25:00:00Z",  # Invalid month and hour
            },
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="date-time|format"):
            jsonschema.validate(invalid_data, schema, format_checker=format_checker)

    def test_invalid_uri_format(self):
        """Test validation of invalid URI format strings."""
        schema = _get_schema()
        format_checker = jsonschema.FormatChecker()
        # `uri` format assertion needs an optional backend (e.g. rfc3987);
        # without it FormatChecker is a no-op and cannot reject bad URIs.
        if format_checker.conforms("not-a-valid-uri", "uri"):
            pytest.skip("jsonschema 'uri' format assertion unavailable (install rfc3987)")

        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test", "references": [{"url": "not-a-valid-uri"}]},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="uri|format"):
            jsonschema.validate(invalid_data, schema, format_checker=format_checker)


class TestConstraintValidation:
    """Test validation of constraint violations (min/max, length, etc.)."""

    def test_array_size_constraints(self):
        """Test validation of array size constraints."""
        schema = _get_schema()

        # ContinuousEvent.conditions array must have minItems: 1
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [],
                    "continuous_events": [
                        {
                            "conditions": [],  # Empty array violates minItems: 1
                            "affects": [],
                        }
                    ],
                }
            },
        }
        with pytest.raises(ValidationError, match="should be non-empty|is too short"):
            jsonschema.validate(invalid_data, schema)

    def test_numeric_constraints(self):
        """Test validation of numeric constraint violations."""
        schema = _get_schema()

        # Stoichiometry must be minimum 1
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {
                "test_rs": {
                    "species": {"A": {}},
                    "parameters": {},
                    "reactions": [
                        {
                            "id": "R1",
                            "substrates": [
                                {
                                    "species": "A",
                                    "stoichiometry": 0,  # Violates minimum: 1
                                }
                            ],
                            "products": None,
                            "rate": "k1",
                        }
                    ],
                }
            },
        }
        with pytest.raises(
            ValidationError,
            match="is less than the minimum|below minimum|less than or equal to the minimum",
        ):
            jsonschema.validate(invalid_data, schema)

        # Test exclusiveMinimum for interval in periodic trigger
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [],
                    "discrete_events": [
                        {
                            "trigger": {
                                "type": "periodic",
                                "interval": 0,  # Violates exclusiveMinimum: 0
                            },
                            "affects": [],
                        }
                    ],
                }
            },
        }
        with pytest.raises(
            ValidationError, match="is less than or equal to the minimum|not greater than"
        ):
            jsonschema.validate(invalid_data, schema)


class TestConditionalValidation:
    """Test validation of conditional schema rules (if/then/else)."""

    def test_observed_variable_requires_expression(self):
        """Test that observed variables must have expression field."""
        schema = _get_schema()

        # Observed variable without expression should fail
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {
                        "y": {
                            "type": "observed"
                            # Missing required "expression" field for observed type
                        }
                    },
                    "equations": [],
                }
            },
        }
        with pytest.raises(ValidationError, match="'expression' is a required property"):
            jsonschema.validate(invalid_data, schema)

    def test_discrete_event_requires_affects_or_functional_affect(self):
        """Test that discrete events must have either affects or functional_affect."""
        schema = _get_schema()

        # Discrete event without affects or functional_affect should fail
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [],
                    "discrete_events": [
                        {
                            "trigger": {"type": "condition", "expression": "x > 1"}
                            # Missing both "affects" and "functional_affect"
                        }
                    ],
                }
            },
        }
        with pytest.raises(ValidationError):
            jsonschema.validate(invalid_data, schema)

    def test_continuous_event_type_specific_requirements(self):
        """Test event_type specific requirements for coupling events."""
        schema = _get_schema()

        # Continuous coupling event without conditions should fail
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "coupling": [
                {
                    "type": "event",
                    "event_type": "continuous",
                    "affects": [],
                    # Missing required "conditions" for continuous events
                }
            ],
        }
        with pytest.raises(
            ValidationError,
            match="is not valid under any of the given schemas|'conditions' is a required property",
        ):
            jsonschema.validate(invalid_data, schema)

        # Discrete coupling event without trigger should fail
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "coupling": [
                {
                    "type": "event",
                    "event_type": "discrete",
                    "affects": [],
                    # Missing required "trigger" for discrete events
                }
            ],
        }
        with pytest.raises(
            ValidationError,
            match="is not valid under any of the given schemas|'trigger' is a required property",
        ):
            jsonschema.validate(invalid_data, schema)


class TestAdditionalPropertiesValidation:
    """Test validation of additional properties restrictions."""

    def test_no_additional_properties_at_top_level(self):
        """Test that additional properties are not allowed at top level."""
        schema = _get_schema()

        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "unexpected_field": "should not be allowed",
        }
        with pytest.raises(ValidationError, match="Additional properties are not allowed"):
            jsonschema.validate(invalid_data, schema)

    def test_no_additional_properties_in_strict_objects(self):
        """Test that additional properties are not allowed in strict objects."""
        schema = _get_schema()

        # Additional property in ModelVariable
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state", "unexpected_field": "not allowed"}},
                    "equations": [],
                }
            },
        }
        with pytest.raises(ValidationError, match="Additional properties are not allowed"):
            jsonschema.validate(invalid_data, schema)

        # Additional property in Equation
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [{"lhs": "x", "rhs": 1, "unexpected_field": "not allowed"}],
                }
            },
        }
        with pytest.raises(ValidationError, match="Additional properties are not allowed"):
            jsonschema.validate(invalid_data, schema)


class TestComplexValidationScenarios:
    """Test complex validation scenarios involving multiple constraints."""

    def test_nested_expression_validation_errors(self):
        """Test validation errors in deeply nested expressions."""
        schema = _get_schema()

        # Nested expression with invalid operator
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}, "y": {"type": "state"}},
                    "equations": [
                        {
                            "lhs": "x",
                            "rhs": {
                                "op": "+",
                                "args": [
                                    {
                                        "op": "invalid nested op",  # Malformed (embedded space) — rejected by the op pattern
                                        "args": ["y"],
                                    },
                                    1,
                                ],
                            },
                        }
                    ],
                }
            },
        }
        with pytest.raises(ValidationError, match="does not match"):
            jsonschema.validate(invalid_data, schema)

    def test_coupling_validation_with_multiple_errors(self):
        """Test coupling validation with various error combinations."""
        schema = _get_schema()

        # operator_compose with wrong number of systems
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "coupling": [
                {
                    "type": "operator_compose",
                    "systems": ["sys1"],  # Should have exactly 2 systems (minItems: 2, maxItems: 2)
                }
            ],
        }
        with pytest.raises(
            ValidationError,
            match="is not valid under any of the given schemas|should be non-empty|is too short|should not be longer than|is too long",
        ):
            jsonschema.validate(invalid_data, schema)

        # couple missing required connector
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "coupling": [
                {
                    "type": "couple",
                    "systems": ["sys1", "sys2"],
                    # Missing required "connector" field
                }
            ],
        }
        with pytest.raises(
            ValidationError,
            match="is not valid under any of the given schemas|'connector' is a required property",
        ):
            jsonschema.validate(invalid_data, schema)

    def test_reaction_system_complex_validation_errors(self):
        """Test complex reaction system validation errors."""
        schema = _get_schema()

        # Reaction with empty reactions array (violates minItems: 1)
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {
                "test_rs": {
                    "species": {"A": {}},
                    "parameters": {},
                    "reactions": [],  # Violates minItems: 1
                }
            },
        }
        with pytest.raises(ValidationError, match="should be non-empty|is too short"):
            jsonschema.validate(invalid_data, schema)


class TestVersionConstraintValidation:
    """Test validation of version constraint violations."""

    def test_version_const_constraint(self):
        """Test that version must match semver pattern and library rejects incompatible versions."""
        schema = _get_schema()

        # Invalid format (not semver) - rejected by schema pattern
        invalid_data = {
            "esm": "invalid",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="pattern"):
            jsonschema.validate(invalid_data, schema)

        # Incompatible major version - rejected by library
        from earthsci_toolkit.parse import UnsupportedVersionError, load

        invalid_data = {
            "esm": "1.0.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(UnsupportedVersionError):
            load(invalid_data)


class TestEdgeCaseValidation:
    """Test edge cases and corner cases for comprehensive coverage."""

    def test_empty_arrays_where_not_allowed(self):
        """Test empty arrays where they should have minimum items."""
        schema = _get_schema()

        # Empty times array in preset_times trigger
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [],
                    "discrete_events": [
                        {
                            "trigger": {
                                "type": "preset_times",
                                "times": [],  # Empty array violates minItems: 1
                            },
                            "affects": [],
                        }
                    ],
                }
            },
        }
        with pytest.raises(ValidationError, match="should be non-empty|is too short"):
            jsonschema.validate(invalid_data, schema)

    def test_null_values_where_not_allowed(self):
        """Test null values in fields that don't allow null."""
        schema = _get_schema()

        # Null in required string field
        invalid_data = {
            "esm": None,  # Should be string
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
        }
        with pytest.raises(ValidationError, match="None is not of type 'string'"):
            jsonschema.validate(invalid_data, schema)

    def test_functional_affect_validation_errors(self):
        """Test functional affect specific validation errors."""
        schema = _get_schema()

        # Missing required fields in functional_affect
        invalid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [],
                    "discrete_events": [
                        {
                            "trigger": {"type": "condition", "expression": "x > 1"},
                            "functional_affect": {
                                "handler_id": "test_handler"
                                # Missing required "read_vars" and "read_params"
                            },
                        }
                    ],
                }
            },
        }
        # The concrete cause is nested under the top-level `models`
        # oneOf[Model, SubsystemRef] umbrella error.
        _assert_rejected_with(schema, invalid_data, "'read_vars' is a required property")


class TestIntegrationValidationScenarios:
    """Integration tests combining multiple validation aspects."""

    def test_comprehensive_invalid_esm_file(self):
        """Test a comprehensively invalid ESM file with multiple errors."""
        schema = _get_schema()

        # This will catch the first validation error
        invalid_data = {
            "esm": "invalid-version",  # Invalid version pattern
            "metadata": "not an object",  # Wrong type
            "models": [],  # Wrong type
            "reaction_systems": {
                "invalid_rs": {
                    "species": "not an object",  # Wrong type
                    "parameters": [],  # Wrong type
                    "reactions": "not an array",  # Wrong type
                }
            },
            "unexpected_field": "not allowed",  # Additional property
        }
        with pytest.raises(ValidationError):
            jsonschema.validate(invalid_data, schema)

    def test_load_function_with_schema_violations(self):
        """Test the load function with various schema violations."""
        from earthsci_toolkit.parse import SchemaValidationError

        # Invalid JSON structure
        with pytest.raises(SchemaValidationError):
            load('{"esm": "invalid"}')

        # Valid JSON but invalid schema
        with pytest.raises(SchemaValidationError):
            load('{"wrong": "structure"}')

        # Test specific schema violations through the load function
        invalid_esm_json = json.dumps(
            {
                "esm": "wrong-version",
                "metadata": {"name": "Test"},
                "models": {"test": {"variables": {}, "equations": []}},
            }
        )
        with pytest.raises(SchemaValidationError):
            load(invalid_esm_json)

    def test_valid_minimal_examples_for_regression(self):
        """Test minimal valid examples to ensure they still work."""
        schema = _get_schema()

        # Minimal valid model
        valid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [{"lhs": "x", "rhs": 1}],
                }
            },
        }
        jsonschema.validate(valid_data, schema)  # Should not raise

        # Minimal valid reaction system
        valid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {
                "test_rs": {
                    "species": {"A": {}},
                    "parameters": {},
                    "reactions": [
                        {
                            "id": "R1",
                            "substrates": None,
                            "products": [{"species": "A", "stoichiometry": 1}],
                            "rate": 1.0,
                        }
                    ],
                }
            },
        }
        jsonschema.validate(valid_data, schema)  # Should not raise


# Performance and stress testing for schema validation
class TestValidationPerformance:
    """Test validation performance with complex documents."""

    def test_deeply_nested_expression_validation(self):
        """Test validation performance with deeply nested expressions."""
        schema = _get_schema()

        # Create a deeply nested expression
        def create_nested_expr(depth):
            if depth == 0:
                return "x"
            return {"op": "+", "args": [create_nested_expr(depth - 1), 1]}

        valid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [
                        {
                            "lhs": "x",
                            "rhs": create_nested_expr(10),  # Deeply nested
                        }
                    ],
                }
            },
        }

        # Should validate without issues
        jsonschema.validate(valid_data, schema)

    def test_large_reaction_system_validation(self):
        """Test validation with large reaction systems."""
        schema = _get_schema()

        # Create many species, parameters, and reactions
        species = {f"S{i}": {} for i in range(50)}
        parameters = {f"k{i}": {"default": 0.1} for i in range(20)}
        reactions = []
        for i in range(30):
            reactions.append(
                {
                    "id": f"R{i}",
                    "substrates": [{"species": f"S{i % 50}", "stoichiometry": 1}],
                    "products": [{"species": f"S{(i + 1) % 50}", "stoichiometry": 1}],
                    "rate": f"k{i % 20}",
                }
            )

        valid_data = {
            "esm": "0.1.0",
            "metadata": {"name": "Large System Test"},
            "reaction_systems": {
                "large_system": {
                    "species": species,
                    "parameters": parameters,
                    "reactions": reactions,
                }
            },
        }

        # Should validate without issues
        jsonschema.validate(valid_data, schema)
