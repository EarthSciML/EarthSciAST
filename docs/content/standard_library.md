# ESS Standard Subsystem Library

The `lib/` directory ships ESS subsystems authored entirely in pure AST and the
spec's closed-function registry (`esm-spec.md` §9.2). `lib/solar.esm` is a
self-contained subsystem includable from any consumer model via subsystem
reference (`esm-spec.md` §4.7); `lib/calendar.esm` and `lib/interp.esm` are
template libraries (below), imported rather than mounted:

```json
{
  "subsystems": {
    "Solar": { "ref": "../lib/solar.esm" }
  }
}
```

## Design principle: AST compositions go here, not in the registry

The closed function registry (`esm-spec.md` §9.1) is a deliberately narrow
extension point. A function only belongs there when it is **not expressible in
finite closed form using the §4.2 AST ops and the existing registry entries**
(plus the cross-binding-semantics and no-cleaner-data-loader-path tests).

The registry's v1 set — the `datetime.*` calendar decompositions and
`interp.searchsorted` — gives authors enough primitives that the *common* Earth
science compositions (solar geometry, tabulated lookups, calendar helpers) all
collapse to AST. The standard library is the home for those compositions:
authored once, validated against the spec, and shipped alongside the spec so
that downstream models can include them by reference instead of reimplementing
(and silently disagreeing on) the math.

The bar to add a new file under `lib/` is the inverse of the bar to add a new
registry entry:

| Question | Belongs in `lib/` | Belongs in §9 registry |
|---|---|---|
| Expressible in pure AST + existing §9 entries? | Yes | No |
| Bit-exact across bindings without per-binding code? | Yes (the AST is the contract) | Requires §9.4 conformance fixture |
| New primitive for the spec? | No | Yes — RFC required |

The `call` op and per-file `registered_functions` block are gone (RFC: closed
function registry; spec v0.3.0). When reviewing changes that propose adding
either a new `lib/` file or a new §9 entry, apply the table above.

## Files

| File | Subsystem | Provides | Inputs |
|---|---|---|---|
| [`lib/calendar.esm`](../lib/calendar.esm) | template library (no subsystem) | expression templates `year`, `month`, `day`, `hour`, `minute`, `second`, `day_of_year`, `julian_day`, `is_leap_year` | the template parameter `t` (s) |
| [`lib/solar.esm`](../lib/solar.esm) | `Solar` | `solar_declination` (rad), `equation_of_time` (min), `true_solar_time` (min), `hour_angle` (rad), `cos_zenith`, `solar_zenith_angle` (rad) | `t_utc` (s), `lat` (deg), `lon` (deg) |
| [`lib/interp.esm`](../lib/interp.esm) | template library (no subsystem) | expression templates `searchsorted`, `linear`, `bilinear` | the template parameters (arrays, query, axis lengths) |

### `lib/calendar.esm`

A template-library file (`esm-spec.md` §9.7.1), like `lib/interp.esm`: nine
match-less expression templates, one per `datetime.*` closed function of §9.2,
each of one parameter `t` — UTC seconds since 1970-01-01T00:00:00Z (binary64,
proleptic Gregorian, no leap seconds). A component imports the templates it
needs and applies them:

```json
{
  "expression_template_imports": [
    { "ref": "../lib/calendar.esm", "only": ["hour", "minute", "second"] }
  ],
  "equations": [
    {
      "lhs": "hour_utc",
      "rhs": { "op": "apply_expression_template", "args": [], "name": "hour",
               "bindings": { "t": "t_utc" } }
    }
  ]
}
```

| Template | Value |
|---|---|
| `year` | proleptic-Gregorian year, astronomical numbering (0 = 1 BC) |
| `month` | 1..12 |
| `day` | day of month, 1..31 |
| `hour`, `minute`, `second` | UTC clock fields, 0..23 and 0..59 (no leap-second slot); a fractional `t` floors toward −∞ |
| `day_of_year` | 1..366 (1 = January 1) |
| `julian_day` | the Julian Date, by §9.2's pinned binary64 formula `(d + 2440588) + ((s − 43200) + (t − floor(t))) / 86400` |
| `is_leap_year` | 1 for a leap year, else 0 |

Each body splits `t` exactly into the day number `d = floor(floor(t) / 86400)`
and the whole second of the day `s = floor(t) − 86400·d`, then runs Howard
Hinnant's `civil_from_days` (400-year eras counted from 0000-03-01, the day of
the era, the year of the era, the day of the year from March 1, the month from
`(5·doy + 2) / 153`), every integer division written `floor(a / b)`; §9.2's
composition note gives the formulas. **Domain:** finite `t` with `|t| < 2^52`
s, about ±142 million years. There every intermediate is an integer below
`2^53`, so each `floor` is exact and each template gives the same bits as the
matching `fn` form; outside it, and for a NaN or infinite `t`, every template
returns NaN (the `fn` forms answer up to the signed 32-bit year range and raise
`closed_function_overflow` beyond it). Each binding's closed-function harness runs every
scenario of `tests/closed_functions/datetime/*/expected.json` through the
expanded templates, and `tests/closed_functions/datetime/*/template.esm`
carries a subset as inline tests for the cross-binding `datetime_templates`
conformance tier.

The fields are dimensionless numbers (`hour` is the count 14, not a duration of
14 hours), `julian_day` included. The template bodies divide `t` by
unit-bearing `const` nodes in seconds (§4.8.5), so a `t` declared in seconds
validates cleanly, one in hours is a scale mismatch, and a dimensionless one
is a dimension mismatch. A consumer that wants a quantity multiplies by its own
conversion factor, as `lib/solar.esm` does with `rad_per_day` and
`min_of_clock`.

The templates replace the earlier `Calendar` subsystem, which wrapped the `fn`
calls in equations and also defined `seconds_since_midnight` and
`fractional_year`; a template library cannot declare a model. Those two helpers
are one line each over the templates (`fractional_year` is `gamma` in
`lib/solar.esm`).

### `lib/solar.esm`

The NOAA Spencer-Fourier solar-position model. `solar_declination` and
`equation_of_time` are 5- and 7-term Fourier series in the fractional-year
angle γ; `solar_zenith_angle` then composes lat/lon and the NOAA hour-angle
formula. It imports the `day_of_year`, `hour`, `minute` and `second`
templates of `lib/calendar.esm` for its calendar fields, so a mount of
`lib/solar.esm` resolves that import beside it (§4.7 edge pipeline). Every
constant is a binary64 literal, so the result is bit-defined relative to the
calendar templates (which give the §9.2 `datetime.*` values) and the §4.2
elementary-function ops; for `|t_utc| ≥ 2^52` s the outputs are NaN. Cross-binding tolerance is ≤ 10 ulp,
within the algorithm's intrinsic ~2 arcminute accuracy.

To use:

```json
{
  "esm": "1.0.0",
  "models": {
    "MyChem": {
      "subsystems": {
        "Solar": { "ref": "../lib/solar.esm" }
      },
      "variables": {
        "j_NO2": { "type": "unknown", "units": "1/s" }
      },
      "equations": [
        { "lhs": "j_NO2",
          "rhs": { "op": "*", "args": [
            "k_NO2",
            { "op": "cos", "args": ["Solar.solar_zenith_angle"] }
          ] } }
      ]
    }
  }
}
```

### `lib/interp.esm`

Like `lib/calendar.esm`, `lib/interp.esm` is a template-library file
(`esm-spec.md` §9.7.1), not a subsystem: it declares three match-less
expression templates and no model. A component imports it with
`expression_template_imports` and calls a template with
`apply_expression_template` (§9.6.2); a template-library file cannot be
mounted as a subsystem.

```json
{
  "expression_template_imports": [{ "ref": "../lib/interp.esm" }],
  "equations": [
    {
      "lhs": "k_photo",
      "rhs": {
        "op": "apply_expression_template", "args": [], "name": "linear",
        "bindings": {
          "table": { "op": "const", "args": [], "value": [1.0e-5, 4.0e-5, 9.0e-5] },
          "axis":  { "op": "const", "args": [], "value": [0.0, 0.5, 1.0] },
          "x": "cos_zenith",
          "n": 3
        }
      }
    }
  ]
}
```

The three templates are the pure-AST definitions of the `interp.*` closed
functions of §9.2, written with `faq` comparison counts, the `index` op and
arithmetic. Each axis length is an explicit integer parameter, used as the
upper bound of a `faq` dense `ranges` entry (a substitution site, §9.6.1):

| Template | Parameters | Value |
|---|---|---|
| `searchsorted` | `x`, `xs`, `n` | `1 + Σ_{k=1..n} ifelse(xs[k] ≥ x, 0, 1)`: the first index with `xs[k] ≥ x`; `n + 1` when there is none, or `x` is NaN; `1` for `n = 0` |
| `linear` | `table`, `axis`, `x`, `n` | flat outside the axis; inside, `i = min(max(Σ_k ifelse(axis[k] ≤ x, 1, 0), 1), n − 1)` and `table[i] + w·(table[i+1] − table[i])` with `w = (x − axis[i]) / (axis[i+1] − axis[i])` |
| `bilinear` | `table`, `axis_x`, `axis_y`, `x`, `y`, `nx`, `ny` | each query clamped to its axis, the cell on each axis found by the same count, then the two x-blends and the y-blend in §9.2's order |

The evaluation order of each body is the one §9.2 pins for the matching
function, including the interior-knot convention of `bilinear` (a clamped
query on interior knot `k` selects cell `k`, so the weight is `0`). On every
success scenario of `tests/closed_functions/interp/*/expected.json` the
expanded template gives the same bits as the `fn` form, NaN queries included;
the Julia harness (`test/closed_functions_test.jl`) checks this scenario by
scenario, and `tests/closed_functions/interp/*/template.esm` carries a subset
as inline tests for the cross-binding `interp_templates` conformance tier.
The templates do not repeat the load-time axis checks of the `fn` form (a
non-monotonic or NaN axis is not rejected); the caller supplies a valid axis.

## Validation and conformance

Each `lib/*.esm` is a schema-valid file under `esm-schema.json`, swept by every
binding's validation corpus. `tests/valid/lib_solar_subsystem_inclusion.esm`
mounts `lib/solar.esm` (and through it imports `lib/calendar.esm`), and the
`template.esm` documents under `tests/closed_functions/` apply the calendar
and interpolation templates. Cross-binding numerical agreement is enforced by the
per-function conformance fixtures under `tests/closed_functions/` (see
`esm-spec.md` §9.4); the lib subsystems are AST compositions of those
primitives and inherit their tolerance contracts.

## Adding a new lib subsystem

1. Identify a composition that recurs across model components (e.g.,
   atmospheric standard-pressure profile, saturation vapor pressure) and is
   expressible in AST + the §9.2 registry.
2. Author `lib/<name>.esm` as a single self-contained subsystem, with
   parameter inputs and unknown outputs defined by equations.
3. Document it in this file, including units, references, and the
   composition's algebraic form.
4. Add a fixture under `tests/valid/lib_<name>_inclusion.esm` exercising
   subsystem inclusion.
5. If the composition turns out to require a primitive not yet in §9.2, file
   an RFC against `esm-spec.md` §9 *before* adding the lib entry — the lib is
   not a back door for closed-registry growth.
