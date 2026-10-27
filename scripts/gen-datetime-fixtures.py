#!/usr/bin/env python3
"""Generate the fractional-time and range-edge scenarios of the `datetime.*`
closed-function fixtures (`tests/closed_functions/datetime/*/expected.json`).

esm-spec §9.2 decomposes a binary64 UTC time `t` into the day number
`floor(t / 86400)` and the time of day `t - 86400 * floor(t / 86400)`, which
lies in `[0, 86400)`; hour, minute and second come from `floor(time of day)`.
Every expected value here is computed EXACTLY from that definition, never by
calling a binding:

* `t` is turned into the exact rational it denotes (`fractions.Fraction`),
  and the floor-divmod is done on that rational, so no rounding enters.
* The calendar date of a day number comes from `datetime.date.fromordinal`
  after shifting the day number by whole 400-year Gregorian cycles (146097
  days, which repeat the calendar exactly) into the range that function
  accepts; the year is then shifted back by 400 per cycle. That covers any
  integer year, far beyond the stdlib's 1..9999.
* `julian_day` is the exact rational `JDN(date) + (tod - 43200) / 86400`,
  rounded once to the nearest binary64 (`Fraction.__float__` is correctly
  rounded). `JDN(date)` is the ordinal-based count, cross-checked against the
  spec's Fliegel–van Flandern formula. Dates before -4800-03-01, where the two
  can disagree, are left out of the julian_day fixture and printed.

Inputs are written as the shortest repr of the binary64 value, so the JSON
literal IS the input. Scenarios already in a fixture are kept and checked
against the same exact computation; the generated ones (named `frac_*` and
`int32_*`) are replaced on every run, so the script is idempotent.

Usage: python3 scripts/gen-datetime-fixtures.py [--check]
  --check  exit non-zero if any fixture file would change (CI-friendly).
"""

import argparse
import datetime as _dt
import json
import math
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "closed_functions" / "datetime"

DAY = 86400
CYCLE_DAYS = 146097  # one 400-year proleptic-Gregorian cycle
EPOCH_ORDINAL = _dt.date(1970, 1, 1).toordinal()  # 719163
INT32_MIN = -(2**31)
INT32_MAX = 2**31 - 1
GENERATED_PREFIXES = ("frac_", "int32_")


class Overflow(Exception):
    """The integer result does not fit in a signed 32-bit integer."""


# ---------------------------------------------------------------------------
# Exact calendar
# ---------------------------------------------------------------------------


def civil_from_day_number(n):
    """(year, month, day) of the day `n` days after 1970-01-01."""
    ordinal = n + EPOCH_ORDINAL
    k = (ordinal - 1) // CYCLE_DAYS  # floor: whole cycles to shift by
    d = _dt.date.fromordinal(ordinal - k * CYCLE_DAYS)
    return d.year + 400 * k, d.month, d.day


def day_number_from_civil(y, m, d):
    """Inverse of `civil_from_day_number`."""
    k = (y - 1) // 400
    return _dt.date(y - 400 * k, m, d).toordinal() + k * CYCLE_DAYS - EPOCH_ORDINAL


def is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def fliegel_van_flandern(y, m, d):
    """The spec's reference JDN formula, with C-style truncating division."""
    a = trunc_div(m - 14, 12)
    return (
        trunc_div(1461 * (y + 4800 + a), 4)
        + trunc_div(367 * (m - 2 - 12 * a), 12)
        - trunc_div(3 * trunc_div(y + 4900 + a, 100), 4)
        + d
        - 32075
    )


def decompose(t):
    """Exact §9.2 decomposition of the binary64 `t`."""
    x = Fraction(t)  # the exact value of the double
    n = math.floor(x / DAY)  # day number
    tod = x - DAY * n  # exact time of day, in [0, 86400)
    assert 0 <= tod < DAY
    s = math.floor(tod)
    y, mo, d = civil_from_day_number(n)
    return {
        "n": n,
        "tod": tod,
        "year": y,
        "month": mo,
        "day": d,
        "hour": s // 3600,
        "minute": (s % 3600) // 60,
        "second": s % 60,
        "day_of_year": n - day_number_from_civil(y, 1, 1) + 1,
        "is_leap_year": 1 if is_leap(y) else 0,
    }


def evaluate(fn, t):
    """Exact expected value of `datetime.<fn>(t)`; raises Overflow for year."""
    p = decompose(t)
    if fn == "julian_day":
        jdn = (p["n"] + EPOCH_ORDINAL) + 1721425  # JDN of the civil date (noon)
        return float(jdn + (p["tod"] - 43200) / Fraction(DAY))
    v = p[fn]
    if not INT32_MIN <= v <= INT32_MAX:
        raise Overflow(v)
    return v


def iso(t):
    p = decompose(t)
    y = p["year"]
    ys = f"{y:04d}" if 0 <= y <= 9999 else f"{y:+05d}"
    frac = p["tod"] - math.floor(p["tod"])
    if frac == 0:
        fs = ""
    elif float(frac) == 1.0:  # e.g. 1 - 5e-324: below 1 but rounds to it
        fs = " + just under 1 s"
    else:
        fs = f" + {float(frac)!r} s"
    return (
        f"{ys}-{p['month']:02d}-{p['day']:02d}T{p['hour']:02d}:"
        f"{p['minute']:02d}:{p['second']:02d}Z{fs}"
    )


# ---------------------------------------------------------------------------
# Scenario set
# ---------------------------------------------------------------------------


def t_of(y, m=1, d=1, hh=0, mm=0, ss=0):
    """Exact integer UTC seconds of a civil instant."""
    return day_number_from_civil(y, m, d) * DAY + hh * 3600 + mm * 60 + ss


# (label, exact integer boundary in seconds). Each is probed from both sides
# with fractional offsets; the label names what rolls over at the boundary.
BOUNDARIES = [
    ("epoch", 0),
    ("second_1970_01_01T00_00_01", 1),
    ("minute_1970_01_01T00_01", 60),
    ("hour_1970_01_01T01", 3600),
    ("day_1970_01_02", DAY),
    ("month_1970_02_01", t_of(1970, 2, 1)),
    ("year_1971", t_of(1971)),
    ("leap_day_start_2000_02_29", t_of(2000, 2, 29)),
    ("leap_day_end_2000_03_01", t_of(2000, 3, 1)),
    ("non_leap_2100_03_01", t_of(2100, 3, 1)),
    ("leap_day_end_2024_03_01", t_of(2024, 3, 1)),
    ("year_2025", t_of(2025)),
    ("pre_epoch_second_1969_12_31T23_59_59", -1),
    ("pre_epoch_minute_1969_12_31T23_59", -60),
    ("pre_epoch_day_1969_12_31", -DAY),
    ("year_1900", t_of(1900)),
    ("year_0001", t_of(1)),
    ("year_0000", t_of(0)),
    ("leap_day_end_0000_03_01", t_of(0, 3, 1)),
    ("year_minus_4713", t_of(-4713)),
    ("year_minus_100000", t_of(-100000)),
    ("year_10000", t_of(10000)),
]


def probes(b):
    """(suffix, t) pairs around the integer boundary `b`; distinct doubles only."""
    fb = float(b)
    assert Fraction(fb) == b, f"boundary {b} is not a binary64"
    cands = [
        ("below_ulp", math.nextafter(fb, -math.inf)),
        ("below_1e_7", fb - 1e-7),
        ("below_half", fb - 0.5),
        ("at", fb),
        ("above_1e_7", fb + 1e-7),
        ("above_ulp", math.nextafter(fb, math.inf)),
    ]
    seen, out = set(), []
    for suffix, t in cands:
        key = (t, math.copysign(1.0, t))
        # An offset below the boundary's ulp rounds back onto the boundary (or
        # onto a neighbour already listed); keep only distinct doubles.
        if key in seen or (suffix != "at" and t == fb):
            continue
        seen.add(key)
        out.append((suffix, t))
    return out


PROBE_TEXT = {
    "below_ulp": "one ulp below",
    "below_1e_7": "1e-7 s below",
    "below_half": "0.5 s below",
    "at": "exactly at",
    "above_1e_7": "1e-7 s above",
    "above_ulp": "one ulp above",
}

EXTRA = [
    # The three worked examples of the ruling (formal/QUESTIONS.md Q-3).
    ("frac_example_59_9999999", 59.9999999, "ruling example: 00:00:59 of 1970-01-01"),
    ("frac_example_86399_9999999", 86399.9999999, "ruling example: 23:59:59 of 1970-01-01"),
    ("frac_example_minus_1e_7", -1e-7, "ruling example: 23:59:59 of 1969-12-31"),
    ("frac_epoch_negative_zero", -0.0, "negative zero is the epoch itself"),
    ("frac_epoch_min_subnormal_below", -5e-324,
     "smallest subnormal below the epoch: 1969-12-31T23:59:59, although 86400 - 5e-324 rounds to 86400 in binary64"),
]


def int32_edges():
    """Largest/smallest doubles whose year is still an Int32, and their neighbours."""
    hi = float(t_of(INT32_MAX + 1))  # first instant of year 2^31
    lo = float(t_of(INT32_MIN))  # first instant of year -2^31
    assert Fraction(hi) == t_of(INT32_MAX + 1) and Fraction(lo) == t_of(INT32_MIN)
    ok = [
        ("int32_year_max_last_double", math.nextafter(hi, -math.inf),
         "largest binary64 whose year is 2147483647 (Int32 max)"),
        ("int32_year_min_first_instant", lo,
         "first instant of year -2147483648 (Int32 min)"),
    ]
    over = [
        ("int32_year_max_plus_one", hi,
         "first instant of year 2147483648: one past Int32 max"),
        ("int32_year_min_minus_one", math.nextafter(lo, -math.inf),
         "largest binary64 before year -2147483648: year -2147483649, one past Int32 min"),
    ]
    return ok, over


FUNCTIONS = ["year", "month", "day", "hour", "minute", "second",
             "day_of_year", "julian_day", "is_leap_year"]


# Before -4800-03-01 the spec's Fliegel-van Flandern reference (truncating
# division) and the standard Julian Day disagree on some dates; which one
# §9.2 means there is an open question, so the julian_day fixture pins
# neither reading on or before that date, even where the two happen to agree.
JULIAN_DAY_FIRST_PINNED = day_number_from_civil(-4800, 3, 1)


def jdn_pinnable(t):
    p = decompose(t)
    if p["n"] < JULIAN_DAY_FIRST_PINNED:
        return False
    assert fliegel_van_flandern(p["year"], p["month"], p["day"]) == p["n"] + EPOCH_ORDINAL + 1721425
    return True


def generated_scenarios(fn, skipped):
    out = []
    points = []
    for label, b in BOUNDARIES:
        for suffix, t in probes(b):
            points.append((f"frac_{label}_{suffix}", t, f"{PROBE_TEXT[suffix]} the {label} boundary"))
    points += EXTRA
    ok, _ = int32_edges()
    points += ok
    for name, t, why in points:
        if fn == "julian_day" and not jdn_pinnable(t):
            skipped.append((fn, name, t))
            continue
        out.append({
            "name": name,
            "description": f"t_utc = {t!r} -> {iso(t)} ({why}). Fields floor toward -inf (esm-spec §9.2).",
            "inputs": [t],
            "expected": evaluate(fn, t),
        })
    return out


def generated_errors(fn):
    if fn != "year":
        return []
    _, over = int32_edges()
    errs = []
    for name, t, why in over:
        try:
            evaluate(fn, t)
            raise AssertionError(f"{name} does not overflow")
        except Overflow:
            pass
        errs.append({
            "name": name,
            "description": f"t_utc = {t!r} ({why}). Bindings MUST raise `closed_function_overflow` (esm-spec §9.2).",
            "inputs": [t],
            "expected_error_code": "closed_function_overflow",
        })
    return errs


def same(a, b):
    return a == b and (not isinstance(a, float) or math.copysign(1, a) == math.copysign(1, b))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    bad, changed, skipped, added = [], [], [], 0
    for fn in FUNCTIONS:
        path = FIXTURES / fn / "expected.json"
        text = path.read_text()
        spec = json.loads(text)
        assert spec["function"] == f"datetime.{fn}"
        keep = [s for s in spec["scenarios"] if not s["name"].startswith(GENERATED_PREFIXES)]
        for s in keep:
            want = evaluate(fn, float(s["inputs"][0]))
            tol = spec["tolerance"]
            diff = abs(want - s["expected"])
            if diff > max(tol["abs"], tol["rel"] * max(1.0, abs(want))):
                bad.append(f"{fn}/{s['name']}: fixture has {s['expected']!r}, exact value is {want!r}")
        gen = generated_scenarios(fn, skipped)
        added += len(gen)
        spec["scenarios"] = keep + gen
        keep_err = [e for e in spec.get("error_scenarios", [])
                    if not e["name"].startswith(GENERATED_PREFIXES)]
        errs = keep_err + generated_errors(fn)
        added += len(errs) - len(keep_err)
        if errs:
            spec["error_scenarios"] = errs
        new = json.dumps(spec, indent=4, ensure_ascii=False) + "\n"
        if new != text:
            changed.append(path)
            if not args.check:
                path.write_text(new)

    for fn, name, t in skipped:
        print(f"skipped {fn}/{name}: t={t!r} is before -4800-03-01 (julian_day reading open)")
    for b in bad:
        print("MISMATCH", b)
    verb = "would change" if args.check else "wrote"
    print(f"{added} generated scenarios; {verb} {len(changed)} file(s); "
          f"{len(bad)} hand-written scenario mismatch(es); {len(skipped)} skipped")
    if bad or (args.check and changed):
        sys.exit(1)


if __name__ == "__main__":
    main()
