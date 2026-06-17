# Grid Conformance Harness — Family-Agnostic Runner (gt-usme)

Cross-binding conformance runner for grid generators. The runner itself
lives in this repo (ESS); **family-specific suites live in
`EarthSciDiscretizations` (ESD)** under `conformance/grids/<family>/` and
are pulled in by CI (or by a dev's local checkout). A binding is conformant
on a family iff every fixture in that family's suite passes when its
adapter is invoked.

This is the "infrastructure" half of the 2026-04-22 grid-inversion
decision: ESS ships the GridAccessor interface (per-binding) and the
runner; ESD ships the family-specific generators and conformance suites.

See:
- `EarthSciDiscretizations/refinery/rig/docs/GRIDS_API.md` — the normative
  cross-binding API contract this runner enforces.
- `manifest.schema.json` (this directory) — the JSON Schema each ESD-side
  suite manifest must validate against.
- `../../../scripts/run-grid-conformance.py` — the runner entry point.

## Status

**Phase 0 / infrastructure (this bead, gt-usme)** — the runner, manifest
schema, and adapter contract land empty of family suites. ESD's per-family
beads (Phases 1-7) populate `EarthSciDiscretizations/conformance/grids/`
as each family's generator lands. The runner accepts an external manifest
path so it can drive ESD-side suites without ESS knowing about families.

## Two checks per fixture

Every fixture exercises **two** independent contracts (GRIDS_API §4):

1. **Primary — byte-identical canonical SHA.** Each binding generates the
   grid, lowers via `to_esm` / `toESM`, canonicalizes per ESS §5.4.6, and
   the SHA-256 of the resulting bytes must match across bindings.

2. **Query-point fallback.** When the primary SHA check fails (e.g.
   transcendental-math ULP divergence on stretched curvilinear grids), the
   runner falls back to pointwise comparisons through the GridAccessor
   surface (`cell_center`, `neighbors`, `metric_eval`). Fields are
   compared with relative tolerance `tolerances.default_rel` (default
   `1e-14`); per-field overrides come from the manifest.

The query-point engine is also the only check available for accessor-only
families (no whole-grid lowering — e.g. mid-development families that
expose accessors but whose `to_esm` still returns a placeholder). A
fixture can opt out of the SHA check via `"sha_check": false`.

## Reference binding for ULP ties

When the ULP fallback fires, Julia is the reference (GRIDS_API §4.3). The
runner reports the max relative deviation per field and the binding-pair
and exits non-zero iff the deviation exceeds the tolerance.

## Manifest layout

A family-specific suite is a directory containing `manifest.json` plus
any inline-grid `.esm` files referenced by `grid.source = "file"`
fixtures.

```
EarthSciDiscretizations/
  conformance/
    grids/
      cartesian/
        manifest.json
        fixtures/
          cart_64x64x32.esm        # optional — inline grid files
      mpas/
        manifest.json
        fixtures/
          x1_2562_panel.esm
      duo/
        manifest.json
      ...
```

The runner is invoked once per family directory:

```bash
python scripts/run-grid-conformance.py \
    --manifest <path-to-manifest.json> \
    --bindings julia,python,rust,typescript \
    --output conformance-results/<family>.json
```

`--bindings` defaults to all bindings declared in the manifest's
`bindings_required` list. A binding listed in `bindings_optional` is
skipped silently if its adapter is not on PATH. A required binding
that is missing is a failure.

### Manifest schema

The full JSON Schema lives in `manifest.schema.json`; the prose summary:

```jsonc
{
  "category":    "grid_conformance",
  "version":     "1.0",
  "family":      "cartesian",        // informational; runner is agnostic
  "description": "...",

  "tolerances": {
    "default_rel": 1e-14,
    "per_field":   { "area": 1e-12 }
  },

  "bindings_required": ["julia", "rust"],
  "bindings_optional": ["python", "typescript"],

  "fixtures": [
    {
      "id":   "cart_64x64x32_basic",
      "tags": ["smoke", "uniform"],

      // Either a generator-opts spec ...
      "grid": {
        "source": "generator",
        "family": "cartesian",
        "opts":   { "nx": 64, "ny": 64, "nz": 32,
                    "extent": [[0,0,0],[1,1,1]] }
      },
      // ... or a path to a pre-canonicalized .esm grid:
      // "grid": { "source": "file", "path": "fixtures/cart_64.esm" }

      "sha_check": true,             // optional, default true

      "queries": [
        { "id": "ctr_0_0_0",     "op": "cell_center",
          "args": [0, 0, 0] },
        { "id": "nbr_of_cell_5", "op": "neighbors",
          "args": [5] },
        { "id": "dx_at_10_10",   "op": "metric_eval",
          "args": ["dx", 10, 10] }
      ]
    }
  ]
}
```

### Query operations

The runner is family-agnostic: it issues opaque query operations to the
adapter and compares whatever the adapter returns. The vocabulary is
fixed at the GridAccessor surface plus the SHA op:

| op             | args                              | result type     |
|----------------|-----------------------------------|-----------------|
| `to_esm_sha`   | (none)                            | hex SHA-256     |
| `cell_center`  | indexes per family (`i`,`j`,…)    | array of floats |
| `neighbors`    | cell handle (int or panel-tuple)  | array of cell handles |
| `metric_eval`  | metric name + indexes             | scalar float    |

Adapters MUST treat unknown ops as `unsupported` (not error). This lets
the corpus grow new ops without forcing every binding to implement them
in lock-step.

## Adapter contract (per binding)

Every binding ships a CLI adapter discoverable at one of:

- `$EARTHSCI_GRID_ADAPTER_<BINDING>` env var (full command), or
- `earthsci-grid-adapter-<binding>` on `PATH`.

The adapter reads a manifest and emits a results JSON:

```bash
<adapter> --manifest <path> --output <path>
```

Output schema (per adapter run):

```jsonc
{
  "binding":         "julia",
  "binding_version": "0.2.0",
  "started_at":      "2026-04-22T16:33:00Z",
  "finished_at":     "2026-04-22T16:33:08Z",
  "fixtures": {
    "<fixture_id>": {
      "status":  "ok" | "error" | "skipped",
      "error":   "<msg if status=error>",
      "queries": {
        "<query_id>": {
          "status": "ok" | "error" | "unsupported",
          "result": <JSON value — number, array, or string>,
          "error":  "<msg if status=error>"
        }
      }
    }
  }
}
```

The runner aggregates these into a cross-binding report, comparing the
`result` of each `(fixture, query)` pairwise and against the Julia
reference where present.

### Result-type comparison rules

| Result type   | Comparison                                                    |
|---------------|---------------------------------------------------------------|
| string (SHA)  | exact match                                                   |
| number        | abs/rel tolerance per `tolerances` (relative dominates)        |
| array of num  | shape-equal + per-element abs/rel                              |
| array of int  | exact match (used for neighbor handles)                        |
| nested array  | recursive — same rules per leaf                                |
| object        | keys match exactly; values per type                            |

`unsupported` results are not failures — they are reported as
`unsupported` in the cross-binding diff and excluded from the pass/fail
tally for that binding. A query that is `unsupported` in **every**
binding is a manifest authoring error and the runner warns.

## Pass/fail semantics

- **Per fixture**: a fixture passes a binding iff (a) its `to_esm_sha`
  matches the reference (or `sha_check: false`), or (b) every supported
  query agrees with the reference within tolerance.
- **Per binding**: a binding passes the suite iff every fixture passes.
- **Per family suite**: the suite passes iff every required binding
  passes. Optional-binding failures are warnings, not errors.

The runner exits `0` iff every required binding passes every fixture in
the manifest, `1` otherwise. JSON report is always written.

## Self-test

The runner ships a built-in self-test that drives a stub adapter
(`scripts/_grid_adapter_stub.py`) against `tests/conformance/grids/example/`.
It validates the runner's plumbing — manifest loading, adapter dispatch,
result diffing, exit codes — without depending on any real binding. CI
runs it on every change to the runner.

```bash
python scripts/run-grid-conformance.py --self-test
```

## What this bead does NOT include

- Family-specific fixtures (live in ESD; populated by ESD-side beads).
- Per-binding GridAccessor implementations (sibling beads gt-hvl4 julia,
  gt-c9j5 rust, gt-6trd python, gt-j2b8 typescript).
- The CLI adapter inside each binding (each binding's GridAccessor bead
  may add its adapter; alternately a follow-up bead per binding).

The runner is wired to find adapters when they appear and to report
`adapter not found` cleanly until then.
