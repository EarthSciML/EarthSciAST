# Valid model - no errors (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/structural_validation_test.jl`

```julia
variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0),
                "k" => EarthSciAST.ModelVariable(EarthSciAST.ParameterVariable, default=0.5)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.Expr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.VarExpr("k"))
            ]
            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciAST.validate_structural(esm_file)
            @test isempty(errors)
```

