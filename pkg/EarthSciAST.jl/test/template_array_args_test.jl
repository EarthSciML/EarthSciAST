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
    {"esm": "2.0.0", "metadata": {"name": "taa_probe"},
     "index_sets": {"c": {"kind": "interval", "size": 3}, "verts": {"kind": "interval", "size": 4},
                    "coord": {"kind": "interval", "size": 2}},
     "models": {"M": {"variables": $(variables), "equations": $(equations)$(extra)}}}
    """
end

@testset "template_array_args (esm-spec §9.6.11)" begin
    @testset "coupled: scalar-declared parameters fed grid arrays, native = interpreter" begin
        ref = _taa_rhs(joinpath(_TAA_DIR, "coupled", "template.esm"), :interpreter)
        got = _taa_rhs(joinpath(_TAA_DIR, "coupled", "template.esm"), :native)
        @test length(ref) == 48
        @test keys(got) == keys(ref)
        # Bit for bit, element by element.
        @test all(k -> reinterpret(UInt64, got[k]) == reinterpret(UInt64, ref[k]), keys(ref))
    end

    # An elementwise application over `[a]` and `[b]` spans their union, the
    # outer product `[a, b]` (esm-spec §4.3.4), so the document builds.
    @testset "arrays over unrelated index sets span their union" begin
        doc = """
        {"esm": "2.0.0", "metadata": {"name": "taa_mismatch"},
         "index_sets": {"a": {"kind": "interval", "size": 2}, "b": {"kind": "interval", "size": 3}},
         "models": {"M": {
           "operator_imports": [{"ref": "esm:std/interp.esm", "only": ["bilinear"]}],
           "variables": {
             "px": {"type": "parameter", "shape": ["a"], "default": [0.5, 1.5]},
             "py": {"type": "parameter", "shape": ["b"], "default": [10.0, 15.0, 20.0]},
             "B": {"type": "unknown"},
             "s": {"type": "unknown", "default": 0.0}},
           "equations": [
             {"lhs": "B", "rhs": {"op": "apply_operator", "args": [], "name": "bilinear",
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
        @test err === nothing
    end

    @testset "an anonymous array argument is refused" begin
        doc = _taa_doc(
            """{"y": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}""",
            """[{"lhs": "y", "rhs": {"op": "apply_operator", "args": [], "name": "linear",
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

    @testset "a template over whole-array operands is not lifted ($compiler)" for compiler in (:interpreter, :native)
        # Both rings are array-role (the body gathers from them), so binding
        # arrays to them is not an elementwise application.
        doc = _taa_doc(
            """{"pa": {"type": "parameter", "shape": ["verts", "coord"],
                  "default": [[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]]},
            "pb": {"type": "parameter", "shape": ["verts", "coord"],
                  "default": [[1.0, 1.0], [3.0, 1.0], [3.0, 3.0], [1.0, 3.0]]},
            "area": {"type": "unknown"}, "s": {"type": "unknown", "default": 0.0}}""",
            """[{"lhs": "area", "rhs": {"op": "apply_operator", "args": [], "name": "overlap",
              "bindings": {"a": "pa", "b": "pb"}}},
            {"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": "area"}]""";
            templates = """{"overlap": {"params": ["a", "b"], "body": {"op": "faq", "output_idx": [],
            "ranges": {"v": [1, 4], "c": [1, 2]}, "args": ["a", "b"],
            "expr": {"op": "*", "args": [{"op": "index", "args": ["a", "v", "c"]},
                                         {"op": "index", "args": ["b", "v", "c"]}]}}}}"""
        )
        file = EarthSciAST.load_string(doc)
        flat = EarthSciAST.promote_downstream_shapes(EarthSciAST.flatten(file))
        area = only(eq for eq in flat.equations if eq.lhs isa EarthSciAST.VarExpr && eq.lhs.name == "M.area")
        @test area.rhs isa EarthSciAST.OpExpr && area.rhs.op == "apply_operator"
        prob = EarthSciAST.esm_problem(file, (0.0, 1.0); compiler = compiler)
        du = fill(NaN, length(prob.u0))
        prob.f!(du, copy(prob.u0), prob.p, 0.0)
        @test du[prob.var_map["M.s"]] == 24.0    # Σ_v,c pa[v,c]·pb[v,c]
    end

    @testset "a shaped read written by hand is not lifted" begin
        # The same reduction the `linear` expansion holds, written by hand: no
        # template application, so the lift leaves it as written and the build
        # refuses it with `faq_bare_array_operand` (esm-spec §4.3.1).
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
        err = try
            EarthSciAST.esm_problem(EarthSciAST.load_string(doc), (0.0, 1.0); compiler = :interpreter)
            nothing
        catch e
            e
        end
        @test err !== nothing && occursin("faq_bare_array_operand", sprint(showerror, err))
    end
end

# The ring stacks the geometry fixtures bind to `overlap_area_planar` are array
# observeds; the interpreter's build substitutes them into the binding, so the
# array parameter is bound to an expression. That reference is expanded for
# its instance (call.jl `_call_expanded_for_array`) rather than refused.
@testset "array parameter bound to an expression: the reference is expanded" begin
    for f in ("polygon_intersection_area_planar", "polygon_intersection_area_padded_ring")
        file = EarthSciAST.load_path(joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "geometry", "$f.esm"))
        prob = EarthSciAST.esm_problem(file, (0.0, 1.0); compiler = :interpreter)
        du = similar(prob.u0)
        prob.f!(du, prob.u0, prob.p, 0.0)
        @test du ≈ [1.0] atol = 1.0e-9
    end
end

# An array parameter bound to a COMPUTED array — a makearray whose region is an
# array-valued application, or an array-valued application read at other
# subscripts — is evaluated once in the caller, as the build's own array
# observed, and passed whole (call.jl `_hoist_array_arguments`); the reference
# is not expanded. The conformance fixture's tendencies, under both compilers.
@testset "array parameter bound to a computed array: passed as an argument" begin
    path = joinpath(
        TESTUTILS_REPO_ROOT, "tests", "conformance", "array_expression_forms",
        "fixtures", "computed_array_argument.esm"
    )
    for compiler in (:interpreter, :native)
        u0 = Dict{String, Float64}()
        for (i, x) in enumerate((1.0, 2.0, 4.0, 8.0))
            u0["a[$i]"] = x
            u0["v[$i]"] = 0.0
            u0["w[$i]"] = 0.0
        end
        prob = EarthSciAST.esm_problem(
            EarthSciAST.load_path(path), (0.0, 1.0); compiler = compiler, u0 = u0
        )
        slot(n) = prob.var_map[only(k for k in keys(prob.var_map) if k == n || endswith(k, "." * n))]
        du = similar(prob.u0)
        prob.f!(du, prob.u0, prob.p, 0.0)
        at(n) = du[slot(n)]
        @test [at("v[$i]") for i in 1:4] == [1.5, 1.5, 3.0, -6.0]
        @test [at("w[$i]") for i in 1:4] == [48.0, 24.0, 12.0, 6.0]
        @test all(iszero, (at("a[$i]") for i in 1:4))
    end
end

# Variants of that fixture: the computed array of `D(v)` (`face_difference`'s
# F) replaced, or the reference moved to another site.
function _caa_variant(f!)
    path = joinpath(
        TESTUTILS_REPO_ROOT, "tests", "conformance", "array_expression_forms",
        "fixtures", "computed_array_argument.esm"
    )
    d = _normj(JSON3.read(read(path, String)))
    m = d["models"]["computed_array_argument"]
    f!(m, m["equations"][2]["rhs"])
    return EarthSciAST.load_string(JSON3.write(d))
end
_caa_build(file; compiler = :interpreter) = EarthSciAST.esm_problem(
    file, (0.0, 1.0); compiler = compiler,
    u0 = Dict{String, Float64}(
        "a[1]" => 1.0, "a[2]" => 2.0, "a[3]" => 4.0, "a[4]" => 8.0,
        ("$n[$i]" => 0.0 for n in ("v", "w") for i in 1:4)...
    )
)
function _caa_refusal(file)
    err = try
        _caa_build(file)
        nothing
    catch e
        e
    end
    return err isa EarthSciAST.TreeWalkError ? sprint(showerror, err) : repr(err)
end
_caa_cells(from = "cells") = Dict{String, Any}("from" => from)
_caa_ref(name, bindings) = Dict{String, Any}(
    "op" => "apply_operator", "args" => Any[], "name" => name, "bindings" => bindings
)

@testset "array parameter bound to a computed array: what is refused, and where" begin
    # A computed array whose own expression binds a computed array: each gets
    # an array of its own (the inner one is the whole-array reference
    # twice(a), read by faces_interior at other subscripts).
    file = _caa_variant() do _, call
        inner = call["bindings"]["F"]["values"][1]
        inner["bindings"]["q"] = _caa_ref("twice", Dict{String, Any}("q" => "a"))
    end
    for compiler in (:interpreter, :native)
        prob = _caa_build(file; compiler = compiler)
        du = similar(prob.u0)
        prob.f!(du, prob.u0, prob.p, 0.0)
        slot(n) = prob.var_map[only(k for k in keys(prob.var_map) if k == n || endswith(k, "." * n))]
        @test [du[slot("v[$i]")] for i in 1:4] == [3.0, 3.0, 6.0, -12.0]
        @test [du[slot("w[$i]")] for i in 1:4] == [48.0, 24.0, 12.0, 6.0]
    end

    # A faq whose element is a reduction (so the build does not read it
    # lazily), F[f] = f * sum(a) = 15 f: over [1, 5] it is passed as an array;
    # over [2, 6] its axis does not start at 1, so its extents are not an
    # array's, and it is refused.
    reduced_F(lo, hi) = _caa_variant() do _, call
        call["bindings"]["F"] = Dict{String, Any}(
            "op" => "faq", "args" => Any["a"], "output_idx" => Any["f"],
            "ranges" => Dict{String, Any}("f" => Any[lo, hi]),
            "expr" => Dict{String, Any}(
                "op" => "faq", "args" => Any["a"], "output_idx" => Any[],
                "ranges" => Dict{String, Any}("j" => _caa_cells()),
                "expr" => Dict{String, Any}(
                    "op" => "*", "args" => Any["f", Dict{String, Any}("op" => "index", "args" => Any["a", "j"])]
                )
            )
        )
    end
    prob = _caa_build(reduced_F(1, 5))
    du = similar(prob.u0)
    prob.f!(du, prob.u0, prob.p, 0.0)
    @test [du[prob.var_map[only(k for k in keys(prob.var_map) if endswith(k, "v[$i]"))]] for i in 1:4] ==
        fill(15.0, 4)
    msg = _caa_refusal(reduced_F(2, 6))
    @test occursin("face_difference", msg) && occursin("cannot be compiled as a call", msg)

    # A reference inside the computed array that does not compile is refused
    # by name: faces_interior's q bound to a filtered faq.
    file = _caa_variant() do _, call
        inner = call["bindings"]["F"]["values"][1]
        inner["bindings"]["q"] = Dict{String, Any}(
            "op" => "faq", "args" => Any["a"], "output_idx" => Any["i"],
            "ranges" => Dict{String, Any}("i" => _caa_cells()),
            "filter" => Dict{String, Any}("op" => ">", "args" => Any["i", 1]),
            "expr" => Dict{String, Any}("op" => "index", "args" => Any["a", "i"])
        )
    end
    msg = _caa_refusal(file)
    @test occursin("faces_interior", msg) && occursin("cannot be compiled as a call", msg)

    # Outside the model's own equations (here an initialization equation that
    # seeds v's cells) the binding is refused, naming the parameter.
    file = _caa_variant() do m, call
        m["initialization_equations"] = Any[
            Dict{String, Any}(
                "lhs" => "v",
                "rhs" => Dict{String, Any}(
                    "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
                    "ranges" => Dict{String, Any}("i" => _caa_cells()),
                    "expr" => Dict{String, Any}("op" => "index", "args" => Any[deepcopy(call), "i"])
                ),
            ),
        ]
    end
    msg = _caa_refusal(file)
    @test occursin("face_difference", msg) && occursin("'F' is bound to a computed array outside", msg)

    # Diagnostics name such an array as an argument, under its equation.
    @test EarthSciAST._hoist_public_label("\0hoist\0argarr1\0v") == "v (hoisted array argument)"
    @test occursin("array argument", EarthSciAST._rule_display("\0hoist\0argarr1\0v"))
    @test occursin("nested reduction", EarthSciAST._rule_display("\0hoist\01\0v"))
end
