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
import SciMLBase
import SciMLBase: solve, remake
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

    run(params) = solve(EarthSciAST.esm_problem(esm_path, (0.0, 1.0); p=params), OrdinaryDiffEqTsit5.Tsit5();
                                       saveat=[1.0])

    # Non-vacuity: the fixture integrates on its own, so every rejection below
    # is about the KEY and not about the document.
    base = run(Dict{String,Float64}())
    @test SciMLBase.successful_retcode(base)
    for (name, want) in pairs(fixture.defaults_at_t1)
        @test isapprox(base[Symbol(String(name))][1], Float64(want); rtol=rtol, atol=atol)
    end

    for case in fixture.cases
        key = String(case.key)
        val = Float64(case.value)
        outcome = String(case.outcome)
        @testset "$(key) => $(outcome)" begin
            if outcome == "resolved"
                sim = run(Dict(key => val))
                @test SciMLBase.successful_retcode(sim)
                for (name, want) in pairs(case.trajectory_at_t1)
                    @test isapprox(sim[Symbol(String(name))][1], Float64(want); rtol=rtol, atol=atol)
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

# Rule 2 was widened to the LONGEST dotted suffix (CONFORMANCE_SPEC §5.31), which
# has two consequences this testset pins.
#
# 1. The leading segments a dotted key drops must NAME SOMETHING — a component or
#    a subsystem the document declares. Without that check `Doc.Left.solo` binds
#    `Left.solo` where no `Doc` exists and a typo'd `Missng.M.pert_amp` quietly
#    drives `M.pert_amp`: an accepted override pointed at a name the author never
#    wrote.
# 2. It makes it possible for TWO distinct keys to designate ONE build name. That
#    is a document authoring error, not a race to settle by ranking the rules:
#    the caller wrote two overrides and only one can take effect, so the run is
#    rejected naming the resolved name and every colliding key. An EXACT hit is
#    never part of a collision — it identifies its name outright and wins.
#
# The collision message is worded identically in Python (`_collision_message`)
# and Rust (`SimulateError::CollidingParameterKeys`); it is asserted verbatim
# here so the three cannot drift.
@testset "override keys: rule 2 validates the leading segments" begin
    names = Set{String}(["Left.gain", "Left.solo", "Right.gain"])
    ns = EarthSciAST._override_namespaces(names)
    @test ns == Set{String}(["Left", "Right"])
    @test EarthSciAST._dotted_suffix_hit(names, ns, "Doc.Left.solo") === nothing
    @test EarthSciAST._dotted_suffix_hit(names, ns, "Left.Left.solo") == "Left.solo"
    _, unknown, _, _ = EarthSciAST._canonicalize_override_keys(
        Float64, names, ns, Dict("Doc.Left.solo" => 9.0))
    @test unknown == ["Doc.Left.solo"]
    # The §4.6 fully-qualified spelling of a name the build holds shorter, with
    # `P` the model's own name and `sub` its mounted subsystem.
    sub_names = Set{String}(["sub.g", "g"])
    sub_ns = EarthSciAST._override_namespaces(sub_names; model_name = "P")
    sub, u, a, c = EarthSciAST._canonicalize_override_keys(
        Float64, sub_names, sub_ns, Dict("P.sub.g" => 1.5))
    @test sub == Dict("sub.g" => 1.5)
    @test isempty(u) && isempty(a) && isempty(c)
    # ...and with `P` out of scope the same key names nothing.
    _, u_np, _, _ = EarthSciAST._canonicalize_override_keys(
        Float64, sub_names, EarthSciAST._override_namespaces(sub_names),
        Dict("P.sub.g" => 1.5))
    @test u_np == ["P.sub.g"]
    # A key none of whose suffixes is a name, and which is the suffix of no
    # name either, stays UNKNOWN under both rule 2 and the widened rule 3.
    _, u2, _, _ = EarthSciAST._canonicalize_override_keys(
        Float64, names, ns, Dict("Missing.solo" => 1.0))
    @test u2 == ["Missing.solo"]
end

# esm-spec §6.6.2 rule 3 is a DOTTED SUFFIX of exactly one name, not merely its
# trailing segment. Against a FLATTENED build carrying `P.sub.g` — which is what
# Julia and Python hand the resolver — all three authored spellings of a mounted
# subsystem's parameter must bind the one name, exactly as they do against a
# single-model build carrying it as `sub.g` (rules 1 and 2 there). `sub.g`
# reached NEITHER rule and was reported unknown, so the same document ran in
# Rust and raised here (issue #227).
@testset "override keys: rule 3 binds a dotted suffix of exactly one name" begin
    names = Set{String}(["P.sub.g", "P.x0"])
    ns = EarthSciAST._override_namespaces(names)
    for key in ("P.sub.g", "sub.g", "g")
        n, u, a, c = EarthSciAST._canonicalize_override_keys(
            Float64, names, ns, Dict(key => 1.5))
        @test n == Dict("P.sub.g" => 1.5)
        @test isempty(u) && isempty(a) && isempty(c)
    end
    # A key that is the suffix of NOTHING stays unknown: widening rule 3 must
    # not turn it into a trailing-segment match on `P.sub.g`.
    for key in ("Missing.solo", "Missing.g", "x.sub.g")
        _, u, _, _ = EarthSciAST._canonicalize_override_keys(
            Float64, names, ns, Dict(key => 1.5))
        @test u == [key]
    end
    # A suffix carried by TWO names is AMBIGUOUS, never tie-broken.
    two = Set{String}(["Left.sub.g", "Right.sub.g"])
    two_ns = EarthSciAST._override_namespaces(two)
    for key in ("sub.g", "g")
        _, u, a, _ = EarthSciAST._canonicalize_override_keys(
            Float64, two, two_ns, Dict(key => 1.5))
        @test isempty(u)
        @test sort(a[key]) == ["Left.sub.g", "Right.sub.g"]
    end
    # Two spellings of ONE name still collide rather than racing.
    _, _, _, c = EarthSciAST._canonicalize_override_keys(
        Float64, names, ns, Dict("sub.g" => 1.5, "g" => 2.5))
    @test c == Dict("P.sub.g" => ["g", "sub.g"])
end

@testset "override keys: two keys, one name, is ambiguous" begin
    names = Set{String}(["Left.solo"])
    ns = Set{String}(["A", "B", "Doc", "Left"])
    collide(pairs) = begin
        _, u, a, c = EarthSciAST._canonicalize_override_keys(Float64, names, ns, Dict(pairs))
        @test isempty(u)
        @test isempty(a)
        c
    end
    # Rule 3 (bare) + rule 2 (longer dotted) on one name.
    c1 = collide(["solo" => 2.0, "Doc.Left.solo" => 9.0])
    @test c1 == Dict("Left.solo" => ["Doc.Left.solo", "solo"])
    # Two rule-2 keys on one name, in either insertion order.
    @test collide(["A.Left.solo" => 1.0, "B.Left.solo" => 2.0]) ==
          Dict("Left.solo" => ["A.Left.solo", "B.Left.solo"])
    @test collide(["B.Left.solo" => 2.0, "A.Left.solo" => 1.0]) ==
          Dict("Left.solo" => ["A.Left.solo", "B.Left.solo"])
    # An EXACT hit wins outright over the competing suffix claims, which are
    # discarded rather than reported.
    n, u, a, c = EarthSciAST._canonicalize_override_keys(
        Float64, names, ns,
        Dict("Left.solo" => 1.0, "solo" => 2.0, "Doc.Left.solo" => 9.0))
    @test n == Dict("Left.solo" => 1.0)
    @test isempty(u) && isempty(a) && isempty(c)
    # The cross-binding message, verbatim.
    @test EarthSciAST._override_collision_message(
              "parameter_overrides", "parameter", "Left.solo",
              ["Doc.Left.solo", "solo"]) ==
          "parameter_overrides: 2 keys designate the parameter 'Left.solo' " *
          "(Doc.Left.solo, solo). Supply exactly one override key per name " *
          "(esm-spec §6.6.2)."
end

# End to end through the document front door: the collision is reported by
# `esm_problem`, not swallowed into a silent winner.
@testset "override keys: a collision reaches the front door" begin
    err = try
        EarthSciAST.esm_problem(joinpath(_OKD_CAT_DIR, "fixtures",
                                         "override_key_diagnostics.esm"), (0.0, 1.0);
                                p = Dict("solo" => 9.0, "Left.Left.solo" => 8.0))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    msg = err === nothing ? "" : sprint(showerror, err)
    @test occursin("2 keys designate the parameter 'Left.solo'", msg)
    @test occursin("Left.Left.solo, solo", msg)
end
