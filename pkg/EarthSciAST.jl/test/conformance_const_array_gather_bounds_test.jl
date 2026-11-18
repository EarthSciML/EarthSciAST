# Conformance harness adapter — const_array_gather_bounds category.
#
# esm-spec §4.3.3 / CONFORMANCE_SPEC §5.5.5: an `index` whose base is a const
# array — a `const` literal written inline, or an observed defined by one — and
# that declares no boundary policy must fail with E_TREEWALK_CONSTARRAY_OOB when
# any index lies outside its own axis. Each fixture is one document with one
# assertion; the manifest says whether it must PASS (an in-range control) or end
# in an ERROR carrying the code.
# See tests/conformance/const_array_gather_bounds/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # conformance_manifest

@testset "Conformance: const_array_gather_bounds (manifest-driven)" begin
    dir, manifest = conformance_manifest("const_array_gather_bounds"; bindings = ("julia",))
    @test String(manifest.reference_binding) == "julia"
    @test any(f -> f.outcome == "error", manifest.fixtures)
    @test any(f -> f.outcome == "pass", manifest.fixtures)

    for fixture in manifest.fixtures
        @testset "$(fixture.id)" begin
            results = run_inline_tests(
                joinpath(dir, String(fixture.path));
                model_name = String(fixture.model),
                alg = OrdinaryDiffEqTsit5.Tsit5(),
                reltol = 1.0e-12, abstol = 1.0e-14
            )
            @test length(results) == 1
            r = only(results)
            if fixture.outcome == "pass"
                @test r.status == EarthSciAST.PASS
                @test r.actual == Float64(fixture.expected)
            else
                @test r.status == EarthSciAST.ERROR
                @test occursin(String(fixture.error_code), r.message)
            end
        end
    end
end
