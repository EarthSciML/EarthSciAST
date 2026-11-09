# The `cast` op (esm-spec §4.2, §11.3.1; CONFORMANCE_SPEC §5.18.2a): the one
# conversion between binary64 and binary32. The fixtures are shared with the
# other four bindings (`tests/conformance/element_type_cast/`). This binding
# evaluates binary64 only, so it asserts `casts` (load and load → emit → load
# keep every cast's `element_type`), `binary64_values` (a cast to Float64 is the
# identity, bit for bit) and `binary64_refusals` (a cast to Float32, or a
# Float32 document, is refused with `float32_unsupported`, never evaluated as the
# identity). `values` and `build_errors` belong to the bindings in `evaluated_by`.

using Test
using JSON3
using EarthSciAST

@testset "element_type_cast: cast between Float64 and Float32 (§11.3.1)" begin
    EA = EarthSciAST
    dir = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "element_type_cast")
    expected = JSON3.read(read(joinpath(dir, "expected.json"), String), Dict{String, Any})
    emitted(file) = JSON3.read(JSON3.write(EA.serialize_esm_file(file)), Dict{String, Any})

    # Every `cast` node's `element_type` in the models' equations, in document
    # order (a node before its operands).
    function casts(doc)
        out = Any[]
        function walk(x)
            if x isa AbstractDict
                get(x, "op", nothing) == "cast" && push!(out, get(x, "element_type", nothing))
                foreach(walk, values(x))
            elseif x isa AbstractVector
                foreach(walk, x)
            end
            return nothing
        end
        for (_, model) in get(doc, "models", Dict())
            foreach(walk, get(model, "equations", Any[]))
        end
        return out
    end

    @testset "casts: $(fixture)" for (fixture, want) in expected["casts"]
        doc = emitted(EA.load_path(joinpath(dir, fixture)))
        @test casts(doc) == collect(Any, want)
        # load -> emit -> load keeps them.
        again = emitted(EA.load_string(JSON3.write(doc)))
        @test casts(again) == collect(Any, want)
        @test again == doc
    end

    @testset "binary64_values: $(fixture)" for (fixture, want) in expected["binary64_values"]
        for c in (:native, :interpreter)
            prob = esm_problem(EA.load_path(joinpath(dir, fixture)), (0.0, 0.0); compiler = c)
            for (name, value) in want
                got = Float64(EA.observed_field(prob, name)[1])
                @test bitstring(got) == bitstring(Float64(value))
            end
        end
    end

    @testset "binary64_refusals: $(fixture)" for (fixture, code) in expected["binary64_refusals"]
        for c in (:native, :interpreter)
            err = try
                esm_problem(EA.load_path(joinpath(dir, fixture)), (0.0, 0.0); compiler = c)
                nothing
            catch e
                e
            end
            @test err isa EA.TreeWalkError
            @test err !== nothing && err.code == code
        end
    end

    # Every evaluator path, not only the up-front build refusal.
    to32 = OpExpr("cast", EA.ASTExpr[VarExpr("x")]; element_type = "Float32")
    to64 = OpExpr("cast", EA.ASTExpr[VarExpr("x")]; element_type = "Float64")
    @testset "evaluate_expr" begin
        @test EA.evaluate_expr(to64, Dict("x" => 0.1)) === 0.1
        err = try
            EA.evaluate_expr(to32, Dict("x" => 0.1))
        catch e
            e
        end
        @test err isa EA.TreeWalkError && err.code == "float32_unsupported"
    end
    @testset "codegen" begin
        @test EA.format_julia_expression(to64) == "x"
        @test_throws EA.TreeWalkError EA.format_julia_expression(to32)
    end
    @testset "display and text parse" begin
        @test EA.format_expression(to32, :ascii) == "cast(x, element_type=Float32)"
        back = EA.parse_expression(EA.format_expression(to32, :ascii))
        @test back isa OpExpr && back.op == "cast" && back.element_type == "Float32"
        for bad in (
                "cast(x)", "cast(x, y, element_type=Float32)",
                "cast(x, element_type=Float16)", "cast(x, Float32)",
                "cast(x, element_type=Float32, manifold=sphere)",
            )
            @test_throws EA.ExpressionParseError EA.parse_expression(bad)
        end
    end
    @testset "a cast has its operand's units" begin
        units = Dict("x" => "m/s")
        got = EA.get_expression_dimensions(to32, units)
        @test got !== nothing
        @test EA._exact_scale(got) == EA._exact_scale(EA.parse_units("m/s"))
    end
    @testset "canonical JSON keeps the precision" begin
        @test EA.canonical_json(to32) == "{\"args\":[\"x\"],\"element_type\":\"Float32\",\"op\":\"cast\"}"
        @test EA.canonical_json(to32) != EA.canonical_json(to64)
    end
end
