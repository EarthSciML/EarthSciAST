# Cross-language conformance: build-time value invention over a derived index set
# (tests/conformance/value_invention_materialize/, issue #266). The Python and
# Rust runners gate the same manifest. A `value` case pins the member count a
# contraction over the derived axis reads; a `refused` case pins the code a
# producer that cannot run is refused under, with no actual (in particular not
# the 0 an empty range would contract to).

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _VIM_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "value_invention_materialize")

@testset "value_invention_materialize conformance" begin
    manifest = JSON3.read(read(joinpath(_VIM_DIR, "manifest.json"), String))
    @test manifest.category == "value_invention_materialize"
    @test "julia" in manifest.bindings_required
    @test Set(String(c.outcome) for fx in manifest.fixtures for c in fx.cases) ==
          Set(["value", "refused"])

    for fx in manifest.fixtures
        @testset "$(fx.id)" begin
            results = run_inline_tests(joinpath(_VIM_DIR, String(fx.path));
                                       model_name=String(fx.model))
            @test length(results) == length(fx.cases)
            for case in fx.cases
                idx = findfirst(r -> r.test_id == String(fx.test_id) &&
                                     r.assertion_idx == case.assertion_idx, results)
                @test idx !== nothing
                idx === nothing && continue
                r = results[idx]
                @test r.variable == String(case.variable)
                if case.outcome == "value"
                    @test r.passed
                    @test r.actual !== nothing && isapprox(r.actual, case.expected; rtol=1e-12)
                else
                    @test !r.passed
                    @test r.actual === nothing
                    @test occursin(String(case.code), r.message)
                    haskey(case, :names) && @test occursin(String(case.names), r.message)
                end
            end
        end
    end
end
