# Cross-binding conformance tests for the M1 semiring / index-set worked
# examples (bead ess-my4.1.5).
#
# Loads the four shared fixtures under tests/valid/aggregate/ that carry inline
# `tests` blocks — the M1-expressible worked examples — and evaluates each
# through `build_evaluator`. Julia, Rust, and Python all check the SAME inline
# expected values baked into these shared fixtures, so agreement here is the
# cross-binding semiring-equivalence proof.
#
# Each fixture is a constant-RHS contraction from zero initial conditions, so
# the derivative du = f!(u0) the evaluator returns IS the trajectory value at
# t=1 (y(1) = rate·1 = rate). We therefore assert on du directly — exact, and
# no ODE integrator dependency — and the asserted numbers mirror the fixtures'
# inline `tests[].assertions[].expected` (which Rust/Python check via simulate).
#
# RFC: docs/content/rfcs/semiring-faq-unified-ir.md §5.1 / §5.2 / §7.1.

using Test
using EarthSciSerialization

const _AGG_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

# Evaluate a shared aggregate fixture and return (du, vmap), seeding every
# state element to zero (the constant-RHS worked examples start from rest).
function _eval_aggregate_fixture(filename::AbstractString, model_name::AbstractString,
                                 elements::Vector{<:AbstractString})
    path = joinpath(_AGG_REPO_ROOT, "tests", "valid", "aggregate", filename)
    @test isfile(path)
    file = EarthSciSerialization.load(path)
    ics = Dict(e => 0.0 for e in elements)
    f!, u0, p, _, vmap = build_evaluator(file; model_name=model_name,
                                         initial_conditions=ics)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    return du, vmap
end

@testset "aggregate worked-example conformance (ess-my4.1.5)" begin
    # 7.1 FVM diffusion as the default sum_product ring, plus the empty-range
    # 0̄ identity: degenerate[i] = Σ_{j∈∅} i·j = 0 (sum_product 0̄).
    @testset "fvm_diffusion_sum_product" begin
        du, vmap = _eval_aggregate_fixture(
            "fvm_diffusion_sum_product.esm", "FvmDiffusionSumProduct",
            ["flux[1]", "flux[2]", "degenerate[1]", "degenerate[2]"])
        @test du[vmap["flux[1]"]] ≈ 6.0
        @test du[vmap["flux[2]"]] ≈ 12.0
        # Empty sum_product contraction returns the normative 0̄ identity (0).
        @test du[vmap["degenerate[1]"]] == 0.0
        @test du[vmap["degenerate[2]"]] == 0.0
    end

    # min_sum (tropical): ⊕ = min over the additive body i+j.
    @testset "min_sum_tropical" begin
        du, vmap = _eval_aggregate_fixture(
            "min_sum_tropical.esm", "MinSumTropical", ["dist[1]", "dist[2]"])
        @test du[vmap["dist[1]"]] ≈ 2.0   # min(2,3,4)
        @test du[vmap["dist[2]"]] ≈ 3.0   # min(3,4,5)
    end

    # max_product: ⊕ = max over the product body i*j.
    @testset "max_product_saturation" begin
        du, vmap = _eval_aggregate_fixture(
            "max_product_saturation.esm", "MaxProductSaturation", ["best[1]", "best[2]"])
        @test du[vmap["best[1]"]] ≈ 3.0   # max(1,2,3)
        @test du[vmap["best[2]"]] ≈ 6.0   # max(2,4,6)
    end

    # Categorical index set resolves to [1, |members|]; a 3-member set drives a
    # 3-wide contraction identical to an interval of size 3.
    @testset "categorical_index_set" begin
        du, vmap = _eval_aggregate_fixture(
            "categorical_index_set.esm", "CategoricalIndexSet",
            ["emissions[1]", "emissions[2]"])
        @test du[vmap["emissions[1]"]] ≈ 6.0
        @test du[vmap["emissions[2]"]] ≈ 12.0
    end
end
