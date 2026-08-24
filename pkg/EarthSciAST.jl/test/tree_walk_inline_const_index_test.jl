# Regression tests for the tree-walk INLINE `const` array gather
# (fix/index-inline-const-array).
#
# Before the fix, an `index({op:const, value:[…]}, <loopvar>, …)` — a non-scalar
# `const` array literal used as the TARGET of an `index()` — survived
# `_resolve_indices` untouched and hit the `E_TREEWALK_UNSUPPORTED_OP:
# non-scalar const outside an array-consuming position` dead-end in `_compile`.
# It is now interned into the const-array registry and gathered through the SAME
# path a registered const-array observed already takes (`_resolve_const_array_gather`):
# a constant subscript folds to the element; a symbolic loop var lowers to a
# `_ConstGatherRef`.

using Test
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const ESM_ICI = EarthSciAST

@testset "tree-walk inline const index gather (fix/index-inline-const-array)" begin

    # ---- end-to-end: constant-RHS ODE reading inline const arrays ----------
    # du(u0) IS the value at t=1 for a constant-RHS ODE from zero ICs, so we
    # assert on du directly (no integrator dependency). Covers a 1-D case and a
    # multi-dim `index({const [n][3][3]}, gt, d, k)` matching the duo usage.
    @testset "fixture build_evaluator: fold path (1-D and multi-dim)" begin
        path = joinpath(TESTUTILS_REPO_ROOT, "pkg", "EarthSciAST.jl", "test",
                        "fixtures", "inline_const_index_gather.esm")
        @test isfile(path)
        file = EarthSciAST.load_path(path)
        ics = Dict("a[1]"=>0.0, "a[2]"=>0.0, "a[3]"=>0.0, "b[1]"=>0.0, "b[2]"=>0.0)
        f!, u0, p, _, vmap = build_evaluator(file; model_name="InlineConstIndex",
                                             initial_conditions=ics)
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["a[1]"]] ≈ 10.0
        @test du[vmap["a[2]"]] ≈ 20.0
        @test du[vmap["a[3]"]] ≈ 30.0
        # b[gt] = Σ_{d=1..3} G[gt][d][1], G[gt][d][k] = 100gt+10d+k.
        @test du[vmap["b[1]"]] ≈ 111.0 + 121.0 + 131.0   # 363
        @test du[vmap["b[2]"]] ≈ 211.0 + 221.0 + 231.0   # 663
    end

    # ---- direct _resolve_indices: fold vs. symbolic gather ------------------
    _c2d = OpExpr("const", ESM_ICI.ASTExpr[];
                  value=[[10.0, 20.0], [30.0, 40.0], [50.0, 60.0]])  # 3×2

    _avi = Dict{String,Tuple{Vector{Int},Vector{Int}}}()
    _vm  = Dict{String,Int}()

    @testset "fully-constant subscripts fold to the scalar element" begin
        ca = Dict{String,AbstractArray{Float64}}()
        idx = OpExpr("index", ESM_ICI.ASTExpr[_c2d, IntExpr(2), IntExpr(1)])
        r = ESM_ICI._resolve_indices(idx, _avi, _vm, ca, ESM_ICI._EMPTY_PGATHER,
                                     nothing, ESM_ICI._EMPTY_BOUND_SYMS)
        @test r isa NumExpr
        @test r.value ≈ 30.0   # vals[2,1]
    end

    @testset "symbolic subscript lowers to a _ConstGatherRef and interns by value" begin
        ca = Dict{String,AbstractArray{Float64}}()
        # index({const 3×2}, 2, rcv) with `rcv` a bound (symbolic) output index.
        idx = OpExpr("index", ESM_ICI.ASTExpr[_c2d, IntExpr(2), VarExpr("rcv")])
        r = ESM_ICI._resolve_indices(idx, _avi, _vm, ca, ESM_ICI._EMPTY_PGATHER,
                                     nothing, Set(["rcv"]))
        @test r isa OpExpr && r.op == "index"
        @test r.value isa ESM_ICI._ConstGatherRef
        @test size(r.value.vals) == (3, 2)
        @test r.value.vals[3, 2] ≈ 60.0
        # constant dim folded to an IntExpr, symbolic dim resolved in place
        @test r.args[1] isa IntExpr && r.args[1].value == 2
        # interned into the (mutable) registry under the reserved prefix
        interned = [k for k in keys(ca) if startswith(k, ESM_ICI._INLINE_CONST_PREFIX)]
        @test length(interned) == 1
        @test r.value.name == interned[1]

        # a SECOND identical literal dedups to the SAME interned name/array
        idx2 = OpExpr("index", ESM_ICI.ASTExpr[
            OpExpr("const", ESM_ICI.ASTExpr[];
                   value=[[10.0, 20.0], [30.0, 40.0], [50.0, 60.0]]),
            IntExpr(1), VarExpr("rcv")])
        r2 = ESM_ICI._resolve_indices(idx2, _avi, _vm, ca, ESM_ICI._EMPTY_PGATHER,
                                      nothing, Set(["rcv"]))
        @test r2.value.name == r.value.name
        @test length([k for k in keys(ca) if startswith(k, ESM_ICI._INLINE_CONST_PREFIX)]) == 1
    end
end
