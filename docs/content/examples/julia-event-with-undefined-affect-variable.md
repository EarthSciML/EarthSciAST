# Event with undefined affect variable (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/structural_validation_test.jl`

```julia
variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.Expr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))
            ]
            events = [
                EarthSciAST.ContinuousEvent(
                    EarthSciAST.Expr[EarthSciAST.OpExpr("-", EarthSciAST.Expr[EarthSciAST.VarExpr("x"), EarthSciAST.NumExpr(10.0)])],
                    [EarthSciAST.AffectEquation("undefined_var", EarthSciAST.NumExpr(0.0))]
                )
            ]
            model = EarthSciAST.Model(variables, equations, events=events)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciAST.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "models.test_model.events[1].affects[1]"
            @test occursin("Affect target variable 'undefined_var' not declared", errors[1].message)
            @test errors[1].error_type == "undefined_affect_variable"
```

