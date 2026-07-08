# Simple ESM File Loading (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/parse_test.jl`

```julia
# Create a minimal ESM file
        test_json = """
        {
          "esm": "0.1.0",
          "metadata": {
            "name": "test_model",
            "description": "Test model",
            "authors": ["Test Author"]
          },
          "models": {
            "simple": {
              "variables": {
                "x": {
                  "type": "state",
                  "default": 1.0,
                  "description": "State variable x"
                }
              },
              "equations": [
                {
                  "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                  "rhs": {"op": "*", "args": [-0.1, "x"]}
                }
              ]
            }
          }
        }
        """

        # Write to temp file
        temp_file = tempname() * ".json"
        write(temp_file, test_json)

        try
            # Test loading
            esm_file = load(temp_file)

            @test esm_file.esm == "0.1.0"
            @test esm_file.metadata.name == "test_model"
            @test esm_file.metadata.description == "Test model"
            @test esm_file.metadata.authors == ["Test Author"]

            @test esm_file.models !== nothing
            @test haskey(esm_file.models, "simple")

            model = esm_file.models["simple"]
            @test haskey(model.variables, "x")

            var_x = model.variables["x"]
            @test var_x.type == StateVariable
            @test var_x.default == 1.0
            @test var_x.description == "State variable x"

            @test length(model.equations) == 1
            eq = model.equations[1]
            @test eq.lhs isa OpExpr
            @test eq.lhs.op == "D"
            @test eq.lhs.wrt == "t"
            @test eq.rhs isa OpExpr
            @test eq.rhs.op == "*"

        finally
            # Clean up
            if isfile(temp_file)
                rm(temp_file)
```

