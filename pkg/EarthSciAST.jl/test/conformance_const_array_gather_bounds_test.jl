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

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _CAGB_CAT_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "const_array_gather_bounds")

@testset "Conformance: const_array_gather_bounds (manifest-driven)" begin
    manifest = JSON3.read(read(joinpath(_CAGB_CAT_DIR, "manifest.json"), String))
    @test manifest.category == "const_array_gather_bounds"
    @test String(manifest.reference_binding) == "julia"
    @test "julia" in manifest.bindings_required
    @test any(f -> f.outcome == "error", manifest.fixtures)
    @test any(f -> f.outcome == "pass", manifest.fixtures)

    for fixture in manifest.fixtures
        @testset "$(fixture.id)" begin
            results = run_inline_tests(joinpath(_CAGB_CAT_DIR, String(fixture.path));
                                       model_name=String(fixture.model),
                                       alg=OrdinaryDiffEqTsit5.Tsit5(),
                                       reltol=1e-12, abstol=1e-14)
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
