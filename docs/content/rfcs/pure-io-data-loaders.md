---
title: "Pure-I/O data loaders: separating read-from-disk from regridding and reprojection"
description: "Strip the data loader down to a single responsibility — read/update a slice of data from disk — by moving regridding (value transfer) and reprojection (coordinate transform) out of the loader and into a model component built from existing ESD pieces. The loader's native grid is expressed once, in the shared GDD Grid format; its variables seed the cadence partition as discrete (or const). A pure-I/O loader is then a model subsystem and a single-component file becomes externally referenceable, closing the loader-reuse gap (ESS issue #24)."
---

> **Status:** Draft proposal. **Bead:** unassigned.
> **Target repos (cross-rig):**
> - **EarthSciSerialization (ESS)** — the `.esm` schema/spec: `DataLoader`,
>   the GDD `Grid` family, subsystem inclusion (§4.7), top-level document
>   validation, loader-seeded cadence, and a small expression-operator-set
>   addition (hyperbolic trig).
> - **EarthSciDiscretizations (ESD)** — a new `reprojection/` rule directory and
>   a staggered B-spline interpolating regridder alongside the existing
>   `regridding/conservative_regrid_overlap_join.esm`.
> - **EarthSciModels / EarthSciData (downstream)** — the
>   `components/earthsci_data/*.esm` files are rewritten into pure loader +
>   regridding-model pairs (migration).

---

## 1. Summary

Today a `DataLoader` does three different jobs at once: it (a) locates and reads
data from disk, (b) describes the data's native grid **and** carries a coordinate
reference system (`spatial.crs` / `grid_type`), and (c) configures regridding
(`regridding.fill_value` / `extrapolation`). Conflating I/O with transformation
is the root cause of the loader-reuse gap in ESS issue #24 and of the format's
two parallel grid representations.

This RFC reduces the loader to **one** responsibility — *read/update a slice of
data from disk* — and relocates the two transformation concerns:

- **Reprojection** (coordinate transform between CRSs) → new declarative
  **ESD `reprojection/`** rules.
- **Regridding** (value transfer onto a target grid) → the existing
  **ESD `regridding/`** conservative kernel plus a new staggered B-spline
  interpolating kernel, chosen **per variable**.

Both transforms are composed by an ordinary **model component associated with
the loader** (the ERA5/WRF-style model that already exists in every
`earthsci_data` file). The loader's *native* grid is expressed once, in the
shared **GDD `Grid`** format, and its output variables seed the cadence partition
as `DISCRETE` (or `CONST` for non-time-varying data).

A loader reduced to pure I/O is no longer a special externally-registered
artifact: it is a plain component that can be a **model subsystem** and can be
**referenced across files** when it is the sole top-level component — which is
exactly what issue #24 asked for, obtained by *subtraction* rather than by adding
a new reference channel.

## 2. Motivation

### 2.1 Immediate trigger — the loader-reuse gap (issue #24)

A coupling/simulation file that wants to drive several models from authoritative,
already-published loaders cannot reuse those loaders by reference: §4.7 subsystem
inclusion is restricted to a file containing *exactly one top-level model or
reaction system* that *must not carry `kind`*, and a `DataLoader` is identified
*by* `kind`. So a consumer must inline copies of loader definitions (which then
drift on every upstream change) or omit them (and the `.esm` is no longer
self-describing). See issue #24 for the full analysis.

### 2.2 Deeper problem — I/O conflated with transform

The reuse gap is a symptom. A loader carries `spatial.crs`/`grid_type` (a
projection) and a `regridding` block — transformation concerns — even though the
transformation target (the consuming model's grid) is not a property of the data
on disk. That conflation produces two further costs:

1. **Two grid representations.** The loader describes grids with
   `DataLoaderSpatial` (`crs` strings, a `grid_type` enum); ESD describes grids
   with the GDD `Grid` family (parametric `family` + `parameters`). The same
   geometric object has two encodings that cannot be cross-validated.
2. **The loader is "the only externally-registered mechanism"** (esm-spec §14)
   partly *because* it bundles runtime-specific regridding. Strip the regridding
   and a loader is just a typed reader — no longer categorically special.

### 2.3 Why the obvious alternatives don't work (and why this one does)

Three restructurings were considered and rejected before arriving at this design
(full reasoning preserved from the issue #24 discussion):

- **Nest the loader inside the model unchanged.** The `Model` schema has no
  `data_loaders` slot and `subsystems` is typed `oneOf:[Model, ReactionSystem,
  SubsystemRef]`; nesting needs a schema change regardless, and a loader that
  still regrids inverts ownership (loaders are shared by many consumers, each on
  its own grid).
- **Strip the file to a loader only.** A `data_loaders`-only document fails
  top-level validation today (the document `anyOf` requires `models`,
  `reaction_systems`, or a GDD `kind`), and §4.7 still requires the referenced
  single component to be a *model or reaction system*.
- **Treat the loader as a model subcomponent while it still regrids.** The
  format wires loaders and models as **coupling peers** (scoped references treat
  a `data_loaders` key as a top-level root; the coupling section connects
  "models, reaction systems, and data loaders"); a still-transforming loader is
  a peer, not a child.

The resolving insight: the loader is a subcomponent only **after** the transform
is removed from it. Once the loader is pure I/O, "loader is a subsystem of the
regridding model" is the correct ownership, the existing §4.7 mechanism applies
(with a one-line extension), and no new reference channel or fragment selector is
needed.

## 3. Design overview — a three-stage pipeline

Getting source data onto a model's grid is three composable stages:

```
 ┌────────────────────┐   ┌──────────────────────┐   ┌─────────────────────┐
 │ 1. READ SLICE      │   │ 2. REPROJECT         │   │ 3. REGRID           │
 │ data loader        │ → │ ESD reprojection/    │ → │ ESD regridding/     │
 │ (pure I/O)         │   │ (coordinate xform)   │   │ (value transfer,    │
 │ native GDD Grid    │   │ native CRS → common  │   │  per variable)      │
 └────────────────────┘   └──────────────────────┘   └─────────────────────┘
        owned by the data loader        composed by the regridding MODEL component
```

- **Stage 1 — loader.** Returns a coordinate-aware slice: raw values plus the
  *native* grid, expressed as a GDD `Grid` (including the native CRS as
  description, not as a transform). Nothing else. Its variables seed the cadence
  partition (§4.6).
- **Stage 2 — reprojection.** A declarative ESD rule transforms coordinates
  between CRSs (e.g. WRF/NEI Lambert-Conformal cell corners → lat-lon), producing
  cell geometries in a common frame. Closed-form forward **and** inverse.
- **Stage 3 — regridding.** A declarative ESD program transfers values onto the
  target GDD `Grid`, with the method chosen **per variable** (§5.2): conservative
  for cell-centered fields, B-spline interpolation for staggered (edge/face)
  fields, and cell-averaging (with a configurable missing-value fill) for
  scattered point sources.

Stages 2–3 are composed by an ordinary **model** (§6). The loader is that
model's subsystem.

## 4. ESS changes — the `.esm` format

### 4.1 Data loader becomes pure I/O

`DataLoader` loses everything except what is needed to *locate, read, and slice*
bytes, plus a *description* of the native grid:

- **Removed:** the `regridding` block (`DataLoaderRegridding` = `fill_value`,
  `extrapolation`). Regridding is a model concern, chosen per variable (§5.2, §6).
- **Replaced:** the bespoke `spatial` block (`DataLoaderSpatial` = `crs`,
  `grid_type`, `extent`, `resolution`, `staggering`) is replaced by a reference
  to / embedding of a GDD `Grid` describing the native grid (§4.2). The native
  CRS is retained — as *description of what is on disk*, used by stage 2 as the
  source CRS — but expressed in the unified grid format, and the loader performs
  **no** reprojection itself.
- **Retained:** `kind`, `source`, `variables`, `temporal` (optional — its absence
  means non-time-varying data, §4.6), `mesh` (for `kind: mesh`), `determinism`,
  `reference`, `metadata`.

Per Q1: the native grid (including the CRS) stays with the loader, but is
expressed in the GDD format.

This pure-I/O reduction and GDD-`Grid` native representation apply to **all**
loader kinds in scope: `grid` (the `crs`-bearing families below), `points`
(OpenAQ — native `Grid` family `unstructured`; verified geographic lat-lon
in EarthSciData.jl), and `mesh` (connectivity + metric fields already live in
`Grid`). None of them regrid or reproject; that is always the model's job.

### 4.2 One grid representation — the GDD `Grid`, with `crs` orthogonal to `family`

The loader's native grid is expressed using the same GDD `Grid` that ESD
discretization already uses (`discretizations/grids/...`, `discretizations/gdd/
*.gdd.json`). This unifies loader-native grids, model-target grids, and
discretization grids under one schema that can be cross-validated.

The current `Grid` (`required: [family, dimensions]`; props `connectivity`,
`description`, `domain`, `extents`, `locations`, `metric_arrays`, `parameters`)
has **no CRS / projection slot** — it cannot represent a projected native grid
such as WRF's or NEI's Lambert Conformal. This RFC adds an optional `crs`
descriptor to `Grid`, **orthogonal to the topological `family`** (Q3): a lat-lon
grid and an LCC grid can share `family`/topology and differ only in `crs`.

```jsonc
// Grid (GDD) — added field, orthogonal to `family`
"crs": {
  "projection": "lambert_conformal",   // longlat | lambert_conformal | mercator | polar_stereographic | rotated_pole
  "datum": "sphere",                    // sphere(R) | WGS84 | ...
  "R": 6370000.0,                       // sphere radius, when datum=sphere
  "parameters": { "lat_1": 30.0, "lat_2": 60.0, "lat_0": 38.999996, "lon_0": -97.0 }
}
```

A geographic grid uses `projection: longlat` (the identity case). The
`crs.parameters` are exactly the parameters consumed by the stage-2 reprojection
rule (§5.1), so the descriptor that *names* the projection and the rule that
*evaluates* it share one parameter set. WRF and NEI both use
`lambert_conformal` with **different** parameters (Appendix A), exercising the
parameterized rule.

### 4.3 Data loaders as model subsystems

A pure-I/O loader may appear as a subsystem of a model. Concretely, `subsystems`
gains the loader alternative:

```jsonc
// before: "subsystems": { "<name>": oneOf[Model, ReactionSystem, SubsystemRef] }
// after:  "subsystems": { "<name>": oneOf[Model, ReactionSystem, DataLoader, SubsystemRef] }
```

The regridding model (§6) declares its loader as a subsystem; the model's
equations consume the loader's variables by the existing dot-notation
(`Parent.Loader.var`) and feed them through reprojection + regridding.

### 4.4 External references to single-component files (extend §4.7)

§4.7's file-shape rule is generalized from "exactly one top-level model or
reaction system" to **"exactly one top-level model, reaction system, or data
loader."** Two concrete edits:

1. **Top-level document validity.** Add an `anyOf` branch permitting a document
   whose sole component is `data_loaders` (today the `anyOf` requires `models`,
   `reaction_systems`, or `kind: grid_discretization_descriptor`).
2. **`SubsystemRef` resolution.** A referenced file containing exactly one
   top-level data loader resolves to that loader, named by the parent's
   subsystem key — exactly as for a single model. No fragment selector is
   required because the file is single-component (this is the structural reason
   the migration in §7 splits co-located `model + loader` files).

This is the issue #24 fix: a single-loader file (or a single-model file that
*owns* its loader as a subsystem) is referenceable through the mechanism that
already exists.

### 4.5 Operator-set addition — hyperbolic trig

Verified against origin/main, the expression operator set already provides full
trig and inverse-trig (`sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`atan2`),
`exp`/`log` (natural)/`log10`, `sqrt`, and `^` (power) — so the reprojection
math in §5.1 needs **no** new function operators. The one transcendental gap is
**hyperbolic trig**: `sinh`, `cosh`, `tanh` and the inverses `asinh`, `acosh`,
`atanh` are all absent.

This RFC adds them to the operator set across all three bindings + the Go/TS
generated types, spec'd with fixed signatures and tolerances exactly like the
existing transcendentals (and mirroring the pending `mod`/`round` addition in
issue #20). They are ordinary unary elementwise operators dispatched exactly like
`sin`/`exp` — no new engine *control* primitive.

Motivation: hyperbolic functions are required for the Mercator-class
reprojections named in §5.1 (the Gudermannian inverse `φ = atan(sinh(y/R))`),
round out the transcendental set for general expressiveness, and were requested
as part of this work.

> The closed **`fn` registry** (`registered_functions.md`) is a different
> mechanism — it holds only `datetime.*` + `interp.searchsorted`, and is **not**
> involved here. Trig/exp/hyperbolic are expression *operators*, not `fn`
> entries.

### 4.6 Loader-seeded cadence — `discrete` vs `const`

The cadence-partition pass (FAQ-IR RFC §6.1) classifies every node of the
computational graph into a total order `CONST ⊏ DISCRETE ⊏ CONTINUOUS`, with a
node's class the **max** over its inputs and the chain bottoming out at *declared
leaf cadences* (state seeds `CONTINUOUS`, parameters/literals seed `CONST`, and a
`discrete` variable kind seeds `DISCRETE`). That RFC already names "loaded met
fields" and "emission inventories that update on a schedule" as the canonical
`discrete` inhabitants — this RFC makes the data loader their concrete source:

- **A loader with `temporal`** seeds its output variables `DISCRETE`, with the
  **refresh trigger = the loader's update times** (derived from `temporal`):
  values are piecewise-constant between ingest events and refreshed on each.
- **A loader without `temporal`** (item 8 — already structurally allowed, since
  `temporal` is optional) describes **non-time-varying** data; its variables seed
  `CONST` and fold at bind.

A pure function of loader fields stays `DISCRETE` (or `CONST`) by max-propagation;
combined with integrated state it becomes `CONTINUOUS` — the existing partition
does the rest, so "downstream of a loader" is `DISCRETE` exactly when it has no
continuous input. Provenance sub-tag (§6.1): loader leaves fold **at bind**
(external resource), not at compile.

### 4.7 Schema / spec delta (summary)

| `$def` / artifact | Change |
|---|---|
| `DataLoaderRegridding` | **Deleted.** |
| `DataLoader.regridding` | **Removed** (regridding is per-variable in the model). |
| `DataLoaderSpatial` | **Deleted**; `DataLoader` references a GDD `Grid` for the native grid instead. |
| `DataLoader.temporal` | Stays **optional**; absence ⇒ non-time-varying ⇒ `CONST` (§4.6). |
| `Grid` | **Add** optional `crs` (projection + datum + parameters), orthogonal to `family`. |
| `subsystems` value | `oneOf` **gains** `DataLoader`. |
| top-level `anyOf` | **Add** a `data_loaders`-only branch. |
| `SubsystemRef` | Resolution **accepts** a single top-level data loader. |
| expression operators | **Add** `sinh`/`cosh`/`tanh`/`asinh`/`acosh`/`atanh` (§4.5). |
| cadence partition | Loader variables seed `DISCRETE`/`CONST` leaves (§4.6) — no schema change beyond the existing `discrete` kind. |
| esm format version | **Bumped** (breaking — §7). |

## 5. ESD changes — rules and components

### 5.1 New `reprojection/` directory

A new top-level `reprojection/` directory in ESD holds declarative coordinate
transforms, one rule per projection family, parameterized by the projection
parameters and expressed over the **expression operator set**
(`sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`atan2`/`log`/`exp`/`^`/`sqrt`, plus the
new hyperbolic ops from §4.5). Each rule provides **forward** (lon,lat → x,y) and
**inverse** (x,y → lon,lat) closed-form transforms, consistent with the
declarative-or-fail principle (no imperative fallback; a projection whose inverse
is not closed-form is reported, not hacked in).

Initial coverage (the distinct projections actually used in
`EarthSciModels/components/earthsci_data`, see Appendix A):

- `reprojection/longlat.json` — geographic WGS84 identity (degenerate forward =
  inverse = identity; included so the pipeline is uniform for unprojected grids).
- `reprojection/lambert_conformal.json` — Lambert Conformal Conic, spherical,
  parameterized by `{lat_1, lat_2, lat_0, lon_0, R}`. Closed-form both
  directions (Appendix B). **Two** datasets use it with different parameters
  (WRF and NEI2016), so the rule is genuinely parameterized, not hard-coded.

The remaining families in the `grid_type` enum (`mercator`,
`polar_stereographic`, `rotated_pole`) are specified as the same rule shape and
added when a dataset needs them — not pre-built speculatively. (Mercator's
inverse is where the §4.5 hyperbolic ops are first needed.)

### 5.2 Regridding — per variable, by staggering

Per Q2 the method is chosen **explicitly per variable** (not inferred from
dataset-level `metadata.tags`), and per the expanded scope the granularity is
**per variable rather than per loader**. The choice follows the variable's
location on its GDD `Grid`, which is concrete and deterministic:

- **Cell-centered, gridded → conservative.** `regridding/
  conservative_regrid_overlap_join.esm` (existing) — area-weighted (overlap join
  → clip → polygon_area → A_j → apply → normalize). Mass-conserving, the right
  default for cell-centered fluxes/emissions.
- **Cell-edge / face-staggered, gridded → B-spline interpolation.**
  `regridding/bspline_regrid.esm` (new) — the staggered-grid B-spline kernel
  (the EarthSciData `InterpolatingRegridder`), for edge/face fields such as wind
  components on Arakawa-C grids. Declarative polynomial evaluation; no
  transcendentals. (A plain `bilinear` kernel is **not** added — it is the
  degree-1 special case of this B-spline and would be redundant.)
- **Scattered points → cell-averaging.** Point loaders (OpenAQ) regrid by
  **averaging the source station values that fall within each target cell** — the
  method EarthSciData.jl's OpenAQ loader already uses (`_build_cell_station_map`
  + per-cell mean). A target cell with **no** contributing station receives a
  **configurable `missing_value`** declared in the JSON; this is the point
  analogue of a no-data fill, not an interpolation. (Plain bin-average + missing
  fill — no scattered-interpolation kernel needed.)

Default-by-staggering is a deterministic derivation from the variable's `Grid`
location, **not** a fuzzy tag inference; an author may override the method per
variable. All kernels are declarative `.esm` evaluated through the ESS engine,
selected by the regridding model (§6).

### 5.3 Projected grids in the GDD `Grid` family

ESD's grid construction (`discretizations/grids/`) currently builds
`cartesian`/`lat_lon`/`arakawa`/`duo` families with no projection. To hold a
projected native grid (WRF/NEI LCC), the GDD `Grid` gains the `crs` descriptor
(§4.2) and ESD adds a `lambert_conformal` grid example/fixture. Construction stays
declarative (closed-form, no iteration): the projected grid's cell-corner
coordinates are produced by applying the `reprojection/lambert_conformal.json`
**inverse** to the regular projected (x,y) lattice.

## 6. The regridding/reprojection model component (convention)

Per Q3 (convention), no new schema kind is introduced. The component that
performs reprojection + regridding is an ordinary `model` — the same `WRFCoupler`/
`LANDFIRECoupler`/… models that already exist in every `earthsci_data` file —
restructured so that:

1. it declares the (now pure-I/O) loader as a **subsystem**;
2. its equations feed the loader's slice through the ESD `reprojection/` rule for
   the loader's native `crs` and then through the ESD `regridding/` program,
   choosing the kernel **per variable** by staggering (§5.2); and
3. it exposes the regridded fields on the model's (target) GDD `Grid` for
   downstream coupling — which is what consumers reference.

**Worked example — ERA5 (geographic → model grid):**

```
ERA5 model
├── subsystems.raw  = data_loaders/era5_loader.esm   (pure I/O; native Grid: longlat 0.25°; DISCRETE @ ERA5 cadence)
├── reproject:  longlat (identity) — no-op coordinate transform
└── regrid (per var):  T, q (centered) → conservative;  U, V (staggered) → B-spline
                       → model target Grid → exposes ERA5.T, ERA5.U, ...
```

**Worked example — WRF (Lambert Conformal → model grid):**

```
WRF model
├── subsystems.raw  = data_loaders/wrf_loader.esm     (pure I/O; native Grid: lambert_conformal LCC)
├── reproject:  lambert_conformal{lat_1:30,lat_2:60,lat_0:39,lon_0:-97,R:6.37e6} → lon/lat
└── regrid (per var):  scalars (centered) → conservative;  U, V (C-grid edges) → B-spline
                       → model target Grid → exposes WRF.U, WRF.V, ...
```

A consumer (e.g. a Camp Fire simulation) references the **WRF model** (single
top-level component, owns its loader subsystem) by `{ "ref": "./wrf.esm" }` and
gets the regridded fields — closing issue #24's use case through §4.7 alone.

## 7. Migration — hard break + lockstep (Q4)

Removing `regridding` and `DataLoaderSpatial` is breaking. Per Q4 we take a clean
flag-day cut rather than a deprecation window:

1. **Bump the esm format version.** A loader carrying `regridding` or the old
   `spatial` shape is **rejected** at load (clear error pointing here).
2. **Rewrite all ten `EarthSciModels/components/earthsci_data/*.esm` files** in
   lockstep into:
   - a **pure-I/O loader** (`source`/`variables` + optional `temporal` + native
     GDD `Grid` with `crs`), and
   - a **regridding model** (existing coupler model + loader subsystem +
     reproject + per-variable regrid), per §6.
   Files: `ceds`, `edgar_v81_monthly`, `era5`, `geosfp`, `landfire`,
   `ncep_ncar`, `nei2016_monthly`, `openaq`, `usgs3dep`, `wrf`. Projected: **`wrf`
   and `nei2016_monthly`** (`lambert_conformal`, different params); the rest
   geographic (`longlat`, identity reprojection). Per-variable regridding by
   staggering (centered → conservative, staggered → B-spline); `openaq` is points
   → cell-averaging with a configurable `missing_value` for empty cells.
3. **Cross-binding lockstep.** The schema change + operator addition land in all
   three ESS bindings (Julia/Rust/Python) + Go/TS generated types simultaneously;
   the ESD rules land with their conformance fixtures; EarthSciModels/EarthSciData
   update in the same coordinated wave.

## 8. Conformance & testing

- **Reprojection round-trip.** For each projection rule, `inverse ∘ forward ≈
  identity` to tolerance over the grid domain, cross-binding byte-identical where
  the closed-form is exact; LCC validated against known proj4 reference points
  for **both** WRF and NEI parameter sets.
- **Hyperbolic ops.** `sinh`/`cosh`/`tanh`/`asinh`/`acosh`/`atanh` get the same
  cross-binding value + tolerance fixtures as the existing `sin`/`exp` operators.
- **Regridding invariants.** Conservative: `Σ_j A_j F_tgt = Σ_i A_i F_src`
  (conservation) and `Σ_i W_ij = 1` (partition of unity). B-spline: reproduction
  of the spline's polynomial degree exactly on staggered locations. Point:
  cell mean of contributing stations; the configured `missing_value` for cells
  with no station.
- **Cadence.** A loader with `temporal` seeds `DISCRETE` (refreshes on its update
  schedule, memoized between); a loader without `temporal` seeds `CONST` (folds
  at bind). Partition output asserted against the FAQ-IR §6.1 conformance
  adapters.
- **GDD grid parity.** A loader's migrated native `Grid` reproduces the geometry
  the old `DataLoaderSpatial` described (extent/resolution/staggering), validated
  by a fixture per migrated dataset.
- **End-to-end.** A consumer file `{ref}`-including a migrated single-component
  model resolves, regrids, and produces fields identical (to tolerance) to the
  pre-migration inline pipeline.
- **Engine.** All ESD rules are declarative `.esm` evaluated through the ESS
  engine — no new engine *control* primitive (the §4.5 hyperbolic ops are
  elementwise math, dispatched exactly like `sin`/`exp`); if a stage appears to
  need a control/guard primitive, stop and report.

## 9. Open questions / future work

1. **Iterative-inverse projections.** `longlat` and spherical `lcc` invert in
   closed form; ellipsoidal datums or `polar_stereographic` edge cases may not.
   Declarative-or-fail: report, don't add an imperative solver.

## Appendix A — Projection inventory (`earthsci_data`)

| File | Native CRS | `grid_type` | Reprojection | Regridding (by variable) |
|---|---|---|---|---|
| `wrf` | `+proj=lcc +lat_1=30 +lat_2=60 +lat_0=39 +lon_0=-97 +a=b=6.37e6` | `lambert_conformal` | LCC ↔ lonlat | centered→conservative, C-grid wind→B-spline |
| `nei2016_monthly` | `+proj=lcc +lat_1=33 +lat_2=45 +lat_0=40 +lon_0=-97 +a=b=6370997` | `lambert_conformal` | LCC ↔ lonlat | emissions (centered)→conservative |
| `geosfp` | `+proj=longlat +datum=WGS84` (0.3125°×0.25°) | `latlon` | identity | centered→conservative, staggered→B-spline |
| `era5` | geographic (lat-lon) | `latlon` | identity | centered→conservative, wind→B-spline |
| `ncep_ncar` | geographic (lat-lon) | `latlon` | identity | centered→conservative, wind→B-spline |
| `landfire` | `+proj=longlat +datum=WGS84` (~30 m) | `latlon` | identity | static, centered→conservative |
| `usgs3dep` | `EPSG:4326` (~10 m) | `latlon` | identity | static, centered→conservative |
| `ceds` | geographic (lat-lon) | `latlon` | identity | emissions→conservative |
| `edgar_v81_monthly` | geographic (lat-lon) | `latlon` | identity | emissions→conservative |
| `openaq` | `+proj=longlat +datum=WGS84` (point stations) | `unstructured` | identity | cell-average; empty cells→configurable `missing_value` |

> Verified verbatim: `wrf`/`nei2016` (LCC), `geosfp`/`landfire`/`usgs3dep`
> (longlat), `openaq` (longlat point stations, EarthSciData.jl). `era5`/
> `ncep_ncar`/`ceds`/`edgar` read from the consistent geographic pattern; confirm
> each during migration. Projected datasets: `wrf` and `nei2016_monthly`.

## Appendix B — Lambert Conformal Conic (spherical), closed form

Forward (λ, φ) → (x, y), with standard parallels φ₁, φ₂, origin (λ₀, φ₀),
radius R:

```
n  = log(cos φ₁ / cos φ₂) / log( tan(π/4 + φ₂/2) / tan(π/4 + φ₁/2) )
F  = cos φ₁ · tan(π/4 + φ₁/2)^n / n
ρ  = R · F / tan(π/4 + φ/2)^n
ρ₀ = R · F / tan(π/4 + φ₀/2)^n
x  = ρ · sin( n (λ − λ₀) )
y  = ρ₀ − ρ · cos( n (λ − λ₀) )
```

Inverse (x, y) → (λ, φ), closed form:

```
ρ  = sign(n) · sqrt(x² + (ρ₀ − y)²)
θ  = atan2( x, ρ₀ − y )
λ  = λ₀ + θ / n
φ  = 2 · atan( (R F / ρ)^(1/n) ) − π/2
```

All operators (`sin`, `cos`, `tan`, `atan`, `atan2`, `log`, `^`, `sqrt`,
`sign`) are in the expression operator set (`log` = natural log; power is `^`),
so the rule is declarative and cross-language byte-comparable to tolerance.
Both the WRF and NEI2016 parameter sets flow through this one rule.
