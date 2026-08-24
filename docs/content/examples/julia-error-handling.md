# Error Handling (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/parse_test.jl`

```julia
# Test invalid JSON
        @test_throws ParseError load_string(IOBuffer("invalid json"))

        # Test missing required fields
        invalid_esm = """{"esm": "1.0.0"}"""  # Missing metadata
        @test_throws SchemaValidationError load_string(IOBuffer(invalid_esm))

        # Test invalid expression format
        @test_throws ParseError EarthSciAST.parse_expression(Dict("invalid" => "data"))
```

