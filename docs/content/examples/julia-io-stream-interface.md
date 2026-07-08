# IO Stream Interface (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/parse_test.jl`

```julia
# Test with IO streams
        test_json = """
        {
          "esm": "0.1.0",
          "metadata": {
            "name": "stream_test",
            "authors": ["Stream Author"]
          },
          "models": {
            "stream_model": {
              "variables": {
                "y": {
                  "type": "parameter",
                  "default": 2.5
                }
              },
              "equations": []
            }
          }
        }
        """

        # Test loading from IOBuffer
        input_buffer = IOBuffer(test_json)
        esm_file = load(input_buffer)

        @test esm_file.metadata.name == "stream_test"
        @test haskey(esm_file.models, "stream_model")
        @test esm_file.models["stream_model"].variables["y"].type == ParameterVariable
        @test esm_file.models["stream_model"].variables["y"].default == 2.5

        # Test saving to IOBuffer
        output_buffer = IOBuffer()
        save(esm_file, output_buffer)

        # Parse the output to verify
        output_json = String(take!(output_buffer))
        parsed_output = JSON3.read(output_json)

        @test parsed_output.metadata.name == "stream_test"
        @test parsed_output.models.stream_model.variables.y.type == "parameter"
        @test parsed_output.models.stream_model.variables.y.default == 2.5
```

