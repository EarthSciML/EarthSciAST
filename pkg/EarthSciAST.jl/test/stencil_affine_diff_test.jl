# End-to-end differential test for the affine polyhedral build (ess-affine).
# Build the SAME model two ways and require bit-identical du:
#   * ESS_AFFINE=1        → the affine access-kernel path (_try_affine_stencil)
#   * ESS_STENCIL_DISABLE=1 → the byte-identical per-cell reference path
# Also assert the affine path actually FIRED (n_acc_kernels ≥ 1), so a silent
# fallback can't make the comparison pass trivially.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

# 2-D 5-point Laplacian stencil over the FULL i×j range → ghost neighbours on all
# four edges. Exercises multi-dim boxes (interior + 4 edges + 4 corners) and the
# row-major state layout the affine map must DERIVE (stride_i=N, stride_j=1).
function _stencil2d_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j"]))
    body = _op("+",
        _idx("u", _op("-", _v("i"), _i(1)), _v("j")),
        _op("*", _n(-4.0), _idx("u", _v("i"), _v("j"))),
        _idx("u", _op("+", _v("i"), _i(1)), _v("j")),
        _idx("u", _v("i"), _op("-", _v("j"), _i(1))),
        _idx("u", _v("i"), _op("+", _v("j"), _i(1))))
    lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=_Didx("u", _v("i"), _v("j")), ranges=Dict("i" => [1, N], "j" => [1, N]))
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=body, ranges=Dict("i" => [1, N], "j" => [1, N]))
    ESM.Model(vars, [ESM.Equation(lhs, rhs)])
end

# 1-D piecewise stencil via a makearray with THREE regions (one-sided at the two
# ends, centered in the interior) — the region-selection structure that drives the
# per-cell/per-branch over-split. The affine build must cut at the region
# boundaries and emit ONE box per region (no ghosts: each region stays in bounds).
function _makearray_region_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    fwd = _op("-", _idx("u", _op("+", _v("i"), _i(1))), _idx("u", _v("i")))
    ctr = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    bwd = _op("-", _idx("u", _v("i")), _idx("u", _op("-", _v("i"), _i(1))))
    mk = ESM.OpExpr("makearray", ESM.ASTExpr[];
        regions=[[[1, 1]], [[2, N - 1]], [[N, N]]],
        values=ESM.ASTExpr[fwd, ctr, bwd])
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("index", mk, _v("i")), "i", 1, N))])
end

# 1-D variable-coefficient diffusion D(u[i]) = K[i]·(u[i-1] − 2u[i] + u[i+1]),
# K a const array. Exercises `_AccConstBox` (the per-cell coefficient addressed by
# the loop multi-index) alongside boundary-ghost boxes.
function _const_coef_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    body = _op("*", _idx("K", _v("i")), lap)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# 1-D GUARDED-SINGULARITY stencil (gordian total-vectorize, Stage 1): the body
# guards a log AND a sqrt behind `ifelse` so that OUT-of-domain cells take the
# else arm. The per-cell reference is LAZY (never evaluates the singular op off
# its domain); the affine tape is EAGER but sanitizes the guarded operands, so
# the two must be bit-identical. A neighbour term keeps it on the stencil/affine
# path (interior + 2 boundary boxes).
function _guarded_stencil_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    ui = _idx("u", _v("i"))
    # ifelse(u[i] > 0, log(u[i]), -1) + ifelse(u[i] >= 0.25, sqrt(u[i]-0.25), 0)
    guarded = _op("+",
        _op("ifelse", _op(">", ui, _n(0.0)), _op("log", ui), _n(-1.0)),
        _op("ifelse", _op(">=", ui, _n(0.25)),
            _op("sqrt", _op("-", ui, _n(0.25))), _n(0.0)))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), ui),
                   _idx("u", _op("+", _v("i"), _i(1))))
    body = _op("+", guarded, lap)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# (du, u0, vmap, diag) for a model, under the affine path or the per-cell path.
function _affine_build(model, ics; affine::Bool, form=:inplace, const_arrays=Dict())
    envs = affine ? ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing) :
                    ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")
    withenv(envs...) do
        f!, u0, p, _tspan, vmap, diag =
            ESM._build_evaluator_impl(model; initial_conditions=ics, form=form,
                                      const_arrays=const_arrays)
        du = zero(u0)
        f!(du, u0, p, 0.0)
        (du, u0, vmap, diag)
    end
end

@testset "affine stencil ≡ per-cell (differential, ess-affine)" begin

    @testset "1D second-difference stencil (N=$N)" for N in (8, 32, 64)
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        du_aff, _, _, d = _affine_build(_stencil_model(N), ics; affine=true)
        du_ref, _, _, _ = _affine_build(_stencil_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1          # affine path fired, not a silent fallback
        @test d.n_vec_kernels == 0          # …and it OWNED the equation
        @test du_aff == du_ref              # bit-identical
    end

    # N-independence: the affine kernel count must NOT grow with the grid size
    # (it is the number of structural boxes: interior + 2 boundary), unlike the
    # per-cell / over-split paths.
    @testset "affine kernel count is N-independent" begin
        counts = map((8, 16, 64, 256)) do N
            ics = Dict("u[$k]" => 0.1k for k in 1:N)
            _, _, _, d = _affine_build(_stencil_model(N), ics; affine=true)
            d.n_acc_kernels
        end
        @test all(==(counts[1]), counts)
    end

    @testset "2D 5-point Laplacian (N=$N)" for N in (5, 16, 33)
        ics = Dict("u[$i,$j]" => sin(0.2i) + 0.3cos(0.1j) + 0.01i*j
                   for i in 1:N, j in 1:N)
        du_aff, _, _, d = _affine_build(_stencil2d_model(N), ics; affine=true)
        du_ref, _, _, _ = _affine_build(_stencil2d_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_aff == du_ref                      # bit-identical, derived row-major layout
    end

    @testset "2D kernel count N-independent (interior+edges+corners)" begin
        counts = map((5, 16, 40)) do N
            ics = Dict("u[$i,$j]" => 0.01i*j for i in 1:N, j in 1:N)
            _, _, _, d = _affine_build(_stencil2d_model(N), ics; affine=true)
            d.n_acc_kernels
        end
        @test all(==(counts[1]), counts)
    end

    @testset "makearray 3-region piecewise (N=$N)" for N in (6, 24, 50)
        ics = Dict("u[$k]" => cos(0.25k) + 0.05k for k in 1:N)
        du_aff, _, _, d = _affine_build(_makearray_region_model(N), ics; affine=true)
        du_ref, _, _, _ = _affine_build(_makearray_region_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_aff == du_ref              # bit-identical across region boundaries
    end

    @testset "makearray region kernel count N-independent" begin
        counts = map((6, 24, 100)) do N
            ics = Dict("u[$k]" => 0.05k for k in 1:N)
            _, _, _, d = _affine_build(_makearray_region_model(N), ics; affine=true)
            d.n_acc_kernels
        end
        @test all(==(counts[1]), counts)    # 3 region boxes regardless of N
    end

    @testset "variable-coefficient K[i]·Δ²u (_AccConstBox, N=$N)" for N in (8, 32)
        K = Float64[0.5 + 0.3sin(0.2k) for k in 1:N]
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        ca = Dict("K" => K)
        du_aff, _, _, d = _affine_build(_const_coef_model(N), ics; affine=true, const_arrays=ca)
        du_ref, _, _, _ = _affine_build(_const_coef_model(N), ics; affine=false, const_arrays=ca)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test du_aff == du_ref              # bit-identical with per-cell const coefficient
    end

    # The guard ops (`ifelse`/`and`/`or`) used to DECLINE the tape and fall to the
    # scalar runner; the tape now compiles them as eager select/blend over a
    # sanitized spine. This oracle pins that end-to-end: a guarded singularity on
    # the affine tape ≡ the lazy per-cell reference, bit for bit.
    @testset "guarded singularity: affine tape ≡ per-cell (N=$N)" for N in (8, 32, 64)
        # sin dips negative and below 0.25, so BOTH guards exclude real cells
        ics = Dict("u[$k]" => sin(0.4k) + 0.05k for k in 1:N)
        du_aff, _, _, d = _affine_build(_guarded_stencil_model(N), ics; affine=true)
        du_ref, _, _, _ = _affine_build(_guarded_stencil_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1          # affine tape owned the guarded equation
        @test d.n_vec_kernels == 0
        @test all(isfinite, du_aff)         # eager eval did not produce NaN from a throw
        @test du_aff == du_ref              # bit-identical to the lazy scalar reference
    end
end
