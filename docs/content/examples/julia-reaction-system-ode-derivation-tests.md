# Reaction System ODE Derivation Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reactions_test.jl`

```julia
@testset "Stoichiometric Matrix Tests" begin
        # Test simple reaction A + B -> C
        species_A = Species("A")
        species_B = Species("B")
        species_C = Species("C")
        species = [species_A, species_B, species_C]

        reaction = Reaction(
            Dict("A" => 1, "B" => 1),  # A + B
            Dict("C" => 1),            # -> C
            VarExpr("k1")
        )

        rxn_sys = ReactionSystem(species, [reaction])
        S = stoichiometric_matrix(rxn_sys)

        @test size(S) == (3, 1)  # 3 species, 1 reaction
        @test S[1, 1] == -1  # A consumed
        @test S[2, 1] == -1  # B consumed
        @test S[3, 1] == 1   # C produced

        # Test multiple reactions: A -> B, B -> C
        reaction1 = Reaction(Dict("A" => 1), Dict("B" => 1), VarExpr("k1"))
        reaction2 = Reaction(Dict("B" => 1), Dict("C" => 1), VarExpr("k2"))

        rxn_sys_multi = ReactionSystem(species, [reaction1, reaction2])
        S_multi = stoichiometric_matrix(rxn_sys_multi)

        @test size(S_multi) == (3, 2)  # 3 species, 2 reactions
        # Reaction 1: A -> B
        @test S_multi[1, 1] == -1  # A consumed
        @test S_multi[2, 1] == 1   # B produced
        @test S_multi[3, 1] == 0   # C unchanged
        # Reaction 2: B -> C
        @test S_multi[1, 2] == 0   # A unchanged
        @test S_multi[2, 2] == -1  # B consumed
        @test S_multi[3, 2] == 1   # C produced

        # Test source reaction (no reactants): -> A
        source_reaction = Reaction(Dict{String,Int}(), Dict("A" => 1), VarExpr("k_source"))
        rxn_sys_source = ReactionSystem([species_A], [source_reaction])
        S_source = stoichiometric_matrix(rxn_sys_source)

        @test size(S_source) == (1, 1)
        @test S_source[1, 1] == 1  # A produced from source

        # Test sink reaction (no products): A ->
        sink_reaction = Reaction(Dict("A" => 1), Dict{String,Int}(), VarExpr("k_sink"))
        rxn_sys_sink = ReactionSystem([species_A], [sink_reaction])
        S_sink = stoichiometric_matrix(rxn_sys_sink)

        @test size(S_sink) == (1, 1)
        @test S_sink[1, 1] == -1  # A consumed by sink

        # Test higher stoichiometry: 2A + B -> 3C
        high_stoich_reaction = Reaction(
            Dict("A" => 2, "B" => 1),
            Dict("C" => 3),
            VarExpr("k_high")
        )
        rxn_sys_high = ReactionSystem(species, [high_stoich_reaction])
        S_high = stoichiometric_matrix(rxn_sys_high)

        @test size(S_high) == (3, 1)
        @test S_high[1, 1] == -2  # 2A consumed
        @test S_high[2, 1] == -1  # B consumed
        @test S_high[3, 1] == 3   # 3C produced
```

