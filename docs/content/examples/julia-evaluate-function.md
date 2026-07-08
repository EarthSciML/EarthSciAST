# evaluate function (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/expression_test.jl`

```julia
# Test NumExpr
        num = NumExpr(3.14)
        @test evaluate(num, Dict{String,Float64}()) == 3.14

        # Test VarExpr with binding
        var_x = VarExpr("x")
        bindings = Dict("x" => 2.5)
        @test evaluate(var_x, bindings) == 2.5

        # Test VarExpr without binding (should throw)
        @test_throws UnboundVariableError evaluate(var_x, Dict{String,Float64}())

        # Test arithmetic operations
        @test evaluate(OpExpr("+", EarthSciAST.Expr[NumExpr(2.0), NumExpr(3.0)]), Dict{String,Float64}()) == 5.0
        @test evaluate(OpExpr("-", EarthSciAST.Expr[NumExpr(5.0), NumExpr(3.0)]), Dict{String,Float64}()) == 2.0
        @test evaluate(OpExpr("*", EarthSciAST.Expr[NumExpr(2.0), NumExpr(3.0)]), Dict{String,Float64}()) == 6.0
        @test evaluate(OpExpr("/", EarthSciAST.Expr[NumExpr(6.0), NumExpr(3.0)]), Dict{String,Float64}()) == 2.0
        @test evaluate(OpExpr("^", EarthSciAST.Expr[NumExpr(2.0), NumExpr(3.0)]), Dict{String,Float64}()) == 8.0

        # Test unary operations
        @test evaluate(OpExpr("+", EarthSciAST.Expr[NumExpr(5.0)]), Dict{String,Float64}()) == 5.0
        @test evaluate(OpExpr("-", EarthSciAST.Expr[NumExpr(5.0)]), Dict{String,Float64}()) == -5.0

        # Test mathematical functions
        @test evaluate(OpExpr("sin", EarthSciAST.Expr[NumExpr(0.0)]), Dict{String,Float64}()) == 0.0
        @test evaluate(OpExpr("cos", EarthSciAST.Expr[NumExpr(0.0)]), Dict{String,Float64}()) == 1.0
        @test evaluate(OpExpr("exp", EarthSciAST.Expr[NumExpr(0.0)]), Dict{String,Float64}()) == 1.0
        @test evaluate(OpExpr("log", EarthSciAST.Expr[NumExpr(1.0)]), Dict{String,Float64}()) == 0.0
        @test evaluate(OpExpr("sqrt", EarthSciAST.Expr[NumExpr(4.0)]), Dict{String,Float64}()) == 2.0
        @test evaluate(OpExpr("abs", EarthSciAST.Expr[NumExpr(-5.0)]), Dict{String,Float64}()) == 5.0

        # Test constants
        π_result = evaluate(OpExpr("π", EarthSciAST.Expr[]), Dict{String,Float64}())
        @test π_result ≈ π
        e_result = evaluate(OpExpr("e", EarthSciAST.Expr[]), Dict{String,Float64}())
        @test e_result ≈ ℯ

        # Test complex expression with variables
        expr = OpExpr("+", EarthSciAST.Expr[OpExpr("*", EarthSciAST.Expr[VarExpr("x"), VarExpr("y")]), NumExpr(1.0)])
        bindings = Dict("x" => 2.0, "y" => 3.0)
        @test evaluate(expr, bindings) == 7.0

        # Test error conditions
        @test_throws DivideError evaluate(OpExpr("/", EarthSciAST.Expr[NumExpr(1.0), NumExpr(0.0)]), Dict{String,Float64}())
        @test_throws DomainError evaluate(OpExpr("log", EarthSciAST.Expr[NumExpr(-1.0)]), Dict{String,Float64}())
        @test_throws DomainError evaluate(OpExpr("sqrt", EarthSciAST.Expr[NumExpr(-1.0)]), Dict{String,Float64}())
        @test_throws ArgumentError evaluate(OpExpr("unknown_op", EarthSciAST.Expr[NumExpr(1.0)]), Dict{String,Float64}())
```

