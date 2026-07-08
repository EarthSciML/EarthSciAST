# Integration with Julia's symbolic manipulation capabilities (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/mtk_catalyst_test.jl`

```julia
# Test expression conversion utilities

        # Test ESM to mock symbolic conversion
        simple_num = NumExpr(42.0)
        @test esm_to_mock_symbolic(simple_num) == "42.0"

        simple_var = VarExpr("x")
        @test esm_to_mock_symbolic(simple_var) == "x"

        # Test differential expression conversion
        diff_expr = OpExpr("D", EarthSciAST.Expr[VarExpr("x")], wrt="t")
        symbolic_diff = esm_to_mock_symbolic(diff_expr)
        @test occursin("D(x, t)", symbolic_diff)

        # Test arithmetic expression conversion
        add_expr = OpExpr("+", EarthSciAST.Expr[VarExpr("a"), VarExpr("b")])
        symbolic_add = esm_to_mock_symbolic(add_expr)
        @test occursin("+(a, b)", symbolic_add)

        # Test mock symbolic to ESM conversion
        @test mock_symbolic_to_esm("42.0") isa NumExpr
        @test mock_symbolic_to_esm("x") isa VarExpr
        @test mock_symbolic_to_esm("D(x, t)") isa OpExpr

        # Test that converted systems maintain symbolic structure
        variables = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "a" => ModelVariable(ParameterVariable; default=2.0)
        )

        equations = [
            Equation(
                OpExpr("D", EarthSciAST.Expr[VarExpr("x")], wrt="t"),
                OpExpr("*", EarthSciAST.Expr[VarExpr("a"), VarExpr("x")])
            )
        ]

        model = Model(variables, equations)
        mtk_sys = to_mtk_system(model, "ExponentialGrowth")

        # Verify the mock system captures the symbolic nature
        @test mtk_sys isa EarthSciAST.MockMTKSystem
        @test length(mtk_sys.equations) == 1
        @test "x" in mtk_sys.states
        @test "a" in mtk_sys.parameters
```

