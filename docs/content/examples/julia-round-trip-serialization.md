# Round-trip Serialization (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/parse_test.jl`

```julia
# Create test data
        metadata = Metadata("test_roundtrip", authors=["Author 1", "Author 2"])

        variables = Dict("x" => ModelVariable(StateVariable, default=1.0))

        lhs = OpExpr("D", Vector{EarthSciAST.Expr}([VarExpr("x")]), wrt="t")
        rhs = OpExpr("*", Vector{EarthSciAST.Expr}([NumExpr(-0.1), VarExpr("x")]))
        equations = [Equation(lhs, rhs)]

        model = Model(variables, equations)
        models = Dict("test_model" => model)

        original_file = EsmFile("0.1.0", metadata, models=models)

        # Test round-trip
        temp_file = tempname() * ".json"

        try
            # Save
            save(original_file, temp_file)
            @test isfile(temp_file)

            # Load
            loaded_file = load(temp_file)

            # Check basic properties
            @test loaded_file.esm == original_file.esm
            @test loaded_file.metadata.name == original_file.metadata.name
            @test loaded_file.metadata.authors == original_file.metadata.authors

            # Check models
            @test loaded_file.models !== nothing
            @test haskey(loaded_file.models, "test_model")

            loaded_model = loaded_file.models["test_model"]
            @test haskey(loaded_model.variables, "x")
            @test loaded_model.variables["x"].type == StateVariable
            @test loaded_model.variables["x"].default == 1.0

            @test length(loaded_model.equations) == 1
            loaded_eq = loaded_model.equations[1]
            @test loaded_eq.lhs isa OpExpr
            @test loaded_eq.lhs.op == "D"
            @test loaded_eq.rhs isa OpExpr
            @test loaded_eq.rhs.op == "*"

        finally
            if isfile(temp_file)
                rm(temp_file)
```

