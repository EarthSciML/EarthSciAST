# validate_structural function (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/structural_validation_test.jl`

```julia
metadata = EarthSciAST.Metadata("test-model")

        @testset "Missing equation for state variable" begin
            # Create a model with missing equation for state variable
            variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0),
                "y" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=2.0),
                "k" => EarthSciAST.ModelVariable(EarthSciAST.ParameterVariable, default=0.5)
            )

            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.Expr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.VarExpr("y"))
                # Missing equation for state variable y
            ]

            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            errors = EarthSciAST.validate_structural(esm_file)
            @test length(errors) == 1
            @test errors[1].path == "models.test_model.equations"
            @test occursin("State variable 'y' has no defining equation", errors[1].message)
            @test errors[1].error_type == "missing_equation"
```

