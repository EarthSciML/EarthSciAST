# Conformance harness adapter — static_evaluation_assertions category.
#
# esm-spec §6.6.3: an assertion's `time` is "Simulation time at which to
# EVALUATE the assertion" — evaluate, not integrate to. A document with no
# differential equations is evaluated once rather than integrated, but "once"
# fixes the number of solves, not the time: an algebraic document is still a
# function of `t`, and every assertion must be answered at its own. The same
# rule governs a `t`-dependent OBSERVED on a document that does integrate.
#
# This is the conformance GATE for issue #406. Julia failed both halves. The
# algebraic fixture's zero-length state vector reached OrdinaryDiffEq, whose
# dense interpolant threw `BoundsError: attempt to access 0-element
# Vector{Float64} at index [1]` at every saved time past the span's start. And
# the build-time cellwise evaluator bound the evaluator's TIME slot to the
# literal 0.0 at every call site, so a `t`-dependent observed read zero on BOTH
# fixtures and reported a plausible wrong number rather than an error — the
# quiet half, and the one a corpus of `time: 0` assertions never catches.
#
# See tests/conformance/static_evaluation_assertions/.

using Test
using JSON3
using EarthSciAST
import SciMLBase
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SEA_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "static_evaluation_assertions")
const _SEA_MANIFEST = joinpath(_SEA_CAT_DIR, "manifest.json")

@testset "Conformance: static_evaluation_assertions (manifest-driven)" begin
    @test isfile(_SEA_MANIFEST)
    manifest = JSON3.read(read(_SEA_MANIFEST, String))
    @test manifest.category == "static_evaluation_assertions"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)
    reltol = Float64(manifest.integrators.julia.reltol)
    abstol = Float64(manifest.integrators.julia.abstol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_SEA_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_SEA_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_inline_tests(esm_path; model_name=String(fixture.model),
                                       alg=OrdinaryDiffEqTsit5.Tsit5(),
                                       reltol=reltol, abstol=abstol)
            @test length(results) == length(golden.assertions)

            # Gate each assertion against BOTH the golden actual (the
            # cross-binding anchor) and the fixture's own declared `expected`
            # (author intent, via `r.passed`).
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

# The regression itself, stated without the golden machinery: the same
# algebraic-only document asserted at the span's start and away from it.
#
# Before the fix the first of these passed — a saved time equal to the span's
# start needs no interpolant — and every later one threw the `BoundsError`
# above. That asymmetry is why the defect survived a corpus whose static
# documents almost all assert at `time: 0`.
@testset "An algebraic document is evaluated at every asserted time (#406)" begin
    probe(time, expected) = """
    {
      "esm": "1.1.0",
      "metadata": {"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"},
      "models": {"TimeProbe": {
        "variables": {
          "a": {"type": "parameter", "units": "1/s", "default": 2.0},
          "y": {"type": "unknown", "units": "1"}
        },
        "equations": [{"lhs": "y", "rhs": {"op": "*", "args": ["a", "t"]}}],
        "tests": [{"id": "t_dep", "time_span": {"start": 0, "end": 10},
          "assertions": [{"variable": "y", "time": $(time), "expected": $(expected),
                          "tolerance": {"abs": 1e-12}}]}]
      }}
    }
    """
    for (time, expected) in ((0.0, 0.0), (5.0, 10.0), (10.0, 20.0))
        file = EarthSciAST.load_string(probe(time, expected))
        results = run_inline_tests(file; alg=OrdinaryDiffEqTsit5.Tsit5())
        @test length(results) == 1
        r = results[1]
        @test r.passed
        @test r.actual !== nothing
        @test isapprox(r.actual, expected; atol=1e-12)
    end
end

# The other half, on a document that INTEGRATES: `evaluate_cellwise` binds the
# time it is given rather than a hard-coded 0.0, so a `t`-dependent observed
# reads the asserted time. `t` travels on its own argument and not through
# `params`, because the compiler maps the name `t` to the evaluator's time slot
# and never resolves it as a parameter read.
@testset "evaluate_cellwise binds the simulation time it is given (#406)" begin
    expr = EarthSciAST.OpExpr("*", EarthSciAST.ASTExpr[EarthSciAST.VarExpr("a"),
                                                       EarthSciAST.VarExpr("t")])
    params = Dict{String,Float64}("a" => 2.0)
    @test EarthSciAST.evaluate_cellwise(expr, [Int[]]; params=params) == [0.0]
    @test EarthSciAST.evaluate_cellwise(expr, [Int[]]; params=params, t=5.0) == [10.0]
    # A `params` entry spelled "t" is NOT the time: the slot is its own channel.
    @test EarthSciAST.evaluate_cellwise(expr, [Int[]];
                                        params=merge(params,
                                                     Dict("t" => 5.0))) == [0.0]
end
