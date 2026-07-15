# AD + out-of-place differential test for the affine access-kernel path (ess-affine).
#
# Task #7 gate. Two properties the affine path must inherit from the per-cell one
# now that `_eval_acc` is eltype-generic and `_make_rhs_oop` runs acc kernels:
#
#   1. The ForwardDiff Jacobian of an AFFINE-built in-place `f!` is bit-identical
#      to the per-cell reference's — over STATE and over a PARAMETER. Same primal
#      arithmetic ⇒ same Duals ⇒ same Jacobian, to the bit.
#   2. A `form=:oop` affine build equals the in-place affine build and the per-cell
#      reference bit-for-bit, and it too differentiates.
#
# Every case asserts the affine path actually FIRED (n_acc_kernels ≥ 1 and it owned
# the equation), so a silent fallback can't make the comparison pass trivially.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# Build an evaluator under the affine path (ESS_AFFINE=1) or the byte-identical
# per-cell reference (ESS_STENCIL_DISABLE=1). Returns (f, u0, p, vmap, diag);
# `f` is `f!(du,u,p,t)` for :inplace or `f(u,p,t)->du` for :oop.
function _affine_f(model, ics; affine::Bool, form=:inplace, const_arrays=Dict())
    envs = affine ? ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing) :
                    ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")
    withenv(envs...) do
        f, u0, p, _tspan, vmap, diag =
            ESM._build_evaluator_impl(model; initial_conditions=ics, form=form,
                                      const_arrays=const_arrays)
        (f, u0, p, vmap, diag)
    end
end

# Jacobian of an in-place RHS w.r.t. the state, and its `du` at a point.
_jac_u(f!, u0, p) =
    ForwardDiff.jacobian(uu -> (d = similar(uu); fill!(d, 0); f!(d, uu, p, 0.0); d), u0)
_du(f!, u0, p) = (d = similar(u0); fill!(d, 0); f!(d, u0, p, 0.0); d)

# ---- models (locally named to avoid clashing with stencil_affine_diff_test.jl) ----

# 2-D 5-point Laplacian over the full i×j range (ghosts on all four edges).
function _ad_2d_model(N)
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

# 1-D variable-coefficient diffusion K[i]·Δ²u (K a const array) — exercises
# `_AccConstBox` const reads (Float64 data, zero derivative) alongside the AD.
function _ad_const_coef_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("*", _idx("K", _v("i")), lap), "i", 1, N))])
end

# 1-D diffusion α·Δ²u with α a SCALAR PARAMETER — the `_NK_PARAM` leaf in the
# access spine, so ForwardDiff-over-parameters exercises the generic param arm.
function _ad_param_model(N; alpha=0.5)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.StateVariable),
        "alpha" => ESM.ModelVariable(ESM.ParameterVariable; default=alpha))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("*", _v("alpha"), lap), "i", 1, N))])
end

@testset "affine access kernels: AD + out-of-place (ess-affine)" begin

    # ---- 1. State Jacobian: affine ≡ per-cell, bit-for-bit ----
    @testset "state Jacobian ≡ per-cell — 1D 2nd-diff (N=$N)" for N in (8, 24)
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        f_aff, u0, p, _, d = _affine_f(_stencil_model(N), ics; affine=true)
        f_ref, _, _, _, _  = _affine_f(_stencil_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_vec_kernels == 0
        @test _jac_u(f_aff, u0, p) == _jac_u(f_ref, u0, p)
    end

    @testset "state Jacobian ≡ per-cell — 2D 5-point (N=$N)" for N in (5, 12)
        ics = Dict("u[$i,$j]" => sin(0.2i) + 0.3cos(0.1j) + 0.01i * j
                   for i in 1:N, j in 1:N)
        f_aff, u0, p, _, d = _affine_f(_ad_2d_model(N), ics; affine=true)
        f_ref, _, _, _, _  = _affine_f(_ad_2d_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test _jac_u(f_aff, u0, p) == _jac_u(f_ref, u0, p)
    end

    @testset "state Jacobian ≡ per-cell — var-coef K[i]·Δ²u (N=$N)" for N in (10, 32)
        K = Float64[0.5 + 0.3sin(0.2k) for k in 1:N]
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        ca = Dict("K" => K)
        f_aff, u0, p, _, d = _affine_f(_ad_const_coef_model(N), ics; affine=true, const_arrays=ca)
        f_ref, _, _, _, _  = _affine_f(_ad_const_coef_model(N), ics; affine=false, const_arrays=ca)
        @test d.n_acc_kernels >= 1
        @test _jac_u(f_aff, u0, p) == _jac_u(f_ref, u0, p)
    end

    # ---- 2. Parameter Jacobian: the generic `_NK_PARAM` arm ----
    @testset "parameter Jacobian ≡ per-cell — α·Δ²u (N=$N)" for N in (8, 20)
        ics = Dict("u[$k]" => cos(0.25k) + 0.05k for k in 1:N)
        f_aff, u0, p, _, d = _affine_f(_ad_param_model(N), ics; affine=true)
        f_ref, _, _, _, _  = _affine_f(_ad_param_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        # differentiate du w.r.t. the scalar parameter α (u fixed at Float64, so
        # only `p.alpha` goes Dual — the path `eltype(u)`-only sizing would break)
        jp(f!) = ForwardDiff.jacobian(
            a -> (dd = similar(u0, eltype(a)); fill!(dd, 0);
                  f!(dd, u0, (; p..., alpha=a[1]), 0.0); dd), [p.alpha])
        @test jp(f_aff) == jp(f_ref)
    end

    # ---- 3. Out-of-place affine build: bit-identical value + differentiable ----
    @testset "form=:oop affine ≡ in-place affine ≡ per-cell (N=$N)" for N in (8, 24)
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        f_oop, u0, p, _, d = _affine_f(_stencil_model(N), ics; affine=true, form=:oop)
        f_iip, _, _, _, _  = _affine_f(_stencil_model(N), ics; affine=true, form=:inplace)
        f_ref, _, _, _, _  = _affine_f(_stencil_model(N), ics; affine=false, form=:inplace)
        @test d.n_acc_kernels >= 1
        du_oop = f_oop(u0, p, 0.0)
        @test du_oop == _du(f_iip, u0, p)        # oop ≡ affine in-place, bit-for-bit
        @test du_oop == _du(f_ref, u0, p)        # …and ≡ the per-cell reference
        # the out-of-place emitter is eltype-generic too — its state Jacobian
        # matches the in-place affine one.
        @test ForwardDiff.jacobian(uu -> f_oop(uu, p, 0.0), u0) == _jac_u(f_iip, u0, p)
    end

    # ---- 4. 2-D out-of-place, exercising the strided-box functional scatter ----
    @testset "form=:oop affine ≡ per-cell — 2D 5-point (N=$N)" for N in (5, 12)
        ics = Dict("u[$i,$j]" => sin(0.2i) + 0.3cos(0.1j) + 0.01i * j
                   for i in 1:N, j in 1:N)
        f_oop, u0, p, _, d = _affine_f(_ad_2d_model(N), ics; affine=true, form=:oop)
        f_ref, _, _, _, _  = _affine_f(_ad_2d_model(N), ics; affine=false, form=:inplace)
        @test d.n_acc_kernels >= 1
        @test f_oop(u0, p, 0.0) == _du(f_ref, u0, p)
    end
end
