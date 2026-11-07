# Calendar templates (`datetime_templates`)

`lib/calendar.esm` is a template-library file (esm-spec §9.7.1) carrying the
pure-AST definitions of the nine `datetime.*` closed functions as match-less
expression templates of one parameter `t`, UTC seconds: `year`, `month`, `day`,
`hour`, `minute`, `second`, `day_of_year`, `julian_day` and `is_leap_year`. Each
splits `t` exactly into the day number `d = floor(floor(t) / 86400)` and the
whole second of the day `s = floor(t) − 86400·d`, runs Howard Hinnant's
`civil_from_days` with every integer division written `floor(a / b)`, and
returns NaN outside the domain `|t| < 2^52` s (and for a NaN or infinite `t`).
`julian_day` is §9.2's pinned formula. This tier checks, in every binding with an
inline-test runner and under every compiler, that the expanded template
reproduces the `binary64` result the closed function is pinned to.

## The fixtures

The documents live beside the scenarios they apply, and the manifest references
them:

| Fixture | Document | Scenarios |
|---|---|---|
| `<fn>_template`, one per function | `tests/closed_functions/datetime/<fn>/template.esm` | 15 (17 for `julian_day`): the epoch, Feb 29 2000, the last second of Feb 28 2100, Mar 1 2400, Dec 31 2024, one second before the epoch, noon of Jan 1 1900, one subnormal below the epoch, `86399.9999999`, one ulp before a leap day, the first instant after one, half a second before year 0, the first instant of year −4713, one ulp before year −100000, one ulp after the start of year 10000; `julian_day` adds Julian Date 0 and a quarter-day fraction in year −100000 |

Each scenario is one algebraic unknown `r_<scenario>` defined by an
`apply_expression_template` call on a parameter `t_<scenario>` (units `s`) whose
default is the scenario's instant. The model's `tolerance` is `{abs: 0, rel: 0}`,
so each assertion passes only on the exact value of `expected.json`. The golden
is the Julia interpreter's.

## What is not here

- The scenarios outside the domain `|t| < 2^52` s: the two int32-year success
  scenarios (`|t|` about `6.8e16`, where the `fn` form still answers) and the
  `closed_function_overflow` error scenarios (out-of-range years, NaN, ±Inf).
  The template returns NaN for all of them, which JSON cannot write. Each
  binding's harness runs every scenario of `expected.json`, these included, plus
  the domain edges `±(2^52 − 1)`, `±(2^52 − 0.5)` and `±2^52`, through the
  expanded template (Julia: `test/closed_functions_test.jl`).
- `julian_day`'s scenario `jd_plus_0_7_frac`: its `expected` is the correctly
  rounded Julian Date, one ulp from §9.2's pinned formula, which the `fn` form
  and the template both give (the fixture's tolerance admits either). The
  harnesses compare the template with the `fn` form bit for bit there.

## Named exclusions

None. Go and TypeScript are scope-excluded: neither has an inline-test runner.
Each checks the expansion of every template in its closed-function harness.
