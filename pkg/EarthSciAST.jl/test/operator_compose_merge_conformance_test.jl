# Conformance harness adapter — `operator_compose` merge intent (Julia).
#
# Driven by the shared manifest at
# tests/conformance/operator_compose_merge/manifest.json
# (esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).
#
# Three things are pinned, and they are distinct:
#
#   1. The merge TALLY is reported — `operator_compose_no_merge` when nothing
#      landed, `operator_compose_partial_merge` when only some did, both naming
#      the unmatched dependent variables. Step 5 still preserves the equations;
#      it is no longer SILENT about doing so, because silence made "merged
#      everything" and "merged nothing" the same observable outcome.
#   2. `require_match: true` promotes either to a hard refusal, and a PARTIAL
#      match refuses exactly as a zero match does. `require_match_satisfied` is
#      the non-vacuity anchor that keeps the flag from being simply always-fatal.
#   3. The BARE-NAME fallback's surviving spelling follows the state's OWNER —
#      the component the document declares first — not `systems[1]`, so an entry
#      means the same thing in either argument order.
#
# Unlike the flatten corpus this category carries no golden: it compares
# DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic surface. Here
# that is `@warn` (captured with `Test.collect_test_logs`) and
# `OperatorComposeRequireMatchError`.

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

@testset "conformance: operator_compose merge intent" begin
    @testset "the manifest is not empty and covers this binding" begin
        # A manifest that silently listed zero cases would make every assertion
        # below vacuously green.
        @test !isempty(_OCM_MANIFEST.cases)
        @test "julia" in _OCM_MANIFEST.bindings_required
        @test sort(String.(collect(keys(_OCM_MANIFEST.codes)))) == [
            "operator_compose_no_merge",
            "operator_compose_partial_merge",
            "operator_compose_require_match_unmatched",
        ]
    end

    for case in _OCM_MANIFEST.cases
        @testset "$(case.id): $(case.outcome)" begin
            if case.outcome == "refused"
                err = try
                    _ocm_flatten(case.path)
                    nothing
                catch e
                    e
                end
                @test err isa OperatorComposeRequireMatchError
                if err isa OperatorComposeRequireMatchError
                    @test startswith(err.details, String(case.code))
                    for name in case.unmatched
                        @test occursin(String(name), err.details)
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
        # fixtures with identical models in identical declaration order,
        # differing ONLY in the `systems` array's order. The tendency is
        # arithmetically identical either way, so the surviving NAME and its
        # DEFAULT are the entire observable difference — compared between the two
        # RUNS rather than only against the manifest, so this fails on
        # disagreement even if both were re-recorded.
        by_id = Dict(String(c.id) => c for c in _OCM_MANIFEST.cases)
        a = by_id["owner_rename_operator_first"]
        b = by_id["owner_rename_mechanism_listed_first"]
        @test String.(a.models_declared) == String.(b.models_declared)
        @test String.(a.systems) == reverse(String.(b.systems))

        function surviving(case)
            system, _ = _ocm_flatten(case.path)
            names = collect(keys(system.state_variables))
            @test length(names) == 1
            return (names[1], system.state_variables[names[1]].default)
        end
        @test surviving(a) == surviving(b)
    end

    @testset "declaration order decides, not argument order" begin
        # The companion to the test above, and what keeps it from being trivial:
        # the same `systems` order with the models declared the other way round
        # must produce the OTHER name. A binding that hard-coded either answer,
        # or that kept renaming onto `systems[1]`, fails one of the two.
        by_id = Dict(String(c.id) => c for c in _OCM_MANIFEST.cases)
        a = by_id["owner_rename_operator_first"]
        b = by_id["owner_rename_mechanism_declared_first"]
        @test String.(a.systems) == String.(b.systems)
        @test String.(a.models_declared) == reverse(String.(b.models_declared))

        sa, _ = _ocm_flatten(a.path)
        sb, _ = _ocm_flatten(b.path)
        @test collect(keys(sa.state_variables)) == ["Sink.O3"]
        @test collect(keys(sb.state_variables)) == ["Chem.O3"]
    end

    @testset "`require_match` survives a round trip, and its default is not emitted" begin
        # A flag that silently vanished on save would make the refusal
        # unreproducible from the file the author kept; emitting the `false`
        # default would put a key on every existing fixture and break load
        # preservation.
        emitted(name) = JSON3.read(to_json(load_path(joinpath(_OCM_DIR, "fixtures", name))))
        @test emitted("require_match_unmatched.esm").coupling[1].require_match === true
        @test !haskey(emitted("no_merge.esm").coupling[1], :require_match)
    end
end
