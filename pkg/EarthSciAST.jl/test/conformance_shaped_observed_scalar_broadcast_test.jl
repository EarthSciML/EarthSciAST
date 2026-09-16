# Conformance harness adapter — shaped_observed_scalar_broadcast category.
#
# A SHAPED observed whose right-hand side is a SCALAR fills every cell of its
# declared shape (esm-spec §4.3.4). The reference binding (Julia) runs the
# OFFICIAL `run_inline_tests` pathway over the committed fixture and must
# reproduce the committed golden actuals (which that same pathway minted). The
# manifest declares julia/python/rust as bindings_required, so the golden is the
# shared cross-binding anchor. Issue #262: Rust dropped the declared shape when
# the value came out scalar, and Python when the right-hand side was a scalar as
# written. See tests/conformance/shaped_observed_scalar_broadcast/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SCALAROBS_REPO_ROOT = TESTUTILS_REPO_ROOT
const _SCALAROBS_CAT_DIR = joinpath(_SCALAROBS_REPO_ROOT, "tests", "conformance",
                                  "shaped_observed_scalar_broadcast")
const _SCALAROBS_MANIFEST = joinpath(_SCALAROBS_CAT_DIR, "manifest.json")

@testset "Conformance: shaped_observed_scalar_broadcast (manifest-driven)" begin
    @test isfile(_SCALAROBS_MANIFEST)
    manifest = JSON3.read(read(_SCALAROBS_MANIFEST, String))
    @test manifest.category == "shaped_observed_scalar_broadcast"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path = joinpath(_SCALAROBS_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_SCALAROBS_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_inline_tests(esm_path; model_name=String(fixture.model),
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
            for a in fixture.assertions
                r = by_idx[Int(a.assertion_idx)]
                @test String(r.variable) == String(a.variable)
                @test isapprox(r.actual, Float64(a.expected); rtol=rtol, atol=atol)
            end
        end
    end
end
