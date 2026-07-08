# Schema Validation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/validate_test.jl`

```julia
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
```

