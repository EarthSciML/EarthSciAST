# Error Handling (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/parse_test.jl`

```julia
# Test invalid JSON
        @test_throws ParseError load(IOBuffer("invalid json"))

        # Test missing required fields
        invalid_esm = """{"esm": "0.1.0"}"""  # Missing metadata
        @test_throws SchemaValidationError load(IOBuffer(invalid_esm))

        # Test invalid expression format
        @test_throws ParseError EarthSciAST.parse_expression(Dict("invalid" => "data"))
```

