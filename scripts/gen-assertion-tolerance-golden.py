#!/usr/bin/env python3
"""Generate tests/conformance/assertion_tolerance/golden/predicate_verdicts.json.

The verdicts are NOT taken from any binding: they are computed here from the
esm-spec §6.6.3 predicate written out longhand, and every case additionally
carries the reason it is there.  The generator also reports, per case, which of
the four known WRONG readings it discriminates, so the non-vacuity claim in the
README is a computed fact rather than a hope.
"""

from __future__ import annotations

import json
import math
import os

INF = float("inf")
NAN = float("nan")


# --- the normative predicate, esm-spec §6.6.3 -----------------------------
def normative(a: float, e: float, rel: float, abs_: float) -> bool:
    if a == e:
        return True
    if not (math.isfinite(a) and math.isfinite(e)):
        return False
    if rel == 0.0 and abs_ == 0.0:
        return False
    return abs(a - e) <= max(abs_, rel * max(abs(a), abs(e)))


# --- the four wrong readings this fixture must be able to see -------------
def wrong_asymmetric(a: float, e: float, rel: float, abs_: float) -> bool:
    """Scales by |expected| alone."""
    if a == e:
        return True
    if not (math.isfinite(a) and math.isfinite(e)):
        return False
    if rel == 0.0 and abs_ == 0.0:
        return False
    return abs(a - e) <= max(abs_, rel * abs(e))


def wrong_sum(a: float, e: float, rel: float, abs_: float) -> bool:
    """numpy isclose: atol + rtol*|expected| (a SUM, strictly more permissive)."""
    if a == e:
        return True
    if not (math.isfinite(a) and math.isfinite(e)):
        return False
    if rel == 0.0 and abs_ == 0.0:
        return False
    return abs(a - e) <= abs_ + rel * abs(e)


def wrong_floor(a: float, e: float, rel: float, abs_: float) -> bool:
    """Symmetric bound with an epsilon floor of 1e-12 on the scale."""
    if a == e:
        return True
    if not (math.isfinite(a) and math.isfinite(e)):
        return False
    if rel == 0.0 and abs_ == 0.0:
        return False
    return abs(a - e) <= max(abs_, rel * max(abs(a), abs(e), 1e-12))


def wrong_nonfinite(a: float, e: float, rel: float, abs_: float) -> bool:
    """No finiteness guard, plus `both non-finite => equal` (the three Rust
    conformance harnesses' `approximately_equal`)."""
    if not math.isfinite(a) and not math.isfinite(e):
        return True
    if abs(a - e) <= abs_:
        return True
    if rel > 0.0:
        return abs(a - e) <= rel * max(abs(a), abs(e))
    return False


WRONG = {
    "asymmetric": wrong_asymmetric,
    "sum_form": wrong_sum,
    "epsilon_floor": wrong_floor,
    "no_finiteness_guard": wrong_nonfinite,
}


def enc(x: float):
    if math.isinf(x):
        return "+inf" if x > 0 else "-inf"
    if math.isnan(x):
        return "nan"
    return x


CASES = [
    # --- the seam: |actual| > |expected| ---------------------------------
    (
        "overshoot_inside_symmetric_bound",
        1.6,
        1.0,
        0.5,
        0.0,
        "The discriminating case. |a-e| = 0.6; the symmetric bound is "
        "0.5*max(1.6, 1.0) = 0.8, the |expected|-only bound is 0.5. Every "
        "binding's own runner passes this; the ad-hoc harnesses failed it.",
    ),
    (
        "overshoot_swapped_is_the_same_verdict",
        1.0,
        1.6,
        0.5,
        0.0,
        "Swap-invariance: the bound depends on the PAIR, not on which side is "
        "called expected. Same verdict as the case above.",
    ),
    (
        "overshoot_exactly_on_the_symmetric_bound",
        2.0,
        1.0,
        0.5,
        0.0,
        "|a-e| = 1.0 = 0.5*max(2.0, 1.0). The bound is inclusive, and both "
        "sides are exact in binary floating point, so no binding may round "
        "this the other way.",
    ),
    (
        "overshoot_outside_the_symmetric_bound",
        2.1,
        1.0,
        0.5,
        0.0,
        "Symmetric is not vacuous: past 0.5*|a| it still fails.",
    ),
    (
        "overshoot_negative_mirror",
        -1.6,
        -1.0,
        0.5,
        0.0,
        "The seam case sign-mirrored: the bound is on magnitudes.",
    ),
    # --- max vs sum (numpy isclose) --------------------------------------
    (
        "max_not_sum_of_the_two_bounds",
        1.5,
        1.0,
        0.3,
        0.3,
        "§6.6.3 takes the LARGER of the two bounds, not their sum. "
        "max(0.3, 0.3*1.5) = 0.45 < 0.5 = |a-e|, while numpy `isclose`'s "
        "atol + rtol*|e| = 0.6 admits it. This is the form #193 flagged.",
    ),
    (
        "max_not_sum_control_that_still_passes",
        1.2,
        1.0,
        0.3,
        0.3,
        "Control for the case above: a pair the max form admits on its own, so "
        "a binding cannot satisfy the previous case by rejecting everything.",
    ),
    # --- zero expected ----------------------------------------------------
    ("both_zero", 0.0, 0.0, 1e-6, 0.0, "Equality answers it before any bound."),
    (
        "both_zero_at_zero_tolerance",
        0.0,
        0.0,
        0.0,
        0.0,
        "Exact-equality mode still passes an exact match.",
    ),
    (
        "negative_zero_against_zero",
        -0.0,
        0.0,
        0.0,
        0.0,
        "IEEE-754: -0.0 == 0.0, so a signed zero is unaffected by the predicate at any tolerance.",
    ),
    (
        "tiny_actual_against_zero_expected",
        1e-20,
        0.0,
        0.5,
        0.0,
        "The consequence §6.6.3 states outright: with the bound written as a "
        "PRODUCT, a nonzero actual against a zero expected needs `abs` (or "
        "rel >= 1). A harness with a 1e-12 floor on the scale passes it.",
    ),
    (
        "subnormal_actual_against_zero_expected",
        1e-320,
        0.0,
        0.5,
        0.0,
        "The same, at the magnitude where an implementation-defined epsilon "
        "floor is invisible to every other case: 1e-300, 1e-12 and "
        "f64::MIN_POSITIVE all rescue this, and the spec forbids all three.",
    ),
    (
        "tiny_actual_against_zero_expected_rescued_by_abs",
        1e-20,
        0.0,
        0.0,
        1e-9,
        "`abs` is how a document expresses 'near zero'. Non-vacuity for the "
        "two cases above: they fail on the rule, not because zero expected "
        "always fails.",
    ),
    (
        "zero_expected_at_rel_one_is_vacuous",
        1.0,
        0.0,
        1.0,
        0.0,
        "rel = 1 makes the symmetric bound |a-e| <= max(|a|,|e|), which every "
        "same-sign pair satisfies. Stated so the vacuity is a pinned property "
        "and not a surprise; the |expected|-only reading FAILS this.",
    ),
    (
        "zero_expected_just_below_rel_one",
        1.0,
        0.0,
        0.999,
        0.0,
        "One ulp of policy below the vacuity: the bound is 0.999 < 1.0.",
    ),
    (
        "zero_expected_negative_actual_at_rel_one",
        -3.0,
        0.0,
        1.0,
        0.0,
        "Zero has no sign to disagree with, so the vacuity is two-sided.",
    ),
    # --- zero actual ------------------------------------------------------
    (
        "zero_actual_against_tiny_expected",
        0.0,
        1e-20,
        0.5,
        0.0,
        "Mirror of the zero-expected case. Both readings agree here, which is "
        "exactly why an |expected|-only harness looked correct for years.",
    ),
    (
        "zero_actual_against_one_at_rel_one",
        0.0,
        1.0,
        1.0,
        0.0,
        "|a-e| = 1.0 = 1.0*max(0, 1). Inclusive bound.",
    ),
    (
        "zero_actual_against_one_at_default_rel",
        0.0,
        1.0,
        1e-6,
        0.0,
        "A collapsed-to-zero actual must still fail at the §6.6.4 default.",
    ),
    # --- opposite signs ---------------------------------------------------
    (
        "opposite_signs_at_rel_one",
        1.0,
        -1.0,
        1.0,
        0.0,
        "rel = 1 is vacuous only for same-sign pairs: |a-e| = 2 > 1 = "
        "max(|a|,|e|). A magnitude-only comparison would pass this.",
    ),
    (
        "opposite_signs_at_rel_two",
        1.0,
        -1.0,
        2.0,
        0.0,
        "rel = 2 is the point at which a sign flip becomes admissible.",
    ),
    (
        "opposite_signs_rescued_by_abs",
        1.0,
        -1.0,
        0.0,
        2.0,
        "`abs` does not care about sign.",
    ),
    (
        "opposite_signs_at_default_rel",
        -1.0,
        1.0,
        1e-6,
        0.0,
        "A sign error is the plainest wrong answer there is.",
    ),
    # --- non-finite -------------------------------------------------------
    (
        "positive_infinity_against_finite",
        INF,
        42.0,
        1e-6,
        1e300,
        "Finiteness is judged BEFORE tolerance: 1e300 is the widest `abs` a "
        "document can spell and it does not rescue an infinity.",
    ),
    (
        "positive_infinity_against_largest_finite_double",
        INF,
        1.7976931348623157e308,
        1.0,
        0.0,
        "Not a magnitude test. The nearest finite double is still not close.",
    ),
    (
        "negative_infinity_against_finite",
        -INF,
        -5.0,
        1e-6,
        1e300,
        "The sign agreeing does not make it finite.",
    ),
    (
        "same_positive_infinity",
        INF,
        INF,
        1e-6,
        0.0,
        "The one case a non-finite value legitimately matches, reachable only "
        "through an API (JSON has no infinite literal).",
    ),
    (
        "same_negative_infinity",
        -INF,
        -INF,
        0.0,
        0.0,
        "The equality clause fires before the zero-tolerance branch.",
    ),
    (
        "opposite_infinities_positive_actual",
        INF,
        -INF,
        1e6,
        1e300,
        "Same class, opposite sign: FAIL. A binding whose guard reads 'both "
        "non-finite => equal' passes this.",
    ),
    (
        "opposite_infinities_negative_actual",
        -INF,
        INF,
        1e-6,
        0.0,
        "The other direction of the same defect.",
    ),
    (
        "nan_against_nan",
        NAN,
        NAN,
        1e-6,
        1e300,
        "NaN is not equal to itself, so the equality clause does not fire and "
        "the finiteness clause rejects it. The 'both non-finite => equal' "
        "guard passes it.",
    ),
    (
        "nan_actual_against_zero",
        NAN,
        0.0,
        1e-6,
        1e300,
        "Control: NaN already failed under the bound alone, because every "
        "IEEE-754 comparison with NaN is false.",
    ),
    (
        "nan_expected_against_finite_actual",
        0.0,
        NAN,
        1e-6,
        1e300,
        "The expected side is guarded too.",
    ),
    (
        "finite_actual_against_infinite_expected",
        1e300,
        INF,
        1e-6,
        0.0,
        "An API-supplied infinite expectation is not met by any finite value.",
    ),
    # --- atol / rtol interaction, both directions -------------------------
    (
        "rel_admits_what_abs_would_reject",
        1000001.0,
        1000000.0,
        1e-3,
        1e-9,
        "rel governs at large magnitude: max(1e-9, 1e-3*1000001) = 1000.001.",
    ),
    (
        "abs_admits_what_rel_would_reject",
        1.000002,
        1.0,
        1e-6,
        1e-5,
        "abs governs at small magnitude: max(1e-5, ~1e-6) = 1e-5 >= 2e-6. The "
        "two previous cases are the OR in §6.6.3, one direction each.",
    ),
    (
        "neither_bound_admits",
        1000001.0,
        1000000.0,
        1e-9,
        1e-9,
        "Both bounds present, both too tight. Non-vacuity for the pair above.",
    ),
    (
        "rel_only_just_inside",
        1.0000009,
        1.0,
        1e-6,
        0.0,
        "The §6.6.4 default tolerance, just inside.",
    ),
    (
        "rel_only_just_outside",
        1.000002,
        1.0,
        1e-6,
        0.0,
        "The same pair one factor of two out: the default is a real bound.",
    ),
    (
        "zero_tolerance_rejects_a_near_miss",
        5.0,
        5.0000001,
        0.0,
        0.0,
        "rel = abs = 0 is exact-equality mode, not 'no bound'. A harness that "
        "substitutes its own default rel when both are zero passes this.",
    ),
    (
        "zero_tolerance_accepts_an_exact_match",
        5.0,
        5.0,
        0.0,
        0.0,
        "Non-vacuity for the case above.",
    ),
    # --- rel >= 1 in general ---------------------------------------------
    (
        "three_orders_of_magnitude_apart_at_rel_one",
        1000.0,
        1.0,
        1.0,
        0.0,
        "The vacuity of rel >= 1 in its most alarming form: 1000 'equals' 1. "
        "Pinned deliberately — an author writing rel: 1 has written a test "
        "that cannot fail on a same-sign actual, and a binding must not "
        "quietly reinterpret that.",
    ),
    (
        "three_orders_of_magnitude_apart_swapped",
        1.0,
        1000.0,
        1.0,
        0.0,
        "Swap-invariance at the vacuous end. The |expected|-only reading also "
        "passes this one, which is what makes the unswapped case above the "
        "discriminating half of the pair.",
    ),
]


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "tests", "conformance", "assertion_tolerance", "golden")
    os.makedirs(out_dir, exist_ok=True)
    cases = []
    seen = set()
    discriminated = {k: 0 for k in WRONG}
    for cid, a, e, rel, abs_, why in CASES:
        assert cid not in seen, f"duplicate case id {cid}"
        seen.add(cid)
        verdict = normative(a, e, rel, abs_)
        catches = sorted(k for k, f in WRONG.items() if f(a, e, rel, abs_) != verdict)
        for k in catches:
            discriminated[k] += 1
        entry = {
            "id": cid,
            "actual": enc(a),
            "expected": enc(e),
            "rel": rel,
            "abs": abs_,
            "passed": verdict,
            "why": why,
        }
        if catches:
            entry["discriminates"] = catches
        cases.append(entry)

    for k, n in discriminated.items():
        assert n > 0, f"no case discriminates the {k} reading"

    n_pass = sum(1 for c in cases if c["passed"])
    assert n_pass > 0 and n_pass < len(cases)

    golden = {
        "$comment": (
            "GOLDEN for CONFORMANCE_SPEC §5.32 / esm-spec §6.6.3. Each case is a "
            "(actual, expected, rel, abs) tuple fed straight to the binding's own "
            "assertion predicate; `passed` is the required verdict. The verdicts are "
            "ANALYTIC — computed from the §6.6.3 rule written out longhand, not read "
            "off any binding. Regenerate with scripts/gen-assertion-tolerance-golden.py."
        ),
        "encoding_comment": (
            "JSON has no infinite or NaN literal, so `actual` and `expected` are "
            "either a JSON number or one of exactly three strings. Nothing else may "
            "appear, and no other numeric field is ever a string; an adapter that "
            "does not recognise one of the three MUST fail rather than skip."
        ),
        "encoding": {"non_finite": ["+inf", "-inf", "nan"]},
        "readings_discriminated_comment": (
            "How many cases change verdict under each known WRONG reading of §6.6.3. "
            "A zero would mean the case list cannot see that defect; the generator "
            "asserts every entry is nonzero. `asymmetric` scales by |expected| alone; "
            "`sum_form` is numpy isclose's abs + rel*|expected|; `epsilon_floor` puts "
            "a 1e-12 floor on the scale; `no_finiteness_guard` drops the finiteness "
            "clause and treats two non-finite values as equal. Every value here is an "
            "integer -- adapters read this object as a map of counts."
        ),
        "readings_discriminated": {
            "asymmetric": discriminated["asymmetric"],
            "sum_form": discriminated["sum_form"],
            "epsilon_floor": discriminated["epsilon_floor"],
            "no_finiteness_guard": discriminated["no_finiteness_guard"],
        },
        "counts": {"cases": len(cases), "pass": n_pass, "fail": len(cases) - n_pass},
        "cases": cases,
    }
    path = os.path.join(out_dir, "predicate_verdicts.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(golden, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"wrote {path}: {len(cases)} cases ({n_pass} pass / {len(cases) - n_pass} fail)")
    print("discriminates:", discriminated)


if __name__ == "__main__":
    main()
