# Conformance harness adapter — assertion_nonfinite category.
#
# esm-spec §6.6.3: an inline-test assertion passes only when `actual ==
# expected`, or both values are FINITE and within the resolved tolerance. A
# ±Inf or NaN actual therefore FAILS against every finite `expected`, whatever
# the tolerance — finiteness is judged BEFORE tolerance.
#
# Julia is the reference binding here because it is the one that was already
# right: `_check_assertion` delegates to `isapprox`, defined as
#   x == y || (isfinite(x) && isfinite(y) && |x-y| <= max(atol, rtol*max(|x|,|y|)))
# The Rust and Python re-implementations of "Julia isapprox semantics" dropped
# the finiteness clause, and with `actual = Inf` the remaining bound is
# vacuously satisfied (`|Inf - e| = Inf <= rtol*max(Inf, |e|) = Inf`), so an
# assertion passed whatever it expected: an overflow, an x/0 or a log(0) turned
# a document that computes nothing meaningful into a green test run. NaN failed
# correctly all along (every IEEE comparison with NaN is false), which is why
# the hole was specific to an infinity and why NaN is carried here as a control.
#
# The category pins VERDICTS, not actuals: ±Inf and NaN are not
# JSON-representable, so each case in the manifest declares the class of the
# actual (`+inf` / `-inf` / `nan` / `finite`) and the required pass/fail.
# See tests/conformance/assertion_nonfinite/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ANF_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "assertion_nonfinite")
const _ANF_MANIFEST = joinpath(_ANF_CAT_DIR, "manifest.json")

_anf_class(v) = isnan(v) ? "nan" : (v == Inf ? "+inf" : (v == -Inf ? "-inf" : "finite"))

@testset "Conformance: assertion_nonfinite (manifest-driven)" begin
    @test isfile(_ANF_MANIFEST)
    manifest = JSON3.read(read(_ANF_MANIFEST, String))
    @test manifest.category == "assertion_nonfinite"
    @test String(manifest.reference_binding) == "julia"
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required
    @test !isempty(manifest.fixtures)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path = joinpath(_ANF_CAT_DIR, String(fixture.path))
            @test isfile(esm_path)
            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(fixture.cases)
            by_key = Dict((r.test_id, r.assertion_idx) => r for r in results)
            for case in fixture.cases
                key = (String(fixture.test_id), Int(case.assertion_idx))
                @test haskey(by_key, key)
                r = by_key[key]
                @test r.variable == String(case.variable)
                @test r.actual !== nothing
                @test _anf_class(Float64(r.actual)) == String(case.actual_class)
                # The verdict IS the contract.
                @test r.passed == Bool(case.passed)
                if haskey(case, :actual)
                    @test isapprox(Float64(r.actual), Float64(case.actual); rtol=1e-9)
                end
            end
        end
    end
end

# The predicate itself, at the boundary the fixture cannot spell: JSON has no
# infinite literal, so `expected = ±Inf` is only reachable through the API.
@testset "assertion predicate: finiteness before tolerance (§6.6.3)" begin
    for (rtol, atol) in ((1e-9, 0.0), (0.0, 1e300), (1e-9, 1e300), (0.0, 0.0))
        @test !EarthSciAST._check_assertion(Inf, 42.0, rtol, atol)
        @test !EarthSciAST._check_assertion(Inf, 0.0, rtol, atol)
        @test !EarthSciAST._check_assertion(-Inf, -42.0, rtol, atol)
        @test !EarthSciAST._check_assertion(NaN, 0.0, rtol, atol)
        @test !EarthSciAST._check_assertion(NaN, NaN, rtol, atol)
        @test !EarthSciAST._check_assertion(1e300, Inf, rtol, atol)
        # The one legitimate non-finite match, and only with the same sign.
        @test EarthSciAST._check_assertion(Inf, Inf, rtol, atol)
        @test EarthSciAST._check_assertion(-Inf, -Inf, rtol, atol)
        @test !EarthSciAST._check_assertion(Inf, -Inf, rtol, atol)
        @test !EarthSciAST._check_assertion(-Inf, Inf, rtol, atol)
    end
    # Unchanged for finite values, signed zero included.
    @test EarthSciAST._check_assertion(1.0, 1.0 + 1e-12, 1e-9, 0.0)
    @test !EarthSciAST._check_assertion(1.0, 1.1, 1e-9, 0.0)
    @test EarthSciAST._check_assertion(-0.0, 0.0, 0.0, 0.0)
    @test EarthSciAST._check_assertion(2.0, 2.0, 0.0, 0.0)
    @test !EarthSciAST._check_assertion(2.0, 2.0000001, 0.0, 0.0)
end
