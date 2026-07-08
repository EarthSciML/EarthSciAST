# free_variables function (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/expression_test.jl`

```julia
# Test NumExpr (no variables)
        num = NumExpr(3.14)
        @test free_variables(num) == Set{String}()

        # Test VarExpr (single variable)
        var_x = VarExpr("x")
        @test free_variables(var_x) == Set(["x"])

        # Test OpExpr with multiple variables
        sum_expr = OpExpr("+", EarthSciAST.Expr[VarExpr("x"), VarExpr("y")])
        @test free_variables(sum_expr) == Set(["x", "y"])

        # Test nested expressions
        nested = OpExpr("*", EarthSciAST.Expr[OpExpr("+", EarthSciAST.Expr[VarExpr("x"), NumExpr(1.0)]), VarExpr("y")])
        @test free_variables(nested) == Set(["x", "y"])

        # Test OpExpr with wrt field
        diff_expr = OpExpr("D", EarthSciAST.Expr[VarExpr("x")], wrt="t")
        @test free_variables(diff_expr) == Set(["x", "t"])

        # Test expression with repeated variables
        repeated = OpExpr("+", EarthSciAST.Expr[VarExpr("x"), VarExpr("x"), VarExpr("y")])
        @test free_variables(repeated) == Set(["x", "y"])
```

