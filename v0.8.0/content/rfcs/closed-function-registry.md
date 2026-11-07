# Closed function registry — removing `call` and §9 from the spec (esm-tzp)

This RFC closes the two open extension points in `esm-spec.md` that defeat
ESS's cross-language conformance goal:

1. **`call` op** in expressions (§4.2 + §4.4) backed by **§9.2 Registered
   Functions** — arbitrary handler IDs whose semantics live in each binding,
   not in the spec.
2. **§9.1 Operators** — "registered by type rather than fully specified, since
   their implementation is inherently tied to the discretization and runtime."

Both shift correctness onto per-binding registration, which is the source of
drift the conformance suite repeatedly trips on (cf. `gt-b13f`-class fixtures).
The ESM audit (`mdl-7e6` close note) found 0 `call` ops in production `.esm`
files, so removing the extension point is realistic *now*, before user code
accumulates around it.

**This RFC is normative for spec authors.** It defines (a) the replacement
mechanism, (b) the initial closed function set, (c) the migration plan for
existing `call` / §9 usage, and (d) the addition process for future entries.
The actual spec text edits and per-binding implementation work happen in
follow-on beads listed in §10.

## Scope

In scope:
- Removing `call` op (§4.2, §4.4) and `registered_functions` (§9.2).
- Replacing them with a closed, spec-defined function registry (this RFC's §3–§5).
- Migrating §9.1 Operators in two tracks: pure parameterizations re-expressed as
  closed functions; state-mutating numerical schemes promoted to a
  spec-versioned identifier set (this RFC's §6).

Out of scope:
- §5.5 Functional Affects (event handlers; separate registry, separate
  cross-language constraints — file separately if motivated).
- Built-in math operators in §4.2 (arithmetic / elementary / conditional /
  array — these stay).
- AST evaluator changes (already shipped: `gt-b13f`, `esm-uun`).
- The discretization machinery itself (`docs/rfcs/discretization.md`,
  `grid-trait.md`).

## 1. Motivation

ESS targets bit-exact-where-possible cross-language conformance across five
bindings (Julia, Rust, Python, Go, TypeScript). The current spec opens two
holes that the conformance harness cannot close from outside:

- A `call` node says "evaluate this function whose body is not in the file."
  The five bindings each ship their own handler implementation; nothing in
  the spec makes them agree on edge cases (NaN propagation, extrapolation,
  table boundary behavior). The escape hatch costs us correctness.
- §9.1 operators have the same problem one level up: each binding implements
  `WesleyDryDep` against its own discretization, with no spec-level
  description of what the operator is *supposed* to do.

A closed registry — every entry fully specified in the spec, including
boundary semantics and tolerance — restores the invariant that an `.esm` file
plus the spec version uniquely determines numerical behavior.

## 2. Resolved decisions (overseer, 2026-04-25)

These are settled and not re-litigated below; the RFC builds on them.

1. **Namespace:** sub-modules. Functions live under `datetime.*`, `interp.*`,
   `lookup.*`, etc. Flat names are not used.
2. **Lookup indices:** integer indices in functions; the `.esm` file carries
   an `enums` block for symbol → integer mapping. Bindings only see integers
   post-resolution.
3. **Tolerance:** global rule "≤ 1 ulp where math allows; exceptions listed
   per function." Transcendentals and composed trig (e.g.
   `solar_zenith_angle`) carry explicit looser bounds in their per-function
   entries.
4. **Inline table size cap:** soft. Linters warn at >1024 entries or >8 KB
   inline JSON; above the cap, authors use `data_loaders`. No spec-level
   rejection.
5. **Migration policy:** option (c). Sweep all `call`-op + §9 usage in this
   RFC's follow-on PRs and ship the spec rev without extension points in the
   same minor release. No deprecation window.

## 3. Replacement mechanism

### 3.1 New top-level field: `enums`

```json
{
  "enums": {
    "land_use_class": {
      "urban": 1,
      "agricultural": 2,
      "deciduous_forest": 3,
      "coniferous_forest": 4,
      "mixed_forest": 5,
      "shrubland": 6,
      "grassland": 7,
      "wetland": 8,
      "water": 9,
      "barren": 10,
      "snow_ice": 11
    },
    "season": {
      "winter": 1,
      "spring": 2,
      "summer": 3,
      "autumn": 4
    }
  }
}
```

Each `enums` entry is a string→integer map (any integer). Symbols are file-local;
two `.esm` files can define `season` independently with different mappings.
References inside expressions use the symbolic name; bindings resolve to the
integer at load time before invoking any closed-function handler.

Enum references in expressions are written `{"op": "enum", "args": ["season",
"summer"]}` and lower to a constant integer at load time. Bindings MUST
reject references to undeclared enums or undeclared symbols within an enum.

### 3.2 New AST op: `fn`

The `call` op (handler-by-string) is replaced by the `fn` op
(spec-fixed-name):

| Op | Required extra fields | Meaning |
|---|---|---|
| `fn` | `name` | Invoke a spec-defined closed function. `name` is a dotted module path (e.g. `"datetime.solar_zenith_angle"`). `args` are the evaluated argument expressions, passed positionally. |

The set of valid `name` values is **closed** and enumerated in §4 of this
RFC. Bindings MUST reject `fn` nodes whose `name` is not in the closed set
for the file's declared `esm` version. There is no per-file `registered_functions`
block; there is no handler ID lookup.

Example — solar zenith angle:

```json
{
  "op": "fn",
  "name": "datetime.solar_zenith_angle",
  "args": ["lat", "lon", "t"]
}
```

Example — 1D linear interpolation against an inline table:

```json
{
  "op": "fn",
  "name": "interp.linear_1d",
  "args": [
    "sza",
    {"op": "const", "value": [0.0, 0.087, 0.175, 0.349, 0.524, 0.698, 0.873, 1.047, 1.221, 1.396, 1.571]},
    {"op": "const", "value": [1.0e-2, 9.8e-3, 9.0e-3, 7.8e-3, 6.0e-3, 4.0e-3, 2.0e-3, 5.0e-4, 1.0e-4, 1.0e-5, 0.0]}
  ]
}
```

The `const` op (existing) carries inline numeric arrays; this is how lookup
data arrives at the function without a side channel.

### 3.3 What is *not* needed anymore

- **§4.4 `call` op section**: removed. The `fn` op replaces it with a closed
  vocabulary.
- **§9.2 `registered_functions` block**: removed. There is no
  authoring-supplied handler registry; everything is spec-defined.
- **`registered_functions` in §2 top-level structure**: removed.
- The `pure_math.esm`-style "register `sq(x) = x²` to exercise the round-trip
  path" fixture: superseded; the `^` op already exercises round-trip for
  scalar math, and `fn` round-trip is exercised by the closed-set fixtures
  in §4.

## 4. Initial closed function set (v1)

This is the **complete** v1 set. New entries require a spec rev (see §7).

Each function specifies: dotted name, arity, argument types & units, return
type & units, boundary/edge behavior, tolerance. All real-valued arguments
and returns are IEEE-754 `binary64` unless stated otherwise.

### 4.1 `datetime.*` — calendar and solar geometry

Notation: `t_utc` is a scalar UTC time in seconds since the Unix epoch
(IEEE-754 `binary64`, monotonically increasing across the simulation). All
functions are pure: same inputs → same output, no leap-second table outside
what the spec defines.

| Name | Arity | Args | Return | Units |
|---|---|---|---|---|
| `datetime.julian_day` | 1 | `t_utc: scalar` | scalar | dimensionless |
| `datetime.day_of_year` | 1 | `t_utc: scalar` | integer scalar (1..366) | dimensionless |
| `datetime.time_of_day_seconds` | 1 | `t_utc: scalar` | scalar (0 ≤ x < 86400) | s |
| `datetime.solar_declination` | 1 | `t_utc: scalar` | scalar | rad |
| `datetime.equation_of_time` | 1 | `t_utc: scalar` | scalar | s |
| `datetime.solar_zenith_angle` | 3 | `lat: scalar [rad], lon: scalar [rad], t_utc: scalar [s]` | scalar | rad |

**Boundary semantics:**
- All datetime functions ignore leap seconds (use UTC as-if proleptic
  Gregorian, no UT1 offset). This is the deliberate cross-binding contract;
  bindings MUST NOT consult an OS leap-second table.
- `solar_declination` and `equation_of_time` are computed from the standard
  NOAA / Spencer (1971) approximations; the spec pins the polynomial
  coefficients in an appendix (§A) so bindings agree to ulp.
- `solar_zenith_angle` returns values in `[0, π]`. Polar-night situations
  return values > π/2 (sun below horizon); the spec does NOT clamp.

**Tolerance:** ≤ 4 ulp for `julian_day`, `day_of_year`,
`time_of_day_seconds`. ≤ 1×10⁻⁶ rad absolute for the trig-composed entries
(`solar_declination`, `solar_zenith_angle`); ≤ 1×10⁻³ s for
`equation_of_time`. The looser bounds reflect the embedded transcendentals
and the tolerated drift in the published formulas.

### 4.2 `interp.*` — inline-table interpolation

Inline tables only. Tables larger than the §2 cap (>1024 entries or >8 KB)
trigger a lint warning; authors are directed to `data_loaders`.

| Name | Arity | Args | Return |
|---|---|---|---|
| `interp.linear_1d` | 3 | `x: scalar, xs: const array[N], ys: const array[N]` | scalar |
| `interp.linear_2d` | 5 | `x: scalar, y: scalar, xs: const array[Nx], ys: const array[Ny], zs: const array[Nx, Ny]` | scalar |
| `interp.bilinear_2d` | 5 | (same as `linear_2d` but explicitly bilinear) | scalar |

**Boundary semantics:**
- `xs` MUST be strictly monotonically increasing. `ys` (in the 2D variants)
  same. Bindings MUST reject non-monotonic tables at load time.
- Out-of-range query points: **clamp to the edge value** (default).
  Authors who need extrapolation use the AST: e.g. `ifelse(x < xs[0],
  fallback_expr, fn(...))`. There is no `extrapolate=true` flag.
- NaN inputs propagate to NaN output.

**Tolerance:** ≤ 1 ulp on samples; ≤ 1 ulp on the linear blend; total
budget ≤ 2 ulp.

### 4.3 `lookup.*` — categorical / integer-indexed tables

For categorical inputs (land-use class, season). Integer indices only —
authors stage symbolic→integer at the `enums` layer (§3.1).

| Name | Arity | Args | Return |
|---|---|---|---|
| `lookup.lookup_1d` | 2 | `idx: integer scalar, table: const array[N]` | scalar |
| `lookup.lookup_2d` | 3 | `idx_a: integer scalar, idx_b: integer scalar, table: const array[Na, Nb]` | scalar |

**Boundary semantics:**
- Indices are 1-based to match every existing example in `esm-spec.md`.
- Out-of-range index: load-time error if the index is a literal; runtime
  error otherwise. There is no clamping; categorical tables have no
  meaningful edge.
- Table layout: row-major (last index fastest). Bindings MUST honor this
  even where their native default differs (e.g. Julia's column-major).

**Tolerance:** exact (no arithmetic).

### 4.4 Why this list

The list is driven by the two motivating clients in the bead:

- **FastJX photolysis** (`pkg/EarthSciAST.jl/.../gaschem.jl`)
  — needs solar geometry + inline-table interpolation of small cross-section
  tables. Covered by `datetime.*` + `interp.*`.
- **Wesely / Zhang dry deposition** — needs categorical land-use × season
  resistance lookups. Covered by `lookup.*` + `enums`.

The cubic / spline interpolators called out in the bead's open questions
**are deliberately deferred to v2** (§7). Linear is the conservative default;
nothing in the v1 client list needs cubic.

## 5. Conformance contract

Each function in §4 ships, in lockstep with the spec rev that introduces it,
with:

1. **A spec section** (this RFC, §4) defining arity, types, units, boundary
   semantics, tolerance.
2. **A conformance fixture** under `tests/closed_functions/<module>/<name>/`
   containing:
   - One canonical `.esm` file invoking the function from a trivial ODE RHS.
   - A reference output file (`expected_<scenario>.json`) with input vectors
     and expected outputs at the spec tolerance.
   - At least one boundary-case scenario (NaN input, edge clamp, midpoint
     interpolation, polar-night for SZA, etc.).
3. **A binding implementation contract**: each binding's test harness
   loads the fixture, evaluates `fn` against the inputs, and asserts
   per-element agreement with the reference output within the declared
   tolerance.

`scripts/test-conformance.sh` MUST run the closed-function fixtures across
all five bindings on every PR. A binding that fails any fixture fails CI.

## 6. Migration of §9.1 Operators

§9.1 is harder than §9.2 because operators describe state mutations, not
pure functions. The RFC handles them in two tracks.

### 6.1 Track A — operators decomposable into closed functions

Several "operators" in current fixtures are really pure parameterizations
plus a fixed application pattern (rate × concentration into the source term).
These migrate to AST equations:

- **WesleyDryDep** (in `tests/valid/operators_comprehensive.esm`):
  the resistance computation is `r_total = r_a(u_star, z_0) + r_b(u_star,
  Sc) + r_c(season, land_use)`. `r_a` and `r_b` are closed-form, expressible
  with existing AST ops. `r_c` is a categorical lookup — `lookup.lookup_2d`
  with `season` and `land_use_class` enum indices. Application to species is
  an additive coupling term (§10), not an operator.
- **BelowCloudScav** (`tests/valid/operators_comprehensive.esm`): scaling
  rate × concentration; pure AST.

Track-A operators MUST be rewritten in the same release as the
`registered_functions` removal. The migration is mechanical; conformance
fixtures cover correctness.

### 6.2 Track B — genuinely state-mutating numerical schemes

Operators like advection, gridded diffusion, or anything coupled to the
discretization grid CANNOT be expressed as closed functions over scalar
inputs. The spec already has the right home for these: the discretization
RFC (`docs/rfcs/discretization.md` §7) defines named **discretization
schemes** mapping PDE operators to stencil templates.

Track-B operators get folded into the discretization layer:

- The `operators` top-level block is removed.
- An `advection` term in a model equation is written as an explicit PDE
  operator (`{"op": "div", ...}` or a stencil reference into
  `discretizations`), not as an opaque `WesleyAdvection` handler ID.
- The existing `data_loaders` mechanism handles input fields (winds,
  precipitation rates).

Each Track-B operator currently in the test corpus needs a follow-on bead
to translate it into a discretization-scheme reference. This RFC does not
itself rewrite those fixtures; §10 lists the beads.

### 6.3 Files affected (audit)

```
$ grep -l '"op": "call"' tests/ examples/ pkg/
tests/registered_funcs/one_d_interpolator.esm
tests/registered_funcs/two_d_table_lookup.esm
tests/registered_funcs/pure_math.esm
tests/registered_funcs/README.md
tests/conformance/round_trip/manifest.json
tests/future/security/schema_bypass_attempts.esm
```

Plus the `registered_functions` schema entries in `esm-schema.json` and
each binding's parser (`pkg/earthsci-ast-go/pkg/esm/esm-schema.json`,
`earthsci-ast-rs/`, `earthsci_ast/`, `earthsci-ast-ts/`,
`EarthSciAST.jl/`).

For §9.1 operators, ~14 fixtures touched (`tests/valid/`,
`tests/coupling/`, `tests/end_to_end/`). The follow-on bead `esm-tzp/op-mig`
(see §10) sweeps these.

## 7. Addition process for future closed functions

The closed set means that the spec must rev whenever a new model needs a
primitive that v1 doesn't cover. Adoption follows this process:

1. **Author files an RFC PR** against `esm-spec.md` (or
   `docs/rfcs/closed-function-registry.md` for incremental updates,
   eventually folded into the spec at the next minor rev).
2. **Bar for inclusion** — the proposed function MUST clear all three:
   - Not expressible in finite closed form using existing AST ops.
   - Has well-defined cross-binding semantics that the proposer can pin
     (formulas, edge cases, tolerance).
   - There is no cleaner `data_loaders` path (the function operates on
     inline scalars / small tables; large data goes through `data_loaders`).
3. **Compatibility-matrix entry**: the RFC adds a row to a new
   `docs/closed-functions-compat.md` table listing which spec version
   introduced the function and any later rev that changed its semantics.
4. **Deprecation policy**: rename = new entry under a new module path; old
   name remains valid for one minor release and is then removed. Semantic
   changes (different formula, different boundary behavior) require a new
   entry, not a redefinition. Bindings MUST refuse to load `.esm` files
   whose declared `esm` version is older than the function's introduction
   version.

## 8. Forward audit (likely v2 additions)

Beyond FastJX + deposition, scanning the EarthSci roadmap for primitives
that the v1 set does not cover:

- **Aerosol microphysics**: Köhler curve evaluation
  (`aerosol.kohler_critical_supersaturation`), kappa-Köhler activation
  diameter (`aerosol.kappa_activation`). Both closed-form transcendentals,
  natural fits.
- **Alternative photolysis schemes**: TUV-style J(O¹D), J(NO₂); these
  reduce to `interp.linear_1d` over published cross-section tables (already
  in v1) IF the table fits inline. Larger TUV tables → `data_loaders`.
- **Zhang (2003) deposition**: extends the Wesely scheme with
  surface-roughness × season tables — same shape as Wesely once enums and
  `lookup.lookup_2d` cover land-use × season.
- **Heterogeneous chemistry** (γ-uptake on surface area density):
  closed-form scaling of pure species rate constants; AST already covers it.
- **Cubic / spline interpolators**: deferred from v1. Concrete model need
  must be cited before adding — current FastJX path uses linear.

The v1 set covers these audit targets either directly (Köhler, Zhang
deposition, heterogeneous chemistry) or via existing v1 entries (TUV ⊂
linear interpolation). Cubic interpolation is the only audit item likely
to need a v2 spec rev, and only if a concrete model demands it.

## 9. Worked migration examples

### 9.1 `pure_math.esm` (round-trip mechanism test)

Before:

```json
{
  "registered_functions": {
    "sq": { "id": "sq", "signature": { "arg_count": 1 } }
  },
  "models": {
    "Demo": {
      "equations": [{
        "op": "==",
        "args": [{"op": "D", "args": ["x"], "wrt": "t"},
                 {"op": "call", "handler_id": "sq", "args": ["x"]}]
      }]
    }
  }
}
```

After (delete the registry, rewrite the body in AST):

```json
{
  "models": {
    "Demo": {
      "equations": [{
        "op": "==",
        "args": [{"op": "D", "args": ["x"], "wrt": "t"},
                 {"op": "^", "args": ["x", 2]}]
      }]
    }
  }
}
```

This is the case the bead's `mdl-7e6` audit was about: zero production
files used `call` for math expressible in AST. The "round-trip mechanism"
fixture goes away — `^` round-trip is already covered.

### 9.2 `one_d_interpolator.esm`

Before — opaque handler `flux_interp_O3`:

```json
{
  "registered_functions": {
    "flux_interp_O3": { "id": "flux_interp_O3", ... }
  },
  ...
  {"op": "call", "handler_id": "flux_interp_O3", "args": ["sza"]}
}
```

After — inline table via `interp.linear_1d`:

```json
{
  ...
  {
    "op": "fn",
    "name": "interp.linear_1d",
    "args": [
      "sza",
      {"op": "const", "value": [0.0, 0.087, 0.175, ...]},
      {"op": "const", "value": [1.0e-2, 9.8e-3, 9.0e-3, ...]}
    ]
  }
}
```

If the FastJX cross-section table is too large for inline, it becomes a
`data_loaders` entry and is referenced by symbolic name — out of scope for
the `interp` family.

### 9.3 WesleyDryDep operator

Before — opaque §9.1 entry:

```json
{
  "operators": {
    "DryDepGrid": {
      "operator_id": "WesleyDryDep",
      "config": {"season": "summer", "land_use_categories": 11},
      ...
    }
  }
}
```

After — enum block + `lookup.lookup_2d` for `r_c`, AST for `r_a` / `r_b`,
additive coupling for application:

```json
{
  "enums": {
    "land_use_class": { "urban": 1, ... "snow_ice": 11 },
    "season":        { "winter": 1, "spring": 2, "summer": 3, "autumn": 4 }
  },
  "models": {
    "DryDep": {
      "equations": [
        { /* r_c lookup (Wesely Table 2) */
          "op": "==",
          "args": ["r_c",
                   {"op": "fn", "name": "lookup.lookup_2d",
                    "args": [{"op": "enum", "args": ["land_use_class", "deciduous_forest"]},
                             {"op": "enum", "args": ["season", "summer"]},
                             {"op": "const", "value": [[ /* 11×4 table */ ]]}]}]
        },
        { /* r_a, r_b in closed form */
          ...
        },
        { /* total resistance */
          "op": "==",
          "args": ["r_total", {"op": "+", "args": ["r_a", "r_b", "r_c"]}]
        }
      ]
    }
  },
  "coupling": [
    { "type": "couple", "systems": ["Chem", "DryDep"],
      "connector": { "equations": [
        { "from": "DryDep.r_total", "to": "Chem.O3",
          "transform": "additive",
          "expression": {"op": "/", "args": [-1, "DryDep.r_total"]}}
      ]}}
  ]
}
```

The opaque operator dissolves into spec-defined pieces.

## 10. Follow-on beads

After this RFC is approved, file (in this order):

1. **`esm-tzp/spec-edits`** — apply §3 edits to `esm-spec.md`: add `enums`
   block, `fn` op, `enum` op, the §4 closed-function reference. Remove §4.4
   `call` and §9.2 `registered_functions`. Update §2 top-level structure
   table. Bump the `esm` minor version.
2. **`esm-tzp/schema-edits`** — corresponding `esm-schema.json` and
   per-binding schema updates (Go binding ships its own copy in
   `pkg/earthsci-ast-go/pkg/esm/esm-schema.json`).
3. **`esm-tzp/op-mig`** — sweep §6.3 fixture set and rewrite Track-A
   operator usages. Rewrite or retire `tests/registered_funcs/*.esm` and
   `tests/registered_funcs/README.md`.
4. **`esm-tzp/track-b`** — for each remaining §9.1 operator (advection
   schemes, gridded diffusion), file a per-operator bead routing it through
   the discretization RFC. Block on the discretization RFC's named
   schemes being usable.
5. **Per-binding implementation beads** (one per binding, five total):
   add `fn` op evaluator + spec-defined function bodies, conformance test
   harness loading the closed-function fixtures.
6. **Per-function conformance fixture beads** — one bead per §4 entry,
   adding `tests/closed_functions/<module>/<name>/` per §5.

Beads (5) and (6) are independent and can fan out across polecats once the
RFC + spec edits land.

## Appendix A — Pinned coefficients for `datetime.*`

The spec rev introducing the `datetime` family pins the following formula
references. Bindings MUST use these — agreement to ulp depends on it.

- **`solar_declination`**: Spencer (1971) Fourier expansion,
  `δ = 0.006918 − 0.399912 cos(γ) + 0.070257 sin(γ) − 0.006758 cos(2γ) +
  0.000907 sin(2γ) − 0.002697 cos(3γ) + 0.001480 sin(3γ)`, where `γ = 2π
  (day_of_year − 1)/365`.
- **`equation_of_time`**: Spencer (1971), `EoT = 229.18 (0.000075 +
  0.001868 cos(γ) − 0.032077 sin(γ) − 0.014615 cos(2γ) − 0.040849
  sin(2γ))` minutes, converted to seconds in the return.
- **`solar_zenith_angle`**: standard cosine law `cos(θ_z) = sin(lat)
  sin(δ) + cos(lat) cos(δ) cos(H)` where `H = (12 − solar_time)·π/12` and
  `solar_time = (time_of_day_seconds + EoT + lon · 12 · 3600 / π) / 3600`.
  Returns `acos(cos(θ_z))`.
- **`julian_day`**: integer Julian day number per the Fliegel–van Flandern
  (1968) algorithm.

Bindings MAY ship a faster implementation if it is bit-exactly equal to the
above on the supported input domain.
