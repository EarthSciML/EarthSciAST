# Loop-invariant hoisting on the affine access-kernel spine (ess-affine). A subtree
# with no cell-varying access (only params, time, fixed state slots, fixed forcing,
# literals) has the SAME value for every cell in a box, so `_build_acc_cse` hoists
# it to a per-CALL scratch filled ONCE before the box loop — not once per cell. The
# value still varies per call (it may read `t`, `p`, or an integrator-moved state),
# so it is RE-EVALUATED each call, never frozen at build.
#
# Asserts, per model: hoist FIRED (n_acc_inv_slots ≥ 1); affine (ESS_AFFINE=1) ≡
# per-cell (ESS_STENCIL_DISABLE) BIT-IDENTICALLY; and the time case re-evaluates
# across calls. A pure stencil (no invariant subexpr) hoists nothing.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

function _inv_build(model, ics; affine::Bool)
    envs = affine ? ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing) :
                    ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")
    withenv(envs...) do
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model; initial_conditions=ics)
        (f!, u0, p, vm, diag)
    end
end
_du(f!, u0, p, t) = (du = zero(u0); f!(du, u0, p, t); du)

# D(c[i]) = sin(2t)·c[i]  — sin(2t) invariant + time-varying → hoisted, re-evaluated.
function _inv_time_model(N)
    vars = Dict("c" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("*", _op("sin", _op("*", _n(2.0), _v("t"))), _idx("c", _v("i")))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("c", _v("i")), "i", 1, N), _ao1(body, "i", 1, N))])
end

# D(u[i]) = (g/h)·(u[i-1] − 2u[i] + u[i+1])  — g/h invariant parameter subexpr.
function _inv_param_model(N; g=3.0, h=7.0)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.StateVariable),
        "g" => ESM.ModelVariable(ESM.ParameterVariable; default=g),
        "h" => ESM.ModelVariable(ESM.ParameterVariable; default=h))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    body = _op("*", _op("/", _v("g"), _v("h")), lap)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body, "i", 1, N))])
end

# D(c[i]) = (s·s)·c[i];  D(s) = 0.  s is a 0-D state — a fixed slot inside the
# arrayop → s·s is loop-invariant but moves with the integrator.
function _inv_state_model(N)
    vars = Dict{String,ESM.ModelVariable}(
        "c" => ESM.ModelVariable(ESM.StateVariable),
        "s" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("*", _op("*", _v("s"), _v("s")), _idx("c", _v("i")))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("c", _v("i")), "i", 1, N), _ao1(body, "i", 1, N)),
                     ESM.Equation(_D("s"), _n(0.0))])
end

# pure Laplacian — every op mixes a cell-varying gather, so nothing is invariant.
function _inv_none_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                    _op("*", _n(-2.0), _idx("u", _v("i"))),
                    _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body, "i", 1, N))])
end

@testset "affine invariant hoist ≡ per-cell (differential, ess-affine)" begin
    @testset "time-varying invariant sin(2t) (N=$N)" for N in (8, 32)
        ics = Dict("c[$k]" => 1.0 + 0.1k for k in 1:N)
        fa, u0, pa, _, d = _inv_build(_inv_time_model(N), ics; affine=true)
        fr, _,  pr, _, _ = _inv_build(_inv_time_model(N), ics; affine=false)
        @test d.n_acc_inv_slots >= 1        # sin(2t) hoisted
        prev = nothing
        for t in (0.0, 0.37, 1.9, -2.5)
            da = _du(fa, u0, pa, t); dr = _du(fr, u0, pr, t)
            @test da == dr                  # bit-identical
            @test da == sin(2t) .* u0       # correct, and re-evaluated at this t
            prev !== nothing && @test da != prev   # genuinely changes with t
            prev = da
        end
    end

    @testset "parameter invariant g/h (N=$N)" for N in (8, 32, 64)
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        fa, u0, pa, _, d = _inv_build(_inv_param_model(N), ics; affine=true)
        fr, _,  pr, _, _ = _inv_build(_inv_param_model(N), ics; affine=false)
        @test d.n_acc_inv_slots >= 1
        @test _du(fa, u0, pa, 0.0) == _du(fr, u0, pr, 0.0)
    end

    @testset "fixed-state invariant s·s (N=$N)" for N in (8, 32)
        ics = Dict{String,Float64}("s" => 1.5)
        for k in 1:N; ics["c[$k]"] = 0.5k; end
        fa, u0, pa, vm, d = _inv_build(_inv_state_model(N), ics; affine=true)
        fr, u0r, pr, _, _ = _inv_build(_inv_state_model(N), ics; affine=false)
        @test d.n_acc_inv_slots >= 1
        @test _du(fa, u0, pa, 0.0) == _du(fr, u0r, pr, 0.0)
    end

    @testset "invariant slot count is N-independent" begin
        counts = map((8, 32, 128)) do N
            ics = Dict("u[$k]" => 0.1k for k in 1:N)
            _inv_build(_inv_param_model(N), ics; affine=true)[5].n_acc_inv_slots
        end
        @test all(==(counts[1]), counts)
        @test counts[1] >= 1
    end

    @testset "pure stencil hoists nothing" begin
        ics = Dict("u[$k]" => sin(0.3k) for k in 1:16)
        _, _, _, _, d = _inv_build(_inv_none_model(16), ics; affine=true)
        @test d.n_acc_inv_slots == 0
    end
end
