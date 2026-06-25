using Test
using EarthSciSerialization
using JSON3

@testset "JSON Parse and Serialize Tests" begin

    @testset "Expression Parsing" begin
        # Test NumExpr (number)
        expr1 = EarthSciSerialization.parse_expression(3.14)
        @test expr1 isa NumExpr
        @test expr1.value == 3.14

        # Test VarExpr (string)
        expr2 = EarthSciSerialization.parse_expression("x")
        @test expr2 isa VarExpr
        @test expr2.name == "x"

        # Test OpExpr (object with 'op')
        op_data = Dict("op" => "+", "args" => [1.0, "x"])
        expr3 = EarthSciSerialization.parse_expression(op_data)
        @test expr3 isa OpExpr
        @test expr3.op == "+"
        @test length(expr3.args) == 2
        @test expr3.args[1] isa NumExpr
        @test expr3.args[2] isa VarExpr
        @test expr3.wrt === nothing
        @test expr3.dim === nothing

        # Test OpExpr with optional parameters
        op_data_wrt = Dict("op" => "D", "args" => ["x"], "wrt" => "t")
        expr4 = EarthSciSerialization.parse_expression(op_data_wrt)
        @test expr4 isa OpExpr
        @test expr4.op == "D"
        @test expr4.wrt == "t"
        @test expr4.dim === nothing
    end

    @testset "ModelVariableType Parsing" begin
        # Test schema values
        @test EarthSciSerialization.parse_model_variable_type("state") == StateVariable
        @test EarthSciSerialization.parse_model_variable_type("parameter") == ParameterVariable
        @test EarthSciSerialization.parse_model_variable_type("observed") == ObservedVariable

        # Test Julia enum values for compatibility
        @test EarthSciSerialization.parse_model_variable_type("StateVariable") == StateVariable
        @test EarthSciSerialization.parse_model_variable_type("ParameterVariable") == ParameterVariable
        @test EarthSciSerialization.parse_model_variable_type("ObservedVariable") == ObservedVariable
    end

    @testset "Simple ESM File Loading" begin
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
            end
        end
    end

    @testset "Round-trip Serialization" begin
        # Create test data
        metadata = Metadata("test_roundtrip", authors=["Author 1", "Author 2"])

        variables = Dict("x" => ModelVariable(StateVariable, default=1.0))

        lhs = OpExpr("D", Vector{EarthSciSerialization.Expr}([VarExpr("x")]), wrt="t")
        rhs = OpExpr("*", Vector{EarthSciSerialization.Expr}([NumExpr(-0.1), VarExpr("x")]))
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
            end
        end
    end

    @testset "Round-trip: regrid / missing_value (ess-v9a.6)" begin
        # Per-variable regrid config slot survives a load -> save -> load cycle
        # with its typed RegridSpec, including the point cell-averaging
        # missing_value (RFC pure-io-data-loaders §5.2, §6).
        variables = Dict("PM2_5" => ModelVariable(StateVariable, default=0.0))
        lhs = OpExpr("D", Vector{EarthSciSerialization.Expr}([VarExpr("PM2_5")]), wrt="t")
        rhs = OpExpr("-", Vector{EarthSciSerialization.Expr}([VarExpr("PM2_5")]))
        regrid = Dict("PM2_5" => EarthSciSerialization.RegridSpec(
            method="cell_average", missing_value=-999.0,
            description="empty target cells receive the no-data sentinel"))
        model = Model(variables, [Equation(lhs, rhs)]; regrid=regrid)
        original_file = EsmFile("0.6.0", Metadata("regrid_roundtrip"),
                                models=Dict("OpenAQCoupler" => model))
        temp_file = tempname() * ".json"
        try
            save(original_file, temp_file)
            loaded = load(temp_file)
            @test haskey(loaded.models["OpenAQCoupler"].regrid, "PM2_5")
            spec = loaded.models["OpenAQCoupler"].regrid["PM2_5"]
            @test spec isa EarthSciSerialization.RegridSpec
            @test spec.method == "cell_average"
            @test spec.missing_value == -999.0
            @test spec.description == "empty target cells receive the no-data sentinel"
        finally
            isfile(temp_file) && rm(temp_file)
        end
    end

    @testset "IO Stream Interface" begin
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
    end

    @testset "Error Handling" begin
        # Test invalid JSON
        @test_throws ParseError load(IOBuffer("invalid json"))

        # Test missing required fields
        invalid_esm = """{"esm": "0.1.0"}"""  # Missing metadata
        @test_throws SchemaValidationError load(IOBuffer(invalid_esm))

        # Test invalid expression format
        @test_throws ParseError EarthSciSerialization.parse_expression(Dict("invalid" => "data"))
    end

    @testset "v0.5.0 inline multi-series y (plots.y array form)" begin
        esm_json = """
        {
          "esm": "0.5.0",
          "metadata": { "name": "multi_y_test" },
          "models": {
            "AB": {
              "variables": {
                "A": { "type": "state", "default": 1.0 },
                "B": { "type": "state", "default": 0.0 }
              },
              "equations": [
                { "lhs": { "op": "D", "args": ["A"], "wrt": "t" }, "rhs": { "op": "*", "args": [-0.1, "A"] } },
                { "lhs": { "op": "D", "args": ["B"], "wrt": "t" }, "rhs": { "op": "*", "args": [0.1, "A"] } }
              ],
              "examples": [
                {
                  "id": "ab_trace",
                  "time_span": { "start": 0.0, "end": 10.0 },
                  "plots": [
                    {
                      "id": "ab_multi",
                      "type": "line",
                      "x": { "variable": "t" },
                      "y": [
                        { "variable": "A", "label": "Species A" },
                        { "variable": "B", "label": "Species B" }
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        # Schema validation must accept array-form y (v0.5.0 widening).
        esm = load(IOBuffer(esm_json))
        @test esm isa EarthSciSerialization.EsmFile
        @test esm.esm == "0.5.0"
    end

end