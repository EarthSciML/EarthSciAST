# The `argmin` / `argmax` templates of lib/relational.esm.
#
# 1. Every scenario of tests/conformance/relational_templates/scenarios.json
#    through the expanded template, under the interpreter and strict native,
#    must give the scenario's `expected` 1-based index.
# 2. The tier's two documents pass their own inline tests under both compilers.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5  # the solver `run_inline_tests` picks

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RT_ROOT = TESTUTILS_REPO_ROOT
const _RT_LIB = joinpath(_RT_ROOT, "lib", "relational.esm")
const _RT_TIER = joinpath(_RT_ROOT, "tests", "conformance", "relational_templates")

# A candidate as `num / den`, so a non-finite one fits in a `const`.
_rt_num_den(v) = v == "NaN" ? (0.0, 0.0) : v == "Inf" ? (1.0, 0.0) :
    v == "-Inf" ? (-1.0, 0.0) : (Float64(v), 1.0)
_rt_const(a) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => a)
_rt_doc(model) = Dict{String, Any}(
    "esm" => "2.0.0",
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

@testset "lib/relational.esm argmin/argmax templates" begin
    scenarios = JSON3.read(read(joinpath(_RT_TIER, "scenarios.json"), String)).scenarios
    @testset "scenario $(s.name)" for s in scenarios
        op, values, expected = String(s.op), collect(s.values), Int(s.expected)
        interp, native = _rt_template_values(op, values)
        @test interp === Float64(expected)
        @test native === Float64(expected)
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
