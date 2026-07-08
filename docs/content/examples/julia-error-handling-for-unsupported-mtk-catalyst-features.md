# Error handling for unsupported MTK/Catalyst features (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Test graceful handling of edge cases

        # Empty model
        empty_vars = Dict{String,ModelVariable}()
        empty_eqs = Equation[]
        empty_model = Model(empty_vars, empty_eqs)

        @test_nowarn to_mtk_system(empty_model, "EmptyModel")
        empty_sys = to_mtk_system(empty_model, "EmptyModel")
        @test empty_sys isa EarthSciAST.MockMTKSystem

        # Model with only observed variables
        obs_only_vars = Dict{String,ModelVariable}(
            "computed" => ModelVariable(ObservedVariable;
                expression=OpExpr("+", EarthSciAST.Expr[NumExpr(1.0), NumExpr(2.0)]))
        )
        obs_only_model = Model(obs_only_vars, Equation[])
        @test_nowarn to_mtk_system(obs_only_model, "ObservedOnly")

        # Empty reaction system
        empty_species = Species[]
        empty_reactions = Reaction[]
        empty_rsys = ReactionSystem(empty_species, empty_reactions)

        @test_nowarn to_catalyst_system(empty_rsys, "EmptyReactions")
        empty_cat_sys = to_catalyst_system(empty_rsys, "EmptyReactions")
        @test empty_cat_sys isa EarthSciAST.MockCatalystSystem

        # Test error handling for incorrect types
        @test_throws ErrorException from_mtk_system("not a mock system", "TestError")
        @test_throws ErrorException from_catalyst_system("not a mock system", "TestError")
```

