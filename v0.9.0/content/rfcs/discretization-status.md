# Discretization RFC — Implementation Status

> **SUPERSEDED (v0.8.0 clean break).** The bespoke discretization / spatial-grid machinery this document concerns was removed from the schema in v0.8.0; grid geometry and discretization are now expressed as `aggregate` Functional Aggregate Query nodes (see `semiring-faq-unified-ir.md`). Retained for historical context only.


Audit status for [`discretization.md`](./discretization.md) sections, as they
land in `esm-schema.json` / `esm-spec.md` / bindings. Scope is the on-wire
schema surface — binding-side runtime work is tracked in the per-binding
beads.

## §6 Grids — landed (gt-5kq3, v2.1)

Top-level `grids` map with `cartesian` / `unstructured`
families is in `esm-schema.json`. Each grid declares `dimensions`,
`locations`, `metric_arrays` and `connectivity` (unstructured).
Loader-backed geometry works by reference:

- `GridMetricGenerator.kind = "loader"` + `{loader, field}` (schema line ~1947–1986)
- `GridConnectivity.{loader, field}` (schema line ~2016–2040)
- `GridMetricGenerator.kind = "builtin"` with a closed name set (currently
  empty); unknown names reject with `E_UNKNOWN_BUILTIN`.

The `tests/grids/unstructured_mpas.esm` fixture rounds-trips in all five
bindings and exercises both loader-backed connectivity and loader-backed
metric arrays.

## §8 `data_loaders` — landed (gt-xboy audit → gt-pgls amendment)

### What's landed

Grid → loader wiring is end-to-end: a grid's `metric_arrays.<m>.generator.{loader, field}`
and `connectivity.<c>.{loader, field}` resolve by name against a top-level
`data_loaders` entry and pick a field that the loader declares under
`variables.<name>`. Pipeline Step 3 (§11) treats loader / builtin
generators as deferred handles — the rewrite engine does not materialize
bulk data.

RFC §8.A (new `kind: "mesh"`, `mesh` subobject with `topology`,
`connectivity_fields`, `metric_fields`, `dimension_sizes`, plus a
`determinism` block) landed under gt-pgls:

| RFC §8.A item | Status |
|---|---|
| `DataLoader.kind` enum includes `"mesh"` | **landed** — enum is now `["grid", "points", "static", "mesh"]` |
| `DataLoader.mesh.{topology, connectivity_fields, metric_fields, dimension_sizes}` | **landed** — `$defs/DataLoaderMesh` (required when `kind: "mesh"`) |
| `DataLoader.determinism.{endian, float_format, integer_width}` | **landed** — `$defs/DataLoaderDeterminism` |
| §8.1 fields table lists `kind: "mesh"` | **landed** in `esm-spec.md` §8.1 |
| §8.9 mesh loaders subsection | **landed** in `esm-spec.md` §8.9 (topology, `determinism`, worked example) |
| §8.7 "mesh connectivity out of scope" retracted | **landed** — bullet removed |
| MPAS conformance fixture uses `kind: "mesh"` | **landed** — `tests/grids/unstructured_mpas.esm` amended |
| 5 language bindings parse `kind: "mesh"` | **landed** — Julia, Python, Rust, Go, TypeScript |

The MPAS fixture now uses `kind: "mesh"` with the mesh + determinism
blocks. Pre-`gt-pgls` files that used `kind: "grid"` as a workaround
still load (the grid enum value is unchanged); new authors should prefer
`kind: "mesh"` for MPAS-style meshes.

### Adjacent gap — `Parameter.value: "from_loader"` (§6.6)

The `Grid.parameters` description (schema line 2092) claims grid-level
parameters "with `value='from_loader'` are resolved at load time from a
referenced data_loaders entry (§6.6)". The `Parameter` $def (schema line
658–671), however, does not declare a `value` field at all — only
`default: number`. The MPAS fixture works around this by providing
numeric defaults (`"nCells": 2562`) and a prose note. This is flagged
here for awareness; it is a §6 gap, not a §8 gap, and is out of scope
for gt-xboy.

### What §8.A adds (now active)

1. Structured, schema-validated declaration of which loader fields are
   integer-typed connectivity vs float-typed metric
   (`mesh.connectivity_fields` / `mesh.metric_fields`).
2. A determinism / reproducibility contract that bindings can reject
   against at load (§14 item 4) — `determinism.{endian, float_format,
   integer_width}`.
3. A dimension-sizes map that feeds `from_loader` parameter resolution
   without forcing authors to pick a numeric default
   (`mesh.dimension_sizes.<dim>: int | "from_file"`).

Load-bearing once bindings start enforcing the determinism contract
(tracked separately) and once `Parameter.value: "from_loader"` lands
(see §6 gap above).

## §11 Pipeline — landed (gt-gbs2, gt-l3dg, gt-q7sh)

`discretize(esm)` end-to-end runner, DAE binding contract, and the
Julia reference pipeline are in. Not in audit scope for gt-xboy.
