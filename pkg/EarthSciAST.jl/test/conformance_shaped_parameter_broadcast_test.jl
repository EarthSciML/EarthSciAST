# Conformance harness adapter — shaped_parameter_broadcast category.
#
# esm-spec §6.3 "Inline array data" / §6.6.2 "Shaped values": a SCALAR on a
# shaped variable keeps its broadcast meaning — the one value applies to every
# element — and the same union applies to a shaped variable's declared
# `default`. The shaped UNKNOWN half was already pinned by `_build_u0` seeding
# every cell from one scalar; the shaped PARAMETER half was not, and Julia
# REFUSED such a document outright: `_partition_variables` requires an
# array-shaped parameter to be backed by `const_arrays` or `param_arrays`, and a
# scalar `default` reached neither, so a spec-valid column component failed with
# `E_TREEWALK_UNSUPPORTED_SHAPE` (EarthSciML/EarthSciAST#219 — Rust and Python
# got the same rule wrong in their own vocabularies). The reference binding
# (Julia) runs the OFFICIAL `run_pde_tests` pathway over the committed fixture
# and must reproduce the committed golden (which that same pathway minted).
#
# See tests/conformance/shaped_parameter_broadcast/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SPB_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "shaped_parameter_broadcast")
const _SPB_MANIFEST = joinpath(_SPB_CAT_DIR, "manifest.json")

@testset "Conformance: shaped_parameter_broadcast (manifest-driven)" begin
    @test isfile(_SPB_MANIFEST)
    manifest = JSON3.read(read(_SPB_MANIFEST, String))
    @test manifest.category == "shaped_parameter_broadcast"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_SPB_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_SPB_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Index by (test_id, assertion_idx) and gate each against BOTH the
            # golden actual (the cross-binding anchor) and the fixture's own
            # declared `expected` (author intent, via `r.passed`).
            by_key = Dict((r.test_id, r.assertion_idx) => r for r in results)
            for g in golden.assertions
                key = (String(g.test_id), Int(g.assertion_idx))
                @test haskey(by_key, key)
                r = by_key[key]
                @test r.passed
                @test r.actual !== nothing
                @test isapprox(r.actual, Float64(g.actual); rtol=rtol, atol=atol)
            end
        end
    end
end
