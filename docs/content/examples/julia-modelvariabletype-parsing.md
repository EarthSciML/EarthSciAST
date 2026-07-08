# ModelVariableType Parsing (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/parse_test.jl`

```julia
# Test schema values
        @test EarthSciAST.parse_model_variable_type("state") == StateVariable
        @test EarthSciAST.parse_model_variable_type("parameter") == ParameterVariable
        @test EarthSciAST.parse_model_variable_type("observed") == ObservedVariable

        # Test Julia enum values for compatibility
        @test EarthSciAST.parse_model_variable_type("StateVariable") == StateVariable
        @test EarthSciAST.parse_model_variable_type("ParameterVariable") == ParameterVariable
        @test EarthSciAST.parse_model_variable_type("ObservedVariable") == ObservedVariable
```

