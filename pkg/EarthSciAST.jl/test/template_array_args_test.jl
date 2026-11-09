# esm-spec §9.6.11: an expression template applied with an array bound to a
# scalar-role parameter is evaluated elementwise. The nine single-model cases
# run as the `template_array_args` inline-test conformance tier; this file pins
# the coupled case (a parameter the component declares scalar, fed a grid array
# by `variable_map`), the refusals (arrays over unrelated index sets, an
# anonymous array argument), and what is not lifted: a template whose operands
# its body takes whole, and a shaped read written by hand.

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

# A one-model document over index sets `c`, `verts` and `coord`.
function _taa_doc(variables, equations; templates = nothing, imports = nothing)
    extra = (templates === nothing ? "" : ", \"expression_templates\": $(templates)") *
        (imports === nothing ? "" : ", \"expression_template_imports\": $(imports)")
    return """
    {"esm": "1.2.0", "metadata": {"name": "taa_probe"},
     "index_sets": {"c": {"kind": "interval", "size": 3}, "verts": {"kind": "interval", "size": 4},
                    "coord": {"kind": "interval", "size": 2}},
     "models": {"M": {"variables": $(variables), "equations": $(equations)$(extra)}}}
    """
end

@testset "template_array_args (esm-spec §9.6.11)" begin
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

    @testset "an anonymous array argument is refused" begin
        doc = _taa_doc(
            """{"y": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}""",
            """[{"lhs": "y", "rhs": {"op": "apply_expression_template", "args": [], "name": "linear",
              "bindings": {"table": {"op": "const", "args": [], "value": [1.0, 2.0, 4.0]},
                           "axis": {"op": "const", "args": [], "value": [0.0, 1.0, 2.0]},
                           "x": {"op": "const", "args": [], "value": [0.5, 1.5]}, "n": 3}}},
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 1.0}]""";
            imports = """[{"ref": "esm:std/interp.esm", "only": ["linear"]}]"""
        )
        err = try
            EarthSciAST.esm_problem(EarthSciAST.load_string(doc), (0.0, 1.0); compiler = :interpreter)
            nothing
        catch e
            e
        end
        @test err isa EarthSciAST.DimensionPromotionError
        @test occursin("array_shape_mismatch: 'M.y'", sprint(showerror, err))
        @test occursin("anonymous array", sprint(showerror, err))
    end

    @testset "a template over geometry operands is not lifted ($compiler)" for compiler in (:interpreter, :native)
        # Both rings are array-role (a geometry operator takes them whole), so
        # binding arrays to them is not an elementwise application.
        doc = _taa_doc(
            """{"pa": {"type": "parameter", "shape": ["verts", "coord"],
                  "default": [[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]]},
            "pb": {"type": "parameter", "shape": ["verts", "coord"],
                  "default": [[1.0, 1.0], [3.0, 1.0], [3.0, 3.0], [1.0, 3.0]]},
            "area": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}""",
            """[{"lhs": "area", "rhs": {"op": "apply_expression_template", "args": [], "name": "overlap",
              "bindings": {"a": "pa", "b": "pb"}}},
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "area"}]""";
            templates = """{"overlap": {"params": ["a", "b"], "body": {"op": "polygon_intersection_area",
            "manifold": "planar", "args": ["a", "b"]}}}"""
        )
        file = EarthSciAST.load_string(doc)
        flat = EarthSciAST.promote_downstream_shapes(EarthSciAST.flatten(file))
        area = only(eq for eq in flat.equations if eq.lhs isa EarthSciAST.VarExpr && eq.lhs.name == "M.area")
        @test area.rhs isa EarthSciAST.OpExpr && area.rhs.op == "apply_expression_template"
        prob = EarthSciAST.esm_problem(file, (0.0, 1.0); compiler = compiler)
        du = fill(NaN, length(prob.u0))
        prob.f!(du, copy(prob.u0), prob.p, 0.0)
        @test du[prob.var_map["M.s"]] == 1.0
    end

    @testset "a shaped read written by hand is not lifted" begin
        # The same reduction the `linear` expansion holds, written by hand: no
        # template application, so the lift leaves it as written.
        doc = _taa_doc(
            """{"u": {"type": "parameter", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
            "tot": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}""",
            """[{"lhs": "tot", "rhs": {"op": "faq", "args": [], "output_idx": [],
              "ranges": {"k": {"from": "c"}}, "expr": "u"}},
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "tot"}]"""
        )
        flat = EarthSciAST.flatten(EarthSciAST.load_string(doc))
        tot(f) = only(eq for eq in f.equations if eq.lhs isa EarthSciAST.VarExpr && eq.lhs.name == "M.tot").rhs
        @test tot(EarthSciAST.promote_downstream_shapes(flat)) == tot(flat)
    end
end
