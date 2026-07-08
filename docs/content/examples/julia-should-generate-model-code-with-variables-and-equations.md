# should generate model code with variables and equations (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/test_codegen.jl`

```julia
file = EsmFile(
                esm = "0.1.0",
                models = Dict(
                    "atmospheric" => Model(
                        variables = Dict(
                            "O3" => ModelVariable(
                                name = "O3",
                                type = StateVariable,
                                default = 50.0,
                                unit = "ppb"
                            ),
                            "k1" => ModelVariable(
                                name = "k1",
                                type = ParameterVariable,
                                default = 1e-3,
                                unit = nothing
                            )
                        ),
                        equations = [
                            Equation(
                                lhs = OpExpr("D", [VarExpr("O3")]),
                                rhs = OpExpr("*", [VarExpr("k1"), VarExpr("O3")])
                            )
                        ]
                    )
                ),
                reaction_systems = Dict{String,ReactionSystem}()
            )

            code = to_python_code(file)

            @test occursin("t = sp.Symbol('t')", code)
            @test occursin("O3 = sp.Function('O3')  # ppb", code)
            @test occursin("k1 = sp.Symbol('k1')", code)
            @test occursin("eq1 = sp.Eq(sp.Derivative(O3(t), t), k1 * O3)", code)
```

