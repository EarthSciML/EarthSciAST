# RFC — Factor dependency-heavy data I/O into EarthSciIO (bead: TBD)

**Status:** Draft v0.1
**Bead:** TBD (file on `bd` before merge)
**Affects spec version:** none directly — this is a packaging/layering RFC. One
optional schema addition is proposed in §6 (`kind: "table"`), tracked separately.
**Scope:** Where the *runtime* data-loader machinery lives. The `.esm` schema's
`data_loaders` declarations (§8 of `esm-spec.md`) are unchanged except for the
optional addition in §6.

---

## 1. Motivation

ESS is a language-agnostic *serialization format*. Its philosophy (`esm-spec.md`
§1, §8) is that an `.esm` file is a fully specified, language-agnostic
mathematical description with **no embedded executable code**, and that data
loaders are the one deliberate exception: they declare *what* an external source
provides and *how to locate it*, while I/O, format adapters, regridding, and
credentials are explicitly **out of scope / runtime concerns** (§8.7).

The repository has drifted from that philosophy. Every language package now
ships a full runtime loader (URL realization, format decode, mirror fallback,
regridding, per-kind grid/points/static loaders). Concretely, the Python
`earthsci-toolkit` — nominally the serialization toolkit — declares these as
**hard, non-optional** dependencies:

```
numpy, scipy, matplotlib, xarray, netcdf4
```

A serialization library should not force every consumer who wants to *parse or
validate* an `.esm` file to install the entire scientific-Python data stack
(including netCDF4 binary wheels). The package contradicts the spec's own §8.7.
`packages/.../data_loaders/regrid.py` even admits it is a stopgap: *"a minimal
bilinear regridder … without pulling in a heavy dependency like xesmf. Callers
that need higher-order regridders should do that out-of-band."*

Two recent bodies of work remove the reason the loaders were heavy:

1. **In-schema conservative regridding** (`ess-my4.4.x`): `intersect_polygon`
   op + `polygon_area` FAQ + polar-edge densification, and the
   conservative-regridding *assembly* (`overlap join → A_ij → A_j → apply →
   normalize`) implemented across Julia/Python/Rust and folded into the M4
   cross-binding tolerance gate. The regridding **weight computation** is now
   part of the serializable IR and is conformance-tested.
2. **GDD grid construction in ESD** (`esd-3we.*`, `esd-heg.*`): cartesian /
   vertical / latlon / arakawa / MPAS-DUO grid construction as elementwise
   FAQs. The **target grid** now has a proper, owned home in
   EarthSciDiscretizations.

With grids owned by ESD and regridding weights owned by ESS, the dependency-heavy
remainder is **pure I/O**: realize a URL, fetch bytes (HTTP/S3/CDS, credentials),
decode a format (netCDF/GRIB/GeoTIFF/CSV/Parquet), and return decoded arrays or
rows. That is the only thing that needs `xarray`/`netcdf4`/`pyproj`/`httpx`, and
it is precisely the thing that **cannot** be conformance-tested across languages
anyway. It should be isolated in a separate repository: **EarthSciIO**.

## 2. Non-goals

- Changing the `data_loaders` declaration schema (other than the optional §6
  `kind: "table"`). Declarations stay in `.esm` files.
- Moving regridding or grid construction. Those stay in ESS (weights) and ESD
  (grids) respectively — see §4 and §5.
- Designing the per-format decoder catalog. EarthSciIO's internal adapter set
  (which formats, which libraries) is an implementation detail of that repo.
- Credentials / auth design. Remains runtime-side and out of the schema (§8.7).

## 3. The seam — what moves and what stays

The loader code straddles two categories. The `opener`/`fetcher`/`parser`
injection points already in the Python package are the pre-drawn cut lines.

### 3.1 Stays in ESS — *executable spec* (pure, zero-dep, conformance-tested)

These are deterministic interpretations of the schema text and define what a
declaration *means*. They must be canonical and byte-identical across bindings,
so they stay in ESS with no heavy dependencies:

- `url_template` expansion (`{date:%Y%m%d}`, `{var}`, `{sector}`, custom keys).
- `time_resolution`: ISO-8601 duration parsing, `file_period` → file-anchor
  resolution, `records_per_file: "auto"` math.
- Mirror **ordering** (producing the ordered fallback *list*, not opening it).
- Variable-name remapping and `unit_conversion` evaluation (the latter is just
  AST evaluation ESS already owns).

EarthSciIO **imports** these rather than re-deriving them, so ESS remains the
single source of truth for declaration semantics.

### 3.2 Moves to EarthSciIO — I/O + format adapters (dependency-heavy)

- The actual open/fetch in `grid.py` / `points.py` / `static_loader.py`
  (`xarray`, `urllib`/`httpx`, S3/CDS clients, credentials).
- Format decode adapters (netCDF/GRIB/GeoTIFF/CSV/Parquet/Arrow).
- Everything requiring `numpy`/`scipy`/`xarray`/`netcdf4`/`pyproj`.

### 3.3 Dependency migration

Remove `numpy, scipy, matplotlib, xarray, netcdf4` from `earthsci-toolkit`'s
hard `dependencies`. Anything still needed by *pure* helpers stays minimal (the
pure helpers above need none of them). The heavy stack becomes EarthSciIO's
dependency set. `pip install earthsci-toolkit` returns to being a lightweight,
foundational dependency.

## 4. Reprojection lives in the geometry layer, not EarthSciIO

Reprojection is a deterministic coordinate map — the same category as the
conservative-regridding geometry (`intersect_polygon`, `polygon_area`), **not**
I/O. The regridding overlap-join already requires a **common frame** (great-circle
edges on the sphere). A projected source grid (Lambert / Mercator / polar
stereographic / rotated pole) must therefore have its cell corners expressed in
the canonical lon/lat frame *before* the join — and "materialize cell-corner
geometry in the canonical frame" is part of grid construction, i.e. ESD/GDD.

Split it the way regridding was split:

- **Analytic projections** (closed-form forward/inverse: Mercator, Lambert
  conformal, polar stereographic, rotated pole) → **closed-form ops in ESS**,
  beside the regridding geometry, **applied by ESD** when building cell geometry.
  Per the "prefer the AST" rule (`CLAUDE.md`, `esm-spec.md` §9.2), a finite
  closed-form map MUST be an AST/`fn` op, not a `call` shelling out to PROJ.
  This keeps reprojection dependency-free and under the cross-binding tolerance
  gate. The schema hooks already exist: `DataLoaderSpatial.crs` and the
  `coordinate_transforms` block are the *declarations*; the closed-form ops are
  the *evaluation*.
- **The only I/O sliver:** survey-grade datum shifts needing external grid-shift
  files (NADCON, geoid grids) are not closed-form. *Fetching* such a grid is
  EarthSciIO's job; *applying* it is still geometry. Rare; **deferred** — out of
  scope for v1 of the split.

**Net: EarthSciIO does not own reprojection.**

## 5. Tabular data

The schema has two different "tabular" features; only one touches EarthSciIO.

### 5.1 `function_tables` + `table_lookup` (v0.4.0) — in-file, no I/O

Literal sampled tables embedded in the `.esm` file (named axes + nested-array
`data`), sugar that lowers to `interp.linear` / `interp.bilinear` / `index`.
They carry their data inline; the binding's expression evaluator handles them.
**EarthSciIO does nothing here** — these are not external sources.

### 5.2 External tabular *sources* (CSV / Parquet / Arrow) — yes, EarthSciIO

Station observations, emissions inventories, and other row-oriented external
datasets. This is the **cleanest** loader case: no regridding geometry at all —
realize URL → fetch → decode → map columns to schema variables. The seed already
exists in the `points` kind (it parses CSV/JSON today).

The output is **not** a grid; it is a **relation**, which feeds directly into the
relational IR ESS has been landing (`join.on`, `aggregate`, value-equality joins,
cadence-partition). Boundary: **EarthSciIO owns fetch + decode + column→variable
mapping; ESS owns every join / aggregate / filter on the resulting table.** Same
discipline as gridded data — I/O never does the relational math. This dovetails
with EarthSciInventory, which is inherently tabular.

## 6. Optional schema addition — `kind: "table"`

External tabular sources currently have to ride on `kind: "points"`, which
implies lat/lon-located rows. Non-located tables (keyed by sector / species /
year, no coordinates — the classic inventory shape) are misrepresented. Propose
an explicit `kind: "table"` so EarthSciIO does not overload `points` and the
loader's output is honestly typed as a relation. This is the one schema-affecting
item; track it as its own bead and minor version bump if accepted.

## 7. The EarthSciIO contract

EarthSciIO resolves `(data_loader declaration, time, substitutions)` into one of
two decoded shapes, then hands off:

| Output | EarthSciIO does | Hands off to |
|---|---|---|
| **gridded** | fetch + decode source arrays + source cell coords | ESS regrid FAQ (weights) → ESD GDD target grid |
| **relation** (tabular) | fetch + decode + column→variable map | ESS relational IR (`join.on`, `aggregate`) |

EarthSciIO **never** does geometry, reprojection (beyond optionally fetching a
datum grid), or relational math. It is a pure "bytes + decode" layer — the part
that cannot be conformance-tested cross-language, hence the right thing to isolate.

```
┌─────────────────────────────────────────────────────────────┐
│ ESS  format + declaration semantics (url/time/mirror/var)    │
│      + geometry/regridding IR (intersect_polygon, A_ij,      │
│        analytic projections) + relational IR (join/aggregate)│
└───────────────▲───────────────────────────▲─────────────────┘
                │ weights                    │ relational ops
┌───────────────┴──────────┐   ┌─────────────┴───────────────┐
│ ESD  GDD grids + applies  │   │ EarthSciIO  fetch + decode  │
│      projections to cells │◄──┤  (numpy/xarray/netcdf4/...) │
└───────────────────────────┘   └─────────────────────────────┘
```

## 8. Open decisions

1. **EarthSciIO ↔ EarthSciData.jl.** EarthSciData.jl already is the Julia
   I/O + conservative-regrid runtime (it uses ConservativeRegridding.jl).
   Does EarthSciIO (a) become a multi-language repo mirroring ESS's package
   layout, with EarthSciData.jl refactored to be its Julia member (delegating
   regridding to the ESS FAQ assembly rather than ConservativeRegridding.jl),
   or (b) stay the non-Julia I/O while EarthSciData.jl remains the Julia one?
   Lean (a) for a single conceptual home; it implies a phased refactor of
   EarthSciData.jl.
2. **Source geometry hand-off.** The conservative overlap-join needs source-cell
   polygons, not just values. Either EarthSciIO returns those polygons (derived
   from the file's CRS/grid metadata), or ESD/GDD constructs the *source* grid
   from the loader's `DataLoaderSpatial` block too — in which case EarthSciIO
   shrinks to "bytes only" and ESD owns both source and target geometry. The
   latter is the cleaner layering if GDD can express a source latlon/staggered
   grid from `DataLoaderSpatial`.
3. **`kind: "table"`** (§6) — accept the explicit tabular kind, or keep
   overloading `points`?

## 9. Migration / phasing

1. Land this RFC; file beads for (a) the dependency migration, (b) repo
   creation, (c) the §6 schema decision, (d) the EarthSciData.jl relationship.
2. Carve the pure helpers (§3.1) into a stable, dependency-free ESS surface and
   add conformance fixtures for url/time/mirror resolution (most already exist).
3. Stand up EarthSciIO; move the §3.2 code; have it import the §3.1 helpers.
4. Drop the heavy deps from `earthsci-toolkit` (§3.3) once nothing in the
   serialization core imports them.
5. Decide and execute the EarthSciData.jl relationship (open decision 1).

The shared `.esm` fixtures remain in ESS as the conformance contract both ESS
and EarthSciIO test against.
