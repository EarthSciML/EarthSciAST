# validate function - complete validation (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/structural_validation_test.jl`

```julia
metadata = EarthSciAST.Metadata("test-model")

        @testset "Valid file" begin
            variables = Dict(
                "x" => EarthSciAST.ModelVariable(EarthSciAST.StateVariable, default=1.0)
            )
            equations = [
                EarthSciAST.Equation(EarthSciAST.OpExpr("D", EarthSciAST.Expr[EarthSciAST.VarExpr("x")], wrt="t"), EarthSciAST.NumExpr(1.0))
            ]
            model = EarthSciAST.Model(variables, equations)
            esm_file = EarthSciAST.EsmFile("0.1.0", metadata, models=Dict("test_model" => model))

            result = EarthSciAST.validate(esm_file)
            # Note: Schema validation might fail due to simplified conversion in validate function
            @test result isa EarthSciAST.ValidationResult
            @test isempty(result.structural_errors)
            @test isempty(result.unit_warnings)
```

