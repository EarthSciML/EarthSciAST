# Closed Function Registry — User Guide

ESS expression trees can invoke a small, **closed** set of named functions
through the `fn` AST op. This page is the user-facing summary; the normative
references are:

- `esm-spec.md` §9 — the full registry definition (signatures, boundary
  semantics, tolerances, error codes).
- `docs/rfcs/closed-function-registry.md` — the design RFC and migration
  plan (covers why the registry is closed and how new entries are added).

For authoring guidance ("when to use `fn` vs. AST ops") see the §1.1 policy
paragraph in `esm-spec.md` and the §9.2 "Why this list" subsection.

## Why "closed"?

ESS targets bit-exact-where-possible cross-language conformance across five
bindings (Julia, Rust, Python, Go, TypeScript). Any extension point that lets
authors register handlers per-binding defeats that goal: each binding ends up
with its own implementation of "the function" and silently disagrees on edge
cases. The registry is therefore **closed by construction**: bindings MUST
reject `fn`-op nodes whose `name` is not in the spec-defined v0.3.0 set, with
diagnostic code `unknown_closed_function`.

Adding a primitive requires a spec rev and follows the addition process in
`docs/rfcs/closed-function-registry.md` §7.

## v0.3.0 set

### `datetime.*` — calendar decomposition

All entries take a single scalar `t_utc` argument: IEEE-754 `binary64` UTC
seconds since the Unix epoch (1970-01-01T00:00:00Z, proleptic Gregorian, **no
leap-second consultation** — the deliberate cross-binding contract). Integer
outputs are signed 32-bit; bindings raise `closed_function_overflow` if a
result would overflow.

| Name | Return | Range | Example (`t_utc=0`) |
|---|---|---|---|
| `datetime.year`         | integer | proleptic-Gregorian year | `1970` |
| `datetime.month`        | integer | 1..12 (1 = January)      | `1` |
| `datetime.day`          | integer | 1..31 (day of month)     | `1` |
| `datetime.hour`         | integer | 0..23                    | `0` |
| `datetime.minute`       | integer | 0..59                    | `0` |
| `datetime.second`       | integer | 0..59 (no leap-second)   | `0` |
| `datetime.day_of_year`  | integer | 1..366 (1 = Jan 1)       | `1` |
| `datetime.julian_day`   | float   | continuous JDN incl. fractional time-of-day | `2440587.5` |
| `datetime.is_leap_year` | integer | 0 or 1                   | `0` |

Negative `t_utc` (pre-1970) is supported and decomposes against the
proleptic-Gregorian calendar (e.g. `datetime.year(-2208988800.0) == 1900`).

Tolerance: integer outputs are exact (zero error). `datetime.julian_day`
agrees to ≤ 1 ulp; the only floating-point operation in the reference
computation is the final divide-by-86400 for the fractional-day offset.

### `interp.*` — search

| Name | Arity | Args | Return |
|---|---|---|---|
| `interp.searchsorted` | 2 | `x: scalar, xs: const array[N]` | integer (1..N+1) |

Returns the smallest 1-based `i` with `xs[i] ≥ x` (Julia
`searchsortedfirst` semantics). Boundary rules:

- `x ≤ xs[1]` → `1`
- `x > xs[N]` → `N + 1`
- NaN `x` → `N + 1` (treated as "greater than every finite element")
- `xs` MUST be non-decreasing; non-monotonic xs raises
  `searchsorted_non_monotonic`.
- NaN entries in `xs` raise `searchsorted_nan_in_table`.

`interp.searchsorted` composes with the existing `index` op (§4.3.3) to
express tabulated lookups. Linear blends between adjacent table entries
are written in AST (subtract neighboring `index`-ed values, multiply by a
fractional weight, add). There is no `interp.linear_1d` in v1; it is
recoverable from `searchsorted` + `index` + AST arithmetic.

## Worked example — solar zenith angle approximation via tabulated lookup

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "PhotolysisDriver" },
  "models": {
    "Photo": {
      "variables": {
        "doy":  { "type": "unknown" },
        "j_o3": { "type": "unknown" }
      },
      "equations": [
        { "lhs": "doy",
          "rhs": { "op": "fn", "name": "datetime.day_of_year", "args": ["t"] } },
        { "lhs": "j_o3", "rhs": {
          "op": "index",
          "args": [
            { "op": "const", "args": [], "value": [1.0e-2, 9.0e-3, 7.8e-3, 4.0e-3, 0.0] },
            {
              "op": "fn",
              "name": "interp.searchsorted",
              "args": [
                "doy",
                { "op": "const", "args": [], "value": [1.0, 90.0, 180.0, 270.0, 366.0] }
              ]
            }
          ]
        }}
      ]
    }
  }
}
```

Here the `fn` op is used twice: once to extract day-of-year from the
simulation's UTC time `t`, and once to find the table-row index in a coarse
seasonal lookup. The actual J(O₃) value is then read out via the `index` op.

## Cross-binding conformance

Every entry in the registry ships with conformance fixtures under
`tests/closed_functions/<module>/<name>/`. Each binding's test harness
loads the canonical `.esm` (which exercises the `fn` op parser) and walks
the scenarios in `expected.json`, asserting agreement at the spec
tolerance. `scripts/test-conformance.sh` runs the fixtures across all five
bindings on every PR.

## Migration from v0.2.x

The `call` op + `registered_functions` block (esm-spec v0.2.x) was removed
in v0.3.0. Most production usage rewrites to AST equations; the few
fixtures that drove the now-removed extension point are listed in
`docs/rfcs/closed-function-registry.md` §6.3 and migrate per the worked
examples in RFC §9.

The `operators` block was likewise removed: state-mutating numerical
schemes are now expressed via PDE operators in equations + named entries in
the `discretizations` block (`docs/rfcs/discretization.md` §7).

## Adding a new function

The bar is high: the proposal MUST clear all three:

1. Not expressible in finite closed form using existing AST ops.
2. Has well-defined cross-binding semantics (formulas, edge cases, tolerance).
3. There is no cleaner `data_loaders` path.

See `docs/rfcs/closed-function-registry.md` §7 for the addition process,
deprecation policy, and compatibility-matrix discipline.
