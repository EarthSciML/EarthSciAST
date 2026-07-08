# ODE Derivation Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/reactions_test.jl`

```julia
# Test simple reaction A + B -> C
        species_A = Species("A")
        species_B = Species("B")
        species_C = Species("C")
        species = [species_A, species_B, species_C]

        param_k1 = Parameter("k1", 0.1, description="Rate constant", units="1/(mol⋅s)")
        parameters = [param_k1]

        reaction = Reaction(
            Dict("A" => 1, "B" => 1),
            Dict("C" => 1),
            VarExpr("k1")
        )

        rxn_sys = ReactionSystem(species, [reaction], parameters=parameters)
        model = derive_odes(rxn_sys)

        # Check variables
        @test length(model.variables) == 4  # 3 species + 1 parameter
        @test haskey(model.variables, "A")
        @test haskey(model.variables, "B")
        @test haskey(model.variables, "C")
        @test haskey(model.variables, "k1")

        @test model.variables["A"].type == StateVariable
        @test model.variables["B"].type == StateVariable
        @test model.variables["C"].type == StateVariable
        @test model.variables["k1"].type == ParameterVariable
        @test model.variables["k1"].default == 0.1

        # Check equations
        @test length(model.equations) == 3  # One for each species

        # Check that each equation is a differential equation
        for eq in model.equations
            @test eq.lhs isa OpExpr
            @test eq.lhs.op == "D"
            @test eq.lhs.wrt == "t"
```

