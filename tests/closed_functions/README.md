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
│   ├── year/                 (datetime.year — proleptic-Gregorian year)
│   │   ├── expected.json     (input vectors + expected outputs + tolerance)
│   │   └── template.esm      (the lib/calendar.esm template on a subset of the scenarios)
│   ├── month/                (datetime.month; each datetime/<fn>/ has the same two files)
│   ├── day/                  (datetime.day)
│   ├── hour/                 (datetime.hour)
│   ├── minute/               (datetime.minute)
│   ├── second/               (datetime.second)
│   ├── day_of_year/          (datetime.day_of_year)
│   ├── julian_day/           (datetime.julian_day)
│   └── is_leap_year/         (datetime.is_leap_year)
└── interp/
    ├── searchsorted/         (interp.searchsorted)
    │   ├── expected.json
    │   └── template.esm      (the lib/interp.esm template on a subset of the scenarios)
    ├── linear/               (interp.linear — 1-D tensor interpolation)
    │   ├── expected.json
    │   └── template.esm
    └── bilinear/             (interp.bilinear — 2-D tensor interpolation)
        ├── expected.json
        └── template.esm
```

Each `interp/<fn>/template.esm` imports `lib/interp.esm` (the pure-AST
templates `searchsorted`, `linear`, `bilinear`) and applies the template to
scenarios of the sibling `expected.json`, asserting each value exactly in an
inline test. The `interp_templates` conformance tier
(`tests/conformance/interp_templates/`) runs those documents in every binding
with an inline-test runner. Each binding's harness additionally runs every
success scenario, NaN queries included, through the expanded template and
asserts the same bits as the `fn` form.

Each `datetime/<fn>/template.esm` likewise imports `lib/calendar.esm` (the nine
pure-AST templates `year`, `month`, `day`, `hour`, `minute`, `second`,
`day_of_year`, `julian_day`, `is_leap_year`, each of one parameter `t`) and
applies the template to scenarios of the sibling `expected.json` inside the
templates' domain `|t| < 2^52` s; the `datetime_templates` tier
(`tests/conformance/datetime_templates/`) runs them. Each binding's harness runs
every scenario, the error scenarios included, through the expanded template:
inside the domain it must give the `fn` form's bits, outside it (the two
int32-year success scenarios, the `closed_function_overflow` scenarios) NaN.
Julia, Python and Rust check the value; TypeScript and Go check the expansion.

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
`template.esm` documents; each binding's harness runs the full scenario sets).
The `error_scenarios` record the load-time checks the removed `fn` op made on
its arguments; the templates do not repeat them, and a binding no longer runs
them.

## Boundary-case coverage

The scenario sets cover the boundary semantics pinned in esm-spec §9.2:

- **Leap-year edges**: 2000 (div by 400), 2100 (div by 100, not 400),
  2400 (div by 400) — the trio that catches naïve `year % 4` implementations.
- **Calendar boundaries**: Feb 29 / Mar 1 transitions, year-end, day-of-year
  rollover (especially day 366 in leap years).
- **Pre-epoch (negative `t_utc`)**: 1969-12-31, 1900-01-01 — extends the
  proleptic-Gregorian calendar backwards without modification.
- **Sub-second / fractional days**: julian_day is the only registry entry
  with fractional output; its scenarios pin the noon-UTC offset.
- **julian_day before -4800-03-01**: the standard Julian Date, where the
  informative Fliegel–van Flandern formula is off by +1, -1 or -2 days, and
  around Julian Date 0.
- **Overflow**: every `datetime.*` function raises `closed_function_overflow`
  one instant past each end of the Int32 year range and for NaN / ±Inf.
  The `datetime.*` fixtures are generated by `scripts/gen-datetime-fixtures.py`
  (exact rational arithmetic; `--check` in CI).
- **searchsorted**: empty array (`xs = []` returns 1, ruling Q-108), single element, duplicates, exact-on-
  boundary, x ≤ xs[1], x > xs[N], NaN x, NaN-in-xs (error), non-monotonic
  xs (error).
- **interp.linear / interp.bilinear**: exact-at-knot (every position),
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
