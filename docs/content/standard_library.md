# ESS Standard Subsystem Library

The `lib/` directory ships ESS subsystems and expression templates authored
entirely in the core expression AST (`esm-spec.md` §4). `lib/solar.esm` is a
self-contained subsystem includable from any consumer model via subsystem
reference (`esm-spec.md` §4.7); `lib/calendar.esm`, `lib/interp.esm`,
`lib/relational.esm` and `lib/geometry.esm` are template libraries (below),
imported rather than mounted:

```json
{
  "subsystems": {
    "Solar": { "ref": "esm:std/solar.esm" }
  }
}
```

## Referencing the library: `esm:std/<file>.esm`

Every binding ships a copy of `lib/` inside its own package, and a ref spelled
`esm:std/<file>.esm` resolves to that copy (`esm-spec.md` §4.7, "Standard-library
references"). A document anywhere on disk, or one loaded from a string, reaches
the library without knowing where the repository is:

| Mechanism | Example |
|---|---|
| Subsystem mount (§4.7) | `"subsystems": { "Solar": { "ref": "esm:std/solar.esm" } }` |
| Top-level mount (§4.7) | `"models": { "Solar": { "ref": "esm:std/solar.esm" } }` |
| Template import (§9.7.2) | `"expression_template_imports": [{ "ref": "esm:std/interp.esm" }]` |
| Coupling import (§10.10) | `{ "type": "coupling_import", "ref": "esm:std/<file>.esm", "bind": { ... } }` |

The rules, in short:

- Every binding MUST resolve the form; it is not an optional capability like URL
  refs or `${VAR}` expansion.
- The whole `esm:` scheme is reserved. A ref beginning with `esm:` is never read
  as a path or a URL. A file the bundle does not contain (`esm:std/nope.esm`) and
  any other `esm:` spelling are the mechanism's ordinary unresolved error
  (`template_import_unresolved`, `coupling_import_unresolved`,
  `unresolved_subsystem_ref`).
- `${VAR}` is not expanded inside an `esm:` ref.
- A relative ref inside a library file names another library file, so a
  library file importing `calendar.esm` works from the bundle (`lib/solar.esm`
  itself writes `esm:std/calendar.esm`).
- The bundle is the `lib/` of the release, so the library a document reaches is
  the one that ships with the format version its binding implements.

Where each binding keeps its copy:

| Binding | Bundled copy | How it is read |
|---|---|---|
| Julia | `pkg/EarthSciAST.jl/data/lib/` | files under `pkgdir(EarthSciAST)` |
| Python | `pkg/earthsci-ast-py/src/earthsci_ast/data/lib/` | package data |
| Rust | `pkg/earthsci-ast-rs/src/stdlib/` | `include_str!`, listed by `build.rs` |
| TypeScript | `pkg/earthsci-ast-ts/src/stdlib-bundle.ts` | a generated module of the file texts |
| Go | `pkg/earthsci-ast-go/pkg/esm/stdlib/` | `go:embed` |

`lib/` is the only copy to edit. `scripts/sync-lib.sh` writes all of the above
(and the docs site's `docs/static/lib/`) from it, and `scripts/sync-lib.sh --check`
fails CI when any copy differs from `lib/`.

## Design principle: compositions go here, not into new operators

The evaluable core of `esm-spec.md` §4.2 is closed: adding an operator is a spec
change, and every operator is one more thing each binding, and the formal model
of the spec, must implement. Calendar arithmetic, table interpolation, keys and
ranks, and polygon overlap areas are all finite compositions of core
operators, so they live here as templates rather than as operators. The
library is authored once, validated against the spec, and shipped alongside it,
so downstream models include it by reference instead of reimplementing (and
silently disagreeing on) the math.

Bindings recover speed by recognising small algebraic shapes in the expanded
AST (a comparison count, a sorted search), never by recognising a template by
name, and every such rewrite gives the same bits as evaluating the expansion.
A new `lib/` file therefore needs no binding code. A computation that genuinely
cannot be written as a finite tree of core operators needs an RFC against
`esm-spec.md` §4.2, not a `lib/` entry.

## Files

| File | Subsystem | Provides | Inputs |
|---|---|---|---|
| [`lib/calendar.esm`](../lib/calendar.esm) | template library (no subsystem) | expression templates `year`, `month`, `day`, `hour`, `minute`, `second`, `day_of_year`, `julian_day`, `is_leap_year`, `seconds_since_midnight` | the template parameter `t` (s) |
| [`lib/solar.esm`](../lib/solar.esm) | `Solar` | `solar_declination` (rad), `equation_of_time` (min), `true_solar_time` (min), `hour_angle` (rad), `cos_zenith`, `solar_zenith_angle` (rad) | `t_utc` (s), `lat` (deg), `lon` (deg) |
| [`lib/interp.esm`](../lib/interp.esm) | template library (no subsystem) | expression templates `searchsorted`, `linear`, `bilinear` | the template parameters (arrays, query, axis lengths) |
| [`lib/relational.esm`](../lib/relational.esm) | template library (no subsystem) | expression templates `argmin`, `argmax`, `argmin_where`, `argmax_where`, `pair_key`, `edge_key`, `rank_of`, `rank_of_set` | the template parameters (candidate values and counts, key components and their ranges) |
| [`lib/geometry.esm`](../lib/geometry.esm) | template library (no subsystem) | expression templates `overlap_area_planar`, `overlap_area_spherical`, `lonlat_to_unit` | the template parameters (ring stacks, cell indices, vertex-slot counts) |

### `lib/calendar.esm`

A template-library file (`esm-spec.md` §9.7.1), like `lib/interp.esm`: ten
public match-less expression templates — the nine calendar fields and
`seconds_since_midnight` — each of one parameter `t`, UTC seconds
since 1970-01-01T00:00:00Z (binary64, proleptic Gregorian, no leap seconds). A
component imports the templates it needs and applies them:

```json
{
  "expression_template_imports": [
    { "ref": "esm:std/calendar.esm", "only": ["hour", "minute", "second"] }
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
| `julian_day` | the Julian Date, by the binary64 formula `(d + 2440588) + ((s − 43200) + (t − floor(t))) / 86400`, in that order |
| `is_leap_year` | 1 for a leap year, else 0 |
| `seconds_since_midnight` | the whole second of the day, 0..86399 s, in seconds (`3600·hour + 60·minute + second`) |

Each body splits `t` exactly into the day number `d = floor(floor(t) / 86400)`
and the whole second of the day `s = floor(t) − 86400·d`, then runs Howard
Hinnant's `civil_from_days` (400-year eras counted from 0000-03-01, the day of
the era, the year of the era, the day of the year from March 1, the month from
`(5·doy + 2) / 153`), every integer division written `floor(a / b)`. Each step is written once, as a helper
template named `civil_*` (`civil_day_number`, `civil_second_of_day`,
`civil_era`, `civil_day_of_era`, `civil_year_of_era`, `civil_day_of_year`,
`civil_month_index`, `civil_is_jan_feb`, `civil_leap`, `civil_leap_next`), and
the later steps call it by reference (§9.7.3); importing a public template with
`only` carries the helpers it needs. The helpers carry no domain guard. The
file is generated by `scripts/gen-lib-calendar.py`, which is the readable form
of the algorithm (`--check` reports a stale file). **Domain:** finite `t` with `|t| < 2^52`
s, about ±142 million years. There every intermediate is an integer below
`2^53`, so each `floor` is exact; outside it, and for a NaN or infinite `t`,
every template returns NaN. The cross-binding `datetime_templates` conformance
tier runs the templates against committed calendar values.

The datetime fields are dimensionless numbers (`hour` is the count 14, not a
duration of 14 hours), `julian_day` included; `seconds_since_midnight` is in
seconds. The template bodies divide `t` by
unit-bearing `const` nodes in seconds (§4.8.5), so a `t` declared in seconds
validates cleanly, one in hours is a scale mismatch, and a dimensionless one
is a dimension mismatch. A consumer that wants a quantity multiplies by its own
conversion factor, as `lib/solar.esm` does with `rad_per_day` and
`min_of_clock`.

### `lib/solar.esm`

The NOAA Spencer-Fourier solar-position model. `solar_declination` and
`equation_of_time` are 5- and 7-term Fourier series in the fractional-year
angle γ; `solar_zenith_angle` then composes lat/lon and the NOAA hour-angle
formula. It imports the `day_of_year`, `hour`, `minute` and `second`
templates of `lib/calendar.esm` for its calendar fields through the
standard-library ref `esm:std/calendar.esm`, so a mount of `lib/solar.esm`
resolves that import wherever the mounting document lives (§4.7). Every
constant is a binary64 literal, so the result is bit-defined relative to the
calendar templates and the §4.2 elementary-function ops; for `|t_utc| ≥ 2^52` s the outputs are NaN. Cross-binding tolerance is ≤ 10 ulp,
within the algorithm's intrinsic ~2 arcminute accuracy.

To use:

```json
{
  "esm": "2.0.0",
  "models": {
    "MyChem": {
      "subsystems": {
        "Solar": { "ref": "esm:std/solar.esm" }
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
  "expression_template_imports": [{ "ref": "esm:std/interp.esm" }],
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

The three templates are 1-D search, 1-D linear and 2-D bilinear interpolation,
written with `faq` comparison counts, the `index` op and arithmetic. Each axis
length is an explicit integer parameter, used as the upper bound of a `faq`
dense `ranges` entry (a substitution site, §9.6.1):

| Template | Parameters | Value |
|---|---|---|
| `searchsorted` | `x`, `xs`, `n` | `1 + Σ_{k=1..n} ifelse(xs[k] ≥ x, 0, 1)`: the first index with `xs[k] ≥ x`; `n + 1` when there is none, or `x` is NaN; `1` for `n = 0` |
| `linear` | `table`, `axis`, `x`, `n` | flat outside the axis; inside, `i = min(max(Σ_k ifelse(axis[k] ≤ x, 1, 0), 1), n − 1)` and `table[i] + w·(table[i+1] − table[i])` with `w = (x − axis[i]) / (axis[i+1] − axis[i])` |
| `bilinear` | `table`, `axis_x`, `axis_y`, `x`, `y`, `nx`, `ny` | each query clamped to its axis, the cell on each axis found by the same count, then the two x-blends and the y-blend |

A clamped query on an interior knot `k` of `bilinear` selects cell `k`, so its
weight is `0`. The templates do not check their axes: a non-monotonic or NaN
axis is not rejected, so the caller supplies a valid one. The cross-binding
`interp_templates` conformance tier pins the values, NaN queries included.

A sampled table (the `function_tables` block of esm 1.x) is a `linear` or
`bilinear` call over the table's data and axes; a multi-output table becomes one
call per output.

Each template takes one query, but `x` and `y` may be arrays: an array bound to
a scalar-role parameter (one the body reads only as a value, never whole) makes
the application elementwise (esm-spec §9.6.11), one lookup per element, bit for
bit the scalar call at that element. This holds when the array arrives by
coupling too: a component that declares `lev` a scalar and computes
`linear(table, axis, lev, n)` gets one lookup per grid cell when a
`variable_map` binds a gridded `lev` to it. The `template_array_args`
conformance tier pins these cases.

### `lib/relational.esm`

`lib/relational.esm` is a template-library file like `lib/interp.esm`. Its
arg-witness templates `argmin(f, n)` and `argmax(f, n)` give the 1-based
index `k` in `1..n` at which the candidate value `f` is smallest (largest).
`f` is an expression over the template's loop symbol — `k_argmin_1` for
`argmin`, `k_argmax_1` for `argmax` — which the template binds to each
candidate index in turn, so the caller writes the candidate's value with that
symbol as its index. `n`, the number of candidates, is an integer used as a
`faq` `ranges` bound. A nearest-generator assignment:

```json
{
  "expression_template_imports": [{ "ref": "esm:std/relational.esm" }],
  "equations": [
    {
      "lhs": { "op": "index", "args": ["assign", "i"] },
      "rhs": {
        "op": "faq", "args": [], "output_idx": ["i"],
        "ranges": { "i": { "from": "points" } },
        "expr": {
          "op": "apply_expression_template", "args": [], "name": "argmin",
          "bindings": {
            "f": { "op": "+", "args": [
              { "op": "*", "args": [
                { "op": "-", "args": [{ "op": "index", "args": ["px", "i"] }, { "op": "index", "args": ["gx", "k_argmin_1"] }] },
                { "op": "-", "args": [{ "op": "index", "args": ["px", "i"] }, { "op": "index", "args": ["gx", "k_argmin_1"] }] }
              ] },
              { "op": "*", "args": [
                { "op": "-", "args": [{ "op": "index", "args": ["py", "i"] }, { "op": "index", "args": ["gy", "k_argmin_1"] }] },
                { "op": "-", "args": [{ "op": "index", "args": ["py", "i"] }, { "op": "index", "args": ["gy", "k_argmin_1"] }] }
              ] }
            ] },
            "n": 3
          }
        }
      }
    }
  ]
}
```

Each body is two `faq` reductions over `k` in `[1, n]`:

| Template | Value |
|---|---|
| `argmin` | `m = min_k f(k)`, then `min_k ifelse(f(k) == m or (f(k) != f(k) and m != m), k, n + 1)` |
| `argmax` | the same with `m = max_k f(k)` |

So equal candidates resolve to the smallest index (RFC semiring-faq-unified-ir
§5.7 rule 6, `-0.0` and `0.0` being equal), and because a NaN term makes a
`min` / `max` reduction NaN, a NaN candidate wins at its first occurrence.
`n = 0` gives `+Inf`, the identity of the `min` reduction. The result is a float holding an integer, usable as an
`index` subscript. `f` appears twice in the expansion (in `m` and in the
selection), and `m` is nested inside the selecting reduction; it does not
depend on that reduction's `k`, so an evaluator may compute it once per call.
The `relational_templates` conformance tier pins the values; a gated
arg-witness is written with `argmin_where` (below).

#### Gated arg-witnesses, keys and ranks

The other templates give composite keys for value invention, ranks among a
set's members, and arg-witnesses gated by a predicate:

| Template | Value |
|---|---|
| `argmin_where(f, p, n)`, `argmax_where(f, p, n)` | the `argmin` / `argmax` body with the predicate `p` as the `filter` of both reductions, capped at `n + 1`: only candidates passing `p` compete, and `n + 1` means none did. `f` and `p` are written over `k_argmin_where_1` (`k_argmax_where_1`). |
| `pair_key(a, b, lo_a, lo_b, n_a, n_b)` | `(a − lo_a)·n_b + (b − lo_b)` for integers `a ∈ [lo_a, lo_a + n_a)`, `b ∈ [lo_b, lo_b + n_b)`; NaN for a component out of range, non-integral or NaN. A directed composite key: equal pairs give equal keys and the keys sort in the pairs' lexicographic order. Exact while `n_a·n_b ≤ 2^53`. |
| `edge_key(u, v, lo, n)` | `pair_key(min(u, v), max(u, v), lo, lo, n, n)`: the undirected key, so `(u, v)` and `(v, u)` coincide. |
| `rank_of(x, members, n)` | `1 + Σ_k ifelse(members[k] ≥ x, 0, 1)`: the 1-based rank of the key `x` among `n` ascending members, the same count as `searchsorted`. |
| `rank_of_set(x, members, S)` | the same count with the candidate range `{"from": S}` (a template parameter may name an index set there, esm-spec §9.6.1): the rank of `x` among the members of the index set `S`, read as `members[k]` for `k` in `S`. For a derived set, `members` is its `member_factor` array, so the set's size need not be known when the document is written. |

How a document uses them:

- **A `distinct` key** is a scalar integer expression: `edge_key(...)` for an
  undirected edge, `pair_key(...)` for a directed pair (nest two calls for
  three components), or the bare component for a one-component key.
- **A key read only as a `join.on` column** (a bin key) is written as one
  integer column per component, `src_bx[i] = floor(src_lon[i] / dx)` and
  `src_by[i] = floor(src_lat[i] / dy)`, joined with one `on` pair per
  component: `{"on": [["src_bx", "tgt_bx"], ["src_by", "tgt_by"]]}`.
- **The rank of a set's own member** is its loop index: `edge_dense_id[e] = e`
  over `e ∈ edges`. `rank_of_set` looks up the rank of any other key among a
  derived set's members.
- **A gated arg-witness** is `argmin_where` whose predicate compares the
  per-component columns at the point and the candidate.

The value-invention layer of each binding accepts a `distinct` `key` that is
any integer-valued expression, and a `join.on` column that is a plain observed
over constant factors. A NaN key or column value (a key template's
out-of-range component) is refused with `value_invention_key_out_of_range`,
naming the column. The documents under
`tests/conformance/relational_templates/rewrites/` use these forms and are
checked against committed golden members, dense IDs, assignment buffers and
right-hand sides.

`rank_of_set` ranks against a derived set by name: each face edge's rank among
a derived `edges` set is
`rank_of_set(edge_key(edge_lo, edge_hi, 1, 6), edge_members, "edges")`, with
`edge_members` the set's `member_factor`. A name that is not a declared index
set is `undefined_index_set`. `argmin_where` / `argmax_where` keep `[1, n]`:
their "none passed" answer `n + 1` needs the count.

### `lib/geometry.esm`

A template-library file like `lib/interp.esm`: three match-less expression
templates giving the overlap area of two convex polygons in the core AST, the
weight of a conservative regrid (`esm-spec.md` §8.6.1). Each polygon operand is one cell of a ring stack: the stack, the cell
index (usually the loop symbol of the enclosing `faq` over candidate pairs) and
the number of vertex slots (an integer, used as a `faq` `ranges` bound).

| Template | Parameters | Value |
|---|---|---|
| `overlap_area_planar` | `ring_a`, `cell_a`, `nv_a`, `ring_b`, `cell_b`, `nv_b` | overlap area of cell `cell_a` of the `[cells, nv_a, 2]` stack `ring_a` and cell `cell_b` of `ring_b`, straight edges, in squared coordinate units |
| `overlap_area_spherical` | the same, over `[cells, nv, 3]` stacks of unit vectors | the same with great-circle edges on the unit sphere, in steradians |
| `lonlat_to_unit` | `ring`, `cell`, `vert`, `comp` | component `comp` (1, 2, 3) of the unit vector `(cos φ cos λ, cos φ sin λ, sin φ)` of vertex `vert` of a `[cells, verts, 2]` lon-lat stack in degrees |

A conservative-regridding narrow phase over the planar manifold:

```json
{
  "expression_template_imports": [{ "ref": "esm:std/geometry.esm" }],
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

Besides the three public templates the file carries `geo_`-prefixed helper
templates, one per step of the method below (cross and dot products, the
signed side of a line or great circle, the on-the-line tolerance, the two
bounds a half-plane imposes on an edge, an edge's contribution, the
Van Oosterom–Strackee term, a ring's orientation fan), which the public bodies
call by reference (`esm-spec.md` §9.7.3). Expanding every reference gives the
fully written-out body. The file is generated by `scripts/gen-lib-geometry.py`
(`--check` to verify it, `--inline OUT.esm` for the written-out form).

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
  unpadded form. Distinct vertices are never merged, however close.
- **Shared edges and vertices.** A half-plane test counts a point as on the
  line when its signed value `g` satisfies
  `|g| ≤ 1e-12 · L1(b − a) · (L1(p) + L1(q) + L1(a))` on the plane (edge
  `p → q` against the line of edge `a → b`, `L1` the sum of absolute
  coordinates) and `|g| ≤ 1e-14` on the sphere (`g = (a × b) · p` over unit
  vectors). An edge lying on an edge of the other polygon is counted once, by
  `ring_a`, when the two run the same way, and not at all when they run
  opposite ways (adjacent cells). Pairs of cells from one grid (identical,
  adjacent, corner-touching) are therefore exact: on the planar fixtures the
  template gives the exact area, and touching cells give `0`. Edges that are
  genuinely distinct but closer than these tolerances are treated as collinear.
- **Contract.** Convex cells (CONFORMANCE_SPEC §5.8's conservative-regridding
  cells), each spherical cell within a hemisphere. A ring of no extent (every
  vertex on one line or point, a zero fan sum) gives `0`; non-convex input is
  outside the contract and is not rejected.

`tests/conformance/geometry_templates/pairs.json` (generated by
`scripts/gen-geometry-template-pairs.py`) lists the cell pairs every polygon and
regridding document in `tests/` clips, with an exact (planar) or 40-digit
(spherical) reference area; the bindings' test suites hold the template to the
CONFORMANCE_SPEC §5.8.2 tolerance against that reference, the planar same-grid
pairs exactly, and the padded copy of every pair to the same bits. Taking
contributions about a vertex of the cell rather than the coordinate origin
avoids the cancellation of a shoelace sum far from the origin.

## Validation and conformance

Each `lib/*.esm` is a schema-valid file under `esm-schema.json`, swept by every
binding's validation corpus. `tests/valid/lib_solar_subsystem_inclusion.esm`
mounts `lib/solar.esm` (and through it imports `lib/calendar.esm`).
Cross-binding numerical agreement is pinned by the template conformance tiers
(`datetime_templates`, `interp_templates`, `relational_templates`,
`geometry_templates`; see CONFORMANCE_SPEC.md). A lib file is an AST
composition, so it needs no per-binding code to conform.

## Adding a new lib subsystem

1. Identify a composition that recurs across model components (e.g.,
   atmospheric standard-pressure profile, saturation vapor pressure) and is
   expressible as a finite tree of the §4.2 core operators.
2. Author `lib/<name>.esm` as a single self-contained subsystem, with
   parameter inputs and unknown outputs defined by equations. A ref to another
   library file is written relative (`calendar.esm`) or as `esm:std/calendar.esm`.
   Then run `scripts/sync-lib.sh` to copy it into the docs site and every binding.
3. Document it in this file, including units, references, and the
   composition's algebraic form.
4. Add a fixture under `tests/valid/lib_<name>_inclusion.esm` exercising
   subsystem inclusion.
5. If the composition turns out to need an operator the core does not have,
   file an RFC against `esm-spec.md` §4.2 *before* adding the lib entry.
