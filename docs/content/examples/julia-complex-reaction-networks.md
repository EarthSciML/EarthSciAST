# Complex Reaction Networks (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reactions_test.jl`

```julia
# Test a more complex network: A + B ⇌ C, C → D
        species = [Species("A"), Species("B"), Species("C"), Species("D")]
        parameters = [
            Parameter("k_forward", 0.1),
            Parameter("k_reverse", 0.05),
            Parameter("k_decay", 0.02)
        ]

        reactions = [
            Reaction(Dict("A"=>1, "B"=>1), Dict("C"=>1), VarExpr("k_forward")),
            Reaction(Dict("C"=>1), Dict("A"=>1, "B"=>1), VarExpr("k_reverse")),
            Reaction(Dict("C"=>1), Dict("D"=>1), VarExpr("k_decay"))
        ]

        rxn_sys = ReactionSystem(species, reactions, parameters=parameters)
        model = derive_odes(rxn_sys)

        @test length(model.variables) == 7  # 4 species + 3 parameters
        @test length(model.equations) == 4  # One for each species

        # Check that the stoichiometric matrix is correct
        S = stoichiometric_matrix(rxn_sys)
        @test size(S) == (4, 3)  # 4 species, 3 reactions

        # Reaction 1: A + B -> C
        @test S[1, 1] == -1  # A consumed
        @test S[2, 1] == -1  # B consumed
        @test S[3, 1] == 1   # C produced
        @test S[4, 1] == 0   # D unchanged

        # Reaction 2: C -> A + B (reverse)
        @test S[1, 2] == 1   # A produced
        @test S[2, 2] == 1   # B produced
        @test S[3, 2] == -1  # C consumed
        @test S[4, 2] == 0   # D unchanged

        # Reaction 3: C -> D
        @test S[1, 3] == 0   # A unchanged
        @test S[2, 3] == 0   # B unchanged
        @test S[3, 3] == -1  # C consumed
        @test S[4, 3] == 1   # D produced
```

