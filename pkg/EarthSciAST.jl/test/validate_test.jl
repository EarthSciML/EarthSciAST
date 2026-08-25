"""
Tests for ESM Format schema validation functionality.
"""

using Test
using EarthSciAST

include("testutils.jl")

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
                        "x" => Dict("type" => "unknown")
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
            EarthSciAST.load_string(io)
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
        local perr = nothing
        try
            EarthSciAST.load_path(fixture)
        catch e
            threw = true
            perr = e
        end
        @test threw
        # The rejection now carries the pinned finding as STRUCTURED fields
        # (`code`, `path`, `details`) rather than baking them into the message,
        # so `validate`/the conformance producer can render it as the shared
        # `(code, path)` structural error.
        @test perr isa EarthSciAST.ParseError
        @test perr.code == "ic_in_reaction_system"
        @test perr.path == "/reaction_systems/Chemistry/constraint_equations/0"
        @test perr.details["species"] == "O3"

        # And `load_failure_structural_error` maps it to the pinned StructuralError.
        serr = EarthSciAST.load_failure_structural_error(perr)
        @test serr !== nothing
        @test serr.error_type == "ic_in_reaction_system"
        @test serr.path == "/reaction_systems/Chemistry/constraint_equations/0"

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
        @test EarthSciAST.load_string(IOBuffer(ok_json)) isa EarthSciAST.EsmFile
    end

    # API_SPEC.md §8 item 13: `validate` takes a TYPED document in every
    # binding. The path convenience — which also renders a load-time rejection
    # as the structural finding the corpus pins — is `validate_path`.
    @testset "validate is typed-only; validate_path does the I/O" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "minimal_chemistry.esm")
        @test isfile(path)

        # The typed entry point.
        file = EarthSciAST.load_path(path)
        typed = validate(file)
        @test typed isa ValidationResult

        # The path entry point agrees with load_path + validate.
        by_path = validate_path(path)
        @test by_path isa ValidationResult
        @test by_path.is_valid == typed.is_valid
        @test [e.error_type for e in by_path.structural_errors] ==
              [e.error_type for e in typed.structural_errors]

        # `validate` no longer has a String method: a caller who passes a path
        # gets a MethodError, not a silent file read.
        @test isempty(methods(validate, (AbstractString,)))
        @test_throws MethodError validate(path)

        # `validate_path` still renders a LOAD-time rejection as a structural
        # finding rather than throwing — the reason this entry point exists.
        bad = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "subsystem_ref_not_found.esm")
        if isfile(bad)
            res = validate_path(bad)
            @test !res.is_valid
            @test !isempty(res.structural_errors)
        end
    end

    # `validate_text` is the TEXT twin of `validate_path` (API_SPEC.md §8 item
    # 13). Julia was the last of the five bindings without it; Go, Python, Rust
    # and TypeScript all had it after phase 6.
    @testset "validate_text is the text entry point and never raises on bad text" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "coordinates_registry.esm")
        @test isfile(path)
        text = read(path, String)

        # It agrees with the typed entry point on a good document.
        typed = validate(EarthSciAST.load_string(text; base_path=dirname(path)))
        by_text = validate_text(text; base_path=dirname(path))
        @test by_text isa ValidationResult
        @test by_text.is_valid == typed.is_valid
        @test [e.error_type for e in by_text.structural_errors] ==
              [e.error_type for e in typed.structural_errors]

        # A caller asking "is this valid?" gets a VERDICT for a bad document too,
        # not an exception — the whole reason this entry point exists, and what
        # Python's validate_text and Go's ValidateText both do. Text is the only
        # input that can carry SCHEMA errors, since a typed EsmFile can exist
        # only by having passed the schema at load.
        schema_bad = validate_text("""{"esm":"1.0.0","metadata":{"name":"x"}}""")
        @test !schema_bad.is_valid
        @test !isempty(schema_bad.schema_errors)

        malformed = validate_text("{not json")
        @test !malformed.is_valid
        @test !isempty(malformed.schema_errors)
        @test malformed.schema_errors[1].keyword == "parse"

        # A (code, path)-carrying load rejection still lands in the STRUCTURAL
        # channel, through the same helper validate_path uses.
        ic_bad = joinpath(TESTUTILS_REPO_ROOT, "tests", "invalid", "ic_in_reaction_system.esm")
        if isfile(ic_bad)
            res = validate_text(read(ic_bad, String); base_path=dirname(ic_bad))
            @test !res.is_valid
            @test !isempty(res.structural_errors)
        end
    end

end