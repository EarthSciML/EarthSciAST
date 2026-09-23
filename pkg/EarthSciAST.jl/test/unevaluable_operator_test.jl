# esm-spec §9.6.6 `unevaluable_operator` in the tree-walk evaluator.
#
# An op that IS in the §4.2 evaluable core but that `_eval_node_op` has no arm
# for must be refused while the evaluator is BUILT, naming the op — never
# deferred to the first RHS call, and never under the Julia-local
# `E_TREEWALK_UNSUPPORTED_OP`. The shared fixture puts each op in the untaken
# branch of an `ifelse`, so only a check that precedes evaluation refuses it.

using Test
using EarthSciAST
using JSON3

const _UO = EarthSciAST

const _UO_FIXTURE = JSON3.read(
    read(joinpath(@__DIR__, "..", "..", "..", "tests", "conformance",
                  "unevaluable_operator", "cases.json"), String),
    Dict{String,Any})

# `D(u) = rhs` with `u` a state and `p` a parameter, built through the public
# `build_evaluator`.
function _uo_build(rhs::_UO.ASTExpr)
    vars = Dict{String,ModelVariable}(
        "u" => ModelVariable(UnknownVariable; default=1.0),
        "p" => ModelVariable(ParameterVariable; default=2.0),
    )
    eq = _UO.Equation(OpExpr("D", _UO.ASTExpr[VarExpr("u")]; wrt="t"), rhs)
    return EarthSciAST._build_evaluator(_UO.Model(vars, _UO.Equation[eq]))
end

_uo_refusal(f) = try
    f()
    nothing
catch e
    e
end

_uo_compile(e::_UO.ASTExpr) =
    _UO._compile(e, Dict{String,Int}(), Set{Symbol}(), Dict{String,Any}())

@testset "unevaluable_operator (esm-spec §9.6.6)" begin

    @testset "shared fixture: refused at build" begin
        for c in _UO_FIXTURE["cases"]
            err = _uo_refusal(() -> _uo_build(_UO.expression_from_json(c["expression"])))
            @test err isa _UO.TreeWalkError
            @test err isa _UO.TreeWalkError && err.code == _UO_FIXTURE["code"]
            @test err isa _UO.TreeWalkError && occursin("'$(c["op"])'", err.detail)
        end
        f!, u0, p, _tspan, vm = _uo_build(
            _UO.expression_from_json(_UO_FIXTURE["control"]["expression"]))
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[vm["u"]] == _UO_FIXTURE["control"]["expected"]
    end

    @testset "a core op with no rule is refused when compiled" begin
        for op in ("rank", "distinct", "argmin", "argmax", "skolem",
                   "reshape", "transpose", "concat")
            err = _uo_refusal(() -> _uo_compile(OpExpr(op, _UO.ASTExpr[NumExpr(1.0)])))
            @test err isa _UO.TreeWalkError && err.code == "unevaluable_operator"
            @test err isa _UO.TreeWalkError && occursin("'$op'", err.detail)
        end
    end

    @testset "a repeated op with no rule is not hoisted past the gate" begin
        # A subexpression that occurs twice is a CSE candidate. `skolem` and
        # `apply_expression_template` are not rewrite targets, so hoisting used to
        # route them into a generic CSE node that failed only at the first RHS call.
        for node in (OpExpr("skolem", _UO.ASTExpr[VarExpr("u")]),
                     OpExpr("rank", _UO.ASTExpr[VarExpr("u")]))
            rhs = OpExpr("+", _UO.ASTExpr[node, node])
            err = _uo_refusal(() -> _uo_build(rhs))
            @test err isa _UO.TreeWalkError && err.code == "unevaluable_operator"
        end
        # A surviving template reference is expanded at build against the
        # document's registry, and refused BY NAME when none reached the build
        # (`E_TREEWALK_UNRESOLVED_TEMPLATE_REF`); what this pins is that it is
        # no longer a hoist candidate that could slip past `_compile_op`.
        tmpl = _UO.expression_from_json(Dict{String,Any}(
            "op" => "apply_expression_template", "args" => Any[], "name" => "tmpl",
            "bindings" => Dict{String,Any}()))
        @test !_UO._cse_hoistable(tmpl)
        @test !_UO._cse_hoistable(OpExpr("skolem", _UO.ASTExpr[VarExpr("u")]))
    end

    @testset "ops with a rule still compile; `true` evaluates" begin
        for op in ("+", "-", "*", "/", "^", "sin", "min", "ifelse", "Pre", "and", "<")
            @test _UO._has_tree_walk_rule(op)
        end
        n = _uo_compile(OpExpr("true", _UO.ASTExpr[]))
        @test _UO._eval_node(n, Float64[], NamedTuple(), 0.0) == 1.0
    end
end
