# esm-spec §9.6.11: an expression template applied with an array bound to a
# scalar-role parameter is evaluated elementwise. The nine single-model cases
# run as the `template_array_args` inline-test conformance tier; this file pins
# the coupled case (a parameter the component declares scalar, fed a grid array
# by `variable_map`), the parameter roles, and the shape-mismatch refusal.

using Test
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _TAA_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "template_array_args")

function _taa_rhs(path::AbstractString, compiler::Symbol)
    prob = EarthSciAST.esm_problem(EarthSciAST.load_path(path), (0.0, 1.0); compiler = compiler)
    prog = EarthSciAST.rhs_program(prob)
    du = zeros(length(prob.u0))
    EarthSciAST.rhs!(
        du, prog, EarthSciAST.rhs_workspace(prog), copy(prob.u0),
        zeros(EarthSciAST.tile_layout(prog).n_aux), EarthSciAST.parameter_vector(prog), 0.0,
        EarthSciAST.default_forcing_set(prog)
    )
    names = Vector{String}(undef, length(du))
    for (k, v) in prob.var_map
        names[Int(v)] = String(k)
    end
    return Dict(zip(names, du))
end

@testset "template_array_args (esm-spec §9.6.11)" begin
    @testset "parameter roles of lib/interp.esm" begin
        lib = EarthSciAST.JSON3.read(read(joinpath(TESTUTILS_REPO_ROOT, "lib", "interp.esm"), String), Dict{String, Any})
        roles = EarthSciAST._template_array_roles(lib["expression_templates"])
        @test roles["linear"] == Set(["table", "axis"])
        @test roles["bilinear"] == Set(["table", "axis_x", "axis_y"])
        @test roles["searchsorted"] == Set(["xs"])
    end

    @testset "coupled: scalar-declared parameters fed grid arrays ($compiler)" for compiler in (:interpreter, :native)
        ref = _taa_rhs(joinpath(_TAA_DIR, "coupled", "fn.esm"), compiler)
        got = _taa_rhs(joinpath(_TAA_DIR, "coupled", "template.esm"), compiler)
        @test length(ref) == 48
        @test keys(got) == keys(ref)
        # Bit for bit, element by element.
        @test all(k -> reinterpret(UInt64, got[k]) == reinterpret(UInt64, ref[k]), keys(ref))
    end

    @testset "arrays over unrelated index sets are refused" begin
        doc = """
        {"esm": "1.2.0", "metadata": {"name": "taa_mismatch"},
         "index_sets": {"a": {"kind": "interval", "size": 2}, "b": {"kind": "interval", "size": 3}},
         "models": {"M": {
           "expression_template_imports": [{"ref": "esm:std/interp.esm", "only": ["bilinear"]}],
           "variables": {
             "px": {"type": "parameter", "shape": ["a"], "default": [0.5, 1.5]},
             "py": {"type": "parameter", "shape": ["b"], "default": [10.0, 15.0, 20.0]},
             "B": {"type": "unknown"},
             "s": {"type": "unknown", "default": 0.0}},
           "equations": [
             {"lhs": "B", "rhs": {"op": "apply_expression_template", "args": [], "name": "bilinear",
               "bindings": {"table": {"op": "const", "args": [], "value": [[1.0, 2.0], [3.0, 4.0]]},
                            "axis_x": {"op": "const", "args": [], "value": [0.0, 2.0]},
                            "axis_y": {"op": "const", "args": [], "value": [10.0, 20.0]},
                            "x": "px", "y": "py", "nx": 2, "ny": 2}}},
             {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 1.0}]}}}
        """
        err = try
            EarthSciAST.esm_problem(EarthSciAST.load_string(doc), (0.0, 1.0); compiler = :interpreter)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("array_shape_mismatch", sprint(showerror, err)) ||
            occursin("conflicting operand shapes", sprint(showerror, err))
    end
end
