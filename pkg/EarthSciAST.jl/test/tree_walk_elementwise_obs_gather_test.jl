# Regression tests for issue #175 — an ELEMENTWISE-defined array observed that is
# reached ONLY through an `index(…)` gather inside an `aggregate` body.
#
# `_fold_elementwise_array_observeds` (tree_walk/build_helpers.jl) inlines an
# array observed whose body is elementwise (`f = 1 + cos(pi*zc)`) into every
# reader, by NAME substitution. A reader that gathers it therefore becomes
#
#     index(1 + cos(pi*zc), j)
#
# and `_resolve_indices_op`'s push-down branch has to distribute that gather over
# the elementwise combination. It used to test only the IMMEDIATE operands for
# array-ness: `1` is a literal and `cos(pi*zc)` is neither a producer node nor a
# variable, so nothing was wrapped, the gather was dropped, and the array leaf
# `zc` reached `_compile` bare as `E_TREEWALK_UNBOUND_VARIABLE: zc`. The operand
# test (`_index_pushdown_arrayish`) now looks THROUGH nested elementwise ops, so
# the gather lands on the leaves: `1 + cos(pi*index(zc, j))`.
#
# The two spellings the issue reports as already working — the same body written
# as an explicit `aggregate(i from lev; … index(zc, i) …)` gather, and the same
# elementwise body consumed directly in a state RHS rather than through a gather
# — are pinned here alongside, and must agree with the folded form value-for-value.

using Test
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const ESM_EOG = EarthSciAST

@testset "elementwise array observed reached via an aggregate gather (#175)" begin

    zc = [0.125, 0.375, 0.625, 0.875]
    fvals = 1 .+ cos.(pi .* zc)          # the observed `f`, per level
    u0val = 2.0
    hvals = u0val .* fvals               # `h = u * f` at the default state

    fixture = joinpath(TESTUTILS_REPO_ROOT, "pkg", "EarthSciAST.jl", "test",
                       "fixtures", "elementwise_obs_gather.esm")

    @testset "fixture builds and evaluates" begin
        @test isfile(fixture)
        file = ESM_EOG.load_path(fixture)
        f!, u0, p, _, vmap = build_evaluator(file; model_name="Column")
        du = similar(u0)
        f!(du, u0, p, 0.0)

        # `colsum[i] = Σ_{j<=i} h[j]` — a cumulative column integral over an
        # elementwise-defined array observed reached only through `index(h, j)`.
        expected = cumsum(hvals)
        for i in 1:4
            @test du[vmap["u[$(i)]"]] ≈ expected[i]
        end
        # `total = Σ_j f[j]` — the same shape through a SCALAR reduction, whose
        # only reference to `f` is the gather (so `zc` is reachable no other way).
        @test du[vmap["s"]] ≈ sum(fvals)
    end

    # ---- The two working spellings the issue names, as differential oracles ----
    #
    # Same numbers three ways: the elementwise observed read through a gather
    # (above), the explicit `aggregate` gather spelling, and the elementwise body
    # consumed directly in a state RHS.
    function _column_model(f_rhs)
        vars = Dict{String,ModelVariable}(
            "zc" => ModelVariable(UnknownVariable; shape=["lev"]),
            "f"  => ModelVariable(UnknownVariable; shape=["lev"]),
            "s"  => ModelVariable(UnknownVariable; default=0.0),
        )
        eqs = Equation[
            Equation(OpExpr("D", ASTExpr[VarExpr("s")]; wrt="t"),
                     OpExpr("aggregate", ASTExpr[VarExpr("f")];
                            semiring="sum_product", output_idx=Any[],
                            ranges=Dict{String,Any}("j" => Any[1, 4]),
                            expr_body=OpExpr("index", ASTExpr[VarExpr("f"), VarExpr("j")]))),
            Equation(VarExpr("zc"),
                     OpExpr("const", ASTExpr[]; value=zc)),
            Equation(VarExpr("f"), f_rhs),
        ]
        return ESM_EOG.Model(vars, eqs)
    end

    _pi = 3.141592653589793

    @testset "explicit-gather spelling agrees" begin
        # f = aggregate(i from lev; 1 + cos(pi*index(zc, i)))
        body = OpExpr("+", ASTExpr[NumExpr(1.0),
                 OpExpr("cos", ASTExpr[OpExpr("*", ASTExpr[NumExpr(_pi),
                   OpExpr("index", ASTExpr[VarExpr("zc"), VarExpr("i")])])])])
        model = _column_model(OpExpr("aggregate", ASTExpr[VarExpr("zc")];
                                     semiring="sum_product", output_idx=Any["i"],
                                     ranges=Dict{String,Any}("i" => Any[1, 4]),
                                     expr_body=body))
        f!, u0, p, _, vmap = build_evaluator(model)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["s"]] ≈ sum(fvals)
    end

    @testset "elementwise spelling agrees" begin
        # f = 1 + cos(pi*zc), read only through `index(f, j)` — the #175 shape.
        body = OpExpr("+", ASTExpr[NumExpr(1.0),
                 OpExpr("cos", ASTExpr[OpExpr("*", ASTExpr[NumExpr(_pi),
                   VarExpr("zc")])])])
        model = _column_model(body)
        f!, u0, p, _, vmap = build_evaluator(model)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["s"]] ≈ sum(fvals)
    end

    # ---- The predicate itself -------------------------------------------------
    @testset "_index_pushdown_arrayish looks through elementwise ops" begin
        is_arr = n -> n == "zc"
        A(e) = ESM_EOG._index_pushdown_arrayish(e, is_arr)

        @test A(VarExpr("zc"))
        @test !A(VarExpr("k"))
        @test !A(NumExpr(1.0))
        # nested elementwise: the whole point of the fix
        nested = OpExpr("+", ASTExpr[NumExpr(1.0),
                   OpExpr("cos", ASTExpr[OpExpr("*", ASTExpr[NumExpr(_pi),
                     VarExpr("zc")])])])
        @test A(nested)
        # elementwise over scalars only stays scalar
        @test !A(OpExpr("+", ASTExpr[NumExpr(1.0),
                   OpExpr("cos", ASTExpr[VarExpr("k")])]))
        # a producer node is array-valued; a SCALAR reduction is not
        @test A(OpExpr("makearray", ASTExpr[]))
        @test A(OpExpr("aggregate", ASTExpr[]; output_idx=Any["i"],
                       ranges=Dict{String,Any}("i" => Any[1, 4]),
                       expr_body=NumExpr(1.0)))
        @test !A(OpExpr("aggregate", ASTExpr[]; output_idx=Any[],
                        ranges=Dict{String,Any}("j" => Any[1, 4]),
                        expr_body=OpExpr("index", ASTExpr[VarExpr("zc"), VarExpr("j")])))
        # an already-gathered leaf is scalar — `index` is not an elementwise op,
        # so the walk does not descend into it and re-wrap the gather.
        @test !A(OpExpr("+", ASTExpr[NumExpr(1.0),
                   OpExpr("index", ASTExpr[VarExpr("zc"), VarExpr("j")])]))
    end

    @testset "a one-element const field is a SCALAR, not a gatherable array" begin
        # `_resolve_indices(::VarExpr)` const-folds a bare reference to a
        # one-element const-array entry (a 0-D loader field, RFC
        # pure-io-data-loaders §4.3) to its literal value, so the push-down's leaf
        # test must leave it alone: wrapping it would gather a 1-element array at
        # the enclosing loop's subscript and read out of range past the first cell.
        @test ESM_EOG._is_scalar_const_field([3.5])
        @test ESM_EOG._is_scalar_const_field(fill(3.5))          # 0-D
        @test !ESM_EOG._is_scalar_const_field([1.0, 2.0])
        @test !ESM_EOG._is_scalar_const_field(3.5)               # not an array at all
    end
end
