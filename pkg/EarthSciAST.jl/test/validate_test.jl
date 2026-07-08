"""
Tests for ESM Format schema validation functionality.
"""

using Test
using EarthSciAST

@testset "Schema Validation" begin

    @testset "validate_schema function" begin
        # Test valid ESM data - minimal valid structure
        valid_data = Dict(
            "esm" => "0.1.0",
            "metadata" => Dict(
                "name" => "test-model",
                "description" => "A test model"
            ),
            "models" => Dict(
                "test" => Dict(
                    "variables" => Dict(
                        "x" => Dict("type" => "state")
                    ),
                    "equations" => [
                        Dict("lhs" => "x", "rhs" => 1.0)
                    ]
                )
            )
        )

        errors = validate_schema(valid_data)
        @test isempty(errors)
        @test isa(errors, Vector{EarthSciAST.SchemaError})

        # Test invalid data - missing required field
        invalid_data = Dict(
            "esm" => "0.1.0"
            # Missing required metadata field
        )

        errors = validate_schema(invalid_data)
        @test !isempty(errors)
        @test isa(errors, Vector{EarthSciAST.SchemaError})
        for error in errors
            @test isa(error.path, String)
            @test isa(error.message, String)
            @test isa(error.keyword, String)
        end
    end

    @testset "SchemaError struct" begin
        error = EarthSciAST.SchemaError("/test/path", "Test error message", "required")
        @test error.path == "/test/path"
        @test error.message == "Test error message"
        @test error.keyword == "required"
    end

    @testset "SchemaValidationError exception" begin
        errors = [EarthSciAST.SchemaError("/", "Test error", "required")]
        exception = EarthSciAST.SchemaValidationError("Validation failed", errors)
        @test exception.message == "Validation failed"
        @test length(exception.errors) == 1
        @test exception.errors[1].path == "/"
    end

    @testset "Integration with load function" begin
        # Test that load function throws SchemaValidationError on invalid schema
        invalid_json = """
        {
            "esm": "0.1.0"
        }
        """

        @test_throws EarthSciAST.SchemaValidationError begin
            io = IOBuffer(invalid_json)
            EarthSciAST.load(io)
        end
    end

    @testset "ic in reaction system constraint_equations (spec §11.4.1)" begin
        # An `ic`-op equation placed inside a reaction system's
        # constraint_equations is SCHEMA-VALID but MUST be rejected at the
        # raw-JSON structural level with diagnostic code `ic_in_reaction_system`.
        fixture = joinpath(@__DIR__, "..", "..", "..", "tests", "invalid",
                           "ic_in_reaction_system.esm")
        @test isfile(fixture)

        local threw = false
        local msg = ""
        try
            EarthSciAST.load(fixture)
        catch e
            threw = true
            msg = e isa EarthSciAST.ParseError ? e.message : string(e)
        end
        @test threw
        @test occursin("ic_in_reaction_system", msg)
        @test occursin("/reaction_systems/Chemistry/constraint_equations/0", msg)
        @test occursin("species=O3", msg)

        # No false positive: a reaction system whose constraint_equations carry
        # no `ic` op loads without error.
        ok_json = """
        {
            "esm": "0.8.0",
            "metadata": {"name": "ok", "authors": ["t"],
                         "created": "2026-07-01T00:00:00Z"},
            "reaction_systems": {
                "Chemistry": {
                    "species": {"O3": {"units": "mol/mol", "default": 4.0e-8}},
                    "parameters": {"k": {"units": "1/s", "default": 1.0e-3}},
                    "reactions": [{
                        "id": "R1", "name": "O3_loss",
                        "substrates": [{"species": "O3", "stoichiometry": 1}],
                        "products": null, "rate": "k"
                    }],
                    "constraint_equations": [
                        {"lhs": "O3", "rhs": 4.0e-8}
                    ]
                }
            }
        }
        """
        @test EarthSciAST.load(IOBuffer(ok_json)) isa EarthSciAST.EsmFile
    end

end