"""
Tests for ESM Format structural validation functionality.
"""

using Test
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT + _require_fixture

@testset "Structural Validation" begin

    @testset "StructuralError struct" begin
        error = EarthSciAST.StructuralError("/models/test/equations", "Test error message", "missing_equation")
        @test error.path == "/models/test/equations"
        @test error.message == "Test error message"
        @test error.error_type == "missing_equation"
    end

    @testset "ValidationResult struct" begin
        schema_errors = [EarthSciAST.SchemaError("/", "Schema error", "required")]
        structural_errors = [EarthSciAST.StructuralError("models.test", "Structural error", "missing_equation")]
        unit_warnings = ["Unit warning"]

        # Test constructor
        result = EarthSciAST.ValidationResult(schema_errors, structural_errors, unit_warnings=unit_warnings)
        @test result.is_valid == false
        @test length(result.schema_errors) == 1
        @test length(result.structural_errors) == 1
        @test length(result.unit_warnings) == 1

        # Test valid case
        result_valid = EarthSciAST.ValidationResult(EarthSciAST.SchemaError[], EarthSciAST.StructuralError[])
        @test result_valid.is_valid == true
        @test isempty(result_valid.schema_errors)
        @test isempty(result_valid.structural_errors)
        @test isempty(result_valid.unit_warnings)
    end

    @testset "validate_structural function" begin
        metadata = EarthSciAST.Metadata("test-model")

        @testset "Missing equation for state variable" begin
            # Create a model with missing equation for state variable
            variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0),
                "y" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=2.0),
                "k" => EarthSciAST.ModelVariable(EarthSciAST.ParameterVariable, default=0.5)
            )

            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.VarExpr("y"))
                # Missing equation for state variable y
            ]

            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciAST.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "/models/test_model/equations"
            @test occursin("State variable 'y' has no defining equation", errors[1].message)
            @test errors[1].error_type == "missing_equation"
        end

        @testset "Reaction system with undefined species" begin
            species = [EarthSciAST.Species("A"), EarthSciAST.Species("B")]
            reactions = [
                EarthSciAST.Reaction("rxn1", [EarthSciAST.StoichiometryEntry("A", 1)], [EarthSciAST.StoichiometryEntry("C", 1)], EarthSciAST.VarExpr("k1"))  # C not defined
            ]
            rs = EarthSciAST.ReactionSystem(species, reactions)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, reaction_systems=Dict("test_reactions" => rs))

            errors = EarthSciAST.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "/reaction_systems/test_reactions/reactions/0/products"
            @test occursin("Species 'C' not declared", errors[1].message)
            @test errors[1].error_type == "undefined_species"
        end

        @testset "Reaction with invalid stoichiometry" begin
            # StoichiometryEntry enforces finite, positive stoichiometry at
            # construction (gt-1e96), so negative values are rejected before
            # validate_structural ever sees them.
            @test_throws ArgumentError EarthSciAST.StoichiometryEntry("A", -1)
        end

        @testset "Null-null reaction" begin
            species = [EarthSciAST.Species("A")]
            reactions = [
                EarthSciAST.Reaction("rxn1", nothing, nothing, EarthSciAST.VarExpr("k1"))  # No reactants or products
            ]
            rs = EarthSciAST.ReactionSystem(species, reactions)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, reaction_systems=Dict("test_reactions" => rs))

            errors = EarthSciAST.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "/reaction_systems/test_reactions/reactions/0"
            @test occursin("null-null reaction", errors[1].message)
            @test errors[1].error_type == "null_reaction"
        end

        @testset "Event with undefined affect variable" begin
            variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))
            ]
            events = [
                EarthSciAST.ContinuousEvent(
                    EarthSciAST.ASTExpr[EarthSciAST.OpExpr("-", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x"), EarthSciAST.NumExpr(10.0)])],
                    [EarthSciAST.AffectEquation("undefined_var", EarthSciAST.NumExpr(0.0))]
                )
            ]
            model = EarthSciAST.Model(variables, equations, continuous_events=events)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciAST.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "/models/test_model/continuous_events/0/affects/0"
            @test occursin("Affect target variable 'undefined_var' not declared", errors[1].message)
            @test errors[1].error_type == "undefined_affect_variable"
        end

        @testset "Valid model - no errors" begin
            variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0),
                "k" => EarthSciAST.ModelVariable(EarthSciAST.ParameterVariable, default=0.5)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.VarExpr("k"))
            ]
            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciAST.validate_structural(esm_file)
            @test isempty(errors)
        end
    end

    @testset "validate function - complete validation" begin
        metadata = EarthSciAST.Metadata("test-model")

        @testset "Valid file" begin
            variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))
            ]
            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            result = EarthSciAST.validate(esm_file)
            # Note: Schema validation might fail due to simplified conversion in validate function
            @test result isa EarthSciAST.ValidationResult
            @test isempty(result.structural_errors)
            @test isempty(result.unit_warnings)
        end

        @testset "File with structural errors" begin
            variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0),
                "y" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=2.0)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))
                # Missing equation for y
            ]
            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            result = EarthSciAST.validate(esm_file)
            @test result isa EarthSciAST.ValidationResult
            @test length(result.structural_errors) == 1
            @test result.is_valid == false  # Should be false due to structural errors
        end
    end

    @testset "validate_coupling_references function" begin
        metadata = EarthSciAST.Metadata("test-model")

        @testset "CouplingOperatorCompose validation" begin
            model = EarthSciAST.Model(Dict("x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0)),
                                  [EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))])
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            # Valid system reference
            coupling = EarthSciAST.CouplingOperatorCompose(["test_model"])
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling, "/coupling/0")
            @test isempty(errors)

            # Invalid system reference
            coupling_bad = EarthSciAST.CouplingOperatorCompose(["nonexistent_system"])
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling_bad, "/coupling/0")
            @test length(errors) == 1
            @test errors[1].path == "/coupling/0/systems/0"
            @test occursin("nonexistent_system", errors[1].message)
            @test errors[1].error_type == "undefined_system"
        end

        @testset "CouplingOperatorApply validation" begin
            # The top-level `operators` block was removed (esm-spec v0.3.0 §9
            # closure), so an operator reference can never resolve — it is
            # always flagged undefined.
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata)

            coupling_bad = EarthSciAST.CouplingOperatorApply("nonexistent_op")
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling_bad, "/coupling/0")
            @test length(errors) == 1
            @test errors[1].path == "/coupling/0/operator"
            @test occursin("nonexistent_op", errors[1].message)
            @test errors[1].error_type == "undefined_operator"
        end

        @testset "CouplingCallback validation" begin
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata)

            # Valid callback
            coupling = EarthSciAST.CouplingCallback("my_callback")
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling, "/coupling/0")
            @test isempty(errors)

            # Empty callback ID
            coupling_bad = EarthSciAST.CouplingCallback("")
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling_bad, "/coupling/0")
            @test length(errors) == 1
            @test errors[1].path == "/coupling/0/callback_id"
            @test occursin("empty", errors[1].message)
            @test errors[1].error_type == "empty_callback_id"
        end

        @testset "CouplingVariableMap validation" begin
            model = EarthSciAST.Model(Dict("x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0)),
                                  [EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))])
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            # Valid variable mapping
            coupling = EarthSciAST.CouplingVariableMap("test_model.x", "test_model.x", "identity")
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling, "/coupling/0")
            @test isempty(errors)

            # Invalid 'from' reference
            coupling_bad_from = EarthSciAST.CouplingVariableMap("invalid.ref", "test_model.x", "identity")
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling_bad_from, "/coupling/0")
            @test length(errors) == 1
            @test errors[1].path == "/coupling/0/from"
            @test occursin("invalid.ref", errors[1].message)
            @test errors[1].error_type == "unresolved_reference"

            # Invalid 'to' reference
            coupling_bad_to = EarthSciAST.CouplingVariableMap("test_model.x", "invalid.ref", "identity")
            errors = EarthSciAST.validate_coupling_references(esm_file, coupling_bad_to, "/coupling/0")
            @test length(errors) == 1
            @test errors[1].path == "/coupling/0/to"
            @test occursin("invalid.ref", errors[1].message)
            @test errors[1].error_type == "unresolved_reference"
        end
    end

    @testset "Reaction rate units: mass-action dimensional check" begin
        metadata = EarthSciAST.Metadata("test-rxn-units")

        @testset "Second-order reaction with 1/s rate constant is rejected" begin
            # A + B -> C with concentrations in mol/L but rate constant in 1/s
            # (should be L/(mol*s)). Mirrors tests/invalid/units_reaction_rate_mismatch.esm.
            species = [
                EarthSciAST.Species("A"; units="mol/L", default=1.0),
                EarthSciAST.Species("B"; units="mol/L", default=1.0),
                EarthSciAST.Species("C"; units="mol/L", default=0.0),
            ]
            parameters = [EarthSciAST.Parameter("k", 0.1; units="1/s")]
            reactions = [
                EarthSciAST.Reaction(
                    "R1",
                    [EarthSciAST.StoichiometryEntry("A", 1), EarthSciAST.StoichiometryEntry("B", 1)],
                    [EarthSciAST.StoichiometryEntry("C", 1)],
                    EarthSciAST.VarExpr("k"),
                ),
            ]
            rs = EarthSciAST.ReactionSystem(species, reactions; parameters=parameters)
            errors = EarthSciAST.validate_reaction_rate_units(rs, "/reaction_systems/Bad")
            @test length(errors) == 1
            @test errors[1].error_type == "unit_inconsistency"
            @test errors[1].path == "/reaction_systems/Bad/reactions/0"
        end

        @testset "Correctly-dimensioned second-order rate constant passes" begin
            species = [
                EarthSciAST.Species("A"; units="mol/L", default=1.0),
                EarthSciAST.Species("B"; units="mol/L", default=1.0),
                EarthSciAST.Species("C"; units="mol/L", default=0.0),
            ]
            parameters = [EarthSciAST.Parameter("k", 0.1; units="L/(mol*s)")]
            reactions = [
                EarthSciAST.Reaction(
                    "R1",
                    [EarthSciAST.StoichiometryEntry("A", 1), EarthSciAST.StoichiometryEntry("B", 1)],
                    [EarthSciAST.StoichiometryEntry("C", 1)],
                    EarthSciAST.VarExpr("k"),
                ),
            ]
            rs = EarthSciAST.ReactionSystem(species, reactions; parameters=parameters)
            errors = EarthSciAST.validate_reaction_rate_units(rs, "/reaction_systems/Good")
            @test isempty(errors)
        end

        @testset "Invalid fixture units_reaction_rate_mismatch.esm is rejected" begin
            fixture_path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "units_reaction_rate_mismatch.esm")
            if _require_fixture(fixture_path)
                esm_data = EarthSciAST.load(fixture_path)
                result = EarthSciAST.validate(esm_data)
                @test !result.is_valid
                @test any(e -> e.error_type == "unit_inconsistency", result.structural_errors)
                # Unit findings are mirrored into unit_warnings (TS-binding parity)
                @test !isempty(result.unit_warnings)
                @test length(result.unit_warnings) ==
                      count(e -> e.error_type == "unit_inconsistency", result.structural_errors)
            end
        end

        # units_dimensional_constant_error.esm declares the ideal gas constant 'R'
        # with units 'kcal/mol' — missing the temperature dimension (canonical is
        # 'J/(mol*K)'). Must be rejected as a structural unit_inconsistency error
        # at the usage site `gas_law_calculation` (mirrors Python's
        # parse._check_physical_constant_units, gt-3tgv).
        @testset "Invalid fixture units_dimensional_constant_error.esm is rejected" begin
            fixture_path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "units_dimensional_constant_error.esm")
            if _require_fixture(fixture_path)
                esm_data = EarthSciAST.load(fixture_path)
                result = EarthSciAST.validate(esm_data)
                @test !result.is_valid
                matching = filter(e -> e.error_type == "unit_inconsistency" &&
                                       occursin("Physical constant used with incorrect dimensional analysis", e.message),
                                  result.structural_errors)
                @test length(matching) >= 1
                if !isempty(matching)
                    err = matching[1]
                    @test err.path == "/models/ConstantUnitsModel/variables/gas_law_calculation"
                    @test occursin("R", err.message)
                    @test occursin("kcal/mol", err.message)
                    @test occursin("J/(mol*K)", err.message)
                end
            end
        end

        # Scale-aware conversion factor check (gt-l76y). Observed variable
        # declared in Pa is assigned '50000 * p_atm' where p_atm is in atm;
        # dimensions match but the numeric scale factor should be 101325 Pa/atm.
        # Mirrors Python's parse._check_conversion_factor_consistency.
        @testset "Conversion factor mismatch flagged" begin
            variables = Dict{String,EarthSciAST.ModelVariable}(
                "p_atm" => EarthSciAST.ModelVariable(
                    EarthSciAST.ParameterVariable;
                    units="atm", default=1.0),
                "converted_pressure" => EarthSciAST.ModelVariable(
                    EarthSciAST.ObservedVariable;
                    units="Pa",
                    expression=EarthSciAST.OpExpr("*",
                        EarthSciAST.ASTExpr[
                            EarthSciAST.NumExpr(50000.0),
                            EarthSciAST.VarExpr("p_atm"),
                        ])),
            )
            model = EarthSciAST.Model(variables, EarthSciAST.Equation[])
            errors = EarthSciAST.validate_conversion_factor_consistency(model, "/models/M")
            @test length(errors) == 1
            @test errors[1].error_type == "unit_inconsistency"
            @test errors[1].path == "/models/M/variables/converted_pressure"
            @test occursin("declared_factor=50000", errors[1].message)
            @test occursin("expected_factor=101325", errors[1].message)
        end

        @testset "Correct conversion factor passes" begin
            variables = Dict{String,EarthSciAST.ModelVariable}(
                "p_atm" => EarthSciAST.ModelVariable(
                    EarthSciAST.ParameterVariable;
                    units="atm", default=1.0),
                "converted_pressure" => EarthSciAST.ModelVariable(
                    EarthSciAST.ObservedVariable;
                    units="Pa",
                    expression=EarthSciAST.OpExpr("*",
                        EarthSciAST.ASTExpr[
                            EarthSciAST.NumExpr(101325.0),
                            EarthSciAST.VarExpr("p_atm"),
                        ])),
            )
            model = EarthSciAST.Model(variables, EarthSciAST.Equation[])
            errors = EarthSciAST.validate_conversion_factor_consistency(model, "/models/M")
            @test isempty(errors)
        end

        @testset "Affine conversion (degC -> K) is skipped" begin
            # 0 °C = 273.15 K, so the conversion is affine — must not be flagged.
            variables = Dict{String,EarthSciAST.ModelVariable}(
                "T_C" => EarthSciAST.ModelVariable(
                    EarthSciAST.ParameterVariable;
                    units="°C", default=0.0),
                "T_K" => EarthSciAST.ModelVariable(
                    EarthSciAST.ObservedVariable;
                    units="K",
                    expression=EarthSciAST.OpExpr("*",
                        EarthSciAST.ASTExpr[
                            EarthSciAST.NumExpr(1.0),
                            EarthSciAST.VarExpr("T_C"),
                        ])),
            )
            model = EarthSciAST.Model(variables, EarthSciAST.Equation[])
            errors = EarthSciAST.validate_conversion_factor_consistency(model, "/models/M")
            @test isempty(errors)
        end

        @testset "Dimensional mismatch is not a conversion-factor error" begin
            # atm vs m — dimensionally incompatible; other checks handle this,
            # this check silently skips.
            variables = Dict{String,EarthSciAST.ModelVariable}(
                "p_atm" => EarthSciAST.ModelVariable(
                    EarthSciAST.ParameterVariable;
                    units="atm", default=1.0),
                "x" => EarthSciAST.ModelVariable(
                    EarthSciAST.ObservedVariable;
                    units="m",
                    expression=EarthSciAST.OpExpr("*",
                        EarthSciAST.ASTExpr[
                            EarthSciAST.NumExpr(2.0),
                            EarthSciAST.VarExpr("p_atm"),
                        ])),
            )
            model = EarthSciAST.Model(variables, EarthSciAST.Equation[])
            errors = EarthSciAST.validate_conversion_factor_consistency(model, "/models/M")
            @test isempty(errors)
        end

        @testset "Invalid fixture units_conversion_factor_error.esm is rejected" begin
            fixture_path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid",
                                    "units_conversion_factor_error.esm")
            if _require_fixture(fixture_path)
                esm_data = EarthSciAST.load(fixture_path)
                result = EarthSciAST.validate(esm_data)
                @test !result.is_valid
                matching = filter(e -> e.error_type == "unit_inconsistency" &&
                                       occursin("Unit conversion factor is incorrect", e.message),
                                  result.structural_errors)
                @test length(matching) >= 1
                if !isempty(matching)
                    err = matching[1]
                    @test err.path == "/models/BadUnitsModel/variables/converted_pressure"
                    @test occursin("declared_factor=50000", err.message)
                    @test occursin("expected_factor=101325", err.message)
                end
            end
        end
    end

    @testset "Gradient operator spatial-coordinate units" begin
        # Since the v0.8.0 Domain.spatial removal, a grad/div/laplacian node's
        # `dim` resolves against the enclosing model's declared variables (the
        # physical coordinate is ordinary declared data, esm-spec domain
        # section). Declared WITHOUT units → unit_inconsistency; declared WITH
        # units → fine; undeclared → legacy metre fallback, never flagged.
        metadata = EarthSciAST.Metadata("test-grad-units")

        grad_model(x_var) = begin
            variables = Dict(
                "c" => EarthSciAST.ModelVariable(
                    EarthSciAST.StateVariable, default=0.0, units="mol/m^3"),
            )
            x_var !== nothing && (variables["x"] = x_var)
            equations = [
                EarthSciAST.Equation(
                    EarthSciAST.OpExpr(
                        "D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("c")]; wrt="t"),
                    EarthSciAST.OpExpr(
                        "grad", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("c")]; dim="x")),
            ]
            EarthSciAST.Model(variables, equations)
        end

        @testset "Coordinate declared without units is rejected" begin
            model = grad_model(EarthSciAST.ModelVariable(
                EarthSciAST.ParameterVariable, default=0.0))
            file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("M" => model))
            errors = EarthSciAST.validate_model_gradient_units(file, model, "/models/M")
            @test length(errors) == 1
            @test errors[1].error_type == "unit_inconsistency"
            @test errors[1].path == "/models/M/equations/0"
            @test occursin("coordinate 'x' has no declared units", errors[1].message)
            @test occursin("variable 'c'", errors[1].message)
        end

        @testset "Coordinate declared with units passes" begin
            model = grad_model(EarthSciAST.ModelVariable(
                EarthSciAST.ParameterVariable, default=0.0, units="m"))
            file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("M" => model))
            @test isempty(EarthSciAST.validate_model_gradient_units(file, model, "/models/M"))
        end

        @testset "Undeclared dim is left to the legacy fallback" begin
            # `x` is not declared as a variable — an index-set axis whose
            # physical coordinate is bound elsewhere (e.g. a discretization
            # rewrite rule, esm-spec §9.6.8) must not be flagged.
            model = grad_model(nothing)
            file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("M" => model))
            @test isempty(EarthSciAST.validate_model_gradient_units(file, model, "/models/M"))
        end

        @testset "Invalid fixture units_gradient_operator_mismatch.esm surfaces the grad error" begin
            fixture_path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "units_gradient_operator_mismatch.esm")
            if _require_fixture(fixture_path)
                esm_data = EarthSciAST.load(fixture_path)
                result = EarthSciAST.validate(esm_data)
                @test !result.is_valid
                matching = filter(e -> e.error_type == "unit_inconsistency" &&
                                       e.path == "/models/SpatialModel/equations/0" &&
                                       occursin("coordinate 'x' has no declared units", e.message),
                                  result.structural_errors)
                @test length(matching) == 1
            end
        end
    end

    @testset "Undefined bare variables in equations (undefined_variable)" begin
        # Invalid fixture: an undefined variable hidden in an aggregate `expr`
        # body (a non-`args` child) must be rejected. Mirrors Rust/Go/TS/Python.
        @testset "Invalid fixture undefined_variable_in_aggregate_expr.esm is rejected" begin
            fixture_path = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid",
                                    "undefined_variable_in_aggregate_expr.esm")
            if _require_fixture(fixture_path)
                esm_data = EarthSciAST.load(fixture_path)
                result = EarthSciAST.validate(esm_data)
                @test !result.is_valid
                undefs = filter(e -> e.error_type == "undefined_variable", result.structural_errors)
                @test !isempty(undefs)
                @test any(e -> occursin("undefined_xyz", e.message), undefs)
            end
        end

        # No false positive: an aggregate whose body references a bound loop
        # index (`i`, introduced by `ranges`) and a declared variable must NOT
        # flag the bound index. Built via the typed API so it is schema-free.
        @testset "Bound loop index in an aggregate is not flagged" begin
            variables = Dict{String,EarthSciAST.ModelVariable}(
                "q" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable),
            )
            agg = EarthSciAST.OpExpr("aggregate",
                EarthSciAST.ASTExpr[EarthSciAST.VarExpr("q")];
                output_idx=Any["i"],
                ranges=Dict{String,Any}("i" => Dict{String,Any}("from" => "cells")),
                expr_body=EarthSciAST.OpExpr("*", EarthSciAST.ASTExpr[
                    EarthSciAST.NumExpr(-0.25),
                    EarthSciAST.OpExpr("index", EarthSciAST.ASTExpr[
                        EarthSciAST.VarExpr("q"), EarthSciAST.VarExpr("i")]),
                ]))
            eq = EarthSciAST.Equation(
                EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("q")]; wrt="t"),
                agg)
            model = EarthSciAST.Model(variables, EarthSciAST.Equation[eq])
            file = EarthSciAST.EsmFile("0.8.0", EarthSciAST.Metadata("AggBoundIdx"),
                                       models=Dict("M" => model))
            errors = EarthSciAST.validate_model_references(file, model, "/models/M")
            @test !any(e -> e.error_type == "undefined_variable", errors)
        end

        # Negative control on the same shape: swap the reduced array for an
        # undeclared name and confirm it IS flagged (so the check above is not
        # vacuous — the bound index `i` is still excused).
        @testset "Undeclared name inside an aggregate body is flagged" begin
            variables = Dict{String,EarthSciAST.ModelVariable}(
                "q" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable),
            )
            agg = EarthSciAST.OpExpr("aggregate",
                EarthSciAST.ASTExpr[EarthSciAST.VarExpr("q")];
                output_idx=Any["i"],
                ranges=Dict{String,Any}("i" => Dict{String,Any}("from" => "cells")),
                expr_body=EarthSciAST.OpExpr("*", EarthSciAST.ASTExpr[
                    EarthSciAST.NumExpr(-0.25),
                    EarthSciAST.OpExpr("index", EarthSciAST.ASTExpr[
                        EarthSciAST.VarExpr("undefined_zzz"), EarthSciAST.VarExpr("i")]),
                ]))
            eq = EarthSciAST.Equation(
                EarthSciAST.OpExpr("D", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("q")]; wrt="t"),
                agg)
            model = EarthSciAST.Model(variables, EarthSciAST.Equation[eq])
            file = EarthSciAST.EsmFile("0.8.0", EarthSciAST.Metadata("AggBoundIdxBad"),
                                       models=Dict("M" => model))
            errors = EarthSciAST.validate_model_references(file, model, "/models/M")
            undefs = filter(e -> e.error_type == "undefined_variable", errors)
            @test !isempty(undefs)
            @test any(e -> occursin("undefined_zzz", e.message), undefs)
        end
    end

end