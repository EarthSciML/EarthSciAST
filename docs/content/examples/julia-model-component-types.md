# Model Component Types (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/runtests.jl`

```julia
# Test Species
        species = Species("CO2", molecular_weight=44.01)
        @test species.name == "CO2"
        @test species.molecular_weight == 44.01
        @test species.description === nothing

        # Test Parameter
        param = Parameter("k", 0.1, description="Rate constant", units="1/s")
        @test param.name == "k"
        @test param.default == 0.1
        @test param.description == "Rate constant"
        @test param.units == "1/s"

        # Test Reaction
        reactants = Dict("A" => 1, "B" => 1)
        products = Dict("C" => 1)
        rate = OpExpr("*", EarthSciAST.Expr[VarExpr("k"), VarExpr("A"), VarExpr("B")])
        reaction = Reaction(reactants, products, rate)
        @test reaction.reactants == reactants
        @test reaction.products == products
        @test reaction.rate == rate
        @test reaction.reversible == false
```

