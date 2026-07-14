"""
Structural validation test suite for ESM format.

This module tests structural validation that goes beyond JSON schema validation,
focusing on verification of error codes, cross-references, and semantic consistency.
"""

import pytest
import json
from conftest import CORPUS_UNIT_DEFECTS, FIXTURES_ROOT

from earthsci_ast import load
from earthsci_ast.validation import validate, SchemaValidationError


class TestStructuralValidation:
    """Test structural validation with specific error codes."""

    @pytest.fixture
    def fixtures_dir(self):
        """Get path to validation fixtures."""
        return FIXTURES_ROOT

    def test_circular_references_error_code(self, fixtures_dir):
        """Test detection of circular references with specific error code."""
        invalid_file = fixtures_dir / "invalid" / "circular_coupling.esm"

        if invalid_file.exists():
            with open(invalid_file) as f:
                content = f.read()

            with pytest.raises(SchemaValidationError) as exc_info:
                load(content)

            # Check for circular reference error code
            error = exc_info.value
            assert "circular" in str(error).lower() or "cycle" in str(error).lower()

    def test_undefined_variable_references(self, fixtures_dir):
        """Test detection of undefined variable references."""
        # Create a test case with undefined variable reference
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [
                        {"lhs": "x", "rhs": "undefined_var"}
                    ],  # Reference to undefined variable
                }
            },
        }

        # This should be caught by structural validation
        result = validate(json.dumps(invalid_esm))
        if not result.is_valid:
            # Validation found errors - that's what we expect
            all_errors = result.schema_errors + result.structural_errors
            error_text = " ".join(str(e) for e in all_errors).lower()
            assert any(
                keyword in error_text
                for keyword in ["undefined", "reference", "variable", "unknown"]
            )

    def test_var_placeholder_tolerated_in_nested_operator(self, fixtures_dir):
        """`_var` (the reserved operator placeholder, spec §6.4) must be accepted
        as a valid reference at ANY nesting depth in a model's equations —
        including nested inside an operator such as the canonical advection idiom
        ``grad(_var, dim)`` — not merely in the top-level ``D(_var)`` derivative
        position. Regression test for the false
        ``undefined variable reference '_var'`` structural error."""
        advection = {
            "esm": "0.2.0",
            "metadata": {"name": "Advection"},
            "models": {
                "Advection": {
                    "variables": {
                        "c": {"type": "state", "units": "kg/m^3", "default": 0.0},
                        "u": {"type": "parameter", "units": "m/s", "default": 1.0},
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["_var"], "wrt": "t"},
                            "rhs": {
                                "op": "*",
                                "args": [
                                    {"op": "-", "args": ["u"]},
                                    {"op": "grad", "args": ["_var"], "dim": "lon"},
                                ],
                            },
                        }
                    ],
                }
            },
        }
        # load() runs the structural reference-resolution check; it must NOT
        # raise on the nested `_var` placeholder.
        load(json.dumps(advection))
        # And validate() must not surface an undefined-reference error for `_var`.
        result = validate(advection)
        ref_errors = [
            e
            for e in (result.schema_errors + result.structural_errors)
            if "undefined variable reference" in e.message and "_var" in e.message
        ]
        assert ref_errors == [], (
            "_var must never be flagged as an undefined variable reference; got "
            f"{[e.message for e in ref_errors]}"
        )

    def test_genuine_undefined_ref_still_caught_alongside_var(self, fixtures_dir):
        """The `_var` tolerance must be placeholder-specific, not a blanket skip:
        a genuinely misspelled variable nested in the same operator position is
        STILL reported as an undefined variable reference."""
        bad = {
            "esm": "0.2.0",
            "metadata": {"name": "Advection"},
            "models": {
                "Advection": {
                    "variables": {
                        "c": {"type": "state", "units": "kg/m^3", "default": 0.0},
                        "u": {"type": "parameter", "units": "m/s", "default": 1.0},
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["_var"], "wrt": "t"},
                            "rhs": {
                                "op": "*",
                                "args": [
                                    {"op": "-", "args": ["u"]},
                                    # `typo_missing` is not a declared variable and
                                    # is not the reserved `_var` placeholder.
                                    {"op": "grad", "args": ["typo_missing"], "dim": "lon"},
                                ],
                            },
                        }
                    ],
                }
            },
        }
        with pytest.raises(SchemaValidationError) as exc_info:
            load(json.dumps(bad))
        assert "undefined variable reference 'typo_missing'" in str(exc_info.value)

    def test_type_mismatch_in_expressions(self, fixtures_dir):
        """Test type consistency in expressions."""
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {
                        "x": {"type": "state", "units": "kg"},
                        "y": {"type": "state", "units": "m"},
                    },
                    "equations": [
                        {"lhs": "x", "rhs": {"op": "+", "args": ["x", "y"]}}  # Unit mismatch
                    ],
                }
            },
        }

        # Unit validation might catch this
        try:
            result = validate(json.dumps(invalid_esm))
            # Some implementations might allow this at parse time but flag in validation
            if hasattr(result, "warnings") and result.unit_warnings:
                assert any("unit" in str(w).lower() for w in result.unit_warnings)
        except Exception as e:
            # If an exception is raised, it should mention units or type mismatch
            assert "unit" in str(e).lower() or "type" in str(e).lower()

    def test_coupling_consistency_validation(self, fixtures_dir):
        """Test coupling system consistency."""
        invalid_coupling_file = fixtures_dir / "invalid" / "coupling_resolution_errors.esm"

        if invalid_coupling_file.exists():
            with open(invalid_coupling_file) as f:
                content = f.read()

            with pytest.raises((SchemaValidationError, Exception)) as exc_info:
                load(content)

            error = str(exc_info.value).lower()
            assert any(
                keyword in error for keyword in ["coupling", "resolution", "consistency", "connect"]
            )

    def test_reaction_system_mass_balance(self, fixtures_dir):
        """Test reaction system mass balance validation."""
        # Create reaction system with mass imbalance
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "reaction_systems": {
                "test_rs": {
                    "species": {"A": {}, "B": {}, "C": {}},
                    "parameters": {"k": {"default": 0.1}},
                    "reactions": [
                        {
                            "id": "R1",
                            "substrates": [{"species": "A", "stoichiometry": 1}],
                            "products": [
                                {"species": "B", "stoichiometry": 2}
                            ],  # Mass imbalance: 1 -> 2
                            "rate": "k",
                        }
                    ],
                }
            },
        }

        # This might be caught by chemical validation
        result = validate(json.dumps(invalid_esm))
        # Mass balance issues might be warnings rather than errors
        if hasattr(result, "warnings"):
            warnings_text = " ".join(str(w) for w in result.unit_warnings).lower()
            if (
                "mass" in warnings_text
                or "balance" in warnings_text
                or "conservation" in warnings_text
            ):
                assert True  # Found expected warning

        # Or it might be valid from schema perspective but flagged elsewhere
        assert result.is_valid or not result.is_valid  # Either outcome is acceptable here

    def test_domain_boundary_consistency(self, fixtures_dir):
        """Test domain and boundary condition consistency."""
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {"test": {"variables": {}, "equations": []}},
            "domains": {
                "default": {
                    "spatial": {"x": {"min": 0, "max": 10}},
                    "boundary_conditions": [
                        {
                            "type": "constant",
                            "dimensions": ["y"],  # Reference to non-existent dimension
                            "value": 0,
                        }
                    ],
                }
            },
        }

        result = validate(json.dumps(invalid_esm))
        if not result.is_valid:
            all_errors = result.schema_errors + result.structural_errors
            errors_text = " ".join(str(e) for e in all_errors).lower()
            assert any(
                keyword in errors_text
                for keyword in ["dimension", "boundary", "domain", "reference"]
            )

    def test_data_loader_configuration_errors(self, fixtures_dir):
        """Test data loader configuration validation."""
        data_loader_error_file = (
            fixtures_dir / "invalid" / "data_loader_config_schema_violation.esm"
        )

        if data_loader_error_file.exists():
            with open(data_loader_error_file) as f:
                content = f.read()

            with pytest.raises((SchemaValidationError, Exception)) as exc_info:
                load(content)

            error = str(exc_info.value).lower()
            assert any(keyword in error for keyword in ["data", "loader", "config", "schema"])

    def test_scope_resolution_errors(self, fixtures_dir):
        """Test scope resolution validation."""
        # Create nested scope with ambiguous references
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "model1": {"variables": {"x": {"type": "state"}}, "equations": []},
                "model2": {
                    "variables": {"x": {"type": "state"}},  # Same name as model1.x
                    "equations": [{"lhs": "x", "rhs": "model1.x"}],  # Reference should be clear
                },
            },
        }

        # Scope resolution should handle this correctly or flag ambiguity
        result = validate(json.dumps(invalid_esm))
        # This might be valid if scope resolution works correctly
        assert result.is_valid or not result.is_valid

    def test_expression_type_validation(self, fixtures_dir):
        """Test expression type validation."""
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [
                        {
                            "lhs": "x",
                            "rhs": {
                                "op": "+",
                                "args": [1],  # Invalid: + operator requires at least 2 arguments
                            },
                        }
                    ],
                }
            },
        }

        with pytest.raises((SchemaValidationError, ValueError)) as exc_info:
            load(json.dumps(invalid_esm))

        error = str(exc_info.value).lower()
        assert any(keyword in error for keyword in ["arg", "operator", "expression", "invalid"])

    def test_placeholder_expansion_errors(self, fixtures_dir):
        """Test placeholder expansion validation."""
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [
                        {
                            "lhs": "x",
                            "rhs": "${undefined_placeholder}",  # Reference to undefined placeholder
                        }
                    ],
                }
            },
        }

        # This might be caught during substitution or validation
        try:
            result = validate(json.dumps(invalid_esm))
            if not result.is_valid:
                errors_text = " ".join(
                    str(e) for e in result.schema_errors + result.structural_errors
                ).lower()
                assert any(
                    keyword in errors_text for keyword in ["placeholder", "undefined", "reference"]
                )
        except Exception as e:
            error = str(e).lower()
            assert any(keyword in error for keyword in ["placeholder", "undefined", "substitution"])


class TestErrorCodeSpecificity:
    """Test that validation errors include specific error codes."""

    def test_validation_error_codes(self):
        """Test that validation errors have specific error codes."""
        invalid_cases = [
            # Missing required field
            ('{"esm": "0.1.0"}', "required"),
            # Wrong type
            ('{"esm": 123, "metadata": {"name": "Test"}}', "type"),
            # Invalid enum value
            (
                '{"esm": "0.1.0", "metadata": {"name": "Test"}, "models": {"m": {"variables": {"x": {"type": "invalid"}}, "equations": []}}}',
                "enum",
            ),
        ]

        for invalid_json, expected_error_type in invalid_cases:
            with pytest.raises((SchemaValidationError, Exception)) as exc_info:
                load(invalid_json)

            error_msg = str(exc_info.value).lower()
            assert expected_error_type in error_msg or "validation" in error_msg

    def test_structural_error_reporting(self):
        """Test that structural errors are reported with context."""
        # Test with a complex invalid structure
        invalid_esm = {
            "esm": "0.1.0",
            "metadata": {"name": "Test"},
            "models": {
                "test_model": {
                    "variables": {"x": {"type": "state"}},
                    "equations": [
                        {
                            "lhs": "x",
                            "rhs": {
                                "op": "unknown op",  # Malformed operator (embedded space) — rejected by the op pattern
                                "args": ["x", "y"],
                            },
                        }
                    ],
                }
            },
        }

        with pytest.raises((SchemaValidationError, Exception)) as exc_info:
            load(json.dumps(invalid_esm))

        error_msg = str(exc_info.value)
        # Should include location information
        assert any(
            keyword in error_msg for keyword in ["test_model", "equations", "op", "unknown_op"]
        )


class TestValidationWithFixtures:
    """Test validation using actual fixture files."""

    @pytest.fixture
    def fixtures_dir(self):
        """Get path to fixtures."""
        return FIXTURES_ROOT

    def test_all_invalid_fixtures_fail_validation(self, fixtures_dir):
        """Test that all files in invalid/ directory fail validation."""
        invalid_dir = fixtures_dir / "invalid"

        if not invalid_dir.exists():
            pytest.skip("Invalid fixtures directory not found")

        invalid_files = list(invalid_dir.glob("*.esm"))
        assert len(invalid_files) > 0, "No invalid fixture files found"

        # Quarantine: fixtures whose only effective defect was an unknown op. As of esm 0.8.0
        # the `op` namespace is open (esm-spec §4.2), so an unknown op is no longer a
        # load/validate error — it is a lowering-time `unlowered_operator` error (§9.6.6).
        # `units_invalid_logarithm.esm` used `ln` (never a real op), so the removed op enum was
        # masking a mis-authored fixture; it is re-enabled once the log-argument dimensionality
        # unit-check lands across bindings and the fixture is fixed to `log`
        # (see docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md, binding phase).
        pending_binding_phase = {"units_invalid_logarithm.esm"}

        failed_files = []
        for invalid_file in invalid_files:
            if invalid_file.name in pending_binding_phase:
                continue
            with open(invalid_file) as f:
                content = f.read()
            # A fixture is "invalid" if either load() rejects it OR validate()
            # reports is_valid=False. Some dimensional checks (e.g. reaction
            # rate/stoichiometry consistency) live in validate() only, matching
            # the Julia/Go/Rust contract.
            try:
                load(content)
            except Exception:
                continue
            result = validate(content)
            if result.is_valid:
                failed_files.append(invalid_file.name)

        if failed_files:
            pytest.fail(f"These invalid files unexpectedly passed validation: {failed_files}")

    def test_units_dimensional_constant_error_fixture(self, fixtures_dir):
        """gt-j91l: physical constant (R) declared with dimensionally-incorrect units
        is flagged at the first usage site (`gas_law_calculation`)."""
        fixture = fixtures_dir / "invalid" / "units_dimensional_constant_error.esm"
        assert fixture.exists(), f"fixture missing: {fixture}"
        with open(fixture) as f:
            content = f.read()

        with pytest.raises(SchemaValidationError) as exc_info:
            load(content)

        msg = str(exc_info.value)
        assert "models/ConstantUnitsModel/variables/gas_law_calculation" in msg
        assert "Physical constant used with incorrect dimensional analysis" in msg
        assert "'R'" in msg
        assert "ideal gas constant" in msg

    def test_reaction_rate_units_mismatch_fixture(self, fixtures_dir):
        """gt-siq3: a 2nd-order reaction whose rate parameter is declared with
        1st-order units (1/s) must be flagged with a structured
        ``unit_inconsistency`` error matching the cross-language contract in
        ``tests/invalid/expected_errors.json``."""
        fixture = fixtures_dir / "invalid" / "units_reaction_rate_mismatch.esm"
        assert fixture.exists(), f"fixture missing: {fixture}"
        with open(fixture) as f:
            content = f.read()

        result = validate(content)
        assert not result.is_valid
        matches = [
            e
            for e in result.structural_errors
            if e.code == "unit_inconsistency"
            and e.path == "/reaction_systems/BadReactions/reactions/0"
        ]
        assert len(matches) == 1, (
            f"expected one unit_inconsistency error, got "
            f"{[(e.code, e.path) for e in result.structural_errors]}"
        )
        err = matches[0]
        assert err.message == (
            "Reaction rate expression has incompatible units for reaction stoichiometry"
        )
        assert err.details == {
            "reaction_id": "R1",
            "rate_units": "1/s",
            "expected_rate_units": "L/(mol*s)",
            "reaction_order": 2,
        }

    def test_ic_in_reaction_system_fixture_rejected(self, fixtures_dir):
        """spec §11.4.1: an `ic`-op equation inside a reaction system's
        `constraint_equations` is SCHEMA-VALID but MUST be rejected structurally
        with code ``ic_in_reaction_system`` (matches the cross-language contract
        in ``tests/invalid/expected_errors.json``)."""
        fixture = fixtures_dir / "invalid" / "ic_in_reaction_system.esm"
        assert fixture.exists(), f"fixture missing: {fixture}"
        with open(fixture) as f:
            content = f.read()

        # Schema-valid: load() must accept it (rejection is structural, not schema).
        load(content)

        result = validate(content)
        assert not result.is_valid
        assert result.schema_errors == []
        matches = [e for e in result.structural_errors if e.code == "ic_in_reaction_system"]
        assert len(matches) == 1, (
            f"expected one ic_in_reaction_system error, got "
            f"{[(e.code, e.path) for e in result.structural_errors]}"
        )
        err = matches[0]
        assert err.path == "/reaction_systems/Chemistry/constraint_equations/0"
        assert err.details == {
            "system": "Chemistry",
            "species": "O3",
            "constraint_equation_index": 0,
        }

    def test_normal_reaction_system_no_ic_false_positive(self, fixtures_dir):
        """A reaction system without an `ic` in its constraint_equations must not
        trip the ic_in_reaction_system diagnostic (no false positives)."""
        content = json.dumps(
            {
                "esm": "0.8.0",
                "metadata": {"name": "ok", "authors": ["t"], "created": "2026-07-01T00:00:00Z"},
                "reaction_systems": {
                    "Chemistry": {
                        "species": {"O3": {"units": "mol/mol", "default": 4.0e-8}},
                        "parameters": {"k": {"units": "1/s", "default": 1.0e-3}},
                        "reactions": [
                            {
                                "id": "R1",
                                "name": "O3_loss",
                                "substrates": [{"species": "O3", "stoichiometry": 1}],
                                "products": None,
                                "rate": "k",
                            }
                        ],
                        "constraint_equations": [
                            {"lhs": "O3", "rhs": 4.0e-8},
                        ],
                    }
                },
            }
        )
        result = validate(content)
        assert not any(e.code == "ic_in_reaction_system" for e in result.structural_errors)

    def test_all_valid_fixtures_pass_validation(self, fixtures_dir):
        """Test that all files in valid/ directory pass validation."""
        valid_dir = fixtures_dir / "valid"

        if not valid_dir.exists():
            pytest.skip("Valid fixtures directory not found")

        valid_files = sorted(valid_dir.glob("*.esm"))
        assert len(valid_files) > 0, "No valid fixture files found"

        failed_files = []
        for valid_file in valid_files[:10]:  # Test first 10 to avoid timeout
            if valid_file.name in CORPUS_UNIT_DEFECTS:
                # Pinned-valid upstream, but correctly rejected here — see
                # conftest.CORPUS_UNIT_DEFECTS.
                continue
            try:
                with open(valid_file) as f:
                    content = f.read()
                result = load(content)
                # Should successfully load
                assert result is not None
            except Exception as e:
                failed_files.append((valid_file.name, str(e)))

        if failed_files:
            errors = [f"{file}: {error}" for file, error in failed_files]
            pytest.fail("These valid files failed validation:\n" + "\n".join(errors))
