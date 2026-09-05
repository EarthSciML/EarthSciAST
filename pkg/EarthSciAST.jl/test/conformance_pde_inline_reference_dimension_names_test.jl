# Conformance harness adapter — pde_inline_reference_dimension_names category.
#
# esm-spec §6.6.5 says an inline `reference` is "an Expression whose free
# variables are the domain dimension names". For a field shaped over index sets
# those are the asserted variable's `shape` entries, each bound per cell to the
# 1-based position along its axis (the index space `coords` reads). Every
# binding used to evaluate the reference as ONE build-time array expression and
# sample it per cell, leaving a free dimension name unbound
# (`E_TREEWALK_UNBOUND_VARIABLE: x` here), so authors spelled every reference
# as an explicit `aggregate(i from x; …)` gather. `bind_dimension_names` now
# wraps a reference that mentions a dimension name free in an aggregate whose
# output indices ARE the dimension names, and leaves every other reference —
# including a gather that rebinds the dimension name as its own loop symbol —
# untouched. Julia is the reference binding: this run must reproduce the
# committed golden actuals (which this same pathway minted). See
# tests/conformance/pde_inline_reference_dimension_names/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RDN_REPO_ROOT = TESTUTILS_REPO_ROOT
const _RDN_CAT_DIR   = joinpath(_RDN_REPO_ROOT, "tests", "conformance",
                                "pde_inline_reference_dimension_names")
const _RDN_MANIFEST  = joinpath(_RDN_CAT_DIR, "manifest.json")

@testset "Conformance: pde_inline_reference_dimension_names (manifest-driven)" begin
    @test isfile(_RDN_MANIFEST)
    manifest = JSON3.read(read(_RDN_MANIFEST, String))
    @test manifest.category == "pde_inline_reference_dimension_names"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_RDN_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_RDN_CAT_DIR, String(fixture.golden))
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
