# Op-table synchronization tests for the tree-walk evaluator.
#
# The evaluator carries several parallel op ladders: the scalar
# `_eval_node_op`, its vectorized twin `_eval_vec_op`, and the build-time
# whitelists `_WS4_FOLDABLE_ELEMENTWISE_OPS` (elementwise array-observed fold)
# and `_STENCIL_ELEMENTWISE_OPS` (symbolic stencil fast path). The MECHANICAL
# arms (unary elementwise / comparisons / fixed-2-ary / n-ary min-max) are now
# GENERATED from the op-registry tables, and the setup-geometry scalar ladder
# is gone entirely (geometry bodies compile into the shared `_Node` IR); these
# tests pin the containment relations so any remaining hand-written drift
# fails CI:
#
#   * every op in `_WS4_FOLDABLE_ELEMENTWISE_OPS` has a scalar eval arm
#     (otherwise the WS4 fold converts a build-time UNSUPPORTED_SHAPE error
#     into a runtime UNSUPPORTED_OP after folding);
#   * every op in `_STENCIL_ELEMENTWISE_OPS` has BOTH a scalar and a
#     vectorized eval arm (the stencil fast path compiles whitelisted ops into
#     `_VecKernel`s evaluated by `_eval_vec_op`);
#   * the scalar and vectorized ladders stay in sync over the full evaluable
#     elementwise op family;
#   * the compiled setup-geometry path covers every op of the documented
#     polygon-area / overlap-join FAQ vocabulary.
#
# Also pins the read-only `_EMPTY_*` sentinel invariant (the shared empty
# Dicts must still be empty after a full build+evaluate cycle).

using Test
using EarthSciAST

const ESM = EarthSciAST

# Representative arity per evaluable elementwise op. Every op appearing in a
# whitelist MUST have an entry here — the first testset below enforces that, so
# adding an op to a whitelist without teaching this table fails with a clear
# message instead of silently skipping the new op.
const _OT_ARITY = Dict{String,Int}(
    "+" => 2, "-" => 2, "*" => 2, "/" => 2, "^" => 2, "pow" => 2,
    "neg" => 1, "sqrt" => 1, "abs" => 1, "sign" => 1,
    "exp" => 1, "log" => 1, "log10" => 1,
    "sin" => 1, "cos" => 1, "tan" => 1,
    "asin" => 1, "acos" => 1, "atan" => 1, "atan2" => 2,
    "sinh" => 1, "cosh" => 1, "tanh" => 1,
    "asinh" => 1, "acosh" => 1, "atanh" => 1,
    "max" => 2, "min" => 2, "floor" => 1, "ceil" => 1,
    "<" => 2, "<=" => 2, ">" => 2, ">=" => 2, "==" => 2, "!=" => 2,
    "and" => 2, "or" => 2, "not" => 1, "ifelse" => 3,
    "pi" => 0, "π" => 0, "e" => 0, "Pre" => 1,
)

# Per-op argument value inside every op's real domain (acosh needs x ≥ 1).
_ot_argval(op) = op == "acosh" ? 1.5 : 0.5

# Build a compiled scalar `_Node` for a representative application of `op`.
function _ot_node(op::String)
    haskey(_OT_ARITY, op) || error("op-table test: no arity entry for op '" *
        op * "' — add it to _OT_ARITY in tree_walk_op_table_test.jl")
    args = ESM.ASTExpr[NumExpr(_ot_argval(op)) for _ in 1:_OT_ARITY[op]]
    return ESM._compile(OpExpr(op, args), Dict{String,Int}(), Set{Symbol}(),
                        Dict{String,Any}())
end

# True iff evaluating `op` through the scalar walker does NOT hit the
# unsupported-op arm (a DomainError or arity error would still prove the arm
# exists, but the chosen arguments avoid those anyway).
function _ot_scalar_supported(op::String)
    node = _ot_node(op)
    try
        v = ESM._eval_node(node, Float64[], NamedTuple(), 0.0)
        return v isa Float64
    catch err
        if err isa ESM.TreeWalkError
            return err.code != "E_TREEWALK_UNSUPPORTED_OP"
        end
        rethrow()
    end
end

# True iff `op` also evaluates through the vectorized twin (`_eval_vec_op`,
# reached by merging two structurally-identical per-cell nodes).
function _ot_vector_supported(op::String)
    node = _ot_node(op)
    merged = ESM._merge_nodes(ESM._Node[node, node], 2)
    try
        v = ESM._eval_vec(merged, Float64[], NamedTuple(), 0.0, Float64)
        return v isa Vector{Float64}
    catch err
        if err isa ESM.TreeWalkError
            return !(err.code in ("E_TREEWALK_UNSUPPORTED_VEC_OP",
                                  "E_TREEWALK_UNSUPPORTED_OP"))
        end
        rethrow()
    end
end

@testset "tree-walk op-table synchronization" begin

    @testset "every whitelist op has an arity entry" begin
        for op in ESM._WS4_FOLDABLE_ELEMENTWISE_OPS
            @test haskey(_OT_ARITY, op)
        end
        for op in ESM._STENCIL_ELEMENTWISE_OPS
            @test haskey(_OT_ARITY, op)
        end
    end

    @testset "_WS4_FOLDABLE_ELEMENTWISE_OPS ⊆ scalar-evaluable ops" begin
        for op in sort!(collect(ESM._WS4_FOLDABLE_ELEMENTWISE_OPS))
            @test _ot_scalar_supported(op)
        end
    end

    @testset "_STENCIL_ELEMENTWISE_OPS ⊆ scalar- AND vector-evaluable ops" begin
        for op in sort!(collect(ESM._STENCIL_ELEMENTWISE_OPS))
            @test _ot_scalar_supported(op)
            @test _ot_vector_supported(op)
        end
    end

    @testset "scalar/vectorized ladder parity over the evaluable family" begin
        # The canonical elementwise family both ladders must agree on: the
        # arity table is exactly the evaluable-core elementwise surface
        # (esm-spec §4.2) plus the canonicalize-internal neg/pow aliases.
        for op in sort!(collect(keys(_OT_ARITY)))
            @test _ot_scalar_supported(op)
            @test _ot_vector_supported(op)
        end
    end

    @testset "scalar/vector numeric agreement on representatives" begin
        # Lane values of the merged template equal the scalar value — a cheap
        # drift check that an arm exists AND computes the same function.
        for op in sort!(collect(keys(_OT_ARITY)))
            node = _ot_node(op)
            sval = ESM._eval_node(node, Float64[], NamedTuple(), 0.0)
            vval = ESM._eval_vec(ESM._merge_nodes(ESM._Node[node, node], 2),
                                 Float64[], NamedTuple(), 0.0, Float64)
            @test length(vval) == 2
            @test vval[1] === sval && vval[2] === sval
        end
    end

    @testset "compiled setup-geometry path covers the documented FAQ vocabulary" begin
        # The setup-geometry scalar ladder (`_geo_apply_scalar/1/2/3`) is
        # retired: geometry bodies COMPILE once per sweep into the shared
        # `_Node` IR (`_geo_compile`, tree_walk/geometry_compile.jl) and
        # evaluate through `_eval_node_op`'s registry-generated arms. Pin that
        # every op of the documented polygon-area / overlap-join FAQ
        # vocabulary still compiles AND evaluates to a Float64.
        geo_ops = Dict{String,Vector{Float64}}(
            "+" => [1.0, 2.0], "*" => [2.0, 3.0], "-" => [5.0, 2.0],
            "/" => [6.0, 3.0], "^" => [2.0, 3.0],
            "max" => [1.0, 2.0], "min" => [1.0, 2.0],
            "sqrt" => [4.0], "abs" => [-2.0], "cos" => [0.5], "sin" => [0.5],
            "atan2" => [1.0, 2.0], "ifelse" => [1.0, 2.0, 3.0],
            "floor" => [1.5], "ceil" => [1.5],
            ">" => [2.0, 1.0], "<" => [1.0, 2.0], ">=" => [2.0, 2.0],
            "<=" => [2.0, 2.0], "==" => [2.0, 2.0], "!=" => [1.0, 2.0],
        )
        _geo_test_ctx() = ESM._GeoCompileCtx(
            ESM._GeoCtx(Dict{String,Any}(), nothing, Dict{String,Int}(),
                        Dict{String,Vector{String}}()),
            Dict{String,Int}(), Dict{String,String}(), Ref(0))
        for (op, args) in sort!(collect(geo_ops); by=first)
            e = OpExpr(op, ESM.ASTExpr[NumExpr(a) for a in args])
            node = ESM._geo_compile(e, _geo_test_ctx())
            v = ESM._eval_node(node, Float64[], nothing, 0.0)
            @test v isa Float64
        end
        # The variadic `-` the interpreter accepted still folds (left fold).
        e3 = OpExpr("-", ESM.ASTExpr[NumExpr(9.0), NumExpr(3.0), NumExpr(2.0)])
        @test ESM._eval_node(ESM._geo_compile(e3, _geo_test_ctx()),
                             Float64[], nothing, 0.0) == 4.0
        # And an op outside the vocabulary still raises the explicit
        # setup-geometry error — now at COMPILE time (before the sweep).
        err = try
            ESM._geo_compile(OpExpr("no_such_op", ESM.ASTExpr[NumExpr(1.0)]),
                             _geo_test_ctx())
            nothing
        catch e
            e
        end
        @test err isa ESM.TreeWalkError
        @test err.code == "E_TREEWALK_GEOMETRY_SETUP"
    end

    @testset "read-only _EMPTY_* sentinels stay empty after build+evaluate" begin
        # A build+evaluate cycle that exercises the scalar path, the arrayop
        # (vectorized) path, const arrays, and an ic equation — the code paths
        # that receive the shared sentinels as defaults.
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=1.0),
            "u" => ModelVariable(StateVariable),
            "k" => ModelVariable(ParameterVariable; default=2.0),
        )
        _v(n) = VarExpr(n)
        _i(x) = IntExpr(Int64(x))
        _o(op, a...; kw...) = OpExpr(op, ESM.ASTExpr[a...]; kw...)
        deqx = ESM.Equation(_o("D", _v("x"); wrt="t"),
                            _o("*", _v("k"), _v("x")))
        body_lhs = _o("D", _o("index", _v("u"), _v("i")); wrt="t")
        lhs = OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
                     ranges=Dict{String,Any}("i" => [1, 4]),
                     expr_body=body_lhs)
        rhs = OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
                     ranges=Dict{String,Any}("i" => [1, 4]),
                     expr_body=_o("*", _o("index", _v("w"), _v("i")),
                                  _o("index", _v("u"), _v("i"))))
        deqa = ESM.Equation(lhs, rhs)
        model = ESM.Model(vars, ESM.Equation[deqx, deqa])
        f!, u0, p, tspan, var_map = build_evaluator(model;
            const_arrays=Dict("w" => [1.0, 2.0, 3.0, 4.0]),
            initial_conditions=Dict("u[1]" => 1.0, "u[2]" => 2.0,
                                    "u[3]" => 3.0, "u[4]" => 4.0))
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test du[var_map["x"]] == 2.0
        @test du[var_map["u[2]"]] == 4.0

        for s in (ESM._EMPTY_DERIVED_EXTENTS, ESM._EMPTY_IDX_ENV,
                  ESM._EMPTY_CONST_ARRAYS, ESM._EMPTY_PARAMS,
                  ESM._EMPTY_PGATHER, ESM._EMPTY_FACTOR_SCOPE)
            @test isempty(s)
        end
        @test isempty(ESM._EMPTY_VI_MAPS.maps)
        @test isempty(ESM._EMPTY_VI_MAPS.map_sets)
    end
end
