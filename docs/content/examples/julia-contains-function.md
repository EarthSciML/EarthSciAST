# contains function (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/expression_test.jl`

```julia
# Test NumExpr (contains no variables)
        num = NumExpr(3.14)
        @test !EarthSciAST.contains(num, "x")

        # Test VarExpr
        var_x = VarExpr("x")
        @test EarthSciAST.contains(var_x, "x")
        @test !EarthSciAST.contains(var_x, "y")

        # Test OpExpr
        sum_expr = OpExpr("+", EarthSciAST.Expr[VarExpr("x"), VarExpr("y")])
        @test EarthSciAST.contains(sum_expr, "x")
        @test EarthSciAST.contains(sum_expr, "y")
        @test !EarthSciAST.contains(sum_expr, "z")

        # Test nested expressions
        nested = OpExpr("*", EarthSciAST.Expr[OpExpr("+", EarthSciAST.Expr[VarExpr("x"), NumExpr(1.0)]), VarExpr("y")])
        @test EarthSciAST.contains(nested, "x")
        @test EarthSciAST.contains(nested, "y")
        @test !EarthSciAST.contains(nested, "z")

        # Test OpExpr with wrt field
        diff_expr = OpExpr("D", EarthSciAST.Expr[VarExpr("x")], wrt="t")
        @test EarthSciAST.contains(diff_expr, "x")
        @test EarthSciAST.contains(diff_expr, "t")
        @test !EarthSciAST.contains(diff_expr, "y")
```

