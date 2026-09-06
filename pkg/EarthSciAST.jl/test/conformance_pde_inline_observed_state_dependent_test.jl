# Conformance harness adapter — pde_inline_observed_state_dependent category.
#
# §6.6.5 inline-test assertions on a STATE-DEPENDENT array OBSERVED. The
# asserted `g = 2*u + rate` moves with the trajectory, so it reaches NO
# build-time product (only STATE-FREE observeds are materialized at build) and
# is not a scalar output row either — every binding used to refuse such an
# assertion outright with "array state 'g' has no cells in var_map". §6.6.5
# admits ANY shaped variable in a `coords` / `reduce` assertion and §5.23 makes
# a reference denote its expansion, so the observed's own expression must be
# evaluated at the SAMPLED STATE. In this reference binding that is
# `_state_scope` putting the solved state (and `t`) into the `evaluate_cellwise`
# scopes; without it the same expression raised
# `E_TREEWALK_UNBOUND_VARIABLE: M.u`.
#
# The fixture's `rate` is the STATE-FREE array observed of the same document,
# asserted alongside as the regression guard on the build-materialized path.
# Julia is the reference binding: this run must reproduce the committed golden
# actuals (which this same pathway minted). See
# tests/conformance/pde_inline_observed_state_dependent/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _OSD_REPO_ROOT = TESTUTILS_REPO_ROOT
const _OSD_CAT_DIR   = joinpath(_OSD_REPO_ROOT, "tests", "conformance",
                                "pde_inline_observed_state_dependent")
const _OSD_MANIFEST  = joinpath(_OSD_CAT_DIR, "manifest.json")

@testset "Conformance: pde_inline_observed_state_dependent (manifest-driven)" begin
    @test isfile(_OSD_MANIFEST)
    manifest = JSON3.read(read(_OSD_MANIFEST, String))
    @test manifest.category == "pde_inline_observed_state_dependent"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_OSD_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_OSD_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Index by assertion_idx and gate each against BOTH the golden
            # actual (cross-binding anchor) and the fixture's own declared
            # `expected` (author intent), and require pass=true.
            by_idx = Dict(r.assertion_idx => r for r in results)
            for g in golden.assertions
                gi = Int(g.assertion_idx)
                @test haskey(by_idx, gi)
                r = by_idx[gi]
                @test r.variable == String(g.variable)
                @test r.passed
                @test r.actual !== nothing
                @test isapprox(r.actual, Float64(g.actual); rtol=rtol, atol=atol)
            end
            for decl in fixture.assertions
                r = by_idx[Int(decl.assertion_idx)]
                @test r.variable == String(decl.variable)
                @test r.expected == Float64(decl.expected)
            end
        end
    end
end
