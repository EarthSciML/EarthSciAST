# Per-cell CSE on the affine access-kernel spine (ess-affine). The spine is walked
# as a TREE once per cell (`_build_branch_template` compiles with no memo), so a
# subexpression that appears k times is evaluated k times per cell. `_build_acc_cse`
# value-numbers the spine, slices each shared OP subtree into an ordered recipe, and
# replaces every occurrence with an `_NK_CACHED` read of a per-cell scratch — one
# evaluation per cell. Bit-identity is automatic (the SAME computation, once), and
# the scratch reuses the Float64/Dual dual-buffer trick so it stays zero-alloc + AD.
#
# Asserts, per sharing model: affine (ESS_AFFINE=1) ≡ per-cell (ESS_STENCIL_DISABLE)
# BIT-IDENTICALLY, CSE FIRED (n_acc_cse_slots ≥ 1), N-independent slot count; and a
# no-sharing model produces ZERO CSE slots (no spurious caching).
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

function _cse_build(model, ics; affine::Bool, const_arrays=Dict())
    envs = affine ? ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing) :
                    ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")
    withenv(envs...) do
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, const_arrays=const_arrays)
        du = zero(u0); f!(du, u0, p, 0.0)
        (du, u0, vm, diag)
    end
end

# D(u[i]) = s*s + s,  s = (u[i-1] − 2u[i] + u[i+1]).  `s` occurs 3× → shared.
function _cse_shared_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    s = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                 _op("*", _n(-2.0), _idx("u", _v("i"))),
                 _idx("u", _op("+", _v("i"), _i(1))))
    body = _op("+", _op("*", s, s), s)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# D(u[i]) = g*g,  g = exp(u[i-1]) * exp(u[i+1]) − a nested shared subexpr through a
# transcendental (the expensive-shared-work case CSE is meant to collapse).
function _cse_nested_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    g = _op("*", _op("exp", _idx("u", _op("-", _v("i"), _i(1)))),
                 _op("exp", _idx("u", _op("+", _v("i"), _i(1)))))
    body = _op("*", g, g)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# D(u[i]) = u[i-1] − 2u[i] + u[i+1]  — plain Laplacian, NO repeated subexpression.
function _cse_nosharing_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                    _op("*", _n(-2.0), _idx("u", _v("i"))),
                    _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

@testset "affine per-cell CSE ≡ per-cell (differential, ess-affine)" begin
    @testset "shared subexpr s*s + s (N=$N)" for N in (8, 32, 64)
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        du_a, _, _, d = _cse_build(_cse_shared_model(N), ics; affine=true)
        du_r, _, _, _ = _cse_build(_cse_shared_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1
        @test d.n_acc_cse_slots >= 1        # CSE fired
        @test du_a == du_r                  # bit-identical with the shared subtree cached
    end

    @testset "nested transcendental g*g, g=exp·exp (N=$N)" for N in (8, 32)
        ics = Dict("u[$k]" => 0.2sin(0.3k) for k in 1:N)
        du_a, _, _, d = _cse_build(_cse_nested_model(N), ics; affine=true)
        du_r, _, _, _ = _cse_build(_cse_nested_model(N), ics; affine=false)
        @test d.n_acc_cse_slots >= 1
        @test du_a == du_r
    end

    @testset "CSE slot count is N-independent" begin
        counts = map((8, 32, 128)) do N
            ics = Dict("u[$k]" => 0.1k for k in 1:N)
            _cse_build(_cse_shared_model(N), ics; affine=true)[4].n_acc_cse_slots
        end
        @test all(==(counts[1]), counts)
        @test counts[1] >= 1
    end

    @testset "no repeated subexpr ⇒ zero CSE slots" begin
        ics = Dict("u[$k]" => sin(0.3k) for k in 1:16)
        du_a, _, _, d = _cse_build(_cse_nosharing_model(16), ics; affine=true)
        du_r, _, _, _ = _cse_build(_cse_nosharing_model(16), ics; affine=false)
        @test d.n_acc_cse_slots == 0        # nothing shared → no spurious caching
        @test du_a == du_r
    end
end
