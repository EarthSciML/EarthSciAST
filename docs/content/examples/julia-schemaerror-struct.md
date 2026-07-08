# SchemaError struct (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/validate_test.jl`

```julia
error = EarthSciAST.SchemaError("/test/path", "Test error message", "required")
        @test error.path == "/test/path"
        @test error.message == "Test error message"
        @test error.keyword == "required"
```

