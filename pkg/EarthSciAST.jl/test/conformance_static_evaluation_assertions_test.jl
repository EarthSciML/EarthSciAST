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

# esm-spec §6.6.3 constrains an assertion's `time` to `[time_span.start,
# time_span.end]`.
#
# The integrating path enforces that incidentally — the solver saves nothing
# past the span's end — and Python's runner, which samples a dense grid over the
# span, refuses the same assertion on a STATIC document. The static evaluation
# added for issue #406 has no boundary of its own: before the grid was
# restricted to the span, `y = a*t` on a span of `[0, 1]` answered `t = 100`
# with `200.0` and reported a PASS, and `t = -5` with `-10.0`. Both now report
# `no saved state at t=… (nearest …)`, the same refusal the integrating path
# gives and the same one Rust and Python give.
@testset "A static assertion outside the declared span is refused (#406)" begin
    doc = """
    {
      "esm": "1.1.0",
      "metadata": {"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"},
      "models": {"TimeProbe": {
        "variables": {
          "a": {"type": "parameter", "units": "1/s", "default": 2.0},
          "y": {"type": "unknown", "units": "1"}
        },
        "equations": [{"lhs": "y", "rhs": {"op": "*", "args": ["a", "t"]}}],
        "tests": [
          {"id": "past_end", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": 100.0, "expected": 200.0}]},
          {"id": "before_start", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": -5.0, "expected": -10.0}]},
          {"id": "at_the_end", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": 1.0, "expected": 2.0,
                           "tolerance": {"abs": 1e-12}}]}
        ]
      }}
    }
    """
    results = run_inline_tests(EarthSciAST.load_string(doc);
                               alg=OrdinaryDiffEqTsit5.Tsit5())
    by_test = Dict(r.test_id => r for r in results)
    @test length(by_test) == 3
    for id in ("past_end", "before_start")
        r = by_test[id]
        @test !r.passed
        @test occursin("no saved state", r.message)
    end
    # The span's own endpoint is inside it and still answers.
    @test by_test["at_the_end"].passed
    @test isapprox(by_test["at_the_end"].actual, 2.0; atol=1e-12)
end

# The evaluation grid itself, stated directly: the span's endpoints are always
# present (so the refusal above can name one, and so a test whose asserted times
# are all out of span still evaluates), the in-span asserted times are kept, and
# the out-of-span ones are dropped.
@testset "_static_evaluation_times restricts the grid to the span (#406)" begin
    @test EarthSciAST._static_evaluation_times([0.0, 4.0, 8.0], 0.0, 8.0) ==
          [0.0, 4.0, 8.0]
    @test EarthSciAST._static_evaluation_times([100.0, -5.0, 0.5], 0.0, 1.0) ==
          [0.0, 0.5, 1.0]
    @test EarthSciAST._static_evaluation_times(Float64[], 0.0, 1.0) == [0.0, 1.0]
    # A span written backwards still yields an ordered grid.
    @test EarthSciAST._static_evaluation_times([0.5], 1.0, 0.0) == [0.0, 0.5, 1.0]
end

# esm-spec §6.6.5 names what an analytic `reference` may read — the asserted
# field's dimension names, FREE, and the model's parameters — and `t` is
# neither. The build-time cellwise evaluator has a time slot holding 0.0, so a
# reference of `t` did not fail there: it answered with the expression at the
# start of the span and reported a plausible wrong number, in Julia, Python and
# Rust alike. Before the refusal this document reported `actual = 2.0` against
# `expected = 0.0` (the field is `t`, so a reference read at 0 is off by the
# whole asserted time); it now names the mistake.
@testset "A §6.6.5 `reference` that mentions `t` is refused (#406)" begin
    doc = """
    {
      "esm": "1.1.0",
      "metadata": {"name": "RefT", "description": "a reference that mentions t", "license": "MIT"},
      "index_sets": {"x": {"kind": "interval", "size": 2}},
      "models": {"RefT": {
        "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x"]}},
        "equations": [
          {"lhs": {"op": "ic", "args": ["u"]},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}}, "expr": 0.0}},
          {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 2]},
                   "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"}},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 2]}, "expr": 1.0}}
        ],
        "tests": [{"id": "reference_mentions_t", "time_span": {"start": 0.0, "end": 2.0},
          "assertions": [{"variable": "u", "time": 2.0, "reduce": "Linf_error",
                          "reference": {"op": "*", "args": [1.0, "t"]}, "expected": 0.0,
                          "tolerance": {"abs": 1e-9}}]}]
      }}
    }
    """
    results = run_inline_tests(EarthSciAST.load_string(doc);
                               alg=OrdinaryDiffEqTsit5.Tsit5())
    @test length(results) == 1
    r = results[1]
    @test !r.passed
    @test r.actual === nothing
    # The sentence is BYTE-IDENTICAL in Rust and Python; the three bindings must
    # reject the same document the same way.
    @test occursin(EarthSciAST._REFERENCE_MENTIONS_TIME, r.message)
    @test EarthSciAST._REFERENCE_MENTIONS_TIME == "inline `reference` mentions `t`, which esm-spec §6.6.5 does not admit: a reference's free variables are the field's dimension names, and its other names are the model's parameters. A reference is evaluated at build time, where the independent variable has no value, so `t` would silently read 0 rather than the asserted time."
end

# The rule itself, at the one function that carries it: FREE mention of `t` is
# refused, a `t` that IS a dimension name of the asserted field is admitted and
# binds to the cell index like any other, and a reference that never mentions it
# is untouched.
@testset "bind_dimension_names refuses a free `t` (#406)" begin
    tref = EarthSciAST.VarExpr("t")
    @test_throws EarthSciAST.InlineTestError EarthSciAST.bind_dimension_names(tref, ["x"])
    # Refused on an UNSHAPED target too — the check runs before the `dims` exit.
    @test_throws EarthSciAST.InlineTestError EarthSciAST.bind_dimension_names(tref, String[])
    # A field shaped over an index set NAMED `t`: §6.6.5 admits it as a
    # dimension name, so it wraps rather than refusing.
    @test EarthSciAST.bind_dimension_names(tref, ["t"]) !== tref
    # A binder's own loop symbol is not a free mention.
    bound = EarthSciAST.OpExpr("faq", EarthSciAST.ASTExpr[];
                               output_idx=Any["t"],
                               ranges=Dict{String,Any}("t" => EarthSciAST.IndexSetRef("x")),
                               expr_body=EarthSciAST.VarExpr("t"))
    @test EarthSciAST.bind_dimension_names(bound, ["x"]) === bound
end
