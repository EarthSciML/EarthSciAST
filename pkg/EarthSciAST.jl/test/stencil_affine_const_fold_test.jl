# LANE_CONST loop-invariance must be derived from the INDEX, never sampled from
# the VALUES (`_derive_lane_repl`, stencil_affine.jl).
#
# The historical fast path folded a const gather to a literal when
# `_eval_recipe`'s VALUE at the box representative equalled its value at the 2^D
# box CORNERS. A const array is arbitrary data, so corner agreement says nothing
# about the interior: a regrid weight column reading (0, 0.5, 0) across a box
# coincides at both ends, folded to the literal 0.0, and silently zeroed the
# interior cell — no error, no warning, wrong number. The fix derives invariance
# structurally: the resolved LINEAR index is verified affine over the box (the
# check that was already there and IS sound — a linear index is affine in the
# loop index by construction, and every boundary-fold transition already cuts
# the box), and only an all-zero stride vector — the index provably does not
# move — licenses the literal fold.
#
# Pinned here at two levels:
#   * unit — `_derive_lane_repl`'s decision itself, so a future "sample a few
#     more points" regression is caught at the exact line rather than
#     probabilistically through a model;
#   * end-to-end — default affine build ≡ per-cell (ESS_STENCIL_DISABLE=1) ≡
#     the analytic answer, on the 1-D corner-coinciding weight and on the
#     regrid weight-matrix column that motivated the report.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# ---------------------------------------------------------------------------
# Unit: the lane-lowering decision for a LANE_CONST recipe over a 1-D box.
# `rec` reads `arr` at the index expression `ix` (in the loop name "j"); the box
# is 1:n. Only LANE_CONST fields matter, so the LANE_STATE-only arguments
# (`oln_rep`, `base`, `strides`) are inert placeholders.
# ---------------------------------------------------------------------------
function _cf_lane(arr, ix, n)
    rec = ESM._LaneRecipe(ESM.LANE_CONST, "W", EarthSciAST.ASTExpr[ix],
                          Int[], Int[], arr, "")
    box = (1:n,)
    ESM._derive_lane_repl(rec, ["j"], Int[1], ESM._box_corners(box), Bool[false],
                          0, 0, Int[1], 1, Dict{String,Int}(), Dict{String,Any}(),
                          IdDict{Any,Vector{Float64}}(), box)
end

@testset "LANE_CONST fold is index-derived, not value-sampled (ess-affine)" begin
    @testset "unit: corner-coinciding weights do NOT fold to a literal" begin
        # W[j] over j∈1:3 reads (1, 5, 1): the corners agree, the interior does not.
        r = _cf_lane([1.0, 5.0, 1.0], _v("j"), 3)
        @test !(r isa ESM._LitRepl)              # the unsound fold is gone
        @test r isa ESM._AccRepl
        @test r.desc.kind == ESM._AK_CONST_BOX   # a real per-cell coefficient read
        @test r.desc.s1 == 1                     # unit stride in the loop dim

        # The (0, 0.5, 0) regrid weight column from the original report — the
        # corners are BOTH 0.0, which is exactly what made the old fold pick 0.0.
        r0 = _cf_lane([0.0, 0.5, 0.0], _v("j"), 3)
        @test !(r0 isa ESM._LitRepl)
        @test r0.desc.kind == ESM._AK_CONST_BOX
    end

    @testset "unit: a loop-INDEPENDENT index still folds to a literal" begin
        # W[2] inside the j-loop: the resolved index has zero stride in every
        # dim, so invariance follows structurally and the fast path must survive.
        r = _cf_lane([1.0, 5.0, 1.0], _i(2), 3)
        @test r isa ESM._LitRepl
        @test r.v == 5.0
    end

    @testset "unit: a one-cell (thin) box folds to a literal" begin
        # Degenerate box 1:1 — the index cannot move, so the fold is legal even
        # though the array varies.
        rec = ESM._LaneRecipe(ESM.LANE_CONST, "W", EarthSciAST.ASTExpr[_v("j")],
                              Int[], Int[], [1.0, 5.0, 1.0], "")
        box = (2:2,)
        r = ESM._derive_lane_repl(rec, ["j"], Int[2], ESM._box_corners(box), Bool[true],
                                  0, 0, Int[1], 1, Dict{String,Int}(), Dict{String,Any}(),
                                  IdDict{Any,Vector{Float64}}(), box)
        @test r isa ESM._LitRepl
        @test r.v == 5.0
    end

    # -----------------------------------------------------------------------
    # End-to-end: affine ≡ per-cell ≡ analytic.
    # -----------------------------------------------------------------------
    function _cf_build(model, ics, const_arrays; affine::Bool)
        envs = affine ? ("ESS_STENCIL_DISABLE" => nothing,) :
                        ("ESS_STENCIL_DISABLE" => "1",)
        withenv(envs...) do
            f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
                initial_conditions=ics, const_arrays=const_arrays)
            du = zero(u0); f!(du, u0, p, 0.0)
            (du, vm, diag)
        end
    end

    @testset "D(c[j]) = W[j]·c[j] with corner-coinciding W" begin
        # W = (1, 5, 1): W[1] == W[3], so the box corners agree and the old fold
        # replaced the whole lane with 1.0, silently dropping the interior 5.0.
        N, W = 3, [1.0, 5.0, 1.0]
        vars = Dict("c" => ESM.ModelVariable(ESM.StateVariable))
        body = _op("*", _idx("W", _v("j")), _idx("c", _v("j")))
        m = ESM.Model(vars, [ESM.Equation(_ao1(_Didx("c", _v("j")), "j", 1, N),
                                          _ao1(body, "j", 1, N))])
        ics = Dict("c[$j]" => Float64(j) for j in 1:N)
        du_a, vm, d = _cf_build(m, ics, Dict("W" => W); affine=true)
        du_r, _, _ = _cf_build(m, ics, Dict("W" => W); affine=false)
        @test d.n_acc_kernels >= 1          # affine path fired, not a silent fallback
        @test du_a == du_r                  # bit-identical to the per-cell oracle
        @test [du_a[vm["c[$j]"]] for j in 1:N] == [1.0, 10.0, 3.0]   # analytic
    end

    @testset "regrid weight matrix D(y[j]) = Σ_i W[i,j]·x[i]" begin
        # 6 source cells → 3 target cells, each target averaging two neighbours.
        # Read along j at fixed i, row 3 of W is (0, 0.5, 0) — the corner
        # coincidence from the report. Under the old fold rows 3 and 4 vanished
        # and du[2] came out 0.0 instead of 2.0.
        W = [0.5 0.0 0.0; 0.5 0.0 0.0; 0.0 0.5 0.0
             0.0 0.5 0.0; 0.0 0.0 0.5; 0.0 0.0 0.5]
        xs = [0.0, 2.0, 1.0, 3.0, 2.0, 4.0]
        want = vec(sum(W .* xs; dims=1))                 # [1.0, 2.0, 3.0]
        body = _op("*", _idx("W", _v("i"), _v("j")), _idx("x", _v("i")))
        rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["j"], expr_body=body,
                         ranges=Dict("j" => [1, 3], "i" => [1, 6]), reduce="+")
        vars = Dict(v => ESM.ModelVariable(ESM.StateVariable) for v in ("y", "x"))
        m = ESM.Model(vars, [ESM.Equation(_ao1(_Didx("y", _v("j")), "j", 1, 3), rhs)])
        ics = merge(Dict("y[$j]" => 0.0 for j in 1:3),
                    Dict("x[$i]" => xs[i] for i in 1:6))
        du_a, vm, d = _cf_build(m, ics, Dict("W" => W); affine=true)
        du_r, _, _ = _cf_build(m, ics, Dict("W" => W); affine=false)
        @test d.n_acc_kernels >= 1
        @test du_a == du_r
        @test [du_a[vm["y[$j]"]] for j in 1:3] == want
    end

    @testset "2-D coefficient K[i,j] coinciding at all four box corners" begin
        # K is 1.0 on the whole boundary ring and 4.0 inside, so ALL 2^2 corners
        # of the full i×j box agree with the representative — the multi-dim form
        # of the same trap.
        N = 4
        K = [(i == 1 || i == N || j == 1 || j == N) ? 1.0 : 4.0 for i in 1:N, j in 1:N]
        vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j"]))
        body = _op("*", _idx("K", _v("i"), _v("j")), _idx("u", _v("i"), _v("j")))
        lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
            expr_body=_Didx("u", _v("i"), _v("j")), ranges=Dict("i" => [1, N], "j" => [1, N]))
        rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
            expr_body=body, ranges=Dict("i" => [1, N], "j" => [1, N]))
        m = ESM.Model(vars, [ESM.Equation(lhs, rhs)])
        ics = Dict("u[$i,$j]" => Float64(10i + j) for i in 1:N, j in 1:N)
        du_a, vm, d = _cf_build(m, ics, Dict("K" => K); affine=true)
        du_r, _, _ = _cf_build(m, ics, Dict("K" => K); affine=false)
        @test d.n_acc_kernels >= 1
        @test du_a == du_r
        @test all(du_a[vm["u[$i,$j]"]] == K[i, j] * (10i + j) for i in 1:N, j in 1:N)
    end
end
