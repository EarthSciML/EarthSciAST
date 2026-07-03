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

        # Test OpExpr (object with 'op'). Use a NON-integral float literal:
        # `parse_expression` applies CONFORMANCE_SPEC §5.5.3.1 rule 1, so an
        # integral-valued float (`1.0`) narrows to an IntExpr; a genuinely
        # fractional float stays a NumExpr.
        op_data = Dict("op" => "+", "args" => [1.5, "x"])
        expr3 = EarthSciSerialization.parse_expression(op_data)
        @test expr3 isa OpExpr
        @test expr3.op == "+"
        @test length(expr3.args) == 2
        @test expr3.args[1] isa NumExpr
        @test expr3.args[2] isa VarExpr
        @test expr3.wrt === nothing
        @test expr3.dim === nothing

        # §5.5.3.1 rule 1: an integral-valued float literal is an integer
        # literal, regardless of source spelling. This makes an integer ratio
        # `{op:"/",args:[1,N]}` inside an `aggregate` `expr` body byte-stable
        # across bindings even when JSON3's context-dependent number inference
        # materialises a bare integer token as Float64 (aggregate int-division
        # cross-binding canonical-form fix).
        @test EarthSciSerialization.parse_expression(1.0) isa IntExpr
        @test EarthSciSerialization.parse_expression(8.0) == IntExpr(8)
        int_ratio = EarthSciSerialization.parse_expression(
            Dict("op" => "/", "args" => [1.0, 8.0]))
        @test int_ratio.args[1] isa IntExpr
        @test int_ratio.args[2] isa IntExpr
        @test EarthSciSerialization.parse_expression(2.5) isa NumExpr

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

    @testset "v0.8.0 variable_map expression transform (esm-spec §10.4)" begin
        esm_json = """
        {
          "esm": "0.8.0",
          "metadata": { "name": "vm_expr_transform_test" },
          "models": {
            "Src": {
              "variables": {
                "F": { "type": "observed", "units": "1", "expression": 4.0 }
              },
              "equations": []
            },
            "Sink": {
              "variables": {
                "u": { "type": "state", "default": 0.0 },
                "offset": { "type": "parameter", "default": 1.5, "units": "1" },
                "F_in": { "type": "parameter", "units": "1" }
              },
              "equations": [
                { "lhs": { "op": "D", "args": ["u"], "wrt": "t" }, "rhs": "F_in" }
              ]
            }
          },
          "coupling": [
            {
              "type": "variable_map",
              "from": "Src.F",
              "to": "Sink.F_in",
              "transform": { "op": "+", "args": [ { "op": "*", "args": [2.0, "Src.F"] }, "Sink.offset" ] }
            }
          ]
        }
        """
        # Schema validation must accept the object-form transform (0.8.0 widening).
        esm = load(IOBuffer(esm_json))
        @test esm isa EarthSciSerialization.EsmFile
        entry = esm.coupling[1]
        @test entry isa CouplingVariableMap
        @test entry.transform isa EarthSciSerialization.Expr
        tr = entry.transform::EarthSciSerialization.OpExpr
        @test tr.op == "+"

        # Round-trip: the expression transform re-serializes losslessly.
        buf = IOBuffer()
        save(esm, buf)
        reparsed = JSON3.read(String(take!(buf)))
        rt = reparsed.coupling[1].transform
        @test rt.op == "+"
        @test rt.args[1].op == "*"
        @test rt.args[1].args[2] == "Src.F"
        @test rt.args[2] == "Sink.offset"

        # factor + expression transform is rejected.
        bad = replace(esm_json,
            "\"transform\": { \"op\": \"+\"" =>
            "\"factor\": 2.0, \"transform\": { \"op\": \"+\"")
        @test_throws Exception load(IOBuffer(bad))
    end

    @testset "Integer ratio inside aggregate stays integer (§5.5.3.1)" begin
        # Regression guard for the aggregate int-division cross-binding divergence
        # (CONFORMANCE_SPEC §5.5.3.1 rule 1). JSON3's context-dependent structural
        # number inference materialises a bare integer token (`1`, `8`) as Float64
        # when an integer ratio `{op:/,args:[1,N]}` is authored inside an
        # `aggregate` `expr` body that is a sibling of a non-integral float (here
        # `cos(pi * ...)`), so the same ratio would round-trip as `1.0/8.0` in
        # Julia but `1/8` in the other four bindings — a byte divergence the AST
        # rule-1 narrowing at the parse boundary removes.
        doc = """
        {
          "esm": "0.8.0",
          "metadata": { "name": "agg_int_ratio_regression" },
          "index_sets": { "x": { "kind": "interval", "size": 8 } },
          "models": { "M": {
            "variables": {
              "u": { "type": "state", "shape": ["x"] },
              "dx": { "type": "observed", "units": "1", "expression": { "op": "/", "args": [1, 8] } }
            },
            "equations": [
              { "lhs": { "op": "aggregate", "output_idx": ["i"], "args": [],
                         "ranges": { "i": { "from": "x" } },
                         "expr": { "op": "D", "args": [ { "op": "index", "args": ["u","i"] } ], "wrt": "t" } },
                "rhs": { "op": "aggregate", "output_idx": ["i"], "args": [],
                         "ranges": { "i": { "from": "x" } },
                         "expr": { "op": "cos", "args": [ { "op": "*", "args": [ 3.141592653589793,
                                     { "op": "*", "args": [ { "op": "-", "args": ["i", 0.5] },
                                                            { "op": "/", "args": [1, 8] } ] } ] } ] } } }
            ]
          } }
        }
        """
        # The raw JSON3 lazy reader corrupts the integer tokens for this shape:
        # this asserts the fixture actually exercises the bug being guarded (the
        # `1/8` INSIDE the aggregate widens to `1.0/8.0`, while the standalone
        # `dx = 1/8` outside the aggregate stays integer).
        raw = JSON3.write(JSON3.read(doc))
        @test occursin("[1.0,8.0]", raw)          # JSON3 widened the in-aggregate ratio
        @test occursin("[1,8]", raw)              # the standalone dx=1/8 stayed integer

        # `load` narrows integral floats at the AST-literal boundary, so every
        # integer ratio — inside the aggregate AND the standalone `dx` — is an
        # IntExpr and re-serializes as a bare integer.
        file = load(IOBuffer(doc))
        s = JSON3.write(EarthSciSerialization.serialize_esm_file(file))
        @test occursin("[1,8]", s)                 # ratios preserved as integers
        @test !occursin("[1.0,8.0]", s)            # NO float promotion survives
        @test !occursin("1.0,8.0", s)

        # Every `/` node's operands are IntExpr, and it evaluates as TRUE division.
        u_rate_dx = file.models["M"].variables["dx"].expression
        @test u_rate_dx.args[1] isa IntExpr
        @test u_rate_dx.args[2] isa IntExpr
        @test EarthSciSerialization.evaluate_expr(u_rate_dx, Dict{String,Float64}()) == 0.125
    end

end