#!/usr/bin/env python3
"""Generate lib/calendar.esm, the pure-AST calendar templates (esm-spec §9.7.1).

The library defines nine calendar fields of a UTC instant, plus
`seconds_since_midnight`, as match-less expression templates of one parameter
`t` (UTC seconds). Each step of the algorithm is written once, as a helper
template (prefix `civil_`), and later steps call it by reference
(`apply_expression_template`, esm-spec §9.7.3) instead of repeating its body:

    civil_day_number(t)      d   = floor(floor(t) / 86400)
    civil_second_of_day(t)   s   = floor(t) - 86400 d             (seconds)
    civil_era(t)             era = floor((d + 719468) / 146097)
    civil_day_of_era(t)      doe = (d + 719468) - 146097 era
    civil_year_of_era(t)     yoe = floor((doe - floor(doe/1460) + floor(doe/36524) - floor(doe/146096)) / 365)
    civil_day_of_year(t)     doy = doe - (365 yoe + floor(yoe/4) - floor(yoe/100))   (from March 1)
    civil_month_index(t)     mp  = floor((5 doy + 2) / 153)                         (from March, 0..11)
    civil_is_jan_feb(t)      doy >= 306
    civil_leap(x), civil_leap_next(x)   the leap rule on a year of era and on the year after it

This is Howard Hinnant's `civil_from_days`. On |t| < 2^52 s every intermediate
is an integer below 2^53, so every floor(a / b) is exact; each public template
returns `0 / 0` (NaN) outside that domain. Constants in seconds are unit-bearing
`const` nodes (esm-spec §4.8.5), so `t` is checked as seconds.

Usage:
    scripts/gen-lib-calendar.py           # write lib/calendar.esm
    scripts/gen-lib-calendar.py --check   # exit 1 if lib/calendar.esm is stale
Then `scripts/sync-lib.sh` mirrors it into docs/static/lib/.
"""

import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "lib" / "calendar.esm"


def op(o, *a):
    return {"op": o, "args": list(a)}


def cs(v):
    return {"op": "const", "args": [], "value": v, "units": "s"}


def fl(x):
    return op("floor", x)


def div(a, b):
    return op("/", a, b)


def mul(a, b):
    return op("*", a, b)


def add(*a):
    return op("+", *a)


def sub(a, b):
    return op("-", a, b)


def fdiv(a, b):
    return fl(div(a, b))


def ref(name, **bindings):
    return {"op": "apply_expression_template", "args": [], "name": name, "bindings": bindings}


def of_t(name):
    return ref(name, t="t")


T = "t"
FT = fl(T)
D = of_t("civil_day_number")
S_S = of_t("civil_second_of_day")
S = div(S_S, cs(1))  # the whole second of the day as a dimensionless count
ERA = of_t("civil_era")
DOE = of_t("civil_day_of_era")
YOE = of_t("civil_year_of_era")
DOY = of_t("civil_day_of_year")
MP = of_t("civil_month_index")
JANFEB = of_t("civil_is_jan_feb")


def rem_is_zero(x, k):
    return op("==", sub(x, mul(k, fdiv(x, k))), 0)


NAN = op("/", 0, 0)


def guard(body):
    return op("ifelse", op("<", op("abs", T), cs(4503599627370496)), body, NAN)


DOMAIN = (
    " Finite t with |t| < 2^52 s; outside it, and for NaN or an infinite t, the value is NaN (0/0)."
)
UNGUARDED = " A step of the public templates, not guarded: meaningful for finite |t| < 2^52 s, where it is exact."

# (name, params, body, description, public)
TEMPLATES = [
    (
        "year",
        ["t"],
        add(add(YOE, mul(400, ERA)), op("ifelse", JANFEB, 1, 0)),
        "Proleptic-Gregorian year of the UTC instant t (seconds since 1970-01-01T00:00:00Z), astronomical numbering (0 = 1 BC): yoe + 400 era, plus one in January and February (Howard Hinnant's civil_from_days).",
        True,
    ),
    (
        "month",
        ["t"],
        add(MP, op("ifelse", op("<", MP, 10), 3, -9)),
        "Calendar month 1..12 of the UTC instant t: mp + 3 for mp < 10 and mp - 9 otherwise, mp being the month counted from March.",
        True,
    ),
    (
        "day",
        ["t"],
        add(sub(DOY, fdiv(add(mul(153, MP), 2), 5)), 1),
        "Day of month 1..31 of the UTC instant t: doy - floor((153 mp + 2) / 5) + 1.",
        True,
    ),
    (
        "hour",
        ["t"],
        fdiv(S, 3600),
        "UTC hour 0..23 of t: floor(s / 3600), s being the whole second of the day.",
        True,
    ),
    (
        "minute",
        ["t"],
        sub(fdiv(S, 60), mul(60, fdiv(S, 3600))),
        "UTC minute 0..59 of t: floor(s / 60) - 60 floor(s / 3600).",
        True,
    ),
    (
        "second",
        ["t"],
        sub(S, mul(60, fdiv(S, 60))),
        "UTC second 0..59 of t (no leap-second slot): s - 60 floor(s / 60); a fractional t floors toward minus infinity.",
        True,
    ),
    (
        "day_of_year",
        ["t"],
        add(add(DOY, 60), op("ifelse", JANFEB, -365, ref("civil_leap", x=YOE))),
        "Day of the year 1..366 of the UTC instant t (1 = January 1): doy - 305 in January and February, otherwise doy + 60 plus one in a leap year.",
        True,
    ),
    (
        "julian_day",
        ["t"],
        add(add(D, 2440588), div(add(sub(S_S, cs(43200)), sub(T, FT)), cs(86400))),
        "Julian Date of the UTC instant t, the binary64 formula (d + 2440588) + ((s - 43200) + (t - floor(t))) / 86400, evaluated in that order.",
        True,
    ),
    (
        "is_leap_year",
        ["t"],
        op("ifelse", JANFEB, ref("civil_leap_next", x=YOE), ref("civil_leap", x=YOE)),
        "1 if the proleptic-Gregorian year of the UTC instant t is a leap year (divisible by 4, and not by 100 unless by 400), else 0. The year is congruent modulo 400 to yoe from March to December and to yoe + 1 in January and February.",
        True,
    ),
    (
        "seconds_since_midnight",
        ["t"],
        S_S,
        "Seconds elapsed since the most recent UTC midnight, 0..86399 s, in seconds: floor(t) - 86400 d, the whole second of the day (integer-valued; a fractional t floors toward minus infinity).",
        True,
    ),
    (
        "civil_day_number",
        ["t"],
        fdiv(FT, cs(86400)),
        "Day number d = floor(floor(t) / 86400) of the UTC instant t: days since 1970-01-01, exact.",
        False,
    ),
    (
        "civil_second_of_day",
        ["t"],
        sub(FT, mul(cs(86400), D)),
        "Whole second of the day s = floor(t) - 86400 d, in seconds, in [0, 86399].",
        False,
    ),
    (
        "civil_era",
        ["t"],
        fdiv(add(D, 719468), 146097),
        "The 400-year era of the date, counted from 0000-03-01: floor((d + 719468) / 146097).",
        False,
    ),
    (
        "civil_day_of_era",
        ["t"],
        sub(add(D, 719468), mul(146097, ERA)),
        "Day of the era doe = (d + 719468) - 146097 era, in [0, 146096].",
        False,
    ),
    (
        "civil_year_of_era",
        ["t"],
        fdiv(sub(add(sub(DOE, fdiv(DOE, 1460)), fdiv(DOE, 36524)), fdiv(DOE, 146096)), 365),
        "Year of the era yoe = floor((doe - floor(doe/1460) + floor(doe/36524) - floor(doe/146096)) / 365), in [0, 399]; the years begin on March 1.",
        False,
    ),
    (
        "civil_day_of_year",
        ["t"],
        sub(DOE, sub(add(mul(365, YOE), fdiv(YOE, 4)), fdiv(YOE, 100))),
        "Day of the year counted from March 1, doy = doe - (365 yoe + floor(yoe/4) - floor(yoe/100)), in [0, 365].",
        False,
    ),
    (
        "civil_month_index",
        ["t"],
        fdiv(add(mul(5, DOY), 2), 153),
        "Month counted from March, mp = floor((5 doy + 2) / 153), in [0, 11].",
        False,
    ),
    (
        "civil_is_jan_feb",
        ["t"],
        op(">=", DOY, 306),
        "True in January and February (doy >= 306, March 1 + 306 days), which belong to the year after the year of era.",
        False,
    ),
    (
        "civil_leap",
        ["x"],
        op(
            "ifelse",
            op(
                "and",
                rem_is_zero("x", 4),
                op("or", op("not", rem_is_zero("x", 100)), op("==", "x", 0)),
            ),
            1,
            0,
        ),
        "1 if a year congruent modulo 400 to x, for x in [0, 399], is a leap year, else 0 (divisible by 400 only at x = 0).",
        False,
    ),
    (
        "civil_leap_next",
        ["x"],
        op(
            "ifelse",
            op(
                "and",
                rem_is_zero(add("x", 1), 4),
                op("or", op("not", rem_is_zero(add("x", 1), 100)), op("==", "x", 399)),
            ),
            1,
            0,
        ),
        "1 if the year after a year congruent modulo 400 to x, for x in [0, 399], is a leap year, else 0 (divisible by 400 only for x = 399).",
        False,
    ),
]

DOC = {
    "esm": "2.0.0",
    "metadata": {
        "name": "Calendar",
        "description": "Standard-library calendar templates (esm-spec §9.7.1 template-library file), generated by scripts/gen-lib-calendar.py. Ten public match-less expression templates of one parameter `t`, UTC seconds since 1970-01-01T00:00:00Z (binary64, proleptic Gregorian, no leap seconds): the calendar fields `year(t)`, `month(t)`, `day(t)`, `hour(t)`, `minute(t)`, `second(t)`, `day_of_year(t)`, `julian_day(t)` and `is_leap_year(t)`, and `seconds_since_midnight(t)`. Each splits t exactly into the day number d = floor(floor(t) / 86400) and the whole second of the day s = floor(t) - 86400 d, then runs Howard Hinnant's civil_from_days, every integer division written floor(a / b); each step is a `civil_*` helper template the others call by reference (esm-spec §9.7.3). On the domain |t| < 2^52 s every intermediate is an integer below 2^53, so each floor is exact and each calendar field is exact. Outside that domain, and for NaN or an infinite t, every public template returns NaN. The second-valued constants are unit-bearing `const` nodes (esm-spec §4.8.5), so t is read in seconds; the calendar fields are dimensionless and seconds_since_midnight is in seconds. Import with `expression_template_imports` and invoke with `apply_expression_template`; see docs/content/standard_library.md.",
        "authors": ["EarthSciML"],
        "created": "2026-04-25T00:00:00Z",
        "tags": ["standard-library", "calendar", "datetime", "expression-templates"],
        "references": [
            {
                "citation": "esm-spec.md §9.6 (expression templates); §9.7.1 (template-library files); §9.7.3 (template references in bodies); §4.8.5 (unit-bearing const)."
            },
            {
                "citation": "Hinnant, H., 2013. chrono-Compatible Low-Level Date Algorithms, `civil_from_days`. https://howardhinnant.github.io/date_algorithms.html"
            },
        ],
    },
    "expression_templates": {
        name: {
            "params": params,
            "description": desc + (DOMAIN if public else UNGUARDED),
            "body": guard(body) if public else body,
        }
        for name, params, body, desc, public in TEMPLATES
    },
}


def dumps(o, ind=0, width=100):
    """Two-space indentation, with any value whose one-line form fits `width` on one line."""
    flat = json.dumps(o, ensure_ascii=False)
    if not isinstance(o, (dict, list)) or len(flat) <= width or not o:
        return flat
    pad = "  " * (ind + 1)
    if isinstance(o, list):
        return (
            "[\n" + ",\n".join(pad + dumps(x, ind + 1, width) for x in o) + "\n" + "  " * ind + "]"
        )
    return (
        "{\n"
        + ",\n".join(
            pad + json.dumps(k, ensure_ascii=False) + ": " + dumps(v, ind + 1, width)
            for k, v in o.items()
        )
        + "\n"
        + "  " * ind
        + "}"
    )


def main():
    text = dumps(DOC) + "\n"
    if sys.argv[1:] == ["--check"]:
        if OUT.read_text(encoding="utf-8") != text:
            print(f"{OUT} is stale: run scripts/gen-lib-calendar.py", file=sys.stderr)
            sys.exit(1)
        return
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
