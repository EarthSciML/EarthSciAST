# Refresh-Path Conformance (`tests/conformance/refresh/`)

Cross-language conformance for the **discrete-cadence loader + dependent-variable
refresh** consumer. Governed by **CONFORMANCE_SPEC.md §5.10**.

This set pins the **composition** the refresh consumer performs each cadence
boundary:

```
provider.refresh(t)  ->  write NATIVE forcing buffer  ->  in-model regrid + integrate segment
```

The regrid is **in-model** — an ordinary coupling contraction the RHS evaluates
(`F_tgt[j] = sum_i W[i,j]*F_src[i]`, with `W` a const weight matrix) — **not** a
refresh-time seam. The obsolete `RegridApplier` / `Regrid` seam was removed in
v0.8.0; the refresh executor now writes the native forcing straight into the
buffer, and regridding is part of the in-model coupling relationship.

It is the capstone over two pieces that already have their own conformance sets:

* **§5.7 cadence PARTITION** (`tests/conformance/cadence/`) — *which class* each
  node is (CONST / DISCRETE / CONTINUOUS) and where it materializes. No runtime
  values.
* **§5.8 regrid KERNEL geometry** (`tests/conformance/geometry/`) — the overlap
  areas / conservation invariants of a single regrid. No cadence, no integration.

§5.10 asserts the two compose to the same **regridded arrays** and the same
**integrated trajectory** across bindings.

## The model

One model `M` over a 3-cell sim grid `j ∈ [1,3]`, fed from a coarse 6-cell native
grid `i ∈ [1,6]`:

| Var | Kind | What |
|-----|------|------|
| `W` | const observed | 2:1 area-weighted regrid weights `W[i,j]` (0.5 for the two source cells in each target cell) |
| `F_src` | DISCRETE loader (`emis`, has `temporal`) | native 6-cell source, refreshed at anchors |
| `scale_src` | CONST loader (`factors`, no `temporal`) | native 6-cell scale, materialized once |
| `F_tgt` | observed | `sum_i W[i,j]*F_src[i]` — the DISCRETE-materialized in-model regrid |
| `scale_tgt` | observed | `sum_i W[i,j]*scale_src[i]` — the CONST in-model regrid |
| `c`, `d` | states | `D(c[j]) = scale_tgt[j]*F_tgt[j]`, `D(d[j]) = c[j]` (coupled) |

## Layout

| File | What it is |
|------|------------|
| `manifest.json` | Fixture list, tolerances, pinned integrators, required bindings. |
| `fixtures/coupled_refresh_regrid.esm` | The shared model (above). |
| `golden/coupled_refresh_regrid.json` | The analytic golden: native loader fields, the in-model regridded arrays, and the integrated trajectory. |

Strictly **offline** — the native fields come from the golden's `native_fields`;
no network, no file I/O.

## The two-view contract (important for adapter authors)

A loader-fed field is declared `discrete` + `data_ingest` in the `.esm` so the
**cadence classifier** can resolve it CONST vs DISCRETE (its loader's `temporal`
block decides). But the **typed array-simulate compiler** has no `Discrete`
variable type — it resolves `M.F_src` / `M.scale_src` as **forcing names** through
the live forcing buffer. So an adapter keeps two views of the one fixture:

1. **classifier view** — the raw document, unchanged (the cadence partition reads
   the `discrete` declarations + `data_loaders`).
2. **simulate view** — the same document with the loader-fed `discrete` variables
   (and the `data_loaders` block) **stripped**, so the RHS compiler sees `F_src` /
   `scale_src` as forcing names. (Python's `flatten` drops them automatically — the
   strip is free; Julia and Rust strip the raw JSON.)

## Adapter contract

For the fixture, each binding's adapter:

1. Loads the fixture; builds the **simulate view** and compiles the coupled RHS +
   its forcing buffer.
2. Seeds one provider per loader **offline** from `golden.native_fields` (CONST
   `factors` returns the 6-cell `M.scale_src`; DISCRETE `emis` returns the 6-cell
   `M.F_src` at each `refresh_times` anchor).
3. `materialize_const` once (CONST `scale_src`), then drives the segmented solve
   over `golden.cadence.refresh_times` ∩ `tspan`, writing the **native** forcing
   into the buffer once per boundary and threading state across segments. The
   in-model `W` contraction regrids it inside the RHS.
4. **Asserts** (loudly, non-zero exit on divergence):
   * **regrid band** — the in-model regridded observeds `M.F_tgt` (per anchor) and
     `M.scale_tgt` equal `golden.regridded_fields` within `regrid_rtol` /
     `regrid_atol`. Distinct paired native values make the averaging load-bearing —
     a stale (un-refreshed) or identity forcing fails here.
   * **trajectory band** — each segment-boundary state (`M.c[j]` / `M.d[j]`) equals
     `golden.trajectory` within `traj_rtol` / `traj_atol`.

Each binding reads the regridded observeds through its build-observability sink
(`BuildInspection.setup_arrays` in Python/Rust; Julia reads `F_tgt` from the
`DiscreteMaterializer` cache and recovers `scale_tgt` from the derivative, since a
const observed is inlined rather than named).

## Tolerances

From `manifest.json` (`tolerances`); see §5.10 for the rationale.

| Band | rtol | atol |
|------|------|------|
| Regridded arrays (vs analytic) | 1e-9 | 1e-11 |
| Integrated trajectory (vs analytic) | 1e-4 | 1e-6 |

The regrid band is tight (a 2:1 average on exact values is exact up to
floating-point); the trajectory band absorbs integrator truncation, matching the
§5.9 manufactured-solution band.

## Bindings

`bindings_required` is `["julia", "python", "rust"]` — all three simulation
bindings reproduce the golden. Go and TypeScript are out of scope (rewrite-only
ports; no array simulator / refresh executor).

## Runners

* **Julia** — `pkg/EarthSciAST.jl/test/refresh_conformance_test.jl`
* **Python** — `pkg/earthsci-ast-py/tests/test_refresh_conformance.py`
* **Rust** — `pkg/earthsci-ast-rs/tests/refresh_conformance.rs`
