# Conformance harness adapter — tolerance_resolution category.
#
# esm-spec §6.6.4 (CONFORMANCE_SPEC §5.21): the `{abs?, rel?}` blocks declared
# at the assertion, test and model levels combine into the single `(rtol, atol)`
# pair the §6.6.3 predicate is evaluated with, and they combine PER FIELD. Each
# of `abs` and `rel` takes its value from the innermost level that declares it,
# so a level declaring only one bound does not mask the other from an enclosing
# level.
#
# The defect it closes (#228): all three bindings returned the first non-nothing
# block WHOLE and defaulted its missing field to 0, so a model `{rel: 1e-6}`
# plus an assertion `{abs: 1e-9}` resolved to `(0, 1e-9)` — the assertion ran
# with NO relative bound at all, silently discarding a tolerance its author
# declared one level up. No other conformance tier could see it: every fixture
# in every other category declares exactly one tolerance block, and one block
# merges identically whether the rule is per-field or wholesale.
#
# Two things §6.6.4 left open are pinned here too: an explicit `0` is a
# DECLARATION ("no bound of this kind") that stops the fallthrough, while a
# missing key or a JSON `null` is an ABSENCE that falls through; and the
# implementation default (`rel = 1e-6`) is TERMINAL, reached only when levels
# 1-3 declare neither bound, rather than a fourth per-field merge level.
#
# The category is DATA-ONLY — resolution is a pure function of the declared
# blocks — so it carries no `.esm` fixture, no integrator and no numeric golden.
# See tests/conformance/tolerance_resolution/.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _TR_CAT_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                             "tolerance_resolution")
const _TR_MANIFEST = joinpath(_TR_CAT_DIR, "manifest.json")

# Build a `Tolerance` from a manifest `levels` entry. A missing key and an
# explicit JSON `null` both mean ABSENT and both land as `nothing`; a `0` is a
# declared bound and must survive as `0.0`.
function _tr_tolerance(block)
    block === nothing && return nothing
    get_field(name) = begin
        v = get(block, name, nothing)
        v === nothing ? nothing : Float64(v)
    end
    return EarthSciAST.Tolerance(; abs=get_field(:abs), rel=get_field(:rel))
end

# The pre-#228 rule, kept here as the thing the new one must never be tighter
# than: the first declared block won wholesale and its missing field became 0.
function _tr_wholesale(model_tol, test_tol, assertion_tol)
    for candidate in (assertion_tol, test_tol, model_tol)
        candidate === nothing && continue
        rel = candidate.rel === nothing ? 0.0 : Float64(candidate.rel)
        atol = candidate.abs === nothing ? 0.0 : Float64(candidate.abs)
        return (rel, atol)
    end
    return (1.0e-6, 0.0)
end

@testset "Conformance: tolerance_resolution (manifest-driven)" begin
    @test isfile(_TR_MANIFEST)
    manifest = JSON3.read(read(_TR_MANIFEST, String))
    @test manifest.category == "tolerance_resolution"
    @test Set(String.(manifest.bindings_required)) == Set(["julia", "python", "rust"])
    # Data-only: pinning an integrator here would be a category error.
    @test manifest.integrators === nothing
    @test length(manifest.cases) >= 15
    @test length(unique(String[String(c.id) for c in manifest.cases])) ==
          length(manifest.cases)
    @test count(c -> c.changed_by_228, manifest.cases) >= 5

    for case in manifest.cases
        levels = case.levels
        model = _tr_tolerance(get(levels, :model, nothing))
        test = _tr_tolerance(get(levels, :test, nothing))
        assertion = _tr_tolerance(get(levels, :assertion, nothing))

        got = EarthSciAST._resolve_tolerance(model, test, assertion)
        want = (Float64(case.resolved.rel), Float64(case.resolved.abs))
        @test got == want

        # Monotonicity: per field the merged value can only come from a level
        # the wholesale rule ignored, so no bound ever tightens and no assertion
        # can flip pass -> fail under this change.
        old = _tr_wholesale(model, test, assertion)
        @test got[1] >= old[1]
        @test got[2] >= old[2]
        @test (old != got) == case.changed_by_228
    end
end
