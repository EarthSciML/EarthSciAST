# Coupled systems with multiple components (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Create two coupled models demonstrating component interaction
        model1_vars = Dict{String,ModelVariable}(
            "x1" => ModelVariable(StateVariable; default=1.0, description="Component 1 state"),
            "k1" => ModelVariable(ParameterVariable; default=0.5, description="Component 1 decay rate")
        )

        model1_eqs = [
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("x1")], wrt="t"),
                OpExpr("*", EarthSciAST.Expr[OpExpr("-", EarthSciAST.Expr[VarExpr("k1")]), VarExpr("x1")])
            )
        ]

        model1 = Model(model1_vars, model1_eqs)

        model2_vars = Dict{String,ModelVariable}(
            "x2" => ModelVariable(StateVariable; default=0.0, description="Component 2 state"),
            "k2" => ModelVariable(ParameterVariable; default=1.0, description="Component 2 production rate")
        )

        model2_eqs = [
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("x2")], wrt="t"),
                OpExpr("*", EarthSciAST.Expr[VarExpr("k2"), VarExpr("x1")])  # Coupling to x1
            )
        ]

        model2 = Model(model2_vars, model2_eqs)

        # Convert both to MTK systems
        sys1 = to_mtk_system(model1, "Component1")
        sys2 = to_mtk_system(model2, "Component2")

        @test sys1 isa EarthSciAST.MockMTKSystem
        @test sys2 isa EarthSciAST.MockMTKSystem

        # Verify coupling information is preserved
        @test "x1" in sys1.states
        @test "x2" in sys2.states
        @test sys1.name == "Component1"
        @test sys2.name == "Component2"
```

