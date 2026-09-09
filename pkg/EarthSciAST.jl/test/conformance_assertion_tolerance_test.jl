# Conformance harness adapter — assertion_tolerance category.
#
# CONFORMANCE_SPEC §5.37 / esm-spec §6.6.3. The subject is the pass predicate
# itself, as a PURE FUNCTION of `(actual, expected, rel, abs)`:
#
#   actual == expected
#   || (isfinite(actual) && isfinite(expected)
#       && !(rel == 0 && abs == 0)
#       && |actual - expected| <= max(abs, rel*max(|actual|, |expected|)))
#
# Every other assertion category is a SIMULATION category: it computes an actual
# and then compares it, so it only ever exercises the predicate at the pairs an
# integrator happens to produce — and those all sit in the |actual| <= |expected|
# region, where rel*max(|a|,|e|) and rel*|e| compute the same number. The two
# readings differ only on an OVERSHOOT, which no fixture in any category
# reaches. This category is data-only for exactly that reason: it needs no
# integrator, so it can state the discriminating pairs directly.
#
# The adapter calls `EarthSciAST._check_assertion` — the same function
# `run_tests` / `run_inline_tests` call, and the one that delegates to `isapprox`.
# An adapter that re-derived the predicate here would be testing itself, which
# is the defect the category exists to close.
#
# See tests/conformance/assertion_tolerance/.

using Test
using JSON3
using EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ATOL_CAT_DIR = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "assertion_tolerance")
const _ATOL_MANIFEST = joinpath(_ATOL_CAT_DIR, "manifest.json")
const _ATOL_GOLDEN = joinpath(_ATOL_CAT_DIR, "golden", "predicate_verdicts.json")

# A golden `actual`/`expected` is either a JSON number or one of exactly three
# strings. An unrecognised value is a HARD ERROR: silently skipping a case would
# let the category shrink without anything going red.
function _atol_number(v, case_id::AbstractString, field::AbstractString)
    if v isa Real
        return Float64(v)
    elseif v isa AbstractString
        s = String(v)
        s == "+inf" && return Inf
        s == "-inf" && return -Inf
        s == "nan" && return NaN
        error("$(case_id): $(field) is the string \"$(s)\"; the golden's encoding " *
              "admits only \"+inf\", \"-inf\" and \"nan\"")
    end
    error("$(case_id): $(field) is $(v), expected a number or a string")
end

@testset "Conformance: assertion_tolerance (manifest-driven)" begin
    @test isfile(_ATOL_MANIFEST)
    manifest = JSON3.read(read(_ATOL_MANIFEST, String))
    @test manifest.category == "assertion_tolerance"
    @test String(manifest.reference_binding) == "analytic"
    # Julia has a §6.6.3 predicate and runners that use it, so it must be
    # REQUIRED rather than excluded.
    @test "julia" in manifest.bindings_required
    @test !haskey(manifest.scope_excluded, :julia)

    @test isfile(_ATOL_GOLDEN)
    golden = JSON3.read(read(_ATOL_GOLDEN, String))
    cases = golden.cases
    @test !isempty(cases)

    failures = String[]
    n_pass = 0
    for case in cases
        cid = String(case.id)
        a = _atol_number(case.actual, cid, "actual")
        e = _atol_number(case.expected, cid, "expected")
        rel = Float64(case.rel)
        atol = Float64(case.abs)
        want = case.passed::Bool
        n_pass += want ? 1 : 0

        got = EarthSciAST._check_assertion(a, e, rel, atol)
        if got != want
            push!(failures,
                  "$(cid): _check_assertion($(a), $(e), rtol=$(rel), atol=$(atol)) = " *
                  "$(got), golden says $(want) — $(String(case.why))")
        end
    end
    @test isempty(failures) || error(
        "$(length(failures)) of $(length(cases)) §6.6.3 predicate cases disagree " *
        "with the golden:\n" * join(failures, "\n"))
    # Non-vacuity: a golden of one verdict would be satisfied by a constant.
    @test 0 < n_pass < length(cases)

    # The generator counts, per known WRONG reading of §6.6.3, how many cases
    # change verdict under it. A zero would mean the case list had quietly
    # stopped being able to see that defect — which is how the ~12 ad-hoc
    # harnesses in #223 stayed green for years.
    d = golden.readings_discriminated
    for reading in (:asymmetric, :sum_form, :epsilon_floor, :no_finiteness_guard)
        @test getproperty(d, reading) > 0
    end
end
