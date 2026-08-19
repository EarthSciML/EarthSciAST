# Conformance harness adapter — pushdown category (Phase 3, clean
# consolidation). Contract (tests/conformance/pushdown/README.md): run
# desugar_pushdown on each manifest input and deep-compare the result to the
# committed golden as parsed JSON; assert idempotency on the golden and input
# purity. The goldens were EMITTED by this binding
# (scripts/generate-pushdown-goldens.jl), so this adapter guards against the
# rewrite drifting from its own recorded output.

module ConformancePushdownTests

using Test
using JSON
using EarthSciAST
const EA = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _TESTS_DIR     = joinpath(TESTUTILS_REPO_ROOT, "tests")
const _MANIFEST_PATH = joinpath(_TESTS_DIR, "conformance", "pushdown", "manifest.json")

# Order-insensitive (keys), numeric-by-value deep equality on parsed JSON.
_deep_eq(a::AbstractDict, b::AbstractDict) =
    Set(String.(keys(a))) == Set(String.(keys(b))) &&
    all(_deep_eq(a[k], b[String(k)]) for k in keys(a))
_deep_eq(a::AbstractVector, b::AbstractVector) =
    length(a) == length(b) && all(_deep_eq(x, y) for (x, y) in zip(a, b))
_deep_eq(a::Real, b::Real) = (a isa Bool) == (b isa Bool) && isequal(Float64(a), Float64(b))
_deep_eq(a, b) = isequal(a, b)

@testset "Conformance: pushdown rewrite (manifest-driven)" begin
    @test isfile(_MANIFEST_PATH)
    manifest = JSON.parsefile(_MANIFEST_PATH)
    @test manifest["category"] == "pushdown"
    @test !isempty(manifest["fixtures"])

    for fixture in manifest["fixtures"]
        id = String(fixture["id"])
        input_path = joinpath(_TESTS_DIR, String(fixture["input"]))
        # A fixture either carries a rewrite `golden` (the pattern fires) or
        # declares `fires: false` and pins the residual `diagnostics` instead.
        fires = get(fixture, "fires", true) !== false
        golden_path = fires ? joinpath(_TESTS_DIR, String(fixture["golden"])) : ""
        dg = get(fixture, "diagnostics", nothing)
        diag_path = dg === nothing ? nothing : joinpath(_TESTS_DIR, String(dg))
        mn = get(fixture, "model_name", nothing)

        @testset "$(id)" begin
            @test isfile(input_path)
            input = JSON.parsefile(input_path)
            pristine = JSON.parsefile(input_path)

            rewritten = mn === nothing ? EA.desugar_pushdown(input) :
                        EA.desugar_pushdown(input; model_name=String(mn))
            if fires
                @test isfile(golden_path)
                golden = JSON.parsefile(golden_path)
                @test rewritten !== input                 # the pattern fired
                @test _deep_eq(rewritten, golden)         # matches the golden
                @test EA.desugar_pushdown(rewritten) === rewritten   # idempotent
            else
                # A `fires: false` fixture is NOT rewritten — and says why.
                @test rewritten === input
            end
            if diag_path !== nothing
                @test isfile(diag_path)
                diags = mn === nothing ? EA.pushdown_diagnostics(input) :
                        EA.pushdown_diagnostics(input; model_name=String(mn))
                @test _deep_eq(diags, JSON.parsefile(diag_path))
            end
            @test _deep_eq(input, pristine)           # input not mutated
        end
    end
end

end # module ConformancePushdownTests
