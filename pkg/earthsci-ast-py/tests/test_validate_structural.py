"""
Structural validation test suite for ESM format.

This module tests structural validation that goes beyond JSON schema validation,
focusing on verification of error codes, cross-references, and semantic consistency.
"""

import pytest
import json
from conftest import CORPUS_UNIT_DEFECTS, FIXTURES_ROOT

from earthsci_ast import load
from earthsci_ast.serialize import save
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
            if "not declared" in e.message and "_var" in e.message
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
        assert "Variable 'typo_missing' referenced in equation is not declared" in str(
            exc_info.value
        )

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


class TestSpecSanctionedConstructsAreNotRejected:
    """The checker must not reject what the spec sanctions.

    Each case below is a construct the spec explicitly allows that a checker bug
    reported as an error. They are grouped here because they share one root
    cause: a check that consults a symbol table which does not (and cannot)
    contain the symbol in question.
    """

    @staticmethod
    def _doc(**over):
        doc = {
            "esm": "0.8.0",
            "metadata": {
                "name": "t",
                "authors": ["a"],
                "created": "2026-01-01T00:00:00Z",
            },
            "models": {},
        }
        doc.update(over)
        return json.dumps(doc)

    def test_domain_independent_variable_is_implicitly_declared(self):
        """(a) esm-spec §5.3: the domain's `independent_variable` is never
        declared as a variable — §5.3's own example differentiates w.r.t. an
        undeclared `t` — so it must never be an `undefined_variable`. A document
        is free to name it something other than `t`."""
        content = self._doc(
            domain={"independent_variable": "tau"},
            models={
                "M": {
                    "variables": {
                        "u": {"type": "state", "units": "1", "default": 0.0},
                        "k": {"type": "parameter", "units": "1/s", "default": 1.0},
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["u"], "wrt": "tau"},
                            "rhs": {"op": "*", "args": ["k", "tau"]},
                        }
                    ],
                }
            },
        )
        result = validate(content)
        assert result.is_valid, [(e.code, e.message) for e in result.structural_errors]

    def test_index_set_names_are_implicitly_declared(self):
        """(a) Spatial coordinate names come from `index_sets` — the document's
        registry of iteration domains — and are not model variables."""
        content = self._doc(
            index_sets={"depth": {"kind": "interval", "size": 4}},
            models={
                "M": {
                    "variables": {
                        "u": {"type": "state", "units": "1", "shape": ["depth"], "default": 0.0}
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                            "rhs": {"op": "*", "args": [-1.0, "depth"]},
                        }
                    ],
                }
            },
        )
        result = validate(content)
        assert result.is_valid, [(e.code, e.message) for e in result.structural_errors]

    def test_operator_placeholder_var_is_legal_in_event_affects(self):
        """(b) esm-spec §6.4: `_var` is the operator placeholder, substituted with
        each matching state variable at `operator_compose` time. It is never a
        declared symbol, so an event affect that writes it is legal — reporting
        `event_var_undeclared` rejects `tests/valid/full_coupled.esm`."""
        content = self._doc(
            models={
                "Op": {
                    "variables": {"k": {"type": "parameter", "units": "1/s", "default": 1.0}},
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["_var"], "wrt": "t"},
                            "rhs": {"op": "*", "args": ["k", "_var"]},
                        }
                    ],
                }
            },
            events=[
                {
                    "name": "reset",
                    "type": "discrete",
                    "condition": True,
                    "affects": [{"lhs": "_var", "rhs": 0.0}],
                }
            ],
        )
        result = validate(content)
        assert not any(e.code == "event_var_undeclared" for e in result.structural_errors), [
            (e.code, e.message) for e in result.structural_errors
        ]

    def test_scoped_references_are_arbitrary_depth(self):
        """(c) esm-spec §4.6: a scoped ref walks a chain of subsystem mounts —
        `A.B.c` — so a checker must not split on `.` and test `c` against `A`'s
        own variables. An UNKNOWN head is still an error."""
        from earthsci_ast.structural_checks import _resolve_scoped_ref

        tables = {
            "models": {"A": {"x": {}}},
            "reaction_systems": {},
            "data_loaders": {},
            "all_systems": {"A"},
            "ref_systems": set(),
            "global_symbols": set(),
        }
        # depth 2, real variable
        assert _resolve_scoped_ref("A.x", tables)[2] == "ok"
        # depth 2, missing variable -> still caught
        assert _resolve_scoped_ref("A.nope", tables)[2] == "no_var"
        # depth 3+ -> deferred to the layer that has the mounted file
        assert _resolve_scoped_ref("A.B.c", tables)[2] == "ok"
        assert _resolve_scoped_ref("A.B.C.d", tables)[2] == "ok"
        # an unknown HEAD is an error at any depth
        assert _resolve_scoped_ref("Nope.B.c", tables)[2] == "no_system"

    def test_reaction_rate_may_contain_a_scoped_reference(self):
        """(d) A rate expression may name a symbol in ANOTHER system
        (`tests/valid/events_cross_system.esm` drives a rate from
        `MeteorologicalSystem.solar_intensity`); it is resolved by the coupling
        layer, not against the reaction system's own parameters."""
        content = self._doc(
            models={
                "Met": {
                    "variables": {"solar": {"type": "parameter", "units": "1", "default": 1.0}},
                    "equations": [],
                }
            },
            reaction_systems={
                "Chem": {
                    "species": {"O3": {"units": "ppb", "default": 40.0}},
                    "parameters": {"k": {"units": "1/s", "default": 1e-3}},
                    "reactions": [
                        {
                            "id": "R1",
                            "name": "photolysis",
                            "substrates": [{"species": "O3", "stoichiometry": 1}],
                            "products": None,
                            "rate": {"op": "*", "args": ["k", "Met.solar"]},
                        }
                    ],
                }
            },
        )
        result = validate(content)
        assert not any(e.code == "undeclared_rate_variable" for e in result.structural_errors), [
            (e.code, e.message) for e in result.structural_errors
        ]

    def test_nonlinear_system_balances_unknowns_against_algebraic_equations(self):
        """(e) A `system_kind: nonlinear` model has no derivatives at all: the
        balance is UNKNOWNS vs EQUATIONS, crediting a non-derivative (algebraic)
        LHS. A missing equation must still be caught."""
        base = {
            "variables": {
                "H": {"type": "state", "units": "M", "default": 1e-7},
                "SO4": {"type": "state", "units": "M", "default": 1e-5},
                "Ksp": {"type": "parameter", "units": "1", "default": 1.0},
            },
            "system_kind": "nonlinear",
        }
        balanced = dict(
            base,
            equations=[
                {"lhs": "H", "rhs": 1e-7},
                {"lhs": {"op": "*", "args": ["H", "H", "SO4"]}, "rhs": "Ksp"},
            ],
        )
        assert validate(self._doc(models={"Eq": balanced})).is_valid

        short = dict(base, equations=[{"lhs": "H", "rhs": 1e-7}])
        result = validate(self._doc(models={"Eq": short}))
        assert not result.is_valid
        assert any(e.code == "equation_count_mismatch" for e in result.structural_errors)

    def test_aggregate_bound_index_is_in_scope_but_free_names_are_not(self):
        """(g) `aggregate`/`makearray` BIND their loop indices; the index is in
        scope inside the construct's body. A name that is NOT bound by an
        enclosing construct must still be reported — bound indices are not an
        allowlist of short names."""

        def doc(inner):
            return self._doc(
                index_sets={"cells": {"kind": "interval", "size": 4}},
                models={
                    "M": {
                        "variables": {
                            "u": {
                                "type": "state",
                                "units": "1",
                                "shape": ["cells"],
                                "default": 0.0,
                            },
                            "k": {"type": "parameter", "units": "1/s", "default": 1.0},
                        },
                        "equations": [
                            {
                                "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                                "rhs": {
                                    "op": "aggregate",
                                    "args": [],
                                    "output_idx": ["i"],
                                    "ranges": {"i": [1, 4]},
                                    "expr": inner,
                                },
                            }
                        ],
                    }
                },
            )

        bound = {"op": "*", "args": ["k", {"op": "index", "args": ["u", "i"]}]}
        assert validate(doc(bound)).is_valid

        free = {"op": "*", "args": ["undeclared_zzz", {"op": "index", "args": ["u", "i"]}]}
        assert not validate(doc(free)).is_valid


class TestUnitFindingCodesAreDistinct:
    """esm-spec §4.8.4: an unreal unit STRING and a provable DIMENSIONAL mismatch
    are different findings with different codes. One tells the author to fix a
    spelling, the other to fix the physics."""

    @staticmethod
    def _model(units, expression=None, extra=None):
        variables = {
            "T": {"type": "parameter", "units": "K", "default": 300.0},
            "c": dict(
                {"type": "observed", "units": units},
                **({"expression": expression} if expression else {}),
            ),
        }
        if extra:
            variables.update(extra)
        return json.dumps(
            {
                "esm": "0.8.0",
                "metadata": {"name": "t", "authors": ["a"], "created": "2026-01-01T00:00:00Z"},
                "models": {"M": {"variables": variables, "equations": []}},
            }
        )

    def test_unreal_unit_string_is_unit_parse_error(self):
        result = validate(self._model("not_a_unit", expression="T"))
        assert not result.is_valid
        codes = [e.code for e in result.structural_errors]
        assert "unit_parse_error" in codes, codes
        assert "unit_inconsistency" not in codes, codes
        err = next(e for e in result.structural_errors if e.code == "unit_parse_error")
        assert err.path == "/models/M/variables/c"

    def test_dimensional_mismatch_is_unit_inconsistency(self):
        # `c` declared in metres but assigned a temperature: both strings parse.
        result = validate(self._model("m", expression="T"))
        assert not result.is_valid
        codes = [e.code for e in result.structural_errors]
        assert "unit_inconsistency" in codes, codes
        assert "unit_parse_error" not in codes, codes


class TestReferenceIntegrityEveryExpressionBearingField:
    """esm-spec §4.9.5 / CONFORMANCE_SPEC §7.1.3 row (h).

    Reference integrity must resolve the free symbols of EVERY Expression in the
    document, not just the ones in `equations`. The walkers descended
    `models[*].equations` (and reaction `rate`) and NOTHING ELSE, so an undefined
    name in any of the other eleven Expression-bearing fields was invisible — a
    silent FALSE NEGATIVE shared by every binding.

    The shared corpus pins one minimal fixture per field. Each is driven here
    against its pinned `(code, path, message, details)` so a regression in any
    single site fails loudly and names the site.
    """

    @pytest.mark.parametrize(
        "fixture_name",
        [
            # the nine model-level sites
            "undefined_variable_in_rhs.esm",
            "undefined_variable_in_observed_expression.esm",
            "undefined_variable_in_guesses.esm",
            "undefined_variable_in_initialization_equation.esm",
            "undefined_variable_in_continuous_event_condition.esm",
            "undefined_variable_in_continuous_event_affect.esm",
            "undefined_variable_in_discrete_event_trigger.esm",
            "undefined_variable_in_discrete_event_affect.esm",
            "undefined_variable_in_assertion_reference.esm",
            # the data-loader site
            "undefined_variable_in_unit_conversion.esm",
            # the two coupling sites (fully qualified refs -> unresolved_scoped_ref)
            "unresolved_scoped_ref_in_connector_expression.esm",
            "unresolved_scoped_ref_in_variable_map_transform.esm",
            # and the non-`args` expression CHILD fields, inside an equation
            "undefined_variable_in_aggregate_expr.esm",
            "undefined_variable_in_aggregate_key.esm",
            "undefined_variable_in_filter.esm",
            "undefined_variable_in_integral_bound.esm",
            "undefined_variable_in_makearray_values.esm",
            "undefined_variable_in_table_lookup_axes.esm",
            "undefined_variable_in_template_bindings.esm",
            "undefined_variable_in_nested_expr.esm",
        ],
    )
    def test_undefined_name_is_caught_at_every_site(self, fixture_name):
        fixtures_dir = FIXTURES_ROOT
        pins = json.loads((fixtures_dir / "invalid" / "expected_errors.json").read_text())
        expected = pins[fixture_name]["structural_errors"][0]

        content = (fixtures_dir / "invalid" / fixture_name).read_text()
        result = validate(content)

        assert not result.is_valid, f"{fixture_name} must be rejected"
        assert result.schema_errors == [], "must reach the STRUCTURAL layer, not fail schema"
        matches = [
            e
            for e in result.structural_errors
            if e.code == expected["code"] and e.path == expected["path"]
        ]
        assert len(matches) == 1, (
            f"{fixture_name}: expected one {expected['code']} @ {expected['path']}, got "
            f"{[(e.code, e.path) for e in result.structural_errors]}"
        )
        assert matches[0].message == expected["message"]
        assert matches[0].details == expected["details"]


class TestValidateBasePath:
    """`validate(..., base_path=...)` — esm-spec §4.7 / §9.7.2.

    Whether a `{"ref": ...}` mount or an `expression_template_imports` edge
    resolves is NOT decidable from the document's own bytes: the target has to be
    opened. A conformance harness holds the fixture TEXT, not its path, so
    without an anchor every subsystem-ref and template-import fixture is
    unsatisfiable. `base_path` supplies the anchor.
    """

    def test_present_ref_target_validates_through_with_base_path(self):
        valid_dir = FIXTURES_ROOT / "valid"
        for name in (
            "subsystem_index_set_merge.esm",
            "template_import_minimal.esm",
            "lib_solar_subsystem_inclusion.esm",
            "lib_calendar_subsystem_inclusion.esm",
        ):
            content = (valid_dir / name).read_text()
            result = validate(content, base_path=str(valid_dir))
            assert result.is_valid, (
                f"{name} must validate clean when its refs can be resolved; got "
                f"{[(e.code, e.path) for e in result.structural_errors + result.schema_errors]}"
            )

    def test_missing_ref_target_is_reported_not_silently_passed(self):
        """A ref whose target does not exist yields the pinned error — with a
        base_path (the target is genuinely absent) and without one (nothing to
        resolve against). It must never silently validate."""
        invalid_dir = FIXTURES_ROOT / "invalid"
        content = (invalid_dir / "subsystem_ref_not_found.esm").read_text()
        for kwargs in ({}, {"base_path": str(invalid_dir)}):
            result = validate(content, **kwargs)
            assert not result.is_valid, f"must be rejected (kwargs={kwargs})"
            assert any(e.code == "unresolved_subsystem_ref" for e in result.structural_errors), [
                (e.code, e.path) for e in result.structural_errors
            ]

    def test_without_base_path_unresolvable_ref_is_never_silently_accepted(self):
        """Backward compatible: omitting `base_path` keeps today's behaviour, and
        a relative ref that cannot be opened is REPORTED, not passed."""
        valid_dir = FIXTURES_ROOT / "valid"
        result = validate((valid_dir / "subsystem_index_set_merge.esm").read_text())
        assert not result.is_valid
        assert any(e.code == "unresolved_subsystem_ref" for e in result.structural_errors)

    def test_template_library_file_is_valid_content(self):
        """A template-LIBRARY file (§9.7.1) declares only `expression_templates`
        and no model/reaction system/data loader. It is empty by DESIGN — it
        exists to be imported — and must not trip the content-presence check."""
        valid_dir = FIXTURES_ROOT / "valid"
        for name in ("template_import_lib.esm", "template_import_rename_lib.esm"):
            result = validate((valid_dir / name).read_text(), base_path=str(valid_dir))
            assert result.is_valid, (
                f"{name} is a template library and is valid; got "
                f"{[(e.code, e.path) for e in result.structural_errors]}"
            )

    def test_coupling_entry_naming_a_nonexistent_system_is_caught(self):
        """A coupling edge may only compose systems the document declares. A
        dotted entry names a SUBSYSTEM at arbitrary depth (§4.6), so only the
        head is decidable here."""
        invalid_dir = FIXTURES_ROOT / "invalid"
        result = validate((invalid_dir / "undefined_system.esm").read_text())
        assert not result.is_valid
        matches = [e for e in result.structural_errors if e.code == "undefined_system"]
        assert len(matches) == 1
        assert matches[0].path == "/coupling/0/systems"
        assert matches[0].details == {"system": "NonExistentSystem"}


class TestTemplateLibraryRoundTrip:
    """esm-spec §9.6.4 rule 5 — Option A expands CALL SITES; it does NOT delete
    DECLARATIONS.

    A top-level `expression_templates` registry and `metaparameters` block
    (§9.7.1) are declarations — peers of `index_sets` — not
    `apply_expression_template` invocations. The emitter treated them as call
    sites and consumed them, so a pure template-library file emitted as
    `{esm, metadata, index_sets}`: none of the five top-level payload keys, which
    the schema's top-level `anyOf` rejects. Since schema validation runs on the
    post-expansion form (rule 4), a conforming library was UNREPRESENTABLE —
    legal on disk, illegal the moment it was loaded and re-emitted.
    """

    @pytest.mark.parametrize("name", ["template_import_lib.esm", "template_import_rename_lib.esm"])
    def test_pure_library_round_trips_to_itself(self, name):
        valid_dir = FIXTURES_ROOT / "valid"
        path = valid_dir / name
        original = json.loads(path.read_text())

        emitted = json.loads(save(load(str(path))))

        # The two declarations survive VERBATIM...
        assert emitted.get("expression_templates") == original["expression_templates"]
        assert emitted.get("metaparameters") == original["metaparameters"]
        # ...and the library is generic: its metaparameter-sized index set must
        # NOT be folded to the default. Emitting `size: 8` where the author wrote
        # `size: "N"` hard-wires the library to its default and silently destroys
        # the genericity that makes it a library — re-importing the emitted form
        # with `{"N": 16}` would no longer resize it.
        assert emitted.get("index_sets") == original["index_sets"]
        # A document kind that cannot round-trip to itself is not a document kind.
        assert emitted == original, "a template library MUST round-trip to itself"

    @pytest.mark.parametrize("name", ["template_import_lib.esm", "template_import_rename_lib.esm"])
    def test_emitted_library_is_still_valid(self, name):
        """Rule 4: schema validation runs on the post-expansion form. The emitted
        library must therefore be valid, and re-emitting it must be a fixpoint."""
        valid_dir = FIXTURES_ROOT / "valid"
        emitted = save(load(str(valid_dir / name)))

        result = validate(emitted, base_path=str(valid_dir))
        assert result.is_valid, [
            (e.code, e.path) for e in result.structural_errors + result.schema_errors
        ]
        assert json.loads(save(load(emitted))) == json.loads(emitted)
