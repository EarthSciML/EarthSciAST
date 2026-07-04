"""
Tests for ESM Format structural validation functionality.
"""

using Test
using EarthSciSerialization

@testset "Structural Validation" begin

    @testset "StructuralError struct" begin
        error = EarthSciSerialization.StructuralError("models.test.equations", "Test error message", "missing_equation")
        @test error.path == "models.test.equations"
        @test error.message == "Test error message"
        @test error.error_type == "missing_equation"
    end

    @testset "ValidationResult struct" begin
        schema_errors = [EarthSciSerialization.SchemaError("/", "Schema error", "required")]
        structural_errors = [EarthSciSerialization.StructuralError("models.test", "Structural error", "missing_equation")]
        unit_warnings = ["Unit warning"]

        # Test constructor
        result = EarthSciSerialization.ValidationResult(schema_errors, structural_errors, unit_warnings=unit_warnings)
        @test result.is_valid == false
        @test length(result.schema_errors) == 1
        @test length(result.structural_errors) == 1
        @test length(result.unit_warnings) == 1

        # Test valid case
        result_valid = EarthSciSerialization.ValidationResult(EarthSciSerialization.SchemaError[], EarthSciSerialization.StructuralError[])
        @test result_valid.is_valid == true
        @test isempty(result_valid.schema_errors)
        @test isempty(result_valid.structural_errors)
        @test isempty(result_valid.unit_warnings)
    end

    @testset "validate_structural function" begin
        metadata = EarthSciSerialization.Metadata("test-model")

        @testset "Missing equation for state variable" begin
            # Create a model with missing equation for state variable
            variables = Dict(
                "x" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=1.0),
                "y" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=2.0),
                "k" => EarthSciSerialization.ModelVariable(EarthSciSerialization.ParameterVariable, default=0.5)
            )

            equations = [
                EarthSciSerialization.Equation(EarthSciSerialization.OpExpr("D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x")], wrt="t"), EarthSciSerialization.VarExpr("y"))
                # Missing equation for state variable y
            ]

            model = EarthSciSerialization.Model(variables, equations)
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciSerialization.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "models.test_model.equations"
            @test occursin("State variable 'y' has no defining equation", errors[1].message)
            @test errors[1].error_type == "missing_equation"
        end

        @testset "Reaction system with undefined species" begin
            species = [EarthSciSerialization.Species("A"), EarthSciSerialization.Species("B")]
            reactions = [
                EarthSciSerialization.Reaction("rxn1", [EarthSciSerialization.StoichiometryEntry("A", 1)], [EarthSciSerialization.StoichiometryEntry("C", 1)], EarthSciSerialization.VarExpr("k1"))  # C not defined
            ]
            rs = EarthSciSerialization.ReactionSystem(species, reactions)
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, reaction_systems=Dict("test_reactions" => rs))

            errors = EarthSciSerialization.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "reaction_systems.test_reactions.reactions[1].products"
            @test occursin("Species 'C' not declared", errors[1].message)
            @test errors[1].error_type == "undefined_species"
        end

        @testset "Reaction with invalid stoichiometry" begin
            # StoichiometryEntry enforces finite, positive stoichiometry at
            # construction (gt-1e96), so negative values are rejected before
            # validate_structural ever sees them.
            @test_throws ArgumentError EarthSciSerialization.StoichiometryEntry("A", -1)
        end

        @testset "Null-null reaction" begin
            species = [EarthSciSerialization.Species("A")]
            reactions = [
                EarthSciSerialization.Reaction("rxn1", nothing, nothing, EarthSciSerialization.VarExpr("k1"))  # No reactants or products
            ]
            rs = EarthSciSerialization.ReactionSystem(species, reactions)
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, reaction_systems=Dict("test_reactions" => rs))

            errors = EarthSciSerialization.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "reaction_systems.test_reactions.reactions[1]"
            @test occursin("null-null reaction", errors[1].message)
            @test errors[1].error_type == "null_reaction"
        end

        @testset "Event with undefined affect variable" begin
            variables = Dict(
                "x" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=1.0)
            )
            equations = [
                EarthSciSerialization.Equation(EarthSciSerialization.OpExpr("D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x")], wrt="t"), EarthSciSerialization.NumExpr(1.0))
            ]
            events = [
                EarthSciSerialization.ContinuousEvent(
                    EarthSciSerialization.Expr[EarthSciSerialization.OpExpr("-", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x"), EarthSciSerialization.NumExpr(10.0)])],
                    [EarthSciSerialization.AffectEquation("undefined_var", EarthSciSerialization.NumExpr(0.0))]
                )
            ]
            model = EarthSciSerialization.Model(variables, equations, continuous_events=events)
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciSerialization.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "models.test_model.continuous_events[1].affects[1]"
            @test occursin("Affect target variable 'undefined_var' not declared", errors[1].message)
            @test errors[1].error_type == "undefined_affect_variable"
        end

        @testset "Valid model - no errors" begin
            variables = Dict(
                "x" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=1.0),
                "k" => EarthSciSerialization.ModelVariable(EarthSciSerialization.ParameterVariable, default=0.5)
            )
            equations = [
                EarthSciSerialization.Equation(EarthSciSerialization.OpExpr("D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x")], wrt="t"), EarthSciSerialization.VarExpr("k"))
            ]
            model = EarthSciSerialization.Model(variables, equations)
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciSerialization.validate_structural(esm_file)
            @test isempty(errors)
        end
    end

    @testset "validate function - complete validation" begin
        metadata = EarthSciSerialization.Metadata("test-model")

        @testset "Valid file" begin
            variables = Dict(
                "x" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=1.0)
            )
            equations = [
                EarthSciSerialization.Equation(EarthSciSerialization.OpExpr("D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x")], wrt="t"), EarthSciSerialization.NumExpr(1.0))
            ]
            model = EarthSciSerialization.Model(variables, equations)
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            result = EarthSciSerialization.validate(esm_file)
            # Note: Schema validation might fail due to simplified conversion in validate function
            @test result isa EarthSciSerialization.ValidationResult
            @test isempty(result.structural_errors)
            @test isempty(result.unit_warnings)
        end

        @testset "File with structural errors" begin
            variables = Dict(
                "x" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=1.0),
                "y" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=2.0)
            )
            equations = [
                EarthSciSerialization.Equation(EarthSciSerialization.OpExpr("D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x")], wrt="t"), EarthSciSerialization.NumExpr(1.0))
                # Missing equation for y
            ]
            model = EarthSciSerialization.Model(variables, equations)
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            result = EarthSciSerialization.validate(esm_file)
            @test result isa EarthSciSerialization.ValidationResult
            @test length(result.structural_errors) == 1
            @test result.is_valid == false  # Should be false due to structural errors
        end
    end

    @testset "validate_coupling_references function" begin
        metadata = EarthSciSerialization.Metadata("test-model")

        @testset "CouplingOperatorCompose validation" begin
            model = EarthSciSerialization.Model(Dict("x" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=1.0)),
                                  [EarthSciSerialization.Equation(EarthSciSerialization.OpExpr("D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x")], wrt="t"), EarthSciSerialization.NumExpr(1.0))])
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            # Valid system reference
            coupling = EarthSciSerialization.CouplingOperatorCompose(["test_model"])
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling, "coupling[1]")
            @test isempty(errors)

            # Invalid system reference
            coupling_bad = EarthSciSerialization.CouplingOperatorCompose(["nonexistent_system"])
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling_bad, "coupling[1]")
            @test length(errors) == 1
            @test errors[1].path == "coupling[1].systems[1]"
            @test occursin("nonexistent_system", errors[1].message)
            @test errors[1].error_type == "undefined_system"
        end

        @testset "CouplingOperatorApply validation" begin
            operator = EarthSciSerialization.Operator("test_op", ["x"])
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, operators=Dict("test_op" => operator))

            # Valid operator reference
            coupling = EarthSciSerialization.CouplingOperatorApply("test_op")
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling, "coupling[1]")
            @test isempty(errors)

            # Invalid operator reference
            coupling_bad = EarthSciSerialization.CouplingOperatorApply("nonexistent_op")
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling_bad, "coupling[1]")
            @test length(errors) == 1
            @test errors[1].path == "coupling[1].operator"
            @test occursin("nonexistent_op", errors[1].message)
            @test errors[1].error_type == "undefined_operator"
        end

        @testset "CouplingCallback validation" begin
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata)

            # Valid callback
            coupling = EarthSciSerialization.CouplingCallback("my_callback")
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling, "coupling[1]")
            @test isempty(errors)

            # Empty callback ID
            coupling_bad = EarthSciSerialization.CouplingCallback("")
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling_bad, "coupling[1]")
            @test length(errors) == 1
            @test errors[1].path == "coupling[1].callback_id"
            @test occursin("empty", errors[1].message)
            @test errors[1].error_type == "empty_callback_id"
        end

        @testset "CouplingVariableMap validation" begin
            model = EarthSciSerialization.Model(Dict("x" => EarthSciSerialization.ModelVariable(EarthSciSerialization.StateVariable, default=1.0)),
                                  [EarthSciSerialization.Equation(EarthSciSerialization.OpExpr("D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("x")], wrt="t"), EarthSciSerialization.NumExpr(1.0))])
            esm_file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            # Valid variable mapping
            coupling = EarthSciSerialization.CouplingVariableMap("test_model.x", "test_model.x", "identity")
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling, "coupling[1]")
            @test isempty(errors)

            # Invalid 'from' reference
            coupling_bad_from = EarthSciSerialization.CouplingVariableMap("invalid.ref", "test_model.x", "identity")
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling_bad_from, "coupling[1]")
            @test length(errors) == 1
            @test errors[1].path == "coupling[1].from"
            @test occursin("invalid.ref", errors[1].message)
            @test errors[1].error_type == "unresolved_reference"

            # Invalid 'to' reference
            coupling_bad_to = EarthSciSerialization.CouplingVariableMap("test_model.x", "invalid.ref", "identity")
            errors = EarthSciSerialization.validate_coupling_references(esm_file, coupling_bad_to, "coupling[1]")
            @test length(errors) == 1
            @test errors[1].path == "coupling[1].to"
            @test occursin("invalid.ref", errors[1].message)
            @test errors[1].error_type == "unresolved_reference"
        end
    end

    @testset "Reaction rate units: mass-action dimensional check" begin
        metadata = EarthSciSerialization.Metadata("test-rxn-units")

        @testset "Second-order reaction with 1/s rate constant is rejected" begin
            # A + B -> C with concentrations in mol/L but rate constant in 1/s
            # (should be L/(mol*s)). Mirrors tests/invalid/units_reaction_rate_mismatch.esm.
            species = [
                EarthSciSerialization.Species("A"; units="mol/L", default=1.0),
                EarthSciSerialization.Species("B"; units="mol/L", default=1.0),
                EarthSciSerialization.Species("C"; units="mol/L", default=0.0),
            ]
            parameters = [EarthSciSerialization.Parameter("k", 0.1; units="1/s")]
            reactions = [
                EarthSciSerialization.Reaction(
                    "R1",
                    [EarthSciSerialization.StoichiometryEntry("A", 1), EarthSciSerialization.StoichiometryEntry("B", 1)],
                    [EarthSciSerialization.StoichiometryEntry("C", 1)],
                    EarthSciSerialization.VarExpr("k"),
                ),
            ]
            rs = EarthSciSerialization.ReactionSystem(species, reactions; parameters=parameters)
            errors = EarthSciSerialization.validate_reaction_rate_units(rs, "/reaction_systems/Bad")
            @test length(errors) == 1
            @test errors[1].error_type == "unit_inconsistency"
            @test errors[1].path == "/reaction_systems/Bad/reactions/0"
        end

        @testset "Correctly-dimensioned second-order rate constant passes" begin
            species = [
                EarthSciSerialization.Species("A"; units="mol/L", default=1.0),
                EarthSciSerialization.Species("B"; units="mol/L", default=1.0),
                EarthSciSerialization.Species("C"; units="mol/L", default=0.0),
            ]
            parameters = [EarthSciSerialization.Parameter("k", 0.1; units="L/(mol*s)")]
            reactions = [
                EarthSciSerialization.Reaction(
                    "R1",
                    [EarthSciSerialization.StoichiometryEntry("A", 1), EarthSciSerialization.StoichiometryEntry("B", 1)],
                    [EarthSciSerialization.StoichiometryEntry("C", 1)],
                    EarthSciSerialization.VarExpr("k"),
                ),
            ]
            rs = EarthSciSerialization.ReactionSystem(species, reactions; parameters=parameters)
            errors = EarthSciSerialization.validate_reaction_rate_units(rs, "/reaction_systems/Good")
            @test isempty(errors)
        end

        @testset "Invalid fixture units_reaction_rate_mismatch.esm is rejected" begin
            fixture_path = joinpath(@__DIR__, "..", "..", "..", "tests", "invalid", "units_reaction_rate_mismatch.esm")
            if isfile(fixture_path)
                esm_data = EarthSciSerialization.load(fixture_path)
                result = EarthSciSerialization.validate(esm_data)
                @test !result.is_valid
                @test any(e -> e.error_type == "unit_inconsistency", result.structural_errors)
            else
                @warn "Fixture not found: $fixture_path"
                @test_broken false
            end
        end

        # units_dimensional_constant_error.esm declares the ideal gas constant 'R'
        # with units 'kcal/mol' — missing the temperature dimension (canonical is
        # 'J/(mol*K)'). Must be rejected as a structural unit_inconsistency error
        # at the usage site `gas_law_calculation` (mirrors Python's
        # parse._check_physical_constant_units, gt-3tgv).
        @testset "Invalid fixture units_dimensional_constant_error.esm is rejected" begin
            fixture_path = joinpath(@__DIR__, "..", "..", "..", "tests", "invalid", "units_dimensional_constant_error.esm")
            if isfile(fixture_path)
                esm_data = EarthSciSerialization.load(fixture_path)
                result = EarthSciSerialization.validate(esm_data)
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
            else
                @warn "Fixture not found: $fixture_path"
                @test_broken false
            end
        end

        # Scale-aware conversion factor check (gt-l76y). Observed variable
        # declared in Pa is assigned '50000 * p_atm' where p_atm is in atm;
        # dimensions match but the numeric scale factor should be 101325 Pa/atm.
        # Mirrors Python's parse._check_conversion_factor_consistency.
        @testset "Conversion factor mismatch flagged" begin
            variables = Dict{String,EarthSciSerialization.ModelVariable}(
                "p_atm" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ParameterVariable;
                    units="atm", default=1.0),
                "converted_pressure" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ObservedVariable;
                    units="Pa",
                    expression=EarthSciSerialization.OpExpr("*",
                        EarthSciSerialization.Expr[
                            EarthSciSerialization.NumExpr(50000.0),
                            EarthSciSerialization.VarExpr("p_atm"),
                        ])),
            )
            model = EarthSciSerialization.Model(variables, EarthSciSerialization.Equation[])
            errors = EarthSciSerialization.validate_conversion_factor_consistency(model, "/models/M")
            @test length(errors) == 1
            @test errors[1].error_type == "unit_inconsistency"
            @test errors[1].path == "/models/M/variables/converted_pressure"
            @test occursin("declared_factor=50000", errors[1].message)
            @test occursin("expected_factor=101325", errors[1].message)
        end

        @testset "Correct conversion factor passes" begin
            variables = Dict{String,EarthSciSerialization.ModelVariable}(
                "p_atm" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ParameterVariable;
                    units="atm", default=1.0),
                "converted_pressure" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ObservedVariable;
                    units="Pa",
                    expression=EarthSciSerialization.OpExpr("*",
                        EarthSciSerialization.Expr[
                            EarthSciSerialization.NumExpr(101325.0),
                            EarthSciSerialization.VarExpr("p_atm"),
                        ])),
            )
            model = EarthSciSerialization.Model(variables, EarthSciSerialization.Equation[])
            errors = EarthSciSerialization.validate_conversion_factor_consistency(model, "/models/M")
            @test isempty(errors)
        end

        @testset "Affine conversion (degC -> K) is skipped" begin
            # 0 °C = 273.15 K, so the conversion is affine — must not be flagged.
            variables = Dict{String,EarthSciSerialization.ModelVariable}(
                "T_C" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ParameterVariable;
                    units="°C", default=0.0),
                "T_K" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ObservedVariable;
                    units="K",
                    expression=EarthSciSerialization.OpExpr("*",
                        EarthSciSerialization.Expr[
                            EarthSciSerialization.NumExpr(1.0),
                            EarthSciSerialization.VarExpr("T_C"),
                        ])),
            )
            model = EarthSciSerialization.Model(variables, EarthSciSerialization.Equation[])
            errors = EarthSciSerialization.validate_conversion_factor_consistency(model, "/models/M")
            @test isempty(errors)
        end

        @testset "Dimensional mismatch is not a conversion-factor error" begin
            # atm vs m — dimensionally incompatible; other checks handle this,
            # this check silently skips.
            variables = Dict{String,EarthSciSerialization.ModelVariable}(
                "p_atm" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ParameterVariable;
                    units="atm", default=1.0),
                "x" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.ObservedVariable;
                    units="m",
                    expression=EarthSciSerialization.OpExpr("*",
                        EarthSciSerialization.Expr[
                            EarthSciSerialization.NumExpr(2.0),
                            EarthSciSerialization.VarExpr("p_atm"),
                        ])),
            )
            model = EarthSciSerialization.Model(variables, EarthSciSerialization.Equation[])
            errors = EarthSciSerialization.validate_conversion_factor_consistency(model, "/models/M")
            @test isempty(errors)
        end

        @testset "Invalid fixture units_conversion_factor_error.esm is rejected" begin
            fixture_path = joinpath(@__DIR__, "..", "..", "..", "tests", "invalid",
                                    "units_conversion_factor_error.esm")
            if isfile(fixture_path)
                esm_data = EarthSciSerialization.load(fixture_path)
                result = EarthSciSerialization.validate(esm_data)
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
            else
                @warn "Fixture not found: $fixture_path"
                @test_broken false
            end
        end
    end

    @testset "Gradient operator spatial-coordinate units" begin
        # Since the v0.8.0 Domain.spatial removal, a grad/div/laplacian node's
        # `dim` resolves against the enclosing model's declared variables (the
        # physical coordinate is ordinary declared data, esm-spec domain
        # section). Declared WITHOUT units → unit_inconsistency; declared WITH
        # units → fine; undeclared → legacy metre fallback, never flagged.
        metadata = EarthSciSerialization.Metadata("test-grad-units")

        grad_model(x_var) = begin
            variables = Dict(
                "c" => EarthSciSerialization.ModelVariable(
                    EarthSciSerialization.StateVariable, default=0.0, units="mol/m^3"),
            )
            x_var !== nothing && (variables["x"] = x_var)
            equations = [
                EarthSciSerialization.Equation(
                    EarthSciSerialization.OpExpr(
                        "D", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("c")]; wrt="t"),
                    EarthSciSerialization.OpExpr(
                        "grad", EarthSciSerialization.Expr[EarthSciSerialization.VarExpr("c")]; dim="x")),
            ]
            EarthSciSerialization.Model(variables, equations)
        end

        @testset "Coordinate declared without units is rejected" begin
            model = grad_model(EarthSciSerialization.ModelVariable(
                EarthSciSerialization.ParameterVariable, default=0.0))
            file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("M" => model))
            errors = EarthSciSerialization.validate_model_gradient_units(file, model, "/models/M")
            @test length(errors) == 1
            @test errors[1].error_type == "unit_inconsistency"
            @test errors[1].path == "/models/M/equations/0"
            @test occursin("coordinate 'x' has no declared units", errors[1].message)
            @test occursin("variable 'c'", errors[1].message)
        end

        @testset "Coordinate declared with units passes" begin
            model = grad_model(EarthSciSerialization.ModelVariable(
                EarthSciSerialization.ParameterVariable, default=0.0, units="m"))
            file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("M" => model))
            @test isempty(EarthSciSerialization.validate_model_gradient_units(file, model, "/models/M"))
        end

        @testset "Undeclared dim is left to the legacy fallback" begin
            # `x` is not declared as a variable — an index-set axis whose
            # physical coordinate is bound elsewhere (e.g. a discretization
            # rewrite rule, esm-spec §9.6.8) must not be flagged.
            model = grad_model(nothing)
            file = EarthSciSerialization.EsmFile("0.1.0", metadata, models=Dict("M" => model))
            @test isempty(EarthSciSerialization.validate_model_gradient_units(file, model, "/models/M"))
        end

        @testset "Invalid fixture units_gradient_operator_mismatch.esm surfaces the grad error" begin
            fixture_path = joinpath(@__DIR__, "..", "..", "..", "tests", "invalid", "units_gradient_operator_mismatch.esm")
            if isfile(fixture_path)
                esm_data = EarthSciSerialization.load(fixture_path)
                result = EarthSciSerialization.validate(esm_data)
                @test !result.is_valid
                matching = filter(e -> e.error_type == "unit_inconsistency" &&
                                       e.path == "/models/SpatialModel/equations/0" &&
                                       occursin("coordinate 'x' has no declared units", e.message),
                                  result.structural_errors)
                @test length(matching) == 1
            else
                @warn "Fixture not found: $fixture_path"
                @test_broken false
            end
        end
    end

end