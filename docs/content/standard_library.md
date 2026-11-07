# ESS Standard Subsystem Library

The `lib/` directory ships ESS subsystems authored entirely in pure AST and the
spec's closed-function registry (`esm-spec.md` §9.2). Each file except
`lib/interp.esm` and `lib/geometry.esm` (template libraries, below) is a
self-contained subsystem includable from any consumer model via subsystem
reference (`esm-spec.md` §4.7):

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
| [`lib/interp.esm`](../lib/interp.esm) | template library (no subsystem) | expression templates `searchsorted`, `linear`, `bilinear` | the template parameters (arrays, query, axis lengths) |
| [`lib/geometry.esm`](../lib/geometry.esm) | template library (no subsystem) | expression templates `overlap_area_planar`, `overlap_area_spherical`, `lonlat_to_unit` | the template parameters (ring stacks, cell indices, vertex-slot counts) |

### `lib/calendar.esm`

A thin AST veneer over the §9.2 `datetime.*` registry: each calendar field is
exposed as an unknown defined by its own equation, so that consumers can scope-reference
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

Unlike the other two files, `lib/interp.esm` is a template-library file
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

### `lib/geometry.esm`

A template-library file like `lib/interp.esm`: three match-less expression
templates giving the overlap area of two convex polygons in the core AST, the
quantity the `polygon_intersection_area` geometry leaf returns (`esm-spec.md`
§8.6.1). Each polygon operand is one cell of a ring stack: the stack, the cell
index (usually the loop symbol of the enclosing `faq` over candidate pairs) and
the number of vertex slots (an integer, used as a `faq` `ranges` bound).

| Template | Parameters | Value |
|---|---|---|
| `overlap_area_planar` | `ring_a`, `cell_a`, `nv_a`, `ring_b`, `cell_b`, `nv_b` | overlap area of cell `cell_a` of the `[cells, nv_a, 2]` stack `ring_a` and cell `cell_b` of `ring_b`, straight edges, in squared coordinate units: the leaf with `manifold: "planar"` |
| `overlap_area_spherical` | the same, over `[cells, nv, 3]` stacks of unit vectors | the same with great-circle edges on the unit sphere, in steradians: the leaf with `manifold: "spherical"` or `"geodesic"` |
| `lonlat_to_unit` | `ring`, `cell`, `vert`, `comp` | component `comp` (1, 2, 3) of the unit vector `(cos φ cos λ, cos φ sin λ, sin φ)` of vertex `vert` of a `[cells, verts, 2]` lon-lat stack in degrees |

A conservative-regridding narrow phase over the planar manifold:

```json
{
  "expression_template_imports": [{ "ref": "../lib/geometry.esm" }],
  "equations": [
    {
      "lhs": "A_ij",
      "rhs": {
        "op": "faq", "args": [], "output_idx": ["i", "j"],
        "ranges": { "i": { "from": "src_cells" }, "j": { "from": "tgt_cells" } },
        "join": [{ "on": [["src_bin", "tgt_bin"]] }],
        "expr": {
          "op": "apply_expression_template", "args": [], "name": "overlap_area_planar",
          "bindings": { "ring_a": "src_poly", "cell_a": "i", "nv_a": 4,
                        "ring_b": "tgt_poly", "cell_b": "j", "nv_b": 4 }
        }
      }
    }
  ]
}
```

On the sphere the caller first builds each unit-vector stack once per cell,
`src_xyz[c, v, d] = lonlat_to_unit(src_poly, c, v, d)` as a `faq` over the
cells, the vertex slots and a 3-element component axis, and passes `src_xyz`
and `tgt_xyz` to `overlap_area_spherical`. Doing the trigonometry once per
vertex instead of once per use inside the pair body is also what keeps the
expanded spherical template small.

**Method.** By Green's theorem the overlap area is the sum, over every edge of
each polygon, of that edge's boundary contribution restricted to the part of the
edge inside the other polygon. For convex polygons that part is one interval
`[t0, t1]` of the edge's chord parameter: `t0` is a `max` and `t1` a `min` `faq`
over the other polygon's closed half-planes, each of which is linear in the
chord parameter (on the sphere too, as a great-circle half-space test
`n · P(t) ≥ 0`). A planar edge from `P` to `Q` contributes
`½ (t1 − t0)⁺ · ((P − O) × (Q − O))`, and a spherical edge the signed area of
the spherical triangle it spans with `O` (Van Oosterom–Strackee, `atan2`), where
`O` is the first vertex of `ring_a`; the contributions of each polygon carry its
orientation sign, so either ring orientation is accepted (on the sphere the
interior is the side of less than a hemisphere, as with S2).

- **Padding.** A repeated vertex (an explicit closing duplicate, or the
  rectangular-storage padding of a mixed-valence mesh) makes a zero-length edge,
  which contributes exactly zero and imposes no half-plane constraint. No
  deduplication step is needed, and a padded ring gives the bits of its
  unpadded form. The leaf deduplicates with the `np.allclose` tolerance
  instead; the two differ only on distinct vertices closer than that tolerance.
- **Shared edges and vertices.** A half-plane test within a small tolerance of
  zero (relative to the coordinates on the plane, absolute `1e-14` on the
  sphere) counts as on the line. An edge lying on an edge of the other polygon
  is counted once, by `ring_a`, when the two run the same way, and not at all
  when they run opposite ways (adjacent cells). Pairs of cells from one grid
  (identical, adjacent, corner-touching) are therefore exact: on the planar
  fixtures the template gives the exact area, and touching cells give `0`.
- **Contract.** Convex cells (CONFORMANCE_SPEC §5.8's conservative-regridding
  cells), each spherical cell within a hemisphere. Non-convex input is outside
  the contract; the template does not reject it. A degenerate ring (fewer than
  three distinct vertices) is not rejected either: where the leaf raises
  `E_TREEWALK_GEOMETRY_CLIP`, the template returns a value (zero area for a
  ring of no extent).

`tests/conformance/geometry_templates/pairs.json` (generated by
`scripts/gen-geometry-template-pairs.py`) lists the cell pairs every polygon and
regridding document in `tests/` clips, with an exact (planar) or 40-digit
(spherical) reference area; the Julia, Python and Rust test suites run each pair
through the template and the leaf and hold them to the CONFORMANCE_SPEC §5.8.2
tolerance, the planar same-grid pairs exactly, and the padded copy of every pair
to the same bits. The template is often closer to the reference than the leaf:
taking contributions about a vertex of the cell rather than the coordinate
origin avoids the cancellation of a shoelace sum far from the origin.

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
   parameter inputs and unknown outputs defined by equations.
3. Document it in this file, including units, references, and the
   composition's algebraic form.
4. Add a fixture under `tests/valid/lib_<name>_inclusion.esm` exercising
   subsystem inclusion.
5. If the composition turns out to require a primitive not yet in §9.2, file
   an RFC against `esm-spec.md` §9 *before* adding the lib entry — the lib is
   not a back door for closed-registry growth.
