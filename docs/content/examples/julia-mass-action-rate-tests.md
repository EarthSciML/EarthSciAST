# Mass Action Rate Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reactions_test.jl`

```julia
species_A = Species("A")
        species_B = Species("B")
        species_C = Species("C")
        species = [species_A, species_B, species_C]

        # Test simple reaction A + B -> C
        reaction = Reaction(
            Dict("A" => 1, "B" => 1),
            Dict("C" => 1),
            VarExpr("k1")
        )

        rate_expr = mass_action_rate(reaction, species)
        @test rate_expr isa OpExpr
        @test rate_expr.op == "*"
        @test length(rate_expr.args) == 3  # k1 * A * B
        @test rate_expr.args[1] isa VarExpr
        @test rate_expr.args[1].name == "k1"

        # Test source reaction: -> A
        source_reaction = Reaction(Dict{String,Int}(), Dict("A" => 1), VarExpr("k_source"))
        source_rate = mass_action_rate(source_reaction, species)
        @test source_rate isa VarExpr
        @test source_rate.name == "k_source"

        # Test higher stoichiometry: 2A -> B
        high_stoich_reaction = Reaction(
            Dict("A" => 2),
            Dict("B" => 1),
            VarExpr("k_high")
        )
        high_rate = mass_action_rate(high_stoich_reaction, species)
        @test high_rate isa OpExpr
        @test high_rate.op == "*"
        @test length(high_rate.args) == 2  # k_high * A^2
        @test high_rate.args[1].name == "k_high"
        @test high_rate.args[2] isa OpExpr
        @test high_rate.args[2].op == "^"
        @test high_rate.args[2].args[1].name == "A"
        @test high_rate.args[2].args[2].value == 2.0

        # Test single reactant: A -> B
        single_reaction = Reaction(
            Dict("A" => 1),
            Dict("B" => 1),
            VarExpr("k_single")
        )
        single_rate = mass_action_rate(single_reaction, species)
        @test single_rate isa OpExpr
        @test single_rate.op == "*"
        @test length(single_rate.args) == 2  # k_single * A
```

