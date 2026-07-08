# Null-null reaction (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/structural_validation_test.jl`

```julia
species = [EarthSciAST.Species("A")]
            reactions = [
                EarthSciAST.Reaction(Dict{String,Int}(), Dict{String,Int}(), EarthSciAST.VarExpr("k1"))  # No reactants or products
            ]
            rs = EarthSciAST.ReactionSystem(species, reactions)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, reaction_systems=Dict("test_reactions" => rs))

            errors = EarthSciAST.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "reaction_systems.test_reactions.reactions[1]"
            @test occursin("null-null reaction", errors[1].message)
            @test errors[1].error_type == "null_reaction"
```

