# ESM ReactionSystem → MockCatalyst conversion with stoichiometry preservation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Create a simple ozone photochemistry system
        species = [
            Species("O3", description="Ozone"),
            Species("NO", description="Nitric oxide"),
            Species("NO2", description="Nitrogen dioxide")
        ]

        parameters = [
            Parameter("k1", 1.8e-12, description="NO + O3 rate", units="cm^3/molec/s"),
            Parameter("j1", 0.005, description="NO2 photolysis rate", units="1/s"),
            Parameter("M", 2.46e19, description="Air density", units="molec/cm^3")
        ]

        reactions = [
            Reaction(
                Dict("NO" => 1, "O3" => 1),
                Dict("NO2" => 1),
                OpExpr("*", EarthSciAST.Expr[VarExpr("k1"), VarExpr("M")])
            ),
            Reaction(
                Dict("NO2" => 1),
                Dict("NO" => 1, "O3" => 1),
                VarExpr("j1")
            )
        ]

        esm_rsys = ReactionSystem(species, reactions; parameters=parameters)
        catalyst_sys = to_catalyst_system(esm_rsys, "OzonePhotochemistry")

        @test catalyst_sys isa EarthSciAST.MockCatalystSystem
        @test catalyst_sys.name == "OzonePhotochemistry"

        # Check species, parameters, and reactions
        @test length(catalyst_sys.species) == 3  # O3, NO, NO2
        @test length(catalyst_sys.parameters) == 3   # k1, j1, M
        @test length(catalyst_sys.reactions) == 2 # Two reactions

        # Verify species names
        @test "O3" in catalyst_sys.species
        @test "NO" in catalyst_sys.species
        @test "NO2" in catalyst_sys.species

        # Verify parameter names
        @test "k1" in catalyst_sys.parameters
        @test "j1" in catalyst_sys.parameters
        @test "M" in catalyst_sys.parameters
```

