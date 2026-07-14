# ESS Standard Subsystem Library

The `lib/` directory ships ESS subsystems authored entirely in pure AST and the
spec's closed-function registry (`esm-spec.md` §9.2). Each file is a self-contained
subsystem includable from any consumer model via subsystem reference (`esm-spec.md`
§4.7):

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
| [`lib/calendar.esm`](../lib/calendar.esm) | `Calendar` | `year`, `month`, `day`, `hour`, `minute`, `second`, `day_of_year`, `julian_day`, `is_leap_year`, `seconds_since_midnight`, `fractional_year` | `t_utc` (s) |
| [`lib/solar.esm`](../lib/solar.esm) | `Solar` | `solar_declination` (rad), `equation_of_time` (min), `true_solar_time` (min), `hour_angle` (rad), `cos_zenith`, `solar_zenith_angle` (rad) | `t_utc` (s), `lat` (deg), `lon` (deg) |
| [`lib/interp.esm`](../lib/interp.esm) | `Interp` | `y_linear` — worked example of 1-D linear interpolation | `x` |

### `lib/calendar.esm`

A thin AST veneer over the §9.2 `datetime.*` registry: each calendar field is
exposed as an observed variable so that consumers can scope-reference
`Calendar.day_of_year`, `Calendar.hour`, etc. via §4.6 dot notation. Two
helpers are defined as compositions:

- `seconds_since_midnight = hour·s_per_hour + minute·s_per_minute + second·s_per_second`
  (integer-exact; the factors are 3600, 60 and 1).
- `fractional_year` — the NOAA solar-position γ angle (radians), defined in
  the file's docstring; reused inside `lib/solar.esm`.

**Why the conversion factors are named parameters.** The clock fields (`hour`,
`minute`, `second`, `day_of_year`, …) are *dimensionless integer calendar field
values* — `hour` is the integer 14, not a duration of 14 hours — exactly as
`month` and `day` are. The seconds and radians therefore have to be carried by
the conversion constants (`s_per_hour`, `rad_per_day`, …), which is what makes
`seconds_since_midnight` (s) and `fractional_year` (rad) dimensionally
well-formed under esm-spec §4.8.3. Annotating the clock fields with time units
instead would be *wrong*, not merely different: `fractional_year`'s bracket
`(day_of_year - 1) + (hour - 12)/24` is a dimensionless day count, so an `hour`
in hours would make it add a time to a pure number.

### `lib/solar.esm`

The NOAA Spencer-Fourier solar-position model. `solar_declination` and
`equation_of_time` are 5- and 7-term Fourier series in the fractional-year
angle γ; `solar_zenith_angle` then composes lat/lon and the NOAA hour-angle
formula. The file is approximately 100 lines of AST; every constant is a
binary64 literal so the result is bit-defined relative to the §9.2 registry
and the §4.2 elementary-function ops. Cross-binding tolerance is ≤ 10 ulp,
within the algorithm's intrinsic ~2 arcminute accuracy.

To use:

```json
{
  "esm": "0.3.0",
  "models": {
    "MyChem": {
      "subsystems": {
        "Solar": { "ref": "../lib/solar.esm" }
      },
      "variables": {
        "j_NO2": { "type": "observed", "units": "1/s",
                   "expression": { "op": "*", "args": [
                     "k_NO2",
                     { "op": "cos", "args": ["Solar.solar_zenith_angle"] }
                   ] } }
      }
    }
  }
}
```

### `lib/interp.esm`

A copy-paste template for 1-D linear interpolation. The closed registry
deliberately ships only `interp.searchsorted` because the rest of the
linear-interp recipe — bracket index, fractional weight, blend — is pure AST
and depends on the caller's `xs`/`ys` arrays. `lib/interp.esm` shows the
canonical assembly with a small inline table; consumers copy the variable
definitions and substitute their own `xs`, `ys`, and query variable.

The recipe (one line per AST node):

```text
i_raw = searchsorted(xs, x)             # 1-based, may be 1 or N+1
i     = min(N, max(2, i_raw))           # clamp so i-1 and i are valid indices
t_raw = (x - xs[i-1]) / (xs[i] - xs[i-1])
t     = clamp(t_raw, 0, 1)              # constant-value extrapolation
y     = ys[i-1] + t * (ys[i] - ys[i-1])
```

Bilinear (2-D) interpolation follows the same pattern with two
`searchsorted` lookups and a 4-point bilinear blend over the 2-D table; it is
left as an exercise (and as a future addition to `lib/interp.esm` once a
real-model use case lands).

## Validation and conformance

Each `lib/*.esm` is a schema-valid file under `esm-schema.json` and is exercised
by the `tests/valid/` parse-and-load suite via the `tests/valid/lib_*.esm`
inclusion fixtures. Cross-binding numerical agreement is enforced by the
per-function conformance fixtures under `tests/closed_functions/` (see
`esm-spec.md` §9.4); the lib subsystems are AST compositions of those
primitives and inherit their tolerance contracts.

## Adding a new lib subsystem

1. Identify a composition that recurs across model components (e.g.,
   atmospheric standard-pressure profile, saturation vapor pressure) and is
   expressible in AST + the §9.2 registry.
2. Author `lib/<name>.esm` as a single self-contained subsystem, with
   parameter-typed inputs and observed-typed outputs.
3. Document it in this file, including units, references, and the
   composition's algebraic form.
4. Add a fixture under `tests/valid/lib_<name>_inclusion.esm` exercising
   subsystem inclusion.
5. If the composition turns out to require a primitive not yet in §9.2, file
   an RFC against `esm-spec.md` §9 *before* adding the lib entry — the lib is
   not a back door for closed-registry growth.
