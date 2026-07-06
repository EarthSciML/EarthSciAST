# Cross-binding conformance tests for the four inverse-trigonometric scalar
# leaf ops acos / asin / atan / atan2 (bead ess-9x1).
#
# Loads the shared fixture tests/valid/scalar_leaves/inverse_trig_leaves.esm —
# which carries an inline `tests` block checked by Python (simulate) and Rust
# (simulate) against the SAME expected values — and evaluates it through
# `build_evaluator`. Julia, Python, and Rust all pin the same constants, so
# agreement here is the cross-binding inverse-trig-leaf proof.
#
# Each variable's RHS is a CONSTANT inverse-trig expression integrated from a
# zero initial condition, so the derivative du = f!(u0) the evaluator returns
# IS the trajectory value at t=1 (y(1) = rate·1 = rate). We therefore assert on
# du directly — exact, no ODE-integrator dependency — and the asserted numbers
# mirror the fixture's inline `tests[].assertions[].expected` (which Rust/Python
# check via simulate): asin(0.5)=π/6, acos(0.5)=π/3, atan(1)=π/4, and
# atan2(1,-1)=3π/4. The atan2 case sits in the second quadrant, so it exercises
# the 2-arg quadrant resolution rather than a bare atan of a ratio.
#
# These leaves back the spherical-geometry FAQs (great-circle arc R·acos,
# lat/lon asin/atan2) consumed by M4 polygon_area (ess-my4.4.3) and the ESD-DUO
# geometry beads.

using Test
using EarthSciSerialization

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _INVTRIG_REPO_ROOT = TESTUTILS_REPO_ROOT

# Evaluate the shared scalar-leaf fixture and return (du, vmap), seeding every
# state element to zero (the constant-RHS worked examples start from rest).
# Scalar state variables key into `vmap` by their bare name (no model prefix).
function _eval_invtrig_fixture(filename::AbstractString, model_name::AbstractString,
                               elements::Vector{<:AbstractString})
    path = joinpath(_INVTRIG_REPO_ROOT, "tests", "valid", "scalar_leaves", filename)
    @test isfile(path)
    file = EarthSciSerialization.load(path)
    ics = Dict(e => 0.0 for e in elements)
    f!, u0, p, _, vmap = build_evaluator(file; model_name=model_name,
                                         initial_conditions=ics)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    return du, vmap
end

@testset "inverse-trig scalar-leaf conformance (ess-9x1)" begin
    du, vmap = _eval_invtrig_fixture(
        "inverse_trig_leaves.esm", "InverseTrigLeaves",
        ["asin_v", "acos_v", "atan_v", "atan2_v"])
    @test du[vmap["asin_v"]]  ≈ 0.5235987755982989   # asin(0.5)  = π/6
    @test du[vmap["acos_v"]]  ≈ 1.0471975511965979   # acos(0.5)  = π/3
    @test du[vmap["atan_v"]]  ≈ 0.7853981633974483   # atan(1)    = π/4
    @test du[vmap["atan2_v"]] ≈ 2.356194490192345    # atan2(1,-1) = 3π/4
end

# Hyperbolic family sinh / cosh / tanh and inverses asinh / acosh / atanh
# (bead ess-v9a.1). Same constant-RHS-from-zero worked-example construction as
# the inverse-trig set above, so each du element IS the op's value at t=1; the
# asserted constants mirror the shared fixture's inline `tests[].expected`,
# which Python (simulate) and Rust (simulate) also check.
@testset "hyperbolic-trig scalar-leaf conformance (ess-v9a.1)" begin
    du, vmap = _eval_invtrig_fixture(
        "hyperbolic_trig_leaves.esm", "HyperbolicTrigLeaves",
        ["sinh_v", "cosh_v", "tanh_v", "asinh_v", "acosh_v", "atanh_v"])
    @test du[vmap["sinh_v"]]  ≈ 1.1752011936438014   # sinh(1)
    @test du[vmap["cosh_v"]]  ≈ 1.5430806348152437   # cosh(1)
    @test du[vmap["tanh_v"]]  ≈ 0.7615941559557649   # tanh(1)
    @test du[vmap["asinh_v"]] ≈ 0.881373587019543    # asinh(1)
    @test du[vmap["acosh_v"]] ≈ 1.3169578969248166   # acosh(2)
    @test du[vmap["atanh_v"]] ≈ 0.5493061443340549   # atanh(0.5)
end
