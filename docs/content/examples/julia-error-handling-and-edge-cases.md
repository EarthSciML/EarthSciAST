# Error Handling and Edge Cases (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reference_resolution_test.jl`

```julia
# Empty ESM file
        metadata = Metadata("EmptyTest")
        empty_esm = EsmFile("0.1.0", metadata)

        @test_throws QualifiedReferenceError resolve_qualified_reference(empty_esm, "AnySystem.var")

        # ESM file with empty collections
        esm_with_empty = EsmFile("0.1.0", metadata,
                                models=Dict{String,Model}(),
                                reaction_systems=Dict{String,ReactionSystem}())

        @test_throws QualifiedReferenceError resolve_qualified_reference(esm_with_empty, "AnySystem.var")

        # Test malformed references
        valid_model = Model(Dict("var" => ModelVariable(StateVariable)), Equation[])
        valid_esm = EsmFile("0.1.0", metadata, models=Dict("System" => valid_model))

        @test_throws QualifiedReferenceError resolve_qualified_reference(valid_esm, "")
        @test_throws QualifiedReferenceError resolve_qualified_reference(valid_esm, "var")  # bare reference
```

