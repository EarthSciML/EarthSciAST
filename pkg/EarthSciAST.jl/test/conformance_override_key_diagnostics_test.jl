# Conformance harness adapter — override_key_diagnostics category.
#
# esm-spec §6.6.2 "Unrecognized override keys": every `parameter_overrides` key
# must designate exactly ONE parameter of the flattened system, and one that
# designates none is an ERROR rather than a silently-ignored no-op. Three
# outcomes, kept distinct: a key that resolves (exactly, or by the LOCAL
# spelling §6.6 mandates) runs; a BARE key that is the local name of two or more
# parameters is AMBIGUOUS; anything else is UNKNOWN.
#
# Julia used to leave an unmatched key verbatim, so it bound nothing and the run
# quietly used every declared default while still reporting a verdict — the same
# silent-wrong-answer shape the §6.6.2 name resolution was introduced to fix,
# one level up. Rust already raised `SimulateError::InvalidParameter`; this
# category is what keeps the three from drifting apart again. It compares
# DIAGNOSTIC OUTCOMES rather than numbers, so it carries no golden: each binding
# asserts its own idiomatic error type (the manifest's `error_surface` records
# which) against the shared per-case classification.
#
# See tests/conformance/override_key_diagnostics/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _OKD_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "override_key_diagnostics")
const _OKD_MANIFEST = joinpath(_OKD_CAT_DIR, "manifest.json")

@testset "Conformance: override_key_diagnostics (manifest-driven)" begin
    @test isfile(_OKD_MANIFEST)
    manifest = JSON3.read(read(_OKD_MANIFEST, String))
    @test manifest.category == "override_key_diagnostics"
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    fixture  = manifest.fixtures[1]
    esm_path = joinpath(_OKD_CAT_DIR, String(fixture.path))
    @test isfile(esm_path)
    rtol = Float64(manifest.tolerances.trajectory_rtol)
    atol = Float64(manifest.tolerances.trajectory_atol)

    # All three outcomes must be exercised, or the category proves nothing
    # about ambiguous-vs-unknown being distinct.
    @test Set(String(c.outcome) for c in fixture.cases) ==
          Set(["resolved", "ambiguous", "unknown"])

    # The whole category rests on `gain` being carried by two components and
    # `solo` by one: pin the flattened parameter names so a change in
    # flattening cannot quietly defuse it.
    flat_params = sort!(String[String(n) for n in
                              keys(EarthSciAST.flatten(EarthSciAST.load_path(esm_path)).parameters)])
    @test flat_params == sort!(String[String(p) for p in fixture.parameters])

    run(params) = EarthSciAST.simulate(esm_path, (0.0, 1.0);
                                       alg=OrdinaryDiffEqTsit5.Tsit5(),
                                       saveat=[1.0], parameters=params)

    # Non-vacuity: the fixture integrates on its own, so every rejection below
    # is about the KEY and not about the document.
    base = run(Dict{String,Float64}())
    @test base.success
    for (name, want) in pairs(fixture.defaults_at_t1)
        @test isapprox(base[String(name)][1], Float64(want); rtol=rtol, atol=atol)
    end

    for case in fixture.cases
        key = String(case.key)
        val = Float64(case.value)
        outcome = String(case.outcome)
        @testset "$(key) => $(outcome)" begin
            if outcome == "resolved"
                sim = run(Dict(key => val))
                @test sim.success
                for (name, want) in pairs(case.trajectory_at_t1)
                    @test isapprox(sim[String(name)][1], Float64(want); rtol=rtol, atol=atol)
                end
            else
                err = try
                    run(Dict(key => val))
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                msg = err === nothing ? "" : sprint(showerror, err)
                # The diagnostic must name the offending key...
                @test occursin(key, msg)
                if outcome == "ambiguous"
                    # ...and, for the ambiguous case, every candidate — else it
                    # does not tell the author how to qualify the name.
                    @test occursin("ambiguous", lowercase(msg))
                    for cand in case.candidates
                        @test occursin(String(cand), msg)
                    end
                else
                    # UNKNOWN must not be reported as the ambiguous case.
                    @test !occursin("ambiguous", lowercase(msg))
                end
            end
        end
    end
end
