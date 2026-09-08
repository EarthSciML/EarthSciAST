# Conformance harness adapter — `operator_compose` merge intent (Julia).
#
# Driven by the shared manifest at
# tests/conformance/operator_compose_merge/manifest.json
# (esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).
#
# Three things are pinned, and they are distinct:
#
#   1. An entry that merges NOTHING is `operator_compose_no_merge`, a hard
#      refusal: such an entry is indistinguishable from one that is not there. A
#      PARTIAL merge stays a warning, because an operator may legitimately
#      contribute states of its own alongside the ones it does merge.
#   2. `require_match` is TRI-STATE and absent is not `false` — absent means "the
#      author has not said" (zero-merge refuses), `true` makes ANY shortfall
#      fatal, `false` DECLARES a standalone-contributing operator and silences
#      both. Each state has a non-vacuity anchor, so a binding cannot pass by
#      being uniformly strict or uniformly lax.
#   3. A bare-name match that would unify two STATES is
#      `operator_compose_ambiguous_bare_name`, a refusal: each carries its own
#      initial condition and the merge keeps one, which is exactly the silent
#      choice that made the `systems` order matter. Where only one side is a
#      state the match is unambiguous and the state owns the quantity.
#
# Unlike the flatten corpus this category carries no golden: it compares
# DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic surface. Here
# that is `@warn` (captured with `Test.collect_test_logs`) and the three error
# types.

# `using Test` MUST precede the testutils include: testutils.jl uses `@test_skip`
# at top level, so `Test` has to be in scope in `Main` already. Including it
# first only works when some earlier file in runtests.jl happened to import Test
# — running this file standalone then fails with `UndefVarError: @test_skip`.
using Test
using EarthSciAST
using JSON3
using Logging

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _OCM_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                          "operator_compose_merge")

# A missing manifest is a hard failure, not a skip: the manifest IS the contract
# this file exists to enforce.
@assert isfile(joinpath(_OCM_DIR, "manifest.json")) "manifest not found in $(_OCM_DIR)"
const _OCM_MANIFEST = JSON3.read(read(joinpath(_OCM_DIR, "manifest.json"), String))

# The refusal each code maps to in THIS binding. The manifest's
# `diagnostic_surface.errors` records the same mapping for every binding; this is
# the Julia column, asserted rather than assumed.
const _OCM_ERRORS = Dict(
    "operator_compose_no_merge" => OperatorComposeNoMergeError,
    "operator_compose_require_match_unmatched" => OperatorComposeRequireMatchError,
    "operator_compose_ambiguous_bare_name" => OperatorComposeAmbiguousBareNameError,
)

"""
Flatten the fixture at `relpath`, returning `(system, diagnostics)` where
`diagnostics` holds only this category's `@warn` messages.
"""
function _ocm_flatten(relpath)
    path = joinpath(_OCM_DIR, relpath)
    logs, system = Test.collect_test_logs(min_level=Logging.Warn) do
        flatten(load_path(path))
    end
    msgs = [string(r.message) for r in logs if startswith(string(r.message), "operator_compose_")]
    return system, msgs
end

"""
The observable outcome of a fixture: either the refusal's type name, or the
surviving states paired with their defaults. Used to compare two runs that must
agree, rather than comparing each against a recorded value.
"""
function _ocm_outcome(case)
    try
        system, _ = _ocm_flatten(case.path)
        return [(k, v.default) for (k, v) in system.state_variables]
    catch e
        return string(typeof(e))
    end
end

@testset "conformance: operator_compose merge intent" begin
    @testset "the manifest is not empty and covers this binding" begin
        # A manifest that silently listed zero cases would make every assertion
        # below vacuously green.
        @test !isempty(_OCM_MANIFEST.cases)
        @test "julia" in _OCM_MANIFEST.bindings_required
        @test _OCM_MANIFEST.codes[Symbol("operator_compose_partial_merge")] == "warning"
        for code in keys(_OCM_ERRORS)
            @test _OCM_MANIFEST.codes[Symbol(code)] == "error"
            # The manifest names an error type per binding per code; reading
            # Julia's column back keeps the record from drifting silently.
            @test String(_OCM_MANIFEST.diagnostic_surface.errors[Symbol(code)].julia) ==
                  string(nameof(_OCM_ERRORS[code]))
        end
    end

    for case in _OCM_MANIFEST.cases
        @testset "$(case.id): $(case.outcome)" begin
            if case.outcome == "refused"
                expected = _OCM_ERRORS[String(case.code)]
                err = try
                    _ocm_flatten(case.path)
                    nothing
                catch e
                    e
                end
                @test err isa expected
                if err isa expected
                    @test startswith(err.details, String(case.code))
                    named = String[]
                    haskey(case, :unmatched) && append!(named, String.(case.unmatched))
                    haskey(case, :unified) && append!(named, String.(case.unified))
                    for name in named
                        @test occursin(name, err.details)
                    end
                end
                continue
            end

            system, found = _ocm_flatten(case.path)

            if case.outcome == "clean"
                @test isempty(found)
            else
                @test length(found) == 1
                if length(found) == 1
                    @test startswith(found[1], String(case.code))
                    # The tally and the unmatched names are the content that
                    # makes the diagnostic actionable; a code with no names is a
                    # shrug.
                    @test occursin("merged $(case.merged) of $(case.authored) equations", found[1])
                    for name in case.unmatched
                        @test occursin(String(name), found[1])
                    end
                end
            end

            if haskey(case, :state_variables)
                @test collect(keys(system.state_variables)) == String.(case.state_variables)
            end
            if haskey(case, :surviving_state)
                @test system.state_variables[String(case.surviving_state)].default ==
                      case.surviving_default
            end
        end
    end

    @testset "flipping the `systems` order changes nothing observable" begin
        # Issue #195 Symptom 1, in the form that fails under the old rule. Two
        # pairs of fixtures, each differing ONLY in the `systems` array's order.
        # The AMBIGUOUS pair used to produce different state names carrying
        # different initial conditions — an argument order choosing an IC.
        # Compared BETWEEN the two runs rather than against the manifest, so this
        # fails on disagreement even if both were re-recorded.
        by_id = Dict(String(c.id) => c for c in _OCM_MANIFEST.cases)
        for (left, right) in (
            ("ambiguous_bare_name", "ambiguous_bare_name_flipped"),
            ("owner_rename_state_wins_observed_first", "owner_rename_state_wins_state_first"),
        )
            a, b = by_id[left], by_id[right]
            @test String.(a.systems) == reverse(String.(b.systems))
            @test _ocm_outcome(a) == _ocm_outcome(b)
        end
    end

    @testset "the ambiguity refusal is not a blanket ban on bare names" begin
        # The two ways out both still work: `translate` names the surviving
        # spelling outright, and a match where only ONE side is a STATE is not
        # ambiguous at all. Without this a binding could pass every refusal by
        # refusing the whole bare-name fallback.
        by_id = Dict(String(c.id) => c for c in _OCM_MANIFEST.cases)
        resolved, _ = _ocm_flatten(by_id["ambiguous_resolved_by_translate"].path)
        @test collect(keys(resolved.state_variables)) == ["Chem.O3"]
        @test resolved.state_variables["Chem.O3"].default == 30.0

        owned, _ = _ocm_flatten(by_id["owner_rename_state_wins_observed_first"].path)
        @test collect(keys(owned.state_variables)) == ["Sink.O3"]
        @test owned.state_variables["Sink.O3"].default == 40.0
    end

    @testset "`require_match` round-trips, an explicit `false` included" begin
        # The flag is TRI-STATE, so an explicit `false` must survive the round
        # trip — dropping it as "the default" would silently re-arm the
        # zero-merge refusal on every document that opted out. An ABSENT flag
        # must stay absent for the same reason, in the other direction.
        emitted(name) = JSON3.read(to_json(load_path(joinpath(_OCM_DIR, "fixtures", name))))
        @test emitted("require_match_unmatched.esm").coupling[1].require_match === true
        @test emitted("no_merge_declared.esm").coupling[1].require_match === false
        @test !haskey(emitted("partial_merge.esm").coupling[1], :require_match)
    end
end
