# EarthSciAST.Expression Operations (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/expression_test.jl`

```julia
@testset "substitute function" begin
        # Test NumExpr (should remain unchanged)
        num = NumExpr(3.14)
        bindings = Dict{String,EarthSciAST.Expr}("x" => NumExpr(2.0))
        @test substitute(num, bindings) === num

        # Test VarExpr with binding
        var_x = VarExpr("x")
        @test substitute(var_x, bindings) === bindings["x"]

        # Test VarExpr without binding (should remain unchanged)
        var_y = VarExpr("y")
        @test substitute(var_y, bindings) === var_y

        # Test OpExpr substitution
        sum_expr = OpExpr("+", EarthSciAST.Expr[var_x, var_y])
        result = substitute(sum_expr, bindings)
        @test result isa OpExpr
        @test result.op == "+"
        @test length(result.args) == 2
        @test result.args[1] === bindings["x"]
        @test result.args[2] === var_y

        # Test nested OpExpr substitution
        nested = OpExpr("*", EarthSciAST.Expr[OpExpr("+", EarthSciAST.Expr[var_x, NumExpr(1.0)]), var_y])
        result = substitute(nested, bindings)
        @test result isa OpExpr
        @test result.op == "*"
        @test result.args[1] isa OpExpr
        @test result.args[1].args[1] === bindings["x"]

        # Test OpExpr with wrt and dim fields
        diff_expr = OpExpr("D", EarthSciAST.Expr[var_x], wrt="t", dim="time")
        result = substitute(diff_expr, bindings)
        @test result.wrt == "t"
        @test result.dim == "time"
```

