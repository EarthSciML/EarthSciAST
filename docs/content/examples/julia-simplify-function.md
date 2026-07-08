# simplify function (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/expression_test.jl`

```julia
# Test NumExpr and VarExpr (already simplified)
        num = NumExpr(3.14)
        @test simplify(num) === num
        var = VarExpr("x")
        @test simplify(var) === var

        # Test constant folding
        @test simplify(OpExpr("+", EarthSciAST.Expr[NumExpr(2.0), NumExpr(3.0)])) == NumExpr(5.0)
        @test simplify(OpExpr("*", EarthSciAST.Expr[NumExpr(2.0), NumExpr(3.0)])) == NumExpr(6.0)

        # Test additive identity: x + 0 = x
        var_x = VarExpr("x")
        @test simplify(OpExpr("+", EarthSciAST.Expr[var_x, NumExpr(0.0)])) === var_x
        @test simplify(OpExpr("+", EarthSciAST.Expr[NumExpr(0.0), var_x])) === var_x

        # Test additive identity with all zeros
        @test simplify(OpExpr("+", EarthSciAST.Expr[NumExpr(0.0), NumExpr(0.0)])) == NumExpr(0.0)

        # Test multiplicative identity: x * 1 = x
        @test simplify(OpExpr("*", EarthSciAST.Expr[var_x, NumExpr(1.0)])) === var_x
        @test simplify(OpExpr("*", EarthSciAST.Expr[NumExpr(1.0), var_x])) === var_x

        # Test multiplicative zero: x * 0 = 0
        @test simplify(OpExpr("*", EarthSciAST.Expr[var_x, NumExpr(0.0)])) == NumExpr(0.0)
        @test simplify(OpExpr("*", EarthSciAST.Expr[NumExpr(0.0), var_x])) == NumExpr(0.0)

        # Test multiplicative identity with all ones
        @test simplify(OpExpr("*", EarthSciAST.Expr[NumExpr(1.0), NumExpr(1.0)])) == NumExpr(1.0)

        # Test exponentiation rules
        @test simplify(OpExpr("^", EarthSciAST.Expr[var_x, NumExpr(0.0)])) == NumExpr(1.0)
        @test simplify(OpExpr("^", EarthSciAST.Expr[var_x, NumExpr(1.0)])) === var_x
        @test simplify(OpExpr("^", EarthSciAST.Expr[NumExpr(0.0), NumExpr(2.0)])) == NumExpr(0.0)
        @test simplify(OpExpr("^", EarthSciAST.Expr[NumExpr(1.0), var_x])) == NumExpr(1.0)

        # Test subtraction: x - 0 = x
        @test simplify(OpExpr("-", EarthSciAST.Expr[var_x, NumExpr(0.0)])) === var_x

        # Test division: x / 1 = x, 0 / x = 0
        @test simplify(OpExpr("/", EarthSciAST.Expr[var_x, NumExpr(1.0)])) === var_x
        @test simplify(OpExpr("/", EarthSciAST.Expr[NumExpr(0.0), var_x])) == NumExpr(0.0)

        # Test recursive simplification
        nested = OpExpr("*", EarthSciAST.Expr[OpExpr("+", EarthSciAST.Expr[NumExpr(1.0), NumExpr(2.0)]), var_x])
        simplified = simplify(nested)
        @test simplified isa OpExpr
        @test simplified.op == "*"
        @test simplified.args[1] == NumExpr(3.0)
        @test simplified.args[2] === var_x

        # Test n-ary operations
        n_ary_add = OpExpr("+", EarthSciAST.Expr[var_x, NumExpr(0.0), VarExpr("y"), NumExpr(0.0)])
        simplified = simplify(n_ary_add)
        @test simplified isa OpExpr
        @test simplified.op == "+"
        @test length(simplified.args) == 2
        @test var_x in simplified.args
        @test VarExpr("y") in simplified.args
```

