---
title: "Streaming output sinks: incremental simulation output to disk (Zarr), checkpoint/restart, and CF coordinates"
description: "Add an output boundary that mirrors the pure-I/O data-loader input seam. A cadence-driven Sink streams simulation state to disk incrementally instead of accumulating the whole trajectory in RAM, so runs whose results do not fit in memory become possible. Zarr is the first backend (cloud- and HPC-native, chunk-as-object). The write path lives in EarthSciIO behind a Writer registry symmetric to the read registries; EarthSciAST exposes a build_output_callback + Sink protocol symmetric to build_refresh_callback + the Provider protocol; the solver stays user-owned (library-exposes-rhs-not-solver). Includes checkpoint/restart, an additive CF coordinate-role schema delta that also covers unstructured and curvilinear grids, multi-grid coupled-component output, and cross-language parity (Julia/Python/Rust) gated by a shared conformance corpus."
---

> **Status:** Draft proposal. **Bead:** unassigned.
> **Target repos (cross-rig):**
> - **EarthSciAST (ESS)** — the `Sink` protocol + `build_output_callback` seam
>   (core + a `DiffEqCallbacks`/`SciMLBase` extension), the flat→gridded output
>   schema derivation, an additive `coordinates` registry in `esm-schema.json`,
>   and the Python/Rust runner counterparts.
> - **EarthSciIO (ESIO)** — the impure **write** boundary: a `Writer`/format
>   registry symmetric to the read `Reader`/`FORMAT_REGISTRY`, a `ZarrWriter`,
>   a store `put`/multipart-commit path, and a per-store output manifest. Mirrors
>   the existing content-addressed **read** cache discipline.
> - **Shared spec / conformance** — a language-neutral **Sink/Writer contract**
>   plus a golden corpus asserting Julia/Python/Rust emit array-identical Zarr.

---

## 1. Summary

Today every EarthSciAST runner returns the **entire** simulation trajectory in
memory. In Julia the solver runs to completion and its whole solution is copied
into `SimulationResult.u::Vector{Vector{Float64}}`
(`ext/EarthSciASTSimulateExt.jl`); Python's `SimulationResult.y` is a dense
`(n_vars, n_times)` array and Rust's `Solution.state` a `Vec<Vec<f64>>` — both
the full trajectory, both RAM-resident. For a lat×lon×level×species PDE the
product `n_timepoints × length(u0)` is exactly what exceeds memory on the large
runs this project targets. There is **no incremental output path**, and no file
writer of any kind (all NetCDF/Zarr/xarray machinery in the tree is input-side).

This RFC adds a **streaming output boundary** that is the mirror image of the
existing pure-I/O data-loader *input* boundary:

| Input (exists today) | Output (this RFC) |
|---|---|
| `build_refresh_callback(; providers, buffers) -> (cb, tstops)` | `build_output_callback(; sinks, schema, snapshot) -> (cb, tstops)` |
| `PresetTimeCallback` `affect!` **pulls** native arrays from a `Provider` | `PresetTimeCallback` `affect!` **snapshots** state and pushes to a `Sink` |
| Provider protocol: `provider_refresh_times` / `provider_sample` / `provider_is_const` | Sink protocol: `sink_output_times` / `sink_write!` / `sink_open!` / `sink_close!` |
| EarthSciIO = impure **read** boundary: transport/store/format registries, content-addressed cache, atomic commit, offline mode | EarthSciIO grows the impure **write** boundary: writer/format + store `put`, staging→atomic-commit, per-store manifest |
| `[[library-exposes-rhs-not-solver]]` — library returns pieces, user attaches to their own `solve` | Same principle — output is a callback the user attaches; no solver embedded |

The design goals, in priority order:

1. **Bounded memory** — the trajectory never has to be fully resident; the sink
   *is* the trajectory store. The solver is told `save_everystep=false`.
2. **Cloud- and HPC-native** — one design that works on object storage (S3/GCS)
   and on parallel filesystems (Lustre/GPFS), driven by Zarr's chunk-as-object
   model.
3. **Checkpoint/restart** — the same machinery persists full-state checkpoints
   for preemption (cloud spot) and walltime (HPC batch) survival, resumable from
   a store manifest.
4. **Round-trip** — output is written in a format EarthSciIO **already reads**,
   so a run's output is another run's input with zero new read code.
5. **Cross-language parity** — Julia, Python, and Rust all emit the same Zarr,
   gated by a shared conformance corpus.
6. **Additive schema** — no breaking change; the one genuine gap (physical
   coordinate values/units bound to an axis) is closed with a purely additive
   `coordinates` registry that also covers unstructured and curvilinear grids.

---

## 2. Motivation and constraints

### 2.1 The bottleneck

`_simulate_solve` (Julia) builds an `ODEProblem`, calls `solve`, and *then*
materializes `sol.t`/`sol.u` wholesale into `SimulationResult`. Nothing is
written incrementally, so peak memory is `O(n_timepoints × length(u0))`. Python
(`scipy.solve_ivp` + dense resample) and Rust (`diffsol` + `run_solver` step
loop) have the same shape. The state itself is a flat vector with a
`name → index` map and column-major `name[i,j]` cell keys (`_cell_key` /
`_parse_cell_key`), identical across all three languages — which is what lets a
single flat→gridded inversion be shared.

### 2.2 Deployment constraints that shape the design

**HPC (parallel filesystem + batch scheduler).**
- Lustre/GPFS punish many-small-files and metadata storms; they reward large,
  stripe-aligned sequential writes and collective I/O.
- Walltime limits ⇒ output must double as **checkpoint/restart** (resumable,
  append-across-jobs).
- Domain-decomposed runs: each rank owns a subdomain and must write its region
  into a global logical array **without a global gather**.
- Compute nodes are often air-gapped; node-local NVMe (`/scratch.local`, already
  the read cache root) is the staging tier. The read side already has an
  offline-mode precedent.

**Cloud (object storage + preemptible instances).**
- S3/GCS have **no append, no random write, no cheap rename** (rename =
  copy+delete). Objects are write-once; large objects use multipart upload
  (parts ≥5 MB). Many tiny PUTs cost real money (requests + egress).
- Spot/preemptible death is routine ⇒ checkpoints must be **frequent, durable,
  idempotent**; restart must be exactly-once.
- Ephemeral local disk ⇒ flush to object store before the instance dies.

**The format tension.** NetCDF4/HDF5 is the science lingua franca and the
HPC-collective-I/O darling, but hostile to object stores and append. **Zarr** is
chunk-per-object: disjoint writers own disjoint chunks, needing *no lock* on
object storage **and** producing stripe-aligned large writes on Lustre. Zarr is
therefore the one backend that satisfies both targets, and EarthSciIO already
*reads* it (`julia/src/zarr.jl`, store-backed, orthogonal `select` pushdown), so
this RFC adds the *write* half of a format the stack round-trips through its own
conformance harness. NetCDF/parallel-HDF5 remains a **later opt-in** backend
behind the same registry seam; it is out of scope for v1.

---

## 3. Architecture overview

Three layers, each mirroring an existing read-side layer:

```
  EarthSciAST core          build_output_callback(; sinks, schema, snapshot) -> (cb, tstops)
  (solver-free)             Sink protocol: sink_output_times / sink_open! / sink_write! / ...
        │                   state_snapshot seam: integrator state -> (slab, global_offset)[]
        ▼
  EarthSciAST ext           PresetTimeCallback affect!  (needs DiffEqCallbacks + SciMLBase)
  (SciMLBase)               unions output tstops into the solve; user attaches cb
        │
        ▼
  EarthSciIO                Writer registry (mirror of Reader/FORMAT_REGISTRY)
  (impure write boundary)   ZarrWriter: dims/coords/chunks declared once, time-chunks appended
                            store.put + multipart-commit; staging→atomic rename; per-store manifest
```

The load-bearing invariant, restated from the read side: **the Sink depends only
on the Writer/store interfaces; a new output backend (NetCDF, a new object store)
registers under a new name without touching the Sink or the callback.** This is
the same rule that lets EarthSciIO's S3/Zarr read backends slot in as `stub`→
`active` with zero Provider-API change.

---

## 4. The Sink protocol (EarthSciAST core)

Declared in a new `src/data_output.jl`, symmetric to `src/data_refresh.jl`. The
core owns the **contract** (generic functions); concrete sinks live in the data
binding (the EarthSciIO extension) or a test mock — exactly as the Provider
protocol's concrete impl is the EarthSciIO `Provider`.

```julia
# --- cadence (mirror of provider_refresh_times / provider_is_const) ---
sink_output_times(sink) -> AbstractVector{Float64}    # solver-seconds tstops; may be empty

# --- lifecycle ---
sink_open!(sink, schema::OutputSchema)                # declare dims/coords/vars/chunking ONCE
sink_write!(sink, t::Real, snapshot; selection=nothing)  # persist one time record
sink_flush!(sink)                                     # durable barrier (checkpoint boundary)
sink_close!(sink)                                     # finalize; write end-of-run manifest

# --- capability (mirror of provider_supports_selection) ---
sink_supports_partial(sink) -> Bool                   # can accept a sub-slab write (distributed)
```

`OutputSchema` is the flat→gridded description built **once** at `prepare` time
(§7): dimension names, per-axis lengths, coordinate variables, chunking, and the
`var → (shape, cell-index map)` needed to scatter a flat `u` into gridded chunks.
It is the output analog of a `Provider` being bound to its native grid.

`snapshot` is opaque to the sink's *caller* but has a fixed shape: a list of
`(array_slab, global_offset)` pairs (§6). In the non-distributed case it is one
slab at offset 0 (the whole state); under sharding it is the addressable local
shards with their global offsets. `selection` is the write-side mirror of the
Provider's read-side projection pushdown: an optional per-axis sub-slab so a
sink can be handed only part of an axis (used for distributed region writes).

### `build_output_callback` — the trigger seam

```julia
"""
    build_output_callback(; sinks, schema, snapshot, pre_write = () -> nothing)
        -> (cb, tstops::Vector{Float64})
"""
```

- Returns a `PresetTimeCallback` whose `affect!` calls `snapshot(integrator)`
  then `sink_write!(sink, integrator.t, snap)` for each sink whose
  `sink_output_times` contains the tick; `tstops` is the sorted, de-duplicated
  **union** of all sinks' output times — the identical construction
  `build_refresh_callback` uses for provider refresh times, so **input refresh
  and output write compose in one `CallbackSet`**.
- Multiple sinks with different cadences are first-class (§8): each grid /
  checkpoint profile is its own sink with its own `sink_output_times`.
- The method lives in `ext/EarthSciASTDataOutputExt.jl` (gated on
  `DiffEqCallbacks` + `SciMLBase`), so the base package never pulls a
  solver-adjacent stack — identical to the `DataRefreshExt` pattern. A core
  fallback throws a helpful error when the extension is not loaded.

### Wiring into `simulate` and killing the RAM trajectory

`_simulate_solve` (the single choke point where `sol.u` is collected today)
gains an `output` path: when one or more sinks are present it passes
`save_everystep = false` (and minimal `save_start`/`save_end`) to `solve`, so the
solver stops accumulating the dense trajectory — the sink owns persistence. The
returned `SimulationResult` in that mode carries the run's **metadata + sink
handles** (retcode, message, the store URLs and their manifests) instead of an
in-memory `u`. A `saveat`-only, no-sink call is byte-identical to today.

---

## 5. EarthSciIO: the impure write boundary

EarthSciIO today is the sanctioned impure **read** boundary. This RFC gives it
the symmetric **write** boundary, reusing its three-registry seam and its
atomic-commit/manifest discipline.

### 5.1 The Writer registry (mirror of the Reader/`FORMAT_REGISTRY`)

```
abstract type Writer end               # encode gridded arrays -> a format on a store
write_open!(w, store, base_url, schema)         # create dims/coords/chunk grid
write_record!(w, handle, t, arrays; region=nothing)   # append/emit one time record
write_close!(w, handle)                          # finalize metadata (.zmetadata, manifest)
```

`WRITER_REGISTRY` is keyed by format name exactly like `FORMAT_REGISTRY`; the
first registration is `zarr` (`active`), with `netcdf` reserved (`stub`). Adding
a format is one `register!` line — never a Sink edit.

### 5.2 Store `put` + commit discipline

The read cache commits a downloaded blob with `staging_path` → `put_blob!`
(atomic `rename(2)`) + a sidecar `Manifest`, guarded by an `mkpidlock` advisory
lock (`julia/src/store.jl`). The write path reuses this verbatim:

- **Local / parallel FS** — write each Zarr chunk to `tmp/<uuid>.part`, atomic
  rename into `blobs/…`-style chunk paths; the rename is the crash barrier (a
  reader never sees a partial chunk). A per-store **output manifest** records
  committed time-chunks (§9).
- **Object store** — the `s3` store (today a `stub`) gains `put_object` via
  **multipart upload**, where the `CompleteMultipartUpload` call is the atomic
  reveal (the object-store analog of `rename`). Disjoint chunk writers need **no
  lock** (each owns its object key), which is the whole reason Zarr scales on
  object storage. This is the write half of what `spec/cloud-future.md` already
  charted for the `s3` store.

### 5.3 Dependency notes

- **Julia:** Zarr encode + `Blosc` compression are already weakdeps on the read
  side; the writer reuses them.
- **Python:** `xarray` + `netcdf4` are already deps; add `zarr`. The streaming
  primitive is `Dataset.to_zarr(store, region=…, mode="a")`.
- **Rust:** no zarr crate today; add `zarrs` under the existing
  `cfg(not(target_arch = "wasm32"))` gating (the writer is a native-only feature,
  like `s2bindings`).

---

## 6. The state-snapshot seam (Reactant / sharding)

The one place the output callback touches the solver state. The state `u` is a
flat host `Vector{Float64}` in the tree-walk/CPU path, but a
`Reactant.ConcreteRArray` (possibly **sharded** across devices/hosts) under the
Reactant execution tier. The snapshot seam abstracts this:

```julia
state_snapshot(integrator) -> Vector{Tuple{Array,NTuple{N,UnitRange}}}   # (slab, global range)
```

- **CPU / non-distributed (v1):** one implementation, `Array(u)` at offset
  covering the whole state. This is the mirror of what the *input* side already
  does when it materializes host forcing buffers (`_write_forcing!`) and, under
  Reactant, gathers/mirrors them with `sync_forcing!`. Correct at any scale that
  fits one host's write bandwidth.
- **Reactant single-host, replicated/gathered:** `Array(u)` triggers XLA's
  gather to host; identical downstream. Fine at moderate device counts.
- **Reactant multi-host, shard-local (later):** Reactant *does* support
  multi-host sharding (`Reactant.Sharding` — `Mesh` / `NamedSharding` /
  `Replicated`, IFRT + PJRT; `Reactant.Distributed` — `local_rank` /
  `num_processes` / `is_initialized`). The primitives to write a shard *without*
  a global gather exist internally — `sharding_to_array_slices` /
  `device_to_array_slices` give each device's **global** slice offsets, and
  per-device data lives in the sharded array's `data` buffers — but there is **no
  clean, documented public API yet** to hand back "my local shard + its global
  offset." So this is deliberately a **later drop-in**: when Reactant exposes
  addressable shards, `state_snapshot` returns the local shards with their global
  ranges, the sink writes each rank's Zarr **region** (`sink_supports_partial`),
  and the gather disappears — **with no change to the callback or the Sink
  protocol.** This is the same "ship behind a stable seam, flip stub→active"
  pattern the read side used for S3/Zarr.

**Design consequence:** do not block v1 on shard-local output. Build the seam
now; ship the host-gather implementation; add the shard-local implementation when
the Reactant API lands.

---

## 7. Zarr layout and the flat→gridded inversion

`OutputSchema` is derived once at `prepare` time from information already in the
document + build artifacts:

- **Which variables, and their axes** — each output variable's `shape` is an
  ordered list of `index_sets` names; the writer clusters variables by their
  shape signature into **grids** (§8). Variable name, dims, and dtype come
  straight from the model. Output variables are **state elements plus a
  caller-named subset of observed/derived fields**: the named observed fields are
  RHS expressions the evaluator already produces, evaluated once at each output
  tick (via the callback's `pre_write` hook) and scattered into their own gridded
  arrays alongside the state.
- **Per-axis length** — `IndexSet.size` (`interval`) or `length(members)`
  (`categorical`); `derived`/`ragged` lengths are known after build.
- **Flat→gridded scatter** — invert `_parse_cell_key` (column-major) to map each
  flat index to its `(i,j,…)` cell, so a flat `u` slab scatters into the right
  gridded chunk. This inversion is identical in Julia/Python/Rust (same cell-key
  scheme, same column-major order), so it is specified **once** in the shared
  spec.
- **Chunking** — default: whole spatial extent × a tunable number of time steps
  per chunk (time-chunked), which matches the write cadence and the common
  "read a map at a time" analysis pattern; overridable per variable. Each
  time-chunk flush is one object (cloud) or one stripe-aligned file (HPC).
- **The `time` axis** — the document's single `Domain.independent_variable`; a
  Zarr **unlimited-style** dimension extended one time-chunk per flush.

The output is therefore a valid, correctly-shaped, correctly-**named**,
dimension-labeled Zarr with integer indices and (for `categorical` axes) member
labels **with no schema change**. What is *not* recoverable without a schema
addition is the physical coordinate **values** on `interval` grid axes — §9.

---

## 8. Coordinates: the CF coordinate-role model (the one schema delta)

### 8.1 The gap

Since v0.8.0 the schema is deliberately **index-space, not coordinate-space**:
`Domain.spatial`/`SpatialDimension`/`CoordinateTransform` were removed; grid
coordinates are "ordinary data" (a loaded field or a declared variable/
parameter) with **no declared link from an axis to its coordinate array**. From
the document you can recover axis **names**, **lengths**, and **categorical
member labels** — but for an `interval` grid axis the physical coordinate
**values** (lat/lon degrees, level in Pa) and per-axis **units/`standard_name`**
are not tied to the axis anywhere. Bare Zarr loads in xarray with axes shown as
`0..N` instead of real lon/lat.

### 8.2 Why a singular per-axis coordinate field is wrong

A scalar `IndexSet.coordinate` encodes the **rectilinear** assumption — one axis,
one monotonic vector (a CF *dimension coordinate*). It breaks on:

- **Unstructured (MPAS/ICON/FVCOM):** state over one `cells` dimension located by
  **two** coordinates `lat(cell)`, `lon(cell)`, both 1-D over the *same*
  dimension, neither monotonic — CF **auxiliary coordinate variables**. One axis
  → many coordinates.
- **Curvilinear (rotated-pole, tripolar ocean):** `lat(y,x)`, `lon(y,x)` are 2-D
  — a single coordinate **spans two axes**, so attaching it to one `IndexSet` is
  ambiguous.

### 8.3 The fix — a coordinate-centric, additive `coordinates` registry

Lean into what v0.8.0 already decided (*coordinates are ordinary data with a
shape*). Add a document-scoped, optional `coordinates` registry. Each entry marks
an existing data array (variable / parameter / loader field, referenced **by
name** exactly as `ragged` index sets reference their `offsets`/`values`) as a
coordinate and attaches CF metadata. The coordinate's **shape is read from its
source**, so it needs no per-axis attachment:

```jsonc
"coordinates": {
  "atm_lat": { "source": "atm_lat_deg", "standard_name": "latitude",  "units": "degrees_north", "axis": "Y" },
  "atm_lon": { "source": "atm_lon_deg", "standard_name": "longitude", "units": "degrees_east",  "axis": "X" },
  "cell_lat": { "source": "mesh_lat",   "standard_name": "latitude",  "units": "degrees_north" },   // aux (no axis)
  "cell_lon": { "source": "mesh_lon",   "standard_name": "longitude", "units": "degrees_east"  }    // aux
}
```

`source` may also be inline `values` (a literal 1-D vector) for the simple
rectilinear case, mirroring what `FunctionTableAxis` already does with
`values`+`units`. One rule drives all topologies:

| grid | coordinate source shapes | CF emission |
|---|---|---|
| rectilinear | `atm_lat[atm_lat_idx]`, `atm_lon[atm_lon_idx]` (monotonic, `axis` set) | **dimension** coordinates |
| unstructured | `cell_lat[cells]`, `cell_lon[cells]` | **auxiliary** coords + `coordinates="cell_lat cell_lon"` on data vars |
| curvilinear | `lat[y,x]`, `lon[y,x]` | **auxiliary** coords + `coordinates="lat lon"` |

The writer derives a data variable's `coordinates` attribute mechanically:
**every coordinate whose source shape is a subset of the data variable's shape
applies to it.** No per-axis assumption anywhere; this *is* the CF coordinate
data model (dimension vs auxiliary coordinates + the `coordinates` attribute).

### 8.4 Mesh topology / UGRID — already expressible

The non-coordinate parts of unstructured grids are constructs the schema already
has:

- **Connectivity** (edges-of-cell, face-node, CSR `edgesOnCell`/`nEdgesOnCell`)
  is exactly what the `ragged` / `derived` `IndexSet` kinds model, referencing
  their factor arrays by name.
- **Mesh location** (node/edge/face) is already `ModelVariable.location`
  (`"cell_center"`, `"edge_normal"`, `"vertex"`) — the UGRID `location`
  attribute.

So UGRID-compliant output is a **mapping** job (emit a `mesh_topology` variable,
tag data vars with `mesh`/`location`, point at the ragged connectivity already
declared) — not a new schema primitive. **Default the writer to plain-CF
auxiliary coordinates** (universally readable by xarray and by EarthSciIO's own
reader); make **UGRID topology an opt-in** emission, since the stated consumers
(EarthSciAST + xarray) both consume auxiliary coordinates without any UGRID
support.

### 8.5 Migration / bridge

The `coordinates` registry is **purely additive** and optional — documents
without it validate and emit exactly as today (bare integer axes), so existing
fixtures are unaffected. **Decision (§14): it lands in `esm-schema.json` in
Phase 1**, not behind a convention-first bridge, since it is small and mirrors
the existing `FunctionTableAxis` (`values`+`units`) pattern. A runner-level
config map (`index_set_name → coordinate field`) remains available as a private
escape hatch for a model whose coordinates are supplied entirely at the API, but
it is not the migration path.

---

## 9. Multi-grid / coupled components

Multiple grids in one run (atmosphere + ocean, e.g. the
`wildfire_atmosphere_ocean.esm` fixture) are supported **by construction**, not
by a new concept:

- `index_sets` is a **document-scoped** registry; each variable independently
  names the axes it lives on. Atmosphere vars over `[atm_lev, atm_lat, atm_lon]`
  and ocean vars over `[ocn_depth, ocn_lat, ocn_lon]` already coexist. Zarr, CF,
  and xarray all represent heterogeneous-dimension variables in one store
  natively (multi-grid single files are routine CF — e.g. Arakawa C-grid `u`/`v`/
  tracer output).
- **Grids are emergent.** The writer partitions variables into grids by their
  shape signature (the set of spatial index sets). "Two grids" is inferred, not
  declared.
- **Names can't collide.** The flat registry has unique keys, so `atm_lat` and
  `ocn_lat` are distinct dimensions; **shared axes dedup** (both components
  referencing one vertical set share one dimension + coordinate) and **distinct
  axes stay distinct** — both by construction.
- **Mixed coordinate *kinds* in one file** are fine: a rectilinear atmosphere, an
  unstructured ocean, and a categorical `species` axis coexist because each
  coordinate declares its own shape and role independently (§8.3).

**Recommended decomposition:** **one Sink per grid.** Coupled components differ
in exactly the things a sink controls — cadence (the ocean typically steps and
outputs slower than the atmosphere), chunk shape, and checkpoint frequency.
Per-grid sinks give each of these independently, and their `sink_output_times`
union into the solver `tstops` the same way multiple input providers'
`refresh_times` do.

**Layout policy** (a config axis, not a feasibility question):

- **Default:** per-grid **Zarr groups in one store** (`/atmosphere`, `/ocean`),
  read back as an xarray `DataTree`. One logical output artifact.
- **Separable:** **distinct stores per component** when lifecycles diverge enough
  to manage independently (different retention, different checkpoint cadence).

**Time across grids:** all components share the one `Domain` time. Same output
cadence ⇒ a shared `time` coordinate; different cadences ⇒ per-group time
coordinates (`atm_time`, `ocn_time`) — another reason per-grid groups/sinks are
the natural unit. **Coupling/regrid stays internal:** each sink writes its
variable on its **native** grid; the atmosphere↔ocean regrid is an ordinary
in-model coupling expression the RHS evaluates, never the writer's concern.

---

## 10. Checkpoint / restart

Modeled as a second **profile** of the same `Sink`, not a separate subsystem:

| profile | contents | precision / compression | cadence |
|---|---|---|---|
| diagnostic output | state + caller-named observed fields, subsettable (reuse `selection`), CF-metadata-rich, may downsample in time | Blosc zstd + shuffle | science-driven interval |
| checkpoint | full state (every element of `u`) | full precision, **lossless** | fixed interval **+** walltime/preemption guard |

**Restart mechanics** mirror the read cache exactly:

- Each sink keeps an **output manifest** (mirror of `julia/src/manifest.jl`)
  recording committed time-chunks + the last durable `t`.
- Resume = read the last **committed** checkpoint chunk from the manifest,
  reseed `u0` at that `t`, continue integrating. Because commit is atomic
  (rename / multipart-complete), a restart never sees a half-written chunk;
  writes past the last committed `t` are simply re-done — **idempotent**,
  exactly-once.

**Julia checkpoint/restart is callback-driven** (no integrator step-loop runner),
staying on the same `[[library-exposes-rhs-not-solver]]` seam as everything else.
The checkpoint trigger is a **freely-composable set** — any combination of a
fixed interval and/or one or more predicates — that lowers to callbacks in the
same `CallbackSet` as the diagnostic sink and the input-refresh callback:

- an optional **interval** → a **`PresetTimeCallback`** at the user-specified
  checkpoint times. Usable entirely on its own (interval-only checkpointing is a
  valid, fully-supported configuration) and portable to the Python/Rust runners.
- zero or more **predicates** → a **`DiscreteCallback`** whose `condition` is the
  **OR** of the predicates, checkpointing just-in-time when any fires. Its
  `affect!` writes the full-state checkpoint and calls `sink_flush!` (the durable
  barrier), then optionally `terminate!(integrator)` for a clean pre-preemption
  exit.

Interval and predicates **compose freely**: interval-only, predicate-only, or
both together; and multiple predicates combine (e.g. SLURM walltime **and** spot
notice **and** a custom condition). A predicate is `should_checkpoint() -> Bool`
(equivalently a `deadline`), and EarthSciAST ships two **built-in predicate
constructors** the caller can opt into: a **SLURM** remaining-walltime predicate
(queries the job's time limit / `SLURM_JOB_END_TIME`, fires within a configurable
margin) and a **cloud spot-preemption** predicate (polls the instance metadata
termination notice, e.g. AWS/GCP). Predicates OR-compose through a small
`any_of(preds...)` helper; a user on PBS, Kubernetes, or a bespoke scheduler
passes their own with no library change. The Rust runner already owns an explicit
`run_solver()` step loop and Python's provider path a cadence-segmenting loop, so
each language expresses the same composable triggers idiomatically; the
**restart** side is uniform — read the last committed checkpoint from the
manifest and reseed a fresh run at that `t`.

---

## 11. Cross-language parity and conformance

All three packages are **full ODE runners** (Julia tree-walk/MTK; Python
`solve_ivp`; Rust `diffsol`) with the **identical** state model (flat vector,
column-major `name[i,j]` keys, `name→index` map) and each already has a mature
**input** Provider seam to mirror (Julia `provider_*` generics; Python
`data_loaders/provider.py` `Provider` protocol; Rust `src/provider.rs`
`CadenceProvider` trait). So the output seam is symmetric across all three.

To prevent drift, specify the output contract in the **shared spec layer** the
read Provider used, not as three independent ports:

- a language-neutral **Sink/Writer contract** (the protocol of §4–5, the
  flat→gridded inversion of §7, the coordinate rules of §8);
- a **golden conformance corpus**: run a small model in each language, assert the
  emitted Zarr is **array-identical** across Julia/Python/Rust (byte-identical
  where compression is deterministic), extending the existing cross-language
  harness.

Injection points already identified: Julia `build_output_callback`; Python's
per-pathway result assembly / the `_simulate_with_discrete_providers` segment
loop; Rust `run_solver()` (`simulate.rs`) and the provider-segmented driver.

---

## 12. Schema changes (summary)

**One additive change to `esm-schema.json`:** a document-scoped, optional
`coordinates` registry (§8.3). Each entry references an existing data array by
name (or inline `values`) and carries `standard_name` / `units` / optional
`axis`. Documents without it validate and emit exactly as today. No field is
removed or repurposed; conformance for existing fixtures is unaffected.

Everything else — dimensionality, axis lengths, axis names, categorical member
labels, multi-grid coexistence, the flat→gridded inversion — is derivable from
the **existing** document + build artifacts and needs **no** schema change.

---

## 13. Sequencing

1. **Spec + conformance scaffold.** Write the language-neutral Sink/Writer
   contract and the flat→gridded inversion into the shared spec; add the
   additive `coordinates` registry to `esm-schema.json`; stand up an (initially
   empty) output conformance corpus.
2. **Julia core seam.** `src/data_output.jl` (Sink protocol + `OutputSchema` +
   `state_snapshot` seam, host-gather impl) and
   `ext/EarthSciASTDataOutputExt.jl` (`build_output_callback` +
   `PresetTimeCallback`); wire `save_everystep=false` into `_simulate_solve`.
3. **EarthSciIO `ZarrWriter`.** Writer registry + `write_open!/record!/close!`;
   local-store staging→atomic-commit + output manifest; Blosc reuse. Round-trip
   test: write with `ZarrWriter`, read back with the existing `ZarrReader`.
4. **Checkpoint profile + restart** from manifest, via callbacks: the
   fixed-interval `PresetTimeCallback` + the `DiscreteCallback` walltime/
   preemption guard (with a pluggable `deadline`/`should_checkpoint` seam).
5. **Coordinates + multi-grid.** Consume the `coordinates` registry (CF
   dimension/auxiliary emission); per-grid sink clustering; Zarr groups; opt-in
   UGRID topology.
6. **Object store.** `s3` store `put` via multipart-commit (flip the read-side
   `s3` store `stub`→`active` on the write path); lock-free disjoint-chunk
   writes.
7. **Python then Rust writers** against the conformance corpus (`zarr` dep for
   Python; `zarrs` crate under wasm32 gating for Rust).
8. **Shard-local distributed output.** `state_snapshot` shard-local impl +
   `sink_supports_partial` region writes, **when** Reactant exposes an
   addressable-shard API. No callback/protocol change required.

---

## 14. Resolved decisions

1. **Coordinates schema — land now.** The additive `coordinates` registry (§8.3)
   goes into `esm-schema.json` in Phase 1 (it is small and matches the existing
   `FunctionTableAxis` `values`+`units` pattern), so output is self-describing
   (real lon/lat in xarray) from the start. No convention-first bridge.
2. **Checkpoint trigger — a freely-composable set of triggers, all via
   callbacks.** Any combination of a fixed **interval** (`PresetTimeCallback`)
   and/or one or more **predicates** (`DiscreteCallback`, OR-combined). Each is
   usable alone — interval-only and predicate-only are both fully supported — and
   they compose together, including multiple predicates at once (§10). No
   integrator-loop runner.
3. **Coupled-run layout — per-grid groups in one store** (`/atmosphere`,
   `/ocean`), read back as an xarray `DataTree` (§9). Store-per-component remains
   available for divergent lifecycles but is not the default.
4. **Output content — raw state + observed.** Sinks write state elements **and**
   RHS-computed observed/derived fields (the evaluator already produces them,
   e.g. PM2.5 from species states), evaluated at each output tick (§4, §7).
5. **Compression — profile-dependent.** Diagnostic profile: Blosc **zstd** with
   byte-shuffle at a moderate level. Checkpoint profile: **lossless only**, for
   bit-reproducible restart.
6. **NetCDF — out of scope for v1.** Zarr only; NetCDF is reserved behind the
   Writer registry as a `stub` for a later phase.

7. **Walltime/preemption signal — caller predicate + built-ins.** The predicate
   trigger takes a caller-provided `should_checkpoint()` as its primary seam
   (§10), OR-composed via `any_of(...)`, with two built-in predicate constructors
   shipped for the common cases: a **SLURM** remaining-walltime predicate and a
   **cloud spot-preemption** notice predicate. PBS/K8s/bespoke schedulers pass
   their own predicate — no library change.
8. **Observed-field output — caller-named subset.** Sinks write the state plus a
   **caller-named subset** of observed/derived fields (not all observed by
   default). The subset is named in the sink config; the evaluator computes just
   those at each output tick.

All RFC decisions are now resolved; open items belong to implementation phases.

---

## 15. Relationship to existing work

- **`pure-io-data-loaders.md`** — this RFC is its output-side mirror: the loader
  is the impure *read* boundary; the sink is the impure *write* boundary. Both
  keep transforms (regrid/reproject) out of the I/O layer — the sink writes
  **native** grids, never regridded ones.
- **`semiring-faq-unified-ir.md`** — coordinates/connectivity as ordinary data +
  `aggregate` FAQs is what makes the coordinate-role model (§8) and multi-grid
  (§9) fall out for free.
- **EarthSciIO read spec** (`registries.md`, `cache-format.md`, `offline-mode.md`,
  `cloud-future.md`) — the write boundary reuses the registry seam, the
  staging→atomic-commit + manifest discipline, and the charted `s3` store; §5
  and §10 are the write-side counterparts.

---

## 16. Frozen implementation contract (v1)

> This section is **normative for implementation** and supersedes any looser
> wording in §4–§14. It resolves the ambiguities found in design review and
> records the decisions made for the v1 build (host-gather; Zarr v3; Julia +
> Python + Rust; s3 write via multipart; Reactant shard-local output deferred).

### 16.1 Format: Zarr **v3**, sharded

- All writers emit **Zarr v3** (`zarr_format: 3`). The `time` axis grows by
  resizing the array; one **shard** per flush packs many logical chunks into one
  object (the sharding codec), giving few large objects on S3/Lustre while keeping
  small logical chunks for readers. This is the small-object mitigation the cloud
  target needs.
- **EarthSciIO's `ZarrReader` is upgraded to read v3** (currently v2-only). The
  read path must round-trip everything the writer emits; a v3 read fixture lands
  with the writer. v2 read support is retained.
- Compression: diagnostic profile = Blosc **zstd** + byte-shuffle, moderate level;
  checkpoint profile = **lossless** (zstd, no lossy step). Codec **parameters** are
  pinned in the shared spec so decoded output is reproducible; see 16.6.

### 16.2 Per-sink `OutputSchema` (resolves review #3)

There is **no single shared `schema`**. Each `Sink` carries/derives its **own**
`OutputSchema` (its variable list, dims, coordinates, chunk/shard shape, codec
profile). `build_output_callback` does **not** take a `schema` argument. Rationale:
the two profiles in §10 (diagnostic = state + observed subset; checkpoint = full
state, lossless) have different variables, chunking, and compression and cannot
share one schema. `sink_open!(sink)` opens the sink against its own schema.

### 16.3 Snapshot carries observed fields (resolves review #2)

The snapshot is **not** state-only. `pre_write` computes the caller-named observed
fields from integrator state and the callback assembles a `StateSnapshot`:

```julia
struct StateSnapshot
    t::Float64
    state::Vector{Tuple{Array,NTuple{N,UnitRange} where N}}   # (slab, global range); one entry, offset-0 whole state in v1
    observed::Dict{String,Array}                              # caller-named observed/derived arrays, host-materialized
end
```

`sink_write!(sink, snap::StateSnapshot; selection=nothing)` receives both, so a
sink scatters state elements and observed fields into their gridded arrays. In v1
`state` is exactly one `(Array(u), (1:length(u),))` pair (host-gather). `observed`
is empty unless the sink's schema names observed outputs; those names drive what
`pre_write` evaluates (the evaluator already produces them).

### 16.4 Sink protocol (final Julia signatures)

Declared in `src/data_output.jl` (core owns the generics + throwing fallbacks,
exactly like `data_refresh.jl`); concrete sinks live in the EarthSciIO extension
or a test mock.

```julia
sink_output_times(sink) -> AbstractVector{Float64}     # tstops; may be empty (predicate-only)
sink_open!(sink)                                       # open against the sink's OWN OutputSchema
sink_write!(sink, snap::StateSnapshot; selection=nothing)
sink_flush!(sink)                                      # durable barrier (checkpoint boundary)
sink_close!(sink)                                      # finalize + end-of-run manifest
sink_supports_partial(sink) -> Bool                    # default false; INERT in v1 (host-gather)
sink_observed_names(sink) -> Vector{String}            # names pre_write must evaluate; may be empty
```

```julia
build_output_callback(; sinks, snapshot, pre_write = () -> nothing)
    -> (cb, tstops::Vector{Float64})
```

- Lives in `ext/EarthSciASTDataOutputExt.jl` (gated on `DiffEqCallbacks` +
  `SciMLBase`); core fallback throws an `OutputError` naming what to load — the
  exact `build_refresh_callback` pattern.
- `affect!` at each tick: run `pre_write()` (fills observed caches) → build the
  `StateSnapshot` via `snapshot(integrator)` + the observed caches → for each sink
  whose `sink_output_times` contains the tick, `sink_write!(sink, snap)`.
- `tstops` = sorted, de-duplicated **union** of all sinks' `sink_output_times`, so
  output composes with input-refresh in one `CallbackSet` (union the two tstops).
- `state_snapshot(integrator)` v1 impl = `[(Array(u), (1:length(u),))]`. The
  `sink_supports_partial`/`selection`/multi-slab machinery is built but inert;
  the Reactant shard-local impl is the deferred phase 8 drop-in (no protocol
  change).

### 16.5 `simulate` wiring

`simulate(prep, tspan; …, sinks = Sink[], pre_write = nothing)`. When `sinks` is
non-empty: build the output callback, **union** its tstops with the refresh
tstops, compose a `CallbackSet(refresh_cb, output_cb)`, and pass
`save_everystep = false` (+ minimal `save_start`/`save_end`) to `_simulate_solve`.
The returned `SimulationResult` gains a mode carrying **metadata + sink handles**
(retcode, message, store URLs, manifests) instead of an in-memory `u`. A
`saveat`-only, no-sink call is byte-identical to today (new kwargs default to the
old path).

### 16.6 Conformance bar: tolerance, not bytes (resolves review #1, #5)

Cross-language and round-trip conformance assert **decoded** agreement, never
compressed-byte identity:

- **Primary:** decoded arrays (state, coordinates, observed) agree within a
  numeric tolerance (`rtol`/`atol` declared per corpus entry), and the structural
  metadata (dims, shapes, `standard_name`/`units`/`axis`, chunk/shard grid) is
  equal.
- **Byte-identity is NOT required** across languages (Julia Blosc.jl / Python
  numcodecs / Rust zarrs are independent codec builds). It may be asserted only
  as an *intra-language* reproducibility property under pinned codec params.

### 16.7 Restart semantics: tolerance-consistent continuation (resolves review #1)

Checkpoint stores the full state `u` at `t` **losslessly**; it does **not** store
the integrator's internal cache (step size, error-controller history, multistep
Nordsieck/order). Restart reseeds a fresh integrator from `u(t)` and continues.
Therefore:

- Restart is a **valid continuation, consistent to solver tolerance** — **not**
  bit-identical to an uninterrupted run (a multistep method re-runs its startup
  transient). The RFC's earlier "bit-reproducible restart" wording is **retracted**
  in favor of "tolerance-consistent."
- Commit is atomic (rename / multipart-complete), so restart never sees a
  half-written shard; re-doing writes past the last committed `t` is idempotent for
  the fixed-schedule diagnostic output. Predicate-driven checkpoints fire at
  run-dependent times, so their *exact* re-emission is not guaranteed — the
  manifest's last-committed `t` is the source of truth for where to resume.
- The **output manifest** (mirror of `manifest.jl`, schema `earthsciio/output-manifest/v1`)
  records: committed time-shards (index + `t` range), last durable `t`, the
  writer format + codec params, the schema fingerprint (variable order, dims,
  dtype), and the store base URL. Restart reads the last committed checkpoint
  shard, reseeds `u0`, and continues.

### 16.8 Concurrent-writer metadata ownership (resolves review #7, #8)

Disjoint **data**-shard writers need no lock (each owns its object key). The
**shared** metadata is coordinated: a designated **rank-0 / owner** writer owns
(a) extending the `time` dimension (array resize / `zarr.json` shape) and (b)
writing consolidated metadata at `sink_close!`. On the local/parallel FS the
existing `mkpidlock` + staging→rename + output manifest cover this; on S3 the
owner serializes the shape/`zarr.json` updates. v1 ships host-gather (a single
writer), so this is a seam exercised by the object-store phase, not a v1 hot path.

### 16.9 Multi-repo / dev workflow

The write boundary lands in **EarthSciIO** (sibling checkout, branch
`feat/streaming-output-sinks`); EarthSciAST's `[sources]` `EarthSciIO` entry is
**temporarily repointed at the local path** for dev/test, and reverted to the
GitHub URL before merge (an upstream EarthSciIO PR merges first). The Writer
registry, `ZarrWriter` (v3), store `put`/multipart, and output manifest are
EarthSciIO; the `Sink`/`build_output_callback`/`OutputSchema` and the concrete
EarthSciIO-bound sink (in `EarthSciASTEarthSciIOExt`) are EarthSciAST.

### 16.10 Framing corrections

Two stale claims in §5–§6 are corrected: EarthSciIO's Zarr **read** path is
already `active`/landed (not a stub to flip), and the **s3 transport** is already
active — only the **s3 store** is a stub. This RFC adds the *write* half of Zarr
and activates the **s3 store**'s `put`; it does not "flip the zarr read stub."

### 16.11 Implementation status (Julia)

The Julia reference path is implemented and verified on branch
`feat/streaming-output-sinks` (EarthSciAST + the sibling EarthSciIO checkout, host-gather):

- **Sink seam + `build_output_callback`** (§4, §16.4–16.5): `PresetTimeCallback`
  cadence, `save_everystep=false`, tstops unioned with input-refresh.
- **`ZarrWriter` v3 + reader upgrade + output manifest** (§5, §16.1): sharded Zarr
  v3, Blosc zstd, staging→atomic-commit, `earthsciio/output-manifest/v1`.
- **Flat→gridded scatter** (§7): column-major inversion of the `name[i,j]` keys.
- **Real dim names + CF coordinates** (§7–§8): `derive_output_meta` +
  `plan_dimension_coordinates` emit real index-set axis names and CF **dimension
  coordinates** (values + `standard_name`/`units`/`axis`) from the additive
  `coordinates` registry (threaded verbatim through `EsmFile`); per-variable CF attrs.
- **Checkpoint / restart** (§10, §16.7): `:checkpoint` lossless profile; predicate
  builtins (`any_of`, SLURM walltime, spot preemption) → a `DiscreteCallback`
  (`build_checkpoint_callback`) that writes + `sink_flush!`es + optionally
  `terminate!`s; manifest-driven `zarr_restart_state` reconstructs a flat `u0`.
- **Multi-grid** (§9): `group_gridding_by_grid` partitions variables by spatial-dim
  signature; one Sink per grid to its own store (the "separable" layout).

**Remaining:** per-grid **Zarr groups in one store** (the §9 default layout) — needs
EarthSciIO group-path support; live **s3** bucket I/O (the object-store `put` path is
wired but only exercised offline — see §16.12); and the deferred Reactant **shard-local**
output (§6, phase 8). Cross-language conformance is tolerance-based decoded-array
agreement (§16.6).

### 16.12 Implementation status (Python / Rust / conformance)

The Python and Rust runner counterparts are implemented on library-backed backends
(no hand-rolled codecs), on EarthSciIO branches merged into `feat/streaming-conformance`:

- **Python** (`earthsciio/backends/zarr_write.py`, `zarr.py`, `s3.py`): reader **and**
  new v3 sharded writer rebuilt on **zarr-python 3.x** (native sharding + `BloscCodec`),
  S3 via **s3fs/fsspec**. Reads both the legacy v2 corpus and v3 sharded stores. Requires
  Python ≥3.11 (the `zarr`/`s3` extras); the lean core still installs on 3.9. Existing
  read conformance stays exact (`verify.py` 5/5); a write→read round-trip pytest passes.
- **Rust** (`rust/src/format/zarr.rs`, `zarr_write.rs`, object-store path): reader and v3
  sharded writer rebuilt on **`zarrs`** with **`object_store`** for local/S3/HTTP. This
  gives up the crate's former C-free build (codec crates `zstd-sys`/`blosc-src` now build
  via `cc`/gcc alone — no clang/bindgen); `#![forbid(unsafe_code)]` on the crate's own
  code is preserved. Corpus read tests + a write↔read round-trip pass.
- **Cross-language write conformance** (§11, §16.6): `conformance/run_write_conformance.sh`
  drives all three writers from a shared spec (`write_spec.json`), cross-reads every
  store with every reader, and asserts decoded-array agreement within tolerance
  (atol 1e-9, rtol 1e-6) plus structural/CF-metadata agreement. All three tracks executed:
  **15/15 pairwise** decoded arrays agree. The compressed shard **bytes differ** across
  languages (three distinct sha256s for the same shard) while decoding identically —
  empirically confirming the §16.6 tolerance-not-bytes policy is load-bearing.

Live S3-bucket I/O is verified only offline (fsspec-memory / `object_store` LocalFileSystem;
no credentials in the test environment). The `s3` **cache** store remains a spec-pinned
stub pending a coordinated cross-language activation.

### 16.13 Codec profiles (and the `wasm` profile)

The writers pin **three** inner-codec profiles. Only the inner (per-chunk) compressor
differs; the `sharding_indexed` outer codec and its `[bytes, crc32c]` shard index are
identical across all three, as are dtype, `dimension_names`, CF attrs and `fill_value`:

| profile | inner chain | purpose |
| --- | --- | --- |
| `diagnostic` | `bytes(le)` → Blosc(zstd, clevel 5, byte-shuffle) | default streaming output |
| `checkpoint` | `bytes(le)` → Blosc(zstd, clevel 7, byte-shuffle) | lossless durability (§16.7) |
| `wasm` | `bytes(le)` → **zstd(level 5)**, no Blosc | browser/WebAssembly-loadable |

**Why `wasm` exists.** Blosc is a *container* (block splitting + byte-shuffle filter)
wrapping the same zstd compressor. Its C sources (`blosc-src`) do not target
`wasm32-unknown-unknown`, whereas the standard Zarr v3 `zstd` codec does (`zstd-sys`
gained wasm32 support), and `sharding_indexed`/`crc32c` are pure Rust. So dropping *only*
the Blosc container yields a store a wasm Zarr reader (e.g. `zarrs` compiled to wasm) can
decode, with no other structural change. Implemented in all three writers plus the Julia
v3 reader (a `CodecZstd` weakdep extension); write conformance runs **both** profiles with
30/30 pairwise decoded-array agreement.

**The `wasm` profile is not a compression sacrifice.** Measured on float64 geophysical
fields at a realistic ~108 KiB inner chunk, plain zstd *beats* Blosc on ratio, because the
byte-shuffle filter destroys the long-range spatial matches a whole-chunk zstd stream
exploits on smooth data:

| data (≈108 KiB inner chunk) | zstd-5 (`wasm`) | Blosc zstd-5 shuffle |
| --- | --- | --- |
| smooth geophysical field | **2.58×** | 1.96× |
| plume / concentration | **2.49×** | 1.90× |
| signal + 1% noise | 1.05× | **1.14×** |

Blosc's genuine advantages are (a) **decode throughput** — ~4.2 GB/s vs ~1.1 GB/s
single-threaded per core — and (b) ratio on **small chunks or noisy fields**, where LZ
matching fails and the shuffle filter is the only remaining source of redundancy. For a
network-bound reader the end-to-end crossover is ≈**200 MB/s of object-store bandwidth per
decoding core**: below that the `wasm` profile is *faster* overall because it transfers
~24% fewer bytes; above it Blosc wins. Typical cloud runners sit well below the crossover;
cache-local re-reads and checkpoint restart sit above it — which is why the profiles stay
separate and `diagnostic`/`checkpoint` keep Blosc, with `wasm` strictly opt-in.
(Indicative numbers: one machine, level 5, synthetic-but-representative fields; the
ranking is stable, the absolute ratios are data- and chunk-shape-dependent.)

**Status caveat.** Wasm-loadability is established *structurally* — the emitted chain is
verified on disk to be blosc-free plain v3 zstd in all three writers — but **no
`wasm32-unknown-unknown` target has been built or executed** against these stores yet.
That remains the acceptance test before browser support is advertised.
