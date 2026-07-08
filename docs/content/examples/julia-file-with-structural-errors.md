# File with structural errors (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/structural_validation_test.jl`

```julia
variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0),
                "y" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=2.0)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.Expr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))
                # Missing equation for y
            ]
            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            result = EarthSciAST.validate(esm_file)
            @test result isa EarthSciAST.ValidationResult
            @test length(result.structural_errors) == 1
            @test result.is_valid == false  # Should be false due to structural errors
```

