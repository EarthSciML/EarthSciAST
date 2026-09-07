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
# Their VERDICTS disagree only inside `rtol*|e| < |a - e| <= rtol*|a|`, which
# needs an OVERSHOOT (`|actual| > |expected|`) whose margin is itself of order
# `rtol`. Everywhere else `max(|a|, |e|) == |e|` or the difference is on the
# same side of both bounds, and the two return the same answer — which is why
# the divergence survived: every pre-existing tolerance case in every binding
# gets the same verdict under both readings, and the `assertion_nonfinite`
# category compares verdicts on non-finite actuals, so nothing here was
# covered. Reverting `_check_assertion` to the `|expected|` denominator must
# turn this red.
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

    # Zero ACTUAL against a nonzero expected — the mirror of the case above.
    # Here the symmetric scale IS `|e|`, so both readings agree; it is pinned
    # because the other one-sided reading (scale by `|actual|` alone) would
    # make the bound zero and reject every inexact match.
    @test !chk(0.0, 1.0, 0.5, 0.0)
    @test chk(0.0, 1.0, 1.0, 0.0)

    # OPPOSITE SIGNS. `rel ≥ 1` is vacuous only for a pair that shares a sign;
    # across a sign change the bound still bites. This is why §6.6.3 says
    # `rel ≥ 1` is not a substitute for an `abs` bound at `expected = 0`.
    @test !chk(1.0, -1.0, 1.0, 0.0)
    @test chk(-1.0, 1.0, 2.0, 0.0)

    # NON-FINITE actuals. The symmetric scale is precisely what makes the
    # finiteness clause load-bearing: `|Inf − e| ≤ rel·max(Inf, |e|)` is
    # `Inf ≤ Inf`, so the bound ALONE would pass every expected value
    # (§6.6.3; the `assertion_nonfinite` category, CONFORMANCE_SPEC §5.20).
    @test !chk(Inf, 1.0, 0.5, 0.0)
    @test !chk(-Inf, 1.0, 0.5, 0.0)
    @test !chk(NaN, 1.0, 0.5, 0.0)
    @test chk(Inf, Inf, 0.5, 0.0)      # the SAME infinity: equality clause
    @test !chk(Inf, -Inf, 0.5, 0.0)    # opposite infinities do not match

    # abs/rel interaction, both directions. An `abs` bound never narrows what
    # `rel` already admits — the predicate takes the MAX of the two — so a tiny
    # `abs` must not turn the overshoot case red:
    @test chk(1.6, 1.0, 0.5, 1e-12)
    # and `abs` admits what the symmetric `rel` rejects (same inputs as the
    # `!chk(3.0, 1.0, 0.5, 0.0)` rejection above):
    @test chk(3.0, 1.0, 0.5, 2.5)
end
