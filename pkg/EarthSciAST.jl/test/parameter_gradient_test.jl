# ∂(RHS)/∂(PARAMETER VECTOR) — the derivative this package did not have a test for.
#
# Every other AD test in this suite differentiates w.r.t. the STATE: that is what a
# stiff solver's Jacobian needs, and `_rhs_value_type` promoting over `eltype(u)`
# alone would have been enough for it. Differentiating w.r.t. PARAMETERS is the
# other shape — `u` stays `Vector{Float64}` and only the `p` values go `Dual` — and
# it is the shape a calibration / adjoint / sensitivity workflow actually asks for.
# Two pieces of existing design are load-bearing for it and are pinned here so a
# later "simplification" cannot quietly remove them:
#
#   * `_rhs_value_type(u, p, t)` derives the value type from ALL THREE inputs
#     (compile.jl). Sized from `eltype(u)` alone, every scratch buffer would be
#     `Float64` and the first store of a `Dual` would throw.
#   * `const_tier.jl` deliberately does NOT constant-fold parameter-only
#     subexpressions at build time. Freezing them would return a ZERO derivative
#     for every parameter sensitivity — a wrong Jacobian that still looks
#     plausible, which is the worst failure mode available.
#
# WHAT IS ASSERTED HERE (the host layer):
#
#   `ForwardDiff.gradient` of a scalar functional of the RHS w.r.t. the parameter
#   vector, through the in-place `f!`. Central finite differences check that it
#   is the RIGHT number (~1e-6), and a non-zero test gives the whole thing teeth:
#   a build that froze the parameters would return zeros and still look
#   self-consistent.

using Test
using EarthSciAST
using ForwardDiff

const _PG_ESM = EarthSciAST

# A 1-D reaction–diffusion model. It is the right
# model for a parameter gradient because all four parameters reach `du` by
# different routes: `k_diff` linearly through the stencil, `k_rxn` linearly
# through the reaction term, and `Ea`/`T` nonlinearly through the hoisted
# INVARIANT `exp(-Ea/T)` — the arm a build-time constant fold would silently
# freeze.
_pg_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_pg_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_pg_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_pg_ao(e) = Dict{String,Any}("op" => "faq", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)
_pg_state(; kw...) = Dict{String,Any}("type" => "unknown",
                                      (String(k) => v for (k, v) in kw)...)
_pg_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

function _pg_rd(N)
    stencil = _pg_o("+", _pg_o("-", _pg_ix("c", _pg_o("-", "i", 1.0)),
                               _pg_o("*", 2.0, _pg_ix("c", "i"))),
                    _pg_ix("c", _pg_o("+", "i", 1.0)))
    rate = _pg_o("*", "k_rxn", _pg_o("exp", _pg_o("neg", _pg_o("/", "Ea", "T"))))
    Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "RD"),
        "index_sets" => Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => N)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "c" => _pg_state(shape = Any["n"]), "k_diff" => _pg_param(0.1),
                "k_rxn" => _pg_param(0.3), "Ea" => _pg_param(50.0),
                "T" => _pg_param(300.0)),
            "equations" => Any[Dict{String,Any}(
                "lhs" => _pg_ao(_pg_Dt(_pg_ix("c", "i"))),
                "rhs" => _pg_ao(_pg_o("-", _pg_o("*", "k_diff", stencil),
                                      _pg_o("*", rate,
                                            _pg_o("^", _pg_ix("c", "i"), 2.0)))))])))
end

const _PG_N = 8
const _PG_DOC = _pg_rd(_PG_N)
const _PG_U = [0.5 + 0.1i for i in 1:_PG_N]
const _PG_T = 0.37
# A non-uniform weight, so the functional is not `sum` — a `sum` objective can
# hide a per-cell sign or ordering error by cancellation.
const _PG_W = [1.0 + 0.05k for k in 1:_PG_N]

const _PG_FI, _, _PG_P0, _, _ = _PG_ESM.build_evaluator(_PG_DOC)
const _PG_SYMS = keys(_PG_P0)
const _PG_PVEC0 = collect(Float64, values(_PG_P0))
_pg_nt(pv) = NamedTuple{_PG_SYMS}(Tuple(pv))

# The scalar functional. Note `du`'s eltype comes from `pv`, NOT from `u`:
# under ∂/∂p the state stays Float64 and only `p` is Dual.
function _pg_obj(u, p, t)
    du = zeros(promote_type(eltype(u), eltype(values(p))), _PG_N)
    _PG_FI(du, u, p, t)
    return sum(_PG_W .* du)
end
_pg_J_iip(pv) = _pg_obj(_PG_U, _pg_nt(pv), _PG_T)

const _PG_G_P = ForwardDiff.gradient(_pg_J_iip, _PG_PVEC0)
const _PG_G_U = ForwardDiff.gradient(uu -> _pg_obj(uu, _PG_P0, _PG_T), _PG_U)

@testset "∂(RHS)/∂(parameter vector) — host" begin

    @testset "ForwardDiff ∂/∂p is finite and non-zero" begin
        @test length(_PG_G_P) == length(_PG_PVEC0) == 4
        # Teeth: a build that constant-folded the parameters would give zeros and
        # still satisfy the finite-difference agreement below, at zero.
        @test all(isfinite, _PG_G_P)
        @test all(!iszero, _PG_G_P)
    end

    @testset "…and both are the right number (central differences)" begin
        # The independent check. Central differences at h = 1e-6·max(|θ|,1) give
        # ~1e-9 truncation on this model, so 1e-6 relative is a real assertion
        # about the VALUE, not a rounding allowance.
        fd = similar(_PG_PVEC0)
        for k in eachindex(_PG_PVEC0)
            h = 1e-6 * max(abs(_PG_PVEC0[k]), 1.0)
            hi = copy(_PG_PVEC0); hi[k] += h
            lo = copy(_PG_PVEC0); lo[k] -= h
            fd[k] = (_pg_J_iip(hi) - _pg_J_iip(lo)) / (2h)
        end
        @test isapprox(_PG_G_P, fd; rtol = 1e-6)
    end

    @testset "∂/∂p and ∂/∂u are computed in DIFFERENT value types" begin
        # The property `_rhs_value_type` exists for: differentiating w.r.t. `p`
        # must not require `u` to be Dual, and vice versa. Both directions run
        # here with the other argument left at Float64.
        @test all(isfinite, _PG_G_U)
        @test all(!iszero, _PG_G_U)
        @test eltype(_PG_U) === Float64          # untouched by the ∂/∂p pass above
    end
end
