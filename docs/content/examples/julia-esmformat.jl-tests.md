# EarthSciAST.jl Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
include("parse_test.jl")
    include("validate_test.jl")
    include("structural_validation_test.jl")
    include("expression_test.jl")
    include("reactions_test.jl")
    # Temporarily disabled due to precompilation issues
    # include("mtk_catalyst_test.jl")
    include("reference_resolution_test.jl")
    include("solver_test.jl")
    include("solver_optimization_test.jl")
    include("test_codegen.jl")

    # Comprehensive test suite for full verification
    @testset "Comprehensive Test Suite" begin

        @testset "Valid Fixture Parse Tests" begin
            # Test loading and parsing all valid test fixtures
            valid_fixtures_dir = joinpath(@__DIR__, "..", "..", "..", "tests", "valid")

            if isdir(valid_fixtures_dir)
                valid_files = filter(f ->
```

