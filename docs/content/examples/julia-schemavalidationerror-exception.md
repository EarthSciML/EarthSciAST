# SchemaValidationError exception (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/validate_test.jl`

```julia
errors = [EarthSciAST.SchemaError("/", "Test error", "required")]
        exception = EarthSciAST.SchemaValidationError("Validation failed", errors)
        @test exception.message == "Validation failed"
        @test length(exception.errors) == 1
        @test exception.errors[1].path == "/"
```

