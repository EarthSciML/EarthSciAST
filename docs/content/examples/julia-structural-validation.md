# Structural Validation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/structural_validation_test.jl`

```julia
@testset "StructuralError struct" begin
        error = EarthSciAST.StructuralError("models.test.equations", "Test error message", "missing_equation")
        @test error.path == "models.test.equations"
        @test error.message == "Test error message"
        @test error.error_type == "missing_equation"
```

