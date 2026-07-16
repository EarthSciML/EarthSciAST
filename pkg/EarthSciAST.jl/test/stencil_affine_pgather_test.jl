# Differential test for LIVE-forcing (pgather) gathers on the affine access-kernel
# path (ess-affine). A per-cell forcing read `index(forcing, i…)` whose index
# varies with the loop used to force a whole-equation fallback (`_derive_lane_repl`
# threw on LANE_PGATHER). It is now lowered to `_AccForcingBox` over the *aliased*
# `_PGatherArray.flat` buffer: the flat linear index is finite-differenced across
# unit loop steps and verified affine at every box corner, exactly like a const
# box, EXCEPT the value is never folded to a literal (the buffer is refreshed in
# place) and the buffer is passed by reference, never copied.
#
# Two invariants per model: (1) affine ≡ per-cell BIT-IDENTITY, affine FIRED
# (n_acc ≥ 1) and OWNED the equation (n_vec == 0); (2) LIVENESS — mutating the same
# buffer in place changes the affine RHS and it still equals per-cell (a copied
# buffer would fail both halves).
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# Build the model under affine and per-cell, binding `buf` by reference. Returns
# a Dict tag → (f!, u0, p, diag).
function _pg_build_both(model, ics, buf)
    out = Dict{Symbol,Any}()
    for (tag, envs) in ((:aff, ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing)),
                        (:ref, ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")))
        withenv(envs...) do
            f!, u0, p, _t, _vm, diag = ESM._build_evaluator_impl(model;
                initial_conditions=ics, param_arrays=Dict("forcing" => buf))
            out[tag] = (f!, u0, p, diag)
        end
    end
    out
end
function _pg_eval(t)
    f!, u0, p, _ = t
    du = zero(u0); f!(du, u0, p, 0.0); du
end

# D(u[i]) = forcing[i]  — pure forcing, one box, isolates _AccForcingBox.
function _pg_pure_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_idx("forcing", _v("i")), "i", 1, N))])
end

# D(u[i]) = forcing[i] + (u[i-1] − 2u[i] + u[i+1]) — lane-affine forcing summed
# with a Laplacian, so every box (interior + 2 boundary) carries a forcing leaf.
function _pg_1d_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("+", _idx("forcing", _v("i")), lap), "i", 1, N))])
end

# D(u[i,j]) = forcing[i,j] + 5-point Laplacian — exercises 2-D forcing strides
# (s1=1, s2=N) alongside the multi-dim box structure.
function _pg_2d_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j"]))
    lap = _op("+",
        _idx("u", _op("-", _v("i"), _i(1)), _v("j")),
        _op("*", _n(-4.0), _idx("u", _v("i"), _v("j"))),
        _idx("u", _op("+", _v("i"), _i(1)), _v("j")),
        _idx("u", _v("i"), _op("-", _v("j"), _i(1))),
        _idx("u", _v("i"), _op("+", _v("j"), _i(1))))
    body = _op("+", _idx("forcing", _v("i"), _v("j")), lap)
    lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=_Didx("u", _v("i"), _v("j")), ranges=Dict("i" => [1, N], "j" => [1, N]))
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=body, ranges=Dict("i" => [1, N], "j" => [1, N]))
    ESM.Model(vars, [ESM.Equation(lhs, rhs)])
end

@testset "affine live-forcing pgather ≡ per-cell (differential, ess-affine)" begin
    @testset "pure forcing D(u[i])=forcing[i] (N=$N)" for N in (8, 32)
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = Dict("u[$k]" => 0.0 for k in 1:N)
        b = _pg_build_both(_pg_pure_model(N), ics, buf)
        du_a = _pg_eval(b[:aff]); du_r = _pg_eval(b[:ref])
        @test b[:aff][4].n_acc_kernels >= 1
        @test b[:aff][4].n_vec_kernels == 0
        @test du_a == du_r
        buf .= Float64[-2.0 + 0.9k for k in 1:N]          # in-place refresh
        du_a2 = _pg_eval(b[:aff]); du_r2 = _pg_eval(b[:ref])
        @test du_a2 == du_r2                              # still agree
        @test du_a2 != du_a                               # affine SAW the refresh (live)
    end

    @testset "forcing + Laplacian, ghost boxes (N=$N)" for N in (8, 32, 64)
        buf = Float64[0.5 + 0.2k for k in 1:N]
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        b = _pg_build_both(_pg_1d_model(N), ics, buf)
        du_a = _pg_eval(b[:aff]); du_r = _pg_eval(b[:ref])
        @test b[:aff][4].n_acc_kernels >= 1
        @test b[:aff][4].n_vec_kernels == 0
        @test du_a == du_r
        buf .= Float64[-3.0 + 0.7k for k in 1:N]
        du_a2 = _pg_eval(b[:aff]); du_r2 = _pg_eval(b[:ref])
        @test du_a2 == du_r2
        @test du_a2 != du_a
    end

    @testset "forcing kernel count N-independent" begin
        counts = map((8, 32, 128)) do N
            buf = Float64[0.2k for k in 1:N]
            ics = Dict("u[$k]" => 0.1k for k in 1:N)
            _pg_build_both(_pg_1d_model(N), ics, buf)[:aff][4].n_acc_kernels
        end
        @test all(==(counts[1]), counts)
    end

    @testset "2-D forcing[i,j] + 5-point Laplacian (N=$N)" for N in (5, 16)
        buf = Float64[0.1i + 0.3j for i in 1:N, j in 1:N]
        ics = Dict("u[$i,$j]" => sin(0.2i) + 0.3cos(0.1j) for i in 1:N, j in 1:N)
        b = _pg_build_both(_pg_2d_model(N), ics, buf)
        du_a = _pg_eval(b[:aff]); du_r = _pg_eval(b[:ref])
        @test b[:aff][4].n_acc_kernels >= 1
        @test b[:aff][4].n_vec_kernels == 0
        @test du_a == du_r
        buf .= Float64[-1.0 + 0.05i*j for i in 1:N, j in 1:N]   # in-place refresh
        du_a2 = _pg_eval(b[:aff]); du_r2 = _pg_eval(b[:ref])
        @test du_a2 == du_r2
        @test du_a2 != du_a
    end
end
