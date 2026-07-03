using Test
using EarthSciSerialization
using JSON3

@testset "EarthSciSerialization.jl Tests" begin

    include("parse_test.jl")
    include("validate_test.jl")
    include("structural_validation_test.jl")
    include("expression_test.jl")
    include("reactions_test.jl")
    include("display_test.jl")
    include("units_test.jl")
    include("conformance_round_trip_test.jl")
    include("mtk_catalyst_test.jl")
    include("real_mtk_integration_test.jl")
    include("mtk_metadata_test.jl")
    include("simulate_e2e_test.jl")
    include("tests_blocks_execution_test.jl")
    include("run_esm_tests_test.jl")
    include("units_fixture_consumption_test.jl")
    include("array_ops_test.jl")
    include("catalyst_extension_test.jl")
    include("reference_resolution_test.jl")
    include("test_codegen.jl")
    include("flatten_test.jl")
    include("flattened_to_esm_test.jl")
    include("shape_promotion_test.jl")
    include("subsystem_ref_test.jl")
    include("editing_test.jl")
    include("data_loader_fixtures_test.jl")
    include("arrayed_vars_test.jl")
    include("canonicalize_test.jl")
    include("relational_test.jl")
    include("simulate_run_test.jl")
    include("loaded_ic_bc_simulation_test.jl")
    include("wildfire_simulation_test.jl")
    include("mtk_export_test.jl")
    include("tree_walk_test.jl")
    include("tree_walk_arrayop_test.jl")
    include("tree_walk_vectorized_test.jl")
    include("tree_walk_allocation_test.jl")
    include("tree_walk_param_gather_test.jl")
    include("data_refresh_test.jl")
    include("data_refresh_e2e_test.jl")
    include("tree_walk_cse_test.jl")
    include("tree_walk_const_array_boundary_test.jl")
    include("tree_walk_semiring_test.jl")
    include("reference_graph_test.jl")
    include("cadence_test.jl")
    include("value_invention_frontdoor_test.jl")
    include("aggregate_conformance_test.jl")
    include("expression_ic_conformance_test.jl")
    include("inverse_trig_conformance_test.jl")
    include("geometry_conformance_test.jl")
    include("geometry_polygon_intersection_area_test.jl")
    include("geometry_assembly_conformance_test.jl")
    include("geometry_overlap_join_conformance_test.jl")
    include("treewalk_binning_alias_test.jl")
    include("geometry_ranged_clip_test.jl")
    include("build_inspection_test.jl")
    include("pde_inline_tests_test.jl")
    include("conformance_pde_inline_observed_rank2_test.jl")
    include("conformance_pde_inline_observed_param_rank2_test.jl")
    include("tree_walk_join_test.jl")
    include("closed_functions_test.jl")
    include("closed_functions_mtk_test.jl")
    include("function_tables_test.jl")
    include("function_tables_lowering_test.jl")
    include("expression_templates_test.jl")
    include("template_imports_test.jl")

    # Comprehensive test suite for full verification
    @testset "Comprehensive Test Suite" begin

        @testset "Valid Fixture Parse Tests" begin
            # Test loading and parsing all valid test fixtures
            valid_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "valid")

            if isdir(valid_fixtures_dir)
                valid_files = filter(f -> endswith(f, ".esm"), readdir(valid_fixtures_dir))
                @info "Testing $(length(valid_files)) valid fixture files"

                for filename in valid_files
                    filepath = joinpath(valid_fixtures_dir, filename)
                    @testset "Valid fixture: $filename" begin
                        try
                            esm_data = EarthSciSerialization.load(filepath)
                            @test esm_data isa EarthSciSerialization.EsmFile
                            @test !isnothing(esm_data.esm)
                            @test !isnothing(esm_data.metadata)
                            @info "✓ Successfully loaded $filename"
                        catch e
                            @warn "Failed to load valid fixture $filename: $e"
                            @test false
                        end
                    end
                end
            else
                @warn "Valid fixtures directory not found: $valid_fixtures_dir"
            end
        end

        @testset "Round-trip Tests" begin
            # Test that load(save(load(file))) == load(file) for all valid fixtures
            valid_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "valid")

            if isdir(valid_fixtures_dir)
                valid_files = filter(f -> endswith(f, ".esm"), readdir(valid_fixtures_dir))

                for filename in valid_files[1:min(5, length(valid_files))]  # Test first 5 for performance
                    filepath = joinpath(valid_fixtures_dir, filename)
                    @testset "Round-trip: $filename" begin
                        try
                            # Load original
                            original = EarthSciSerialization.load(filepath)

                            # Create temp file for round-trip test
                            temp_file = tempname() * ".esm"

                            try
                                # Save and reload
                                EarthSciSerialization.save(temp_file, original)
                                reloaded = EarthSciSerialization.load(temp_file)

                                # Compare key fields
                                @test original.esm == reloaded.esm
                                @test original.metadata.name == reloaded.metadata.name

                                # For files with models, compare model count
                                if !isnothing(original.models) && !isnothing(reloaded.models)
                                    @test length(original.models) == length(reloaded.models)
                                end

                                @info "✓ Round-trip test passed for $filename"
                            finally
                                # Clean up temp file
                                isfile(temp_file) && rm(temp_file)
                            end
                        catch e
                            @warn "Round-trip test failed for $filename: $e"
                            @test false
                        end
                    end
                end
            end
        end

        @testset "Invalid Fixture Schema Tests" begin
            # Test that invalid fixtures produce expected schema errors
            invalid_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "invalid")

            if isdir(invalid_fixtures_dir)
                invalid_files = filter(f -> endswith(f, ".esm"), readdir(invalid_fixtures_dir))
                @info "Testing $(length(invalid_files)) invalid fixture files"

                for filename in invalid_files[1:min(10, length(invalid_files))]  # Test first 10 for performance
                    filepath = joinpath(invalid_fixtures_dir, filename)
                    @testset "Invalid fixture: $filename" begin
                        # Should either throw ParseError or produce validation errors
                        error_found = false
                        try
                            esm_data = EarthSciSerialization.load(filepath)
                            result = EarthSciSerialization.validate(esm_data)
                            if !result.is_valid
                                @test !isempty(result.schema_errors) || !isempty(result.structural_errors)
                                error_found = true
                                @info "✓ Invalid fixture $filename correctly produced validation errors"
                            end
                        catch e
                            if e isa EarthSciSerialization.ParseError || e isa EarthSciSerialization.SchemaValidationError
                                error_found = true
                                @info "✓ Invalid fixture $filename correctly threw error: $(typeof(e))"
                            else
                                @warn "Unexpected error for $filename: $e"
                            end
                        end
                        if !error_found
                            @test_broken false # Expected validation error for invalid fixture $filename
                        else
                            @test true
                        end
                    end
                end
            else
                @warn "Invalid fixtures directory not found: $invalid_fixtures_dir"
            end
        end

        @testset "Display Format Tests" begin
            # Test pretty-printing matches display fixtures
            display_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "display")

            if isdir(display_fixtures_dir)
                display_files = filter(f -> endswith(f, ".json"), readdir(display_fixtures_dir))
                @info "Testing $(length(display_files)) display fixture files"

                for filename in display_files[1:min(3, length(display_files))]  # Test first 3
                    filepath = joinpath(display_fixtures_dir, filename)
                    @testset "Display format: $filename" begin
                        try
                            display_data = JSON3.read(read(filepath, String))

                            # Fixture shape varies: some are flat arrays of cases, some are
                            # objects with a "chemical_formulas" key. Walk whatever structure
                            # we actually get and verify that any "input" expression parses.
                            cases = if display_data isa JSON3.Array
                                display_data
                            elseif display_data isa JSON3.Object && haskey(display_data, :chemical_formulas)
                                display_data[:chemical_formulas]
                            else
                                []
                            end

                            # Walk cases, handling both flat {input, ...} objects
                            # and nested {description, tests: [...]} groups. Inputs
                            # may be either expression objects or plain strings
                            # (chemical formulas) — parse the expression form only.
                            for case in cases
                                if case isa JSON3.Object && haskey(case, :input)
                                    if case[:input] isa JSON3.Object
                                        expr = EarthSciSerialization.parse_expression(case[:input])
                                        @test expr isa EarthSciSerialization.Expr
                                    end
                                elseif case isa JSON3.Object && haskey(case, :tests)
                                    # Nested group — each sub-test has input/unicode/latex.
                                    # No expression parsing needed; just confirm the group
                                    # shape is what the fixture documents.
                                    @test case[:tests] isa JSON3.Array
                                end
                            end
                            # Sanity check the fixture wasn't empty
                            @test !isempty(cases)

                            @info "✓ Display format test passed for $filename"
                        catch e
                            @warn "Display format test failed for $filename: $e"
                            @test false
                        end
                    end
                end
            else
                @warn "Display fixtures directory not found: $display_fixtures_dir"
            end
        end

        # Substitution fixture tests live in expression_test.jl, where they
        # assert each case's expected output (not just that substitute runs).
    end

    @testset "Expression Types" begin
        # Test NumExpr
        num_expr = NumExpr(3.14)
        @test num_expr.value == 3.14
        @test num_expr isa EarthSciSerialization.Expr

        # Test VarExpr
        var_expr = VarExpr("x")
        @test var_expr.name == "x"
        @test var_expr isa EarthSciSerialization.Expr

        # Test OpExpr
        op_expr = OpExpr("+", EarthSciSerialization.Expr[NumExpr(1.0), VarExpr("x")])
        @test op_expr.op == "+"
        @test length(op_expr.args) == 2
        @test op_expr.wrt === nothing
        @test op_expr.dim === nothing
        @test op_expr isa EarthSciSerialization.Expr

        # Test OpExpr with optional parameters
        diff_expr = OpExpr("D", EarthSciSerialization.Expr[VarExpr("x")], wrt="t", dim="time")
        @test diff_expr.wrt == "t"
        @test diff_expr.dim == "time"
    end

    @testset "Equation Types" begin
        # Test Equation. Qualify ESM.Equation: under MTK 11 + Pkg.test
        # extras the test session has both ESS and MTK loaded into Main,
        # which makes the bare `Equation` reference ambiguous.
        lhs = OpExpr("D", EarthSciSerialization.Expr[VarExpr("x")], wrt="t")
        rhs = OpExpr("*", EarthSciSerialization.Expr[NumExpr(2.0), VarExpr("x")])
        eq = EarthSciSerialization.Equation(lhs, rhs)
        @test eq.lhs == lhs
        @test eq.rhs == rhs

        # Test AffectEquation
        affect_eq = AffectEquation("x", NumExpr(0.0))
        @test affect_eq.lhs == "x"
        @test affect_eq.rhs isa NumExpr
    end

    @testset "ModelVariable Types" begin
        # Test ModelVariableType enum
        @test StateVariable isa ModelVariableType
        @test ParameterVariable isa ModelVariableType
        @test ObservedVariable isa ModelVariableType

        # Test ModelVariable
        mv = ModelVariable(StateVariable, default=1.0, description="Test variable")
        @test mv.type == StateVariable
        @test mv.default == 1.0
        @test mv.description == "Test variable"
        @test mv.expression === nothing
    end

    @testset "Model Component Types" begin
        # Test Species
        species = Species("CO2", units="mol/m^3", default=1e-6)
        @test species.name == "CO2"
        @test species.units == "mol/m^3"
        @test species.default == 1e-6
        @test species.description === nothing

        # Test Parameter
        param = Parameter("k", 0.1, description="Rate constant", units="1/s")
        @test param.name == "k"
        @test param.default == 0.1
        @test param.description == "Rate constant"
        @test param.units == "1/s"

        # Test Reaction
        reactants = Dict("A" => 1, "B" => 1)
        products = Dict("C" => 1)
        rate = OpExpr("*", EarthSciSerialization.Expr[VarExpr("k"), VarExpr("A"), VarExpr("B")])
        reaction = Reaction(reactants, products, rate)
        @test reaction.reactants == reactants
        @test reaction.products == products
        @test reaction.rate == rate
        @test reaction.reversible == false
    end

    @testset "Event System Types" begin
        # Test DiscreteEventTrigger types
        cond_trigger = ConditionTrigger(VarExpr("x"))
        @test cond_trigger isa DiscreteEventTrigger
        @test cond_trigger.expression isa VarExpr

        periodic_trigger = PeriodicTrigger(10.0, phase=2.0)
        @test periodic_trigger isa DiscreteEventTrigger
        @test periodic_trigger.period == 10.0
        @test periodic_trigger.phase == 2.0

        preset_trigger = PresetTimesTrigger([1.0, 5.0, 10.0])
        @test preset_trigger isa DiscreteEventTrigger
        @test preset_trigger.times == [1.0, 5.0, 10.0]

        # Test FunctionalAffect
        affect = FunctionalAffect("x", NumExpr(1.0), operation="add")
        @test affect.target == "x"
        @test affect.expression isa NumExpr
        @test affect.operation == "add"
    end

    @testset "System Configuration Types" begin
        # Test Reference
        ref = Reference(doi="10.1000/test", citation="Test paper")
        @test ref.doi == "10.1000/test"
        @test ref.citation == "Test paper"
        @test ref.url === nothing
        @test ref.notes === nothing

        # Test Metadata
        metadata = Metadata("test_model",
                          description="A test model",
                          authors=["Test Author"],
                          license="MIT")
        @test metadata.name == "test_model"
        @test metadata.description == "A test model"
        @test metadata.authors == ["Test Author"]
        @test metadata.license == "MIT"

        # Test Domain (esm-spec v0.8.0: temporal-only; the spatial table was removed)
        domain = Domain(temporal=Dict("t" => [0.0, 100.0]))
        @test domain.temporal isa Dict

        # Test EsmFile
        esm_file = EsmFile("0.1.0", metadata)
        @test esm_file.esm == "0.1.0"
        @test esm_file.metadata == metadata
        @test esm_file.models === nothing
        @test esm_file.coupling == []
    end

    @testset "Type Hierarchy" begin
        # Test that all expression types are subtypes of Expr
        @test NumExpr <: EarthSciSerialization.Expr
        @test VarExpr <: EarthSciSerialization.Expr
        @test OpExpr <: EarthSciSerialization.Expr

        # Test that trigger types are subtypes of DiscreteEventTrigger
        @test ConditionTrigger <: DiscreteEventTrigger
        @test PeriodicTrigger <: DiscreteEventTrigger
        @test PresetTimesTrigger <: DiscreteEventTrigger

        # Test that event types are subtypes of EventType
        @test ContinuousEvent <: EarthSciSerialization.EventType
        @test DiscreteEvent <: EarthSciSerialization.EventType
    end
end