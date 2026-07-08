# Integration with load function (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/validate_test.jl`

```julia
# Test that load function throws SchemaValidationError on invalid schema
        invalid_json = """
        {
            "esm": "0.1.0"
        }
        """

        @test_throws EarthSciAST.SchemaValidationError begin
            io = IOBuffer(invalid_json)
            EarthSciAST.load(io)
```

