# esm-spec §6.6.3 — the relative bound is SYMMETRIC in `actual` and `expected`.
#
# The scale is `max(|actual|, |expected|)`, the larger of the two magnitudes,
# NOT `|expected|` alone. §6.6.3 used to state both: the normative box (and the
# schema's `Tolerance` description) gave the `|expected|`-only denominator while
# the finiteness rationale further down the same section reasoned from
# `max(|∞|, |expected|)` — two different rules for one predicate, and the three
# executing bindings all implemented the symmetric one. EarthSciML/EarthSciAST#193
# settled it as symmetric; this pins the choice at the seam where the two
# readings actually disagree.
#
# They disagree only when `|actual| > |expected|` — an OVERSHOOT. Everywhere
# else `max(|a|, |e|) == |e|` and the two are the same number, which is why the
# divergence survived: every pre-existing tolerance case in every binding sits
# in the agreeing region, and the `assertion_nonfinite` category compares
# verdicts on non-finite actuals, so nothing here was covered. Reverting
# `_check_assertion` to the `|expected|` denominator must turn this red.
using Test
using EarthSciAST

@testset "assertion tolerance: symmetric relative bound (§6.6.3)" begin
    chk = EarthSciAST._check_assertion

    # The discriminator (issue #193). |actual| > |expected|, so the symmetric
    # scale is 1.6, not 1.0:
    #   symmetric:  0.6 <= 0.5 * max(1.6, 1.0) = 0.8   -> PASS
    #   |expected|: 0.6 <= 0.5 * 1.0           = 0.5   -> FAIL
    @test chk(1.6, 1.0, 0.5, 0.0)
    # Just past the symmetric bound, so both readings agree again.
    @test !chk(3.0, 1.0, 0.5, 0.0)

    # Symmetry as the property, not just the one case: swapping the arguments
    # cannot change the verdict. Under an `|expected|`-only denominator the
    # first pair below disagrees with itself reversed.
    for (a, e) in ((1.6, 1.0), (1.0, 1.6), (3.0, 1.0), (1.0, 3.0), (-2.0, -1.2))
        @test chk(a, e, 0.5, 0.0) == chk(e, a, 0.5, 0.0)
    end

    # No ε floor, and none permitted: the bound is a product, not a quotient,
    # so `expected == 0` needs no protection. It reads `|a| <= rel*|a|`, which
    # a nonzero actual clears only at `rel >= 1` — a purely relative tolerance
    # says nothing about how close to zero is close enough.
    @test !chk(1.0, 0.0, 0.5, 0.0)
    @test chk(1.0, 0.0, 1.0, 0.0)
    @test chk(1.0, 0.0, 0.0, 1.0)      # an `abs` bound is the way to spell it
    @test chk(0.0, 0.0, 0.0, 0.0)      # exact-equality clause, no tolerance

    # An `abs` bound never narrows what `rel` already admits: the predicate
    # takes the MAX of the two bounds, so declaring a tiny `abs` alongside a
    # wide `rel` must not turn the overshoot case red.
    @test chk(1.6, 1.0, 0.5, 1e-12)
end
