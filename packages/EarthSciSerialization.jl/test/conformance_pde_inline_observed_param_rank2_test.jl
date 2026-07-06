# Conformance harness adapter — pde_inline_observed_param_rank2 category.
#
# §6.6.5 inline-test assertions on a RANK-2 array OBSERVED whose expression
# references a model PARAMETER (`scaled` = k * base, k a scalar parameter). The
# reference binding (Julia) runs the OFFICIAL `run_pde_tests` pathway over the
# committed fixture and must reproduce the committed golden actuals (which that
# same pathway minted). The manifest declares julia/python/rust as
# bindings_required.
#
# This is the conformance GATE for the build-time cellwise-evaluation
# parameter-binding fix: model parameters are load-time constants and are in
# scope for a directly-asserted observed (esm-spec §6.6.5); STATE is not. Before
# the fix, Julia's `_observed_field` re-materialized the observed via
# `evaluate_cellwise` with only the const-array registry in scope, so a
# parameter-dependent observed asserted directly raised
# `E_TREEWALK_UNBOUND_VARIABLE`. See
# tests/conformance/pde_inline_observed_param_rank2/.

using Test
using JSON3
using EarthSciSerialization
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _OPR2_REPO_ROOT = TESTUTILS_REPO_ROOT
const _OPR2_CAT_DIR   = joinpath(_OPR2_REPO_ROOT, "tests", "conformance",
                                 "pde_inline_observed_param_rank2")
const _OPR2_MANIFEST  = joinpath(_OPR2_CAT_DIR, "manifest.json")

@testset "Conformance: pde_inline_observed_param_rank2 (manifest-driven)" begin
    @test isfile(_OPR2_MANIFEST)
    manifest = JSON3.read(read(_OPR2_MANIFEST, String))
    @test manifest.category == "pde_inline_observed_param_rank2"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_OPR2_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_OPR2_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Index the Julia run by assertion_idx and gate each against BOTH
            # the golden actual (cross-binding anchor) and the fixture's own
            # declared `expected` (author intent), and require pass=true.
            by_idx = Dict(r.assertion_idx => r for r in results)
            for g in golden.assertions
                gi = Int(g.assertion_idx)
                @test haskey(by_idx, gi)
                r = by_idx[gi]
                @test r.passed
                @test r.actual !== nothing
                @test isapprox(r.actual, Float64(g.actual); rtol=rtol, atol=atol)
            end
        end
    end
end
