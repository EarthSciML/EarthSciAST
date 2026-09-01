# Conformance harness adapter — round-trip category. REFERENCE ADAPTER.
#
# The oracle is the AUTHORED FIXTURE. This file used to compare emit pass 2
# against emit pass 3 — `save(load(F))` vs `save(load(save(load(F))))`, with F
# itself never a participant — which is the self-comparing shape described in
# tests/conformance/README.md and is blind to any field lost on the FIRST load:
# the second emit forgets exactly what the first forgot, so the equation holds
# perfectly over an already-damaged document.
#
# esm-spec §9.6.4 rule 5 now states BOTH halves normatively ("Load preservation"
# and "Idempotence"), and neither implies the other, so both are asserted here.
#
# See tests/conformance/README.md for the full contract: the five
# normalizations, the two exemption ledgers (`load_transforms` for
# spec-mandated rewrites, `known_divergences` for the defect ratchet), and the
# `preserved_keys` field-loss check that runs on EVERY fixture, excused or not.

using Test
using JSON3
using OrderedCollections
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT + _require_fixture

const _TESTS_DIR     = joinpath(TESTUTILS_REPO_ROOT, "tests")
const _MANIFEST_PATH = joinpath(_TESTS_DIR, "conformance", "round_trip", "manifest.json")
const _BINDING       = "julia"

# Applied to BOTH sides, so no relaxation can hide a drop. README §normalizations.
_is_empty_container(v) = (v isa AbstractVector || v isa AbstractDict) && isempty(v)
_relaxed_key(ks, parent, y) =
    ks == "expect_cadence" ||
    (ks == "independent_variable" && parent == "domain" && y == "t") ||
    (ks == "initial_offset" && y == 0)

function _normalize(v, parent::String = "")
    if v isa AbstractDict
        out = OrderedDict{String,Any}()
        for (k, x) in v
            ks = String(k)
            y = _normalize(x, ks)
            (_is_empty_container(y) || _relaxed_key(ks, parent, y)) && continue
            out[ks] = y
        end
        return out
    elseif v isa AbstractVector
        return Any[_normalize(x, parent) for x in v]
    else
        return v
    end
end

"Every `/a/b[0]/c` path at which the two documents differ."
function _json_diff(a, b, path = "")
    out = String[]
    if a isa AbstractDict && b isa AbstractDict
        for k in keys(a)
            haskey(b, k) ? append!(out, _json_diff(a[k], b[k], "$path/$k")) :
                push!(out, "$path/$k  DROPPED (was $(first(JSON3.write(a[k]), 120)))")
        end
        for k in keys(b)
            haskey(a, k) || push!(out, "$path/$k  ADDED ($(first(JSON3.write(b[k]), 120)))")
        end
    elseif a isa AbstractVector && b isa AbstractVector
        if length(a) != length(b)
            push!(out, "$path  LENGTH $(length(a)) -> $(length(b))")
        else
            for i in eachindex(a)
                append!(out, _json_diff(a[i], b[i], "$path[$(i - 1)]"))
            end
        end
    elseif a != b
        push!(out, "$path  $(repr(a)) -> $(repr(b))")
    end
    return out
end

"`(wire_key, json_path)` for every mapping key in `orig` absent from `emitted`."
function _dropped_keys(orig, emitted, path = "")
    out = Tuple{String,String}[]
    if orig isa AbstractDict && emitted isa AbstractDict
        for (k, v) in orig
            ks = String(k)
            here = "$path.$ks"
            haskey(emitted, ks) ? append!(out, _dropped_keys(v, emitted[ks], here)) :
                push!(out, (ks, here))
        end
    elseif orig isa AbstractVector && emitted isa AbstractVector
        for i in 1:min(length(orig), length(emitted))
            append!(out, _dropped_keys(orig[i], emitted[i], "$path[$(i - 1)]"))
        end
    end
    return out
end

@testset "Conformance: round-trip (manifest-driven)" begin
    @test isfile(_MANIFEST_PATH)

    manifest = JSON3.read(read(_MANIFEST_PATH, String))
    @test manifest.category == "round_trip"
    @test !isempty(manifest.fixtures)

    preserved = Set(String.(manifest.preserved_keys))

    # Fixture id => the divergence entry naming THIS binding non-conformant. A
    # binding listed `conformant`, or listed in neither column, is held to full
    # equality — that is what makes the ledger a ratchet rather than a licence.
    excused_by_divergence = Dict{String,String}()
    for d in get(manifest, :known_divergences, [])
        _BINDING in String.(d.nonconformant) || continue
        for f in d.fixtures
            excused_by_divergence[String(f)] = String(d.id)
        end
    end

    stale = String[]

    for fixture in manifest.fixtures
        id = String(fixture.id)
        fixture_path = joinpath(_TESTS_DIR, String(fixture.path))

        @testset "$(id)" begin
            _require_fixture(fixture_path) || return

            original = EarthSciAST.load_path(fixture_path)
            first_json = to_json_compact(original)

            authored_v = _normalize(JSON3.read(read(fixture_path, String),
                                               OrderedDict{String,Any}))
            emitted_v = _normalize(JSON3.read(first_json, OrderedDict{String,Any}))

            has_transform = haskey(fixture, :load_transforms) &&
                            !isempty(fixture.load_transforms)
            divergence = get(excused_by_divergence, id, nothing)
            excused = has_transform || divergence !== nothing

            diff = _json_diff(authored_v, emitted_v)

            # 1. LOAD PRESERVATION (esm-spec §9.6.4 rule 5).
            if !excused
                @test isempty(diff) ||
                      error("$(id): save(load(F)) differs from F — either a field is " *
                            "being dropped/invented, or a spec-REQUIRED load-time " *
                            "transform needs a `load_transforms` entry citing its " *
                            "clause. Do NOT add one to silence a drop.\n  " *
                            join(diff, "\n  "))
            elseif isempty(diff)
                # Improving, not failing: README adapter contract item 8.
                push!(stale, id)
            end

            # 2. FIELD LOSS — runs on EVERY fixture, excused or not.
            lost = [where for (key, where) in _dropped_keys(authored_v, emitted_v)
                    if key in preserved]
            @test isempty(lost) ||
                  error("$(id): dropped preserved field(s) at $(lost). A load-time " *
                        "transform rewrites a CONSTRUCT; it does not licence dropping " *
                        "the document around it.")

            # 3. IDEMPOTENCE (esm-spec §9.6.4 rule 5) — still required, no longer alone.
            second_json = to_json_compact(EarthSciAST.load_document(
                JSON3.read(first_json, OrderedDict{String,Any})))
            @test JSON3.read(first_json) == JSON3.read(second_json)
        end
    end

    if !isempty(stale)
        @info "round-trip: excused fixtures that now round-trip cleanly in $_BINDING " *
              "(ledger entry may be stale — trim by hand; this is NOT a failure)" stale
    end
end
