# Bidirectional conversion: ESM → MTK → ESM with metadata preservation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Test round-trip conversion for model
        variables = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=2.0, description="Position"),
            "k" => ModelVariable(ParameterVariable; default=0.5, description="Damping coefficient")
        )

        equations = [
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("x")], wrt="t"),
                OpExpr("*", EarthSciAST.Expr[OpExpr("-", EarthSciAST.Expr[VarExpr("k")]), VarExpr("x")])
            )
        ]

        original_model = Model(variables, equations)
        mtk_sys = to_mtk_system(original_model, "TestModel")
        recovered_model = from_mtk_system(mtk_sys, "TestModel")

        @test recovered_model isa Model
        @test length(recovered_model.equations) == length(original_model.equations)

        # Check that we have similar variable types and can recover the original
        @test recovered_model.variables["x"].type == StateVariable
        @test recovered_model.variables["k"].type == ParameterVariable
        @test recovered_model.variables["x"].default == 2.0
        @test recovered_model.variables["k"].default == 0.5
```

