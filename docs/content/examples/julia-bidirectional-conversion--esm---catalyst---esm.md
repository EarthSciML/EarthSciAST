# Bidirectional conversion: ESM → Catalyst → ESM (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Test round-trip conversion for reaction system
        species = [Species("A"), Species("B")]
        parameters = [Parameter("k", 1.0, units="1/s")]
        reactions = [
            Reaction(Dict("A" => 1), Dict("B" => 1), VarExpr("k"))
        ]

        original_rsys = ReactionSystem(species, reactions; parameters=parameters)
        catalyst_sys = to_catalyst_system(original_rsys, "TestReactions")
        recovered_rsys = from_catalyst_system(catalyst_sys, "TestReactions")

        @test recovered_rsys isa ReactionSystem
        @test length(recovered_rsys.species) == length(original_rsys.species)
        @test length(recovered_rsys.reactions) == length(original_rsys.reactions)
        @test length(recovered_rsys.parameters) == length(original_rsys.parameters)

        # Verify species names are preserved
        original_species_names = Set(spec.name for spec in original_rsys.species)
        recovered_species_names = Set(spec.name for spec in recovered_rsys.species)
        @test original_species_names == recovered_species_names

        # Verify parameter data is preserved
        @test recovered_rsys.parameters[1].name == "k"
        @test recovered_rsys.parameters[1].default == 1.0
```

