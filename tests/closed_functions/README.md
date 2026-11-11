# Closed-function scenarios — reference data for the standard-library templates

At esm 2.0.0 the `fn` op and its closed function registry were removed; the
`datetime.*` and `interp.*` functions are now the pure-AST templates of
`lib/calendar.esm` and `lib/interp.esm` (`esm:std/calendar.esm`,
`esm:std/interp.esm`). The `expected.json` files here stay as the pinned
`binary64` reference values those templates must reproduce (esm-spec 1.x §9.2
pinned them for the functions), and each directory's `template.esm` applies the
template to a subset of the scenarios. 1.x documents that called the functions
are converted with `python -m earthsci_ast.migrate`.

## Layout

```
tests/closed_functions/
├── datetime/
│   ├── year/                 (year — proleptic-Gregorian year)
│   │   ├── expected.json     (input vectors + expected outputs + tolerance)
│   │   └── template.esm      (the lib/calendar.esm template on a subset of the scenarios)
│   ├── month/                (month; each datetime/<fn>/ has the same two files)
│   ├── day/                  (day)
│   ├── hour/                 (hour)
│   ├── minute/               (minute)
│   ├── second/               (second)
│   ├── day_of_year/          (day_of_year)
│   ├── julian_day/           (julian_day)
│   └── is_leap_year/         (is_leap_year)
└── interp/
    ├── searchsorted/         (searchsorted)
    │   ├── expected.json
    │   └── template.esm      (the lib/interp.esm template on a subset of the scenarios)
    ├── linear/               (linear — 1-D tensor interpolation)
    │   ├── expected.json
    │   └── template.esm
    └── bilinear/             (bilinear — 2-D tensor interpolation)
        ├── expected.json
        └── template.esm
```

Each `interp/<fn>/template.esm` imports `lib/interp.esm` (the pure-AST
templates `searchsorted`, `linear`, `bilinear`) and applies the template to
scenarios of the sibling `expected.json`, asserting each value exactly in an
inline test. The `interp_templates` conformance tier
(`tests/conformance/interp_templates/`) runs those documents in every binding
with an inline-test runner.

Each `datetime/<fn>/template.esm` likewise imports `lib/calendar.esm` (the nine
pure-AST templates `year`, `month`, `day`, `hour`, `minute`, `second`,
`day_of_year`, `julian_day`, `is_leap_year`, each of one parameter `t`) and
applies the template to scenarios of the sibling `expected.json` inside the
templates' domain `|t| < 2^52` s; the `datetime_templates` tier
(`tests/conformance/datetime_templates/`) runs them. Outside that domain (the
two int32-year success scenarios, the `closed_function_overflow` scenarios) the
templates return NaN.

The full scenario sets, NaN queries and out-of-domain instants included, are
evaluated against the template contract of esm-spec §9.8 by three harnesses:
Python `pkg/earthsci-ast-py/tests/test_template_scenarios.py` (scalar
interpreter), Julia `pkg/EarthSciAST.jl/test/template_scenarios_test.jl` and
Rust `pkg/earthsci-ast-rs/tests/template_scenarios.rs` (interpreter and
native). Every interp success scenario must match bit for bit. Every datetime
instant, `error_scenarios` included, must give the scenario's `expected` inside
`|t| < 2^52` s and NaN outside it, and the domain edges `±(2^52 − 1)` and
`±(2^52 − 0.5)` are checked against an exact integer calendar computation in
the test, `±2^52` against NaN. Go and TypeScript cannot evaluate a `faq`, so
the Go suite checks the expansion of every scenario instead.

## `expected.json` schema

```jsonc
{
  "function": "datetime.year",                    // dotted module path
  "tolerance": { "abs": 0, "rel": 0 },            // per esm-spec §9.2
  "scenarios": [
    {
      "name": "epoch",                            // human-readable label
      "description": "Unix epoch — 1970-01-01T00:00:00Z",
      "inputs": [ 0.0 ],                          // positional args
      "expected": 1970                            // scalar (number) or array
    }
  ],
  "error_scenarios": [                            // calls that MUST fail
    {
      "name": "nonfinite_nan",
      "inputs": [ "NaN" ],                        // "NaN" / "Inf" / "-Inf" strings
      "expected_error_code": "closed_function_overflow"
    }
  ]
}
```

JSON has no NaN or infinity, so a non-finite input or expected value is
written as the string `"NaN"`, `"Inf"` or `"-Inf"`.

## What bindings MUST do

For each `expected.json`, run every success scenario through the expanded
template and assert the result agrees with `expected` within the declared
`tolerance` (the `interp_templates` and `datetime_templates` tiers run the
`template.esm` documents, which hold the scenarios JSON can write).
The `error_scenarios` record the checks the removed `fn` op made on its
arguments; the templates do not repeat them. The datetime ones are instants
outside the templates' domain and must give NaN; the interp ones are invalid
tables (non-monotonic axis, NaN in an axis, length mismatch), for which the
templates have no contract, so a binding does not run them.

## Boundary-case coverage

The scenario sets cover the boundary semantics esm-spec 1.x §9.2 pinned for
the functions:

- **Leap-year edges**: 2000 (div by 400), 2100 (div by 100, not 400),
  2400 (div by 400) — the trio that catches naïve `year % 4` implementations.
- **Calendar boundaries**: Feb 29 / Mar 1 transitions, year-end, day-of-year
  rollover (especially day 366 in leap years).
- **Pre-epoch (negative `t_utc`)**: 1969-12-31, 1900-01-01 — extends the
  proleptic-Gregorian calendar backwards without modification.
- **Sub-second / fractional days**: julian_day is the only calendar field
  with fractional output; its scenarios pin the noon-UTC offset.
- **julian_day before -4800-03-01**: the standard Julian Date, where the
  informative Fliegel–van Flandern formula is off by +1, -1 or -2 days, and
  around Julian Date 0.
- **Overflow**: the 1.x `datetime.*` functions raised `closed_function_overflow`
  one instant past each end of the Int32 year range and for NaN / ±Inf; the
  templates return NaN there.
  The `datetime.*` fixtures are generated by `scripts/gen-datetime-fixtures.py`
  (exact rational arithmetic; `--check` in CI).
- **searchsorted**: empty array (`xs = []` returns 1, ruling Q-108), single element, duplicates, exact-on-
  boundary, x ≤ xs[1], x > xs[N], NaN x, NaN-in-xs (error), non-monotonic
  xs (error).
- **linear / bilinear**: exact-at-knot (every position),
  midpoint and quarter-point blends, below/above each axis (extrapolate-
  flat), NaN x or y (NaN out), minimal-size grid (N=2 / 2x2), non-uniform
  axis spacing. Load-time error scenarios cover non-monotonic axis,
  equal-adjacent axis, axis-table length mismatch (and ragged rows for
  bilinear), NaN in axis, single-element axis, and a `const` table or
  axis of the wrong rank (`interp_table_not_const` /
  `interp_axis_not_const`, ruling Q-108; `[]` as a bilinear table is
  rank 1, ruling Q-111), a ±Inf axis entry (`interp_nan_in_axis`, ruling
  Q-113), and calls that break two adjacent rules of the pinned order
  (ruling Q-110).
