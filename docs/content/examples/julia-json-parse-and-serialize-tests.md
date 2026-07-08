# JSON Parse and Serialize Tests (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/parse_test.jl`

```julia
@testset "Expression Parsing" begin
        # Test NumExpr (number)
        expr1 = EarthSciAST.parse_expression(3.14)
        @test expr1 isa NumExpr
        @test expr1.value == 3.14

        # Test VarExpr (string)
        expr2 = EarthSciAST.parse_expression("x")
        @test expr2 isa VarExpr
        @test expr2.name == "x"

        # Test OpExpr (object with 'op')
        op_data = Dict("op" => "+", "args" => [1.0, "x"])
        expr3 = EarthSciAST.parse_expression(op_data)
        @test expr3 isa OpExpr
        @test expr3.op == "+"
        @test length(expr3.args) == 2
        @test expr3.args[1] isa NumExpr
        @test expr3.args[2] isa VarExpr
        @test expr3.wrt === nothing
        @test expr3.dim === nothing

        # Test OpExpr with optional parameters
        op_data_wrt = Dict("op" => "D", "args" => ["x"], "wrt" => "t")
        expr4 = EarthSciAST.parse_expression(op_data_wrt)
        @test expr4 isa OpExpr
        @test expr4.op == "D"
        @test expr4.wrt == "t"
        @test expr4.dim === nothing
```

