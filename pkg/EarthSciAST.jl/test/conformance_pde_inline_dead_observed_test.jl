# Conformance harness adapter — pde_inline_dead_observed category.
#
# §6.6.5 inline-test assertions on an array OBSERVED that NO LIVE EQUATION
# CONSUMES. The reference binding (Julia) runs the OFFICIAL `run_pde_tests`
# pathway over the committed fixture and must reproduce the committed golden
# actuals (which that same pathway minted). The manifest declares
# julia/python/rust as bindings_required: Rust (`esm test`) and Python
# (`run_pde_tests`) already answered this document, so the golden is the shared
# cross-binding anchor.
#
# This is the conformance GATE for #176: before the fix, the elementwise
# array-observed fold inlined `diag` / `chain` into their readers and — having
# none — dropped them, so `BuildInspection.observed_exprs` carried neither and
# every assertion here failed with "array state '<name>' has no cells in
# var_map". See tests/conformance/pde_inline_dead_observed/ and the unit
# coverage in pde_inline_dead_observed_test.jl.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _DEADOBS_REPO_ROOT = TESTUTILS_REPO_ROOT
const _DEADOBS_CAT_DIR = joinpath(_DEADOBS_REPO_ROOT, "tests", "conformance",
                                  "pde_inline_dead_observed")
const _DEADOBS_MANIFEST = joinpath(_DEADOBS_CAT_DIR, "manifest.json")

@testset "Conformance: pde_inline_dead_observed (manifest-driven)" begin
    @test isfile(_DEADOBS_MANIFEST)
    manifest = JSON3.read(read(_DEADOBS_MANIFEST, String))
    @test manifest.category == "pde_inline_dead_observed"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path = joinpath(_DEADOBS_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_DEADOBS_CAT_DIR, String(fixture.golden))
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
            for a in fixture.assertions
                r = by_idx[Int(a.assertion_idx)]
                @test String(r.variable) == String(a.variable)
                @test isapprox(r.actual, Float64(a.expected); rtol=rtol, atol=atol)
            end
        end
    end
end
