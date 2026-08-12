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
#   vector, through the in-place `f!` AND through `form = :oop`, agreeing to
#   rtol 1e-12 — the two emitters run the same operations in the same order, so
#   this is a tight bound, not a fitted one. Central finite differences check that
#   both are the RIGHT number (~1e-6), and a non-zero test gives the whole thing
#   teeth: a build that froze the parameters would pass an emitter-vs-emitter
#   comparison of two zeros.
#
# The TRACED layers (reverse-mode ∂/∂p and ∂/∂u under Reactant/XLA, `p`-is-a-real-
# XLA-input, and the reverse-over-`@trace while` `@test_broken`) live in
# test/reactant_parameter_gradient_test.jl, included from the bottom of this file
# under `ESM_TEST_REACTANT=1` — the same gate test/reactant_oop_test.jl uses, and
# for the same reason (Reactant bundles an XLA runtime). They are a separate FILE
# rather than a branch in this one because `Reactant.@trace` / `@compile` are
# MACROS: an `if` around them still macro-expands, so merely mentioning them in an
# un-taken branch would break the default, Reactant-free suite.

using Test
using EarthSciAST
using ForwardDiff

const _PG_ESM = EarthSciAST

# The 1-D reaction–diffusion model from test/reactant_oop_test.jl (`_rd`), kept
# here verbatim so this file runs with NO Reactant in the session. It is the right
# model for a parameter gradient because all four parameters reach `du` by
# different routes: `k_diff` linearly through the stencil, `k_rxn` linearly
# through the reaction term, and `Ea`/`T` nonlinearly through the hoisted
# INVARIANT `exp(-Ea/T)` — the arm a build-time constant fold would silently
# freeze.
_pg_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_pg_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_pg_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_pg_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)
_pg_state(; kw...) = Dict{String,Any}("type" => "state",
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
const _PG_FO, _, _, _, _ = _PG_ESM.build_evaluator(_PG_DOC; form = :oop)
const _PG_SYMS = keys(_PG_P0)
const _PG_PVEC0 = collect(Float64, values(_PG_P0))
_pg_nt(pv) = NamedTuple{_PG_SYMS}(Tuple(pv))

# The scalar functional, once per emitter. Note `du`'s eltype comes from `pv`,
# NOT from `u`: under ∂/∂p the state stays Float64 and only `p` is Dual.
_pg_obj(u, p, t) = sum(_PG_W .* _PG_FO(u, p, t))
_pg_J_oop(pv) = _pg_obj(_PG_U, _pg_nt(pv), _PG_T)
function _pg_J_iip(pv)
    du = zeros(eltype(pv), _PG_N)
    _PG_FI(du, _PG_U, _pg_nt(pv), _PG_T)
    return sum(_PG_W .* du)
end

# The host reference every traced assertion is measured against.
const _PG_G_OOP = ForwardDiff.gradient(_pg_J_oop, _PG_PVEC0)
const _PG_G_U = ForwardDiff.gradient(uu -> _pg_obj(uu, _PG_P0, _PG_T), _PG_U)

@testset "∂(RHS)/∂(parameter vector) — host" begin

    @testset "ForwardDiff ∂/∂p agrees across both emitters" begin
        @test length(_PG_G_OOP) == length(_PG_PVEC0) == 4
        # Teeth: a build that constant-folded the parameters would give zeros and
        # still satisfy the agreement test below.
        @test all(isfinite, _PG_G_OOP)
        @test all(!iszero, _PG_G_OOP)
        @test isapprox(ForwardDiff.gradient(_pg_J_iip, _PG_PVEC0), _PG_G_OOP;
                       rtol = 1e-12)
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
            fd[k] = (_pg_J_oop(hi) - _pg_J_oop(lo)) / (2h)
        end
        @test isapprox(_PG_G_OOP, fd; rtol = 1e-6)
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

# ---- Traced (Reactant/XLA) — opt-in ----------------------------------------
if get(ENV, "ESM_TEST_REACTANT", "0") == "1"
    include("reactant_parameter_gradient_test.jl")
else
    @info "skipping the traced ∂/∂p tests (reactant_parameter_gradient_test.jl); " *
          "set ESM_TEST_REACTANT=1, with Reactant in the environment, to run them"
end
