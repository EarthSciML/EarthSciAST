# Regression tests for the tree_walk.jl audit fixes:
#
#   * scalar `ic(var)` RHS may reference model PARAMETERS (esm-spec §6.6.5
#     build-time evaluation scope), matching the array/field-ic path;
#   * `_parse_cell_key` — the shared inverse of `_cell_key` (also consumed by
#     simulate.jl / pde_inline_tests.jl);
#   * `_sub_preserving` preserves EVERY OpExpr field (now routed through
#     `reconstruct`), including `table`/`table_axes`/`output`/`distinct`/`key`
#     which the hand-rolled rebuild used to drop;
#   * the resolve→compile live-forcing side channel is a typed `_PGatherRef`;
#   * `_eval_vec_op` raises E_TREEWALK_ARITY (not BoundsError) on malformed
#     nodes, matching its scalar twin;
#   * the `:fn` eval arm throws explicitly instead of falling through to
#     `nothing` when const-args are present but no interp.* case matches.

using Test
using EarthSciSerialization

const ESM = EarthSciSerialization

_af_v(n) = VarExpr(n)
_af_n(x) = NumExpr(Float64(x))
_af_op(op, a...; kw...) = OpExpr(op, ESM.Expr[a...]; kw...)

@testset "tree_walk audit fixes" begin

    # ----------------------------------------------------------------
    @testset "scalar ic(var) RHS resolves parameters (spec §6.6.5)" begin
        vars = Dict{String,ModelVariable}(
            "x" => ModelVariable(StateVariable; default=0.0),
            "k" => ModelVariable(ParameterVariable; default=3.0),
        )
        eqs = ESM.Equation[
            ESM.Equation(_af_op("ic", _af_v("x")),
                         _af_op("*", _af_v("k"), _af_n(2.0))),
            ESM.Equation(_af_op("D", _af_v("x"); wrt="t"), _af_n(0.0)),
        ]
        model = ESM.Model(vars, eqs)

        # Default parameter value: ic(x) = k*2 = 6.
        f!, u0, p, tspan, var_map = build_evaluator(model)
        @test u0[var_map["x"]] == 6.0

        # parameter_overrides feed the same resolved scope: ic(x) = 5*2 = 10.
        _, u0b, _, _, vmb = build_evaluator(model;
            parameter_overrides=Dict("k" => 5.0))
        @test u0b[vmb["x"]] == 10.0

        # An explicit initial_conditions entry still wins over the ic equation.
        _, u0c, _, _, vmc = build_evaluator(model;
            initial_conditions=Dict("x" => 42.0))
        @test u0c[vmc["x"]] == 42.0

        # An UNBOUND name in a scalar ic RHS is still a clear error, and the
        # diagnostic now carries the underlying cause.
        badm = ESM.Model(vars, ESM.Equation[
            ESM.Equation(_af_op("ic", _af_v("x")), _af_v("nope")),
            ESM.Equation(_af_op("D", _af_v("x"); wrt="t"), _af_n(0.0)),
        ])
        err = try
            build_evaluator(badm)
            nothing
        catch e
            e
        end
        @test err isa ESM.TreeWalkError
        @test err.code == "E_TREEWALK_UNSUPPORTED_EQUATION"
        @test occursin("nope", err.detail)
    end

    # ----------------------------------------------------------------
    @testset "_parse_cell_key is the inverse of _cell_key" begin
        @test ESM._parse_cell_key("u[3]") == ("u", [3])
        @test ESM._parse_cell_key("u[2,3]") == ("u", [2, 3])
        @test ESM._parse_cell_key("Sys.O3[10,1,7]") == ("Sys.O3", [10, 1, 7])
        # Round trip.
        for (name, idxs) in (("u", [1]), ("a.b", [4, 5]), ("x", [1, 2, 3]))
            @test ESM._parse_cell_key(ESM._cell_key(name, idxs)) == (name, idxs)
        end
        # Non-cell-keys → nothing.
        @test ESM._parse_cell_key("u") === nothing
        @test ESM._parse_cell_key("u[]") === nothing
        @test ESM._parse_cell_key("u[a]") === nothing
        @test ESM._parse_cell_key("[3]") === nothing
        @test ESM._parse_cell_key("u[1,]") === nothing
        @test ESM._parse_cell_key("u[1]x") === nothing
    end

    # ----------------------------------------------------------------
    @testset "_sub_preserving preserves every OpExpr field" begin
        # A node carrying the fields the old hand-rolled rebuild dropped
        # (`table`, `table_axes`, `output`, `distinct`, `key`) plus `ranges`
        # (which forces the reconstruct path even when nothing binds).
        keyexpr = _af_op("skolem", _af_v("i"))
        node = OpExpr("aggregate", ESM.Expr[_af_v("q")];
                      output_idx=Any["i"],
                      ranges=Dict{String,Any}("i" => [1, 3]),
                      expr_body=_af_op("+", _af_v("q"), _af_v("z")),
                      reduce="+", semiring="sum_product",
                      table="tbl0",
                      table_axes=Dict{String,Any}("T" => _af_v("q")),
                      output=1,
                      join=Any[], filter=_af_op(">", _af_v("q"), _af_n(0)),
                      id="node0", manifold="planar",
                      distinct=true, key=keyexpr)
        subd = ESM._sub_preserving(node,
                                   Dict{String,ESM.Expr}("z" => _af_n(7.0)))
        @test subd.table == "tbl0"
        @test subd.table_axes !== nothing
        @test subd.output == 1
        @test subd.distinct === true
        @test subd.key === keyexpr
        @test subd.id == "node0"
        @test subd.manifold == "planar"
        @test subd.reduce == "+"
        @test subd.semiring == "sum_product"
        # The substitution itself happened (body z → 7.0).
        @test (subd.expr_body::OpExpr).args[2] isa NumExpr
    end

    # ----------------------------------------------------------------
    @testset "live-forcing side channel is a typed _PGatherRef" begin
        buf = reshape(Float64[10, 20, 30, 40], 2, 2)
        pg = Dict("F" => ESM._PGatherArray(vec(buf), collect(size(buf))))
        idx_node = _af_op("index", _af_v("F"), IntExpr(Int64(2)), IntExpr(Int64(1)))
        resolved = ESM._resolve_indices(idx_node,
            Dict{String,Tuple{Vector{Int},Vector{Int}}}(),
            Dict{String,Int}(), ESM._EMPTY_CONST_ARRAYS, pg)
        @test resolved isa OpExpr && resolved.op == "index"
        @test resolved.value isa ESM._PGatherRef
        @test (resolved.value::ESM._PGatherRef).lin == 2   # column-major (2,1)
        node = ESM._compile(resolved, Dict{String,Int}(), Set{Symbol}(),
                            Dict{String,Any}())
        @test node.kind == ESM._NK_PARAM_GATHER
        @test ESM._eval_node(node, Float64[], NamedTuple(), 0.0) == 20.0
        # Live: an in-place refresh of the caller's buffer shows through.
        buf[2, 1] = 99.0
        @test ESM._eval_node(node, Float64[], NamedTuple(), 0.0) == 99.0
    end

    # ----------------------------------------------------------------
    @testset "_eval_vec_op arity guards match the scalar twin" begin
        lit = ESM._mknode(kind=ESM._NK_LITERAL, literal=0.5)
        for (op, nargs, wrong) in ((:/, 2, 1), (:^, 2, 1), (:not, 1, 2),
                                   (:ifelse, 3, 2), (:neg, 1, 2),
                                   (:sqrt, 1, 2), (:atan2, 2, 1),
                                   (:<, 2, 1), (:min, 2, 1), (:max, 2, 0))
            bad = ESM._mkvnode(kind=ESM._VK_OP, op=op,
                children=ESM._VecNode[ESM._merge_nodes(ESM._Node[lit], 1)
                                      for _ in 1:wrong],
                buf=Vector{Float64}(undef, 1))
            err = try
                ESM._eval_vec_op(bad, Float64[], NamedTuple(), 0.0)
                nothing
            catch e
                e
            end
            @test err isa ESM.TreeWalkError
            @test err.code == "E_TREEWALK_ARITY"
        end
    end

    # ----------------------------------------------------------------
    @testset ":fn arm throws explicitly on a non-interp const-args handler" begin
        # Hand-construct the (compile-unreachable) node shape: const args
        # present, but the name matches no interp.* eval case. The arm must
        # throw, never return `nothing`.
        bad = ESM._mknode(kind=ESM._NK_OP, op=:fn,
                          handler=("datetime.julian_day", Any[[1.0]]),
                          children=ESM._Node[ESM._mknode(kind=ESM._NK_LITERAL,
                                                         literal=0.0)])
        err = try
            ESM._eval_node(bad, Float64[], NamedTuple(), 0.0)
            nothing
        catch e
            e
        end
        @test err isa ESM.TreeWalkError
        @test err.code == "E_TREEWALK_UNKNOWN_CLOSED_FUNCTION"
    end
end
