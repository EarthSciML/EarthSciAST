# The `argmin` / `argmax` templates of lib/relational.esm against the
# `argmin` / `argmax` arg-witness ops.
#
# 1. Every scenario of tests/conformance/relational_templates/scenarios.json
#    through the expanded template, under the interpreter and strict native,
#    must give the scenario's `expected` 1-based index; the op (the value-
#    invention front door, the candidates as a caller array) must give the same
#    index, except where the scenario pins `op_expected` (a NaN candidate after
#    the first, which the op skips and the template picks).
# 2. Every argmin/argmax fixture that computes an assignment, with each op
#    node rewritten as the template (the op's `arg` renamed to the template's
#    loop symbol, n the size of its candidate set) and its caller data written
#    as `const` unknowns, gives the op's assignment buffer under both compilers.
# 3. The tier's two documents pass their own inline tests under both compilers.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5  # the solver `run_inline_tests` picks

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RT_ROOT = TESTUTILS_REPO_ROOT
const _RT_LIB = joinpath(_RT_ROOT, "lib", "relational.esm")
const _RT_TIER = joinpath(_RT_ROOT, "tests", "conformance", "relational_templates")

_rt_decode(v) = v == "NaN" ? NaN : v == "Inf" ? Inf : v == "-Inf" ? -Inf : Float64(v)
# A candidate as `num / den`, so a non-finite one fits in a `const`.
_rt_num_den(v) = v == "NaN" ? (0.0, 0.0) : v == "Inf" ? (1.0, 0.0) :
    v == "-Inf" ? (-1.0, 0.0) : (Float64(v), 1.0)
_rt_const(a) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => a)
_rt_doc(model) = Dict{String, Any}(
    "esm" => "1.1.0",
    "metadata" => Dict{String, Any}("name" => "relational_template_probe", "authors" => Any["t"]),
    "models" => Dict{String, Any}("M" => model)
)

# The template's value per compiler, as the derivative of a state `r`.
function _rt_template_values(op::String, values)
    sym = "k_$(op)_1"
    nd = [_rt_num_den(v) for v in values]
    f = Dict{String, Any}(
        "op" => "/", "args" => Any[
            Dict{String, Any}("op" => "index", "args" => Any[_rt_const(first.(nd)), sym]),
            Dict{String, Any}("op" => "index", "args" => Any[_rt_const(last.(nd)), sym]),
        ]
    )
    model = Dict{String, Any}(
        "expression_template_imports" => Any[Dict{String, Any}("ref" => "relational.esm")],
        "variables" => Dict{String, Any}(
            "r" => Dict{String, Any}("type" => "unknown", "units" => "1", "default" => 0.0)
        ),
        "equations" => Any[
            Dict{String, Any}(
                "lhs" => Dict{String, Any}("op" => "D", "args" => Any["r"], "wrt" => "t"),
                "rhs" => Dict{String, Any}(
                    "op" => "apply_expression_template", "args" => Any[], "name" => op,
                    "bindings" => Dict{String, Any}("f" => f, "n" => length(values))
                )
            ),
        ]
    )
    file = load_string(JSON3.write(_rt_doc(model)); base_path = dirname(_RT_LIB))
    return map((:interpreter, :native)) do compiler
        f!, u0, p, _, vm = EarthSciAST._build_evaluator(file; compiler)
        du = similar(u0)
        f!(du, u0, p, 0.0)
        du[vm["r"]]
    end
end

function _rt_op_value(op::String, values)
    raw = Dict{String, Any}(
        "esm" => "1.1.0",
        "metadata" => Dict{String, Any}("name" => "relational_op_probe"),
        "index_sets" => Dict{String, Any}(
            "points" => Dict{String, Any}("kind" => "interval", "size" => 1),
            "cands" => Dict{String, Any}("kind" => "interval", "size" => length(values))
        ),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "c" => Dict{String, Any}("type" => "parameter", "shape" => Any["cands"]),
                    "a" => Dict{String, Any}("type" => "unknown", "shape" => Any["points"])
                ),
                "equations" => Any[
                    Dict{String, Any}(
                        "lhs" => Dict{String, Any}("op" => "index", "args" => Any["a", "i"]),
                        "rhs" => Dict{String, Any}(
                            "op" => "faq", "output_idx" => Any["i"], "args" => Any["c"],
                            "ranges" => Dict{String, Any}("i" => Dict{String, Any}("from" => "points")),
                            "expr" => Dict{String, Any}(
                                "op" => op, "args" => Any["c"], "arg" => "g",
                                "ranges" => Dict{String, Any}("g" => Dict{String, Any}("from" => "cands")),
                                "expr" => Dict{String, Any}("op" => "index", "args" => Any["c", "g"])
                            )
                        )
                    ),
                ]
            )
        )
    )
    file = EarthSciAST.coerce_esm_file(JSON3.read(JSON3.write(raw)))
    m = EarthSciAST._select_model(file, "M")
    ca = Dict{String, Any}("c" => [_rt_decode(v) for v in values])
    vi = EarthSciAST.materialize_value_invention(m, file.index_sets, ca, Dict{String, Float64}())
    return only(vi.assignments["a"])
end

@testset "lib/relational.esm argmin/argmax templates" begin
    scenarios = JSON3.read(read(joinpath(_RT_TIER, "scenarios.json"), String)).scenarios
    @testset "scenario $(s.name)" for s in scenarios
        op, values, expected = String(s.op), collect(s.values), Int(s.expected)
        interp, native = _rt_template_values(op, values)
        @test interp === Float64(expected)
        @test native === Float64(expected)
        op_expected = haskey(s, :op_expected) ? Int(s.op_expected) : expected
        @test _rt_op_value(op, values) == op_expected
    end
end

# ---------------------------------------------------------------------------
# Fixture rewrite: each op node `{op: argmin, arg: g, ranges: {g: {from: S}},
# expr: E}` (no `join`/`filter`) becomes `apply_expression_template(argmin,
# f = E[g -> k_argmin_1], n = |S|)`. Caller data become `x ~ const(data)`
# unknowns and each arg-witness output `a` drives a state `w_a` with
# `D(w_a[i]) = a[i]`, so the derivative at t = 0 is the assignment buffer.
# Equations other than the arg-witness assignments, and data they do not
# read, are dropped.

_rt_rename(e::AbstractString, a, b) = e == a ? b : String(e)
_rt_rename(e::AbstractVector, a, b) = Any[_rt_rename(x, a, b) for x in e]
_rt_rename(e::AbstractDict, a, b) = Dict{String, Any}(String(k) => _rt_rename(v, a, b) for (k, v) in e)
_rt_rename(e, a, b) = e

_rt_is_witness(e) = e isa AbstractDict && get(e, "op", nothing) in ("argmin", "argmax")
_rt_has_witness(e) = _rt_is_witness(e) ||
    (e isa AbstractDict && any(_rt_has_witness, values(e))) ||
    (e isa AbstractVector && any(_rt_has_witness, e))

function _rt_to_template(e, index_sets)
    if _rt_is_witness(e)
        @assert !haskey(e, "join") && !haskey(e, "filter") "no template counterpart for a gated arg-witness"
        op = String(e["op"])
        arg = String(e["arg"])
        (sym, spec), = collect(e["ranges"])
        @assert String(sym) == arg
        n = index_sets[String(spec["from"])]["size"]
        return Dict{String, Any}(
            "op" => "apply_expression_template", "args" => Any[], "name" => op,
            "bindings" => Dict{String, Any}("f" => _rt_rename(e["expr"], arg, "k_$(op)_1"), "n" => n)
        )
    elseif e isa AbstractDict
        return Dict{String, Any}(String(k) => _rt_to_template(v, index_sets) for (k, v) in e)
    elseif e isa AbstractVector
        return Any[_rt_to_template(x, index_sets) for x in e]
    end
    return e
end

function _rt_template_buffers(rel, model_name, data)
    raw = EarthSciAST.Cadence.to_native(JSON3.read(read(joinpath(_RT_ROOT, rel), String)))
    isets = raw["index_sets"]
    m = raw["models"][model_name]
    vars = Dict{String, Any}()
    eqs = Any[]
    outputs = String[]
    witness_text = join((JSON3.write(eq["rhs"]) for eq in m["equations"] if _rt_has_witness(eq["rhs"])), " ")
    for (k, v) in data
        occursin("\"$k\"", witness_text) || continue
        vars[k] = Dict{String, Any}("type" => "unknown", "shape" => m["variables"][k]["shape"])
        push!(eqs, Dict{String, Any}("lhs" => k, "rhs" => _rt_const(v)))
    end
    for eq in m["equations"]
        _rt_has_witness(eq["rhs"]) || continue
        a = eq["lhs"]["args"][1]
        i = eq["lhs"]["args"][2]
        shape = m["variables"][a]["shape"]
        push!(outputs, a)
        vars[a] = Dict{String, Any}("type" => "unknown", "shape" => shape)
        vars["w_$a"] = Dict{String, Any}("type" => "unknown", "shape" => shape, "default" => 0.0)
        push!(eqs, Dict{String, Any}("lhs" => eq["lhs"], "rhs" => _rt_to_template(eq["rhs"], isets)))
        push!(
            eqs, Dict{String, Any}(
                "lhs" => Dict{String, Any}(
                    "op" => "faq", "args" => Any[], "output_idx" => Any[i],
                    "ranges" => Dict{String, Any}(i => Dict{String, Any}("from" => shape[1])),
                    "expr" => Dict{String, Any}(
                        "op" => "D", "wrt" => "t",
                        "args" => Any[Dict{String, Any}("op" => "index", "args" => Any["w_$a", i])]
                    )
                ),
                "rhs" => Dict{String, Any}(
                    "op" => "faq", "args" => Any[a], "output_idx" => Any[i],
                    "ranges" => Dict{String, Any}(i => Dict{String, Any}("from" => shape[1])),
                    "expr" => Dict{String, Any}("op" => "index", "args" => Any[a, i])
                )
            )
        )
    end
    doc = _rt_doc(
        Dict{String, Any}(
            "expression_template_imports" => Any[Dict{String, Any}("ref" => "relational.esm")],
            "variables" => vars, "equations" => eqs
        )
    )
    doc["index_sets"] = isets
    file = load_string(JSON3.write(doc); base_path = dirname(_RT_LIB))
    return map((:interpreter, :native)) do compiler
        f!, u0, p, _, vm = EarthSciAST._build_evaluator(file; compiler)
        du = similar(u0)
        f!(du, u0, p, 0.0)
        Dict(a => [du[vm["w_$a[$k]"]] for k in 1:count(n -> startswith(n, "w_$a["), keys(vm))] for a in outputs)
    end
end

function _rt_op_buffers(rel, model_name, data)
    file = EarthSciAST.coerce_esm_file(JSON3.read(read(joinpath(_RT_ROOT, rel), String)))
    m = EarthSciAST._select_model(file, model_name)
    ca = Dict{String, Any}(k => Float64.(v) for (k, v) in data)
    return EarthSciAST.materialize_value_invention(m, file.index_sets, ca, Dict{String, Float64}()).assignments
end

const _RT_GEN = Dict("gx" => [0.0, 1.0, 2.0], "gy" => [0.0, 0.0, 0.0])
# (fixture, model, caller data, the op's assignment buffers)
const _RT_FIXTURES = [
    (
        "tests/valid/faq/nearest_generator_argmin.esm", "NearestGeneratorArgmin",
        merge(_RT_GEN, Dict("px" => [0.0, 1.0, 1.5, 2.0], "py" => [0.0, 0.5, 0.0, 0.0])),
        Dict("assign" => [1, 2, 2, 3]),
    ),
    (
        "tests/valid/faq/nearest_generator_argmin.esm", "NearestGeneratorArgmin",
        merge(_RT_GEN, Dict("px" => [2.0, 0.5, 0.5, 1.5], "py" => [0.0, 0.0, 1.0, -0.5])),
        Dict("assign" => [3, 1, 1, 2]),
    ),
    (
        "tests/valid/faq/nearest_generator_centroid.esm", "NearestGeneratorCentroid",
        Dict("gx" => [0.0, 1.0, 2.0], "px" => [0.0, 0.75, 1.25, 2.0], "rho" => [1.0, 1.0, 3.0, 4.0]),
        Dict("assign" => [1, 2, 2, 3]),
    ),
]

@testset "argmin fixtures rewritten as the template give the op's buffer" begin
    @testset "$(rel) $(name) $(i)" for (i, (rel, name, data, want)) in enumerate(_RT_FIXTURES)
        op = _rt_op_buffers(rel, name, data)
        for (a, buf) in want
            @test op[a] == buf
        end
        for got in _rt_template_buffers(rel, name, data)
            for (a, buf) in want
                @test got[a] == Float64.(buf)
            end
        end
    end
end

@testset "relational_templates tier documents pass their inline tests" begin
    @testset "$(fx) [$(compiler)]" for fx in ("argmin_template.esm", "nearest_generator_template_ode.esm"),
            compiler in (:interpreter, :native)
        results = run_inline_tests(joinpath(_RT_TIER, "fixtures", fx); compiler)
        @test !isempty(results)
        @test all(r -> r.status == EarthSciAST.PASS, results)
    end
end
