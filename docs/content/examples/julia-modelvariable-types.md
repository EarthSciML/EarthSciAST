# ModelVariable Types (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test ModelVariableType enum
        @test StateVariable isa ModelVariableType
        @test ParameterVariable isa ModelVariableType
        @test ObservedVariable isa ModelVariableType

        # Test ModelVariable
        mv = ModelVariable(StateVariable, default=1.0, description="Test variable")
        @test mv.type == StateVariable
        @test mv.default == 1.0
        @test mv.description == "Test variable"
        @test mv.expression === nothing
```

