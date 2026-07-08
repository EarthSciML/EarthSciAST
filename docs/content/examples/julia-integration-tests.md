# Integration tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/expression_test.jl`

```julia
# Test substitute + simplify
        expr = OpExpr("*", EarthSciAST.Expr[OpExpr("+", EarthSciAST.Expr[VarExpr("x"), NumExpr(0.0)]), VarExpr("y")])
        bindings = Dict{String,EarthSciAST.Expr}("y" => NumExpr(1.0))
        substituted = substitute(expr, bindings)
        simplified = simplify(substituted)
        @test simplified === VarExpr("x")

        # Test free_variables + evaluate
        expr = OpExpr("+", EarthSciAST.Expr[OpExpr("*", EarthSciAST.Expr[VarExpr("x"), VarExpr("y")]), NumExpr(1.0)])
        vars = free_variables(expr)
        @test vars == Set(["x", "y"])

        # Ensure we can evaluate with all free variables
        eval_bindings = Dict("x" => 2.0, "y" => 3.0)
        result = evaluate(expr, eval_bindings)
        @test result == 7.0

        # Test error when missing a variable
        partial_bindings = Dict("x" => 2.0)  # missing "y"
        @test_throws UnboundVariableError evaluate(expr, partial_bindings)
```

