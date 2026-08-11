# Output-Derivation Conformance (`tests/conformance/output_derivation/`)

Cross-language conformance for the **simulation-output derivation** — the step
that turns

```
.esm document + flat state element names + a caller-named observed subset
```

into the dimension-labeled, CF-annotated **output plan** a Zarr writer is handed.
Governed by the `streaming-output-sinks` RFC §7–§9, with the reconciled decisions
recorded in §16.12.

## Why this exists

The derivation lives in **two** languages —
`pkg/EarthSciAST.jl/src/data_output.jl` and
`pkg/earthsci-ast-rs/src/data_output.rs` — and until this corpus **it had no
cross-language gate at any level.**

The gate people reach for is EarthSciIO's `conformance/write_spec.json`, but that
is an *already-derived* schema: its keys are `dims`, `time_dim`, `coords`, `vars`,
`chunk_shape`, `shard_shape`. That harness therefore starts **downstream** of
derivation and drives the three writers from a hand-authored shape. No amount of
coverage there could have caught a derivation bug.

The two compose, because **a derivation corpus's output type is the write
corpus's input type**:

```
.esm ──[derivation]──▶ OutputSchema ──[writers]──▶ Zarr store
     └─ this corpus ──┘              └─ EarthSciIO/conformance ─┘
```

Together they are an end-to-end chain from document to bytes with the seam between
them checked.

## What it caught

Three divergences between the two implementations, all silent, all fixed in the
same change that added this corpus (RFC §16.12):

1. **Scalars.** Julia gave a scalar the singleton shape `[1]` and a synthetic
   `<base>_d0` axis, so every scalar became its own single-member grid — a 0-D
   model with 66 scalar states emitted 66 length-1 dimensions named after their
   own variables and 66 separate grids. Rust made a scalar genuinely
   0-spatial-dimensional. **Rust was right**; Julia now matches.
2. **On-disk dimension order.** Julia wrote `[…spatial, time]`; Rust writes
   `[time, …spatial]`. **Rust was right** (CF §2.4's T,Z,Y,X; the record-first
   layout a NetCDF unlimited dimension requires; the order EarthSciIO's own
   `write_spec.json` already pins for all three writers); Julia now matches.
3. **The record-axis name.** Rust reads `domain.independent_variable` as RFC §7
   specifies; Julia hardcoded `"time"`. **Rust was right**; Julia now matches.

## Layout

| File | What it is |
|------|------------|
| `manifest.json` | The cases: fixture, golden, `slot_names`, `observed`, plus the input and representation contracts. |
| `fixtures/scalar_0d.esm` | A purely 0-D model — four bare scalars, one of them `observed`. The case that exposed divergence 1. |
| `fixtures/gridded.esm` | One 3×2 `[lon, lat]` grid, two variables, both axes carrying `coordinates` entries. |
| `fixtures/mixed.esm` | Scalars **and** two different gridded signatures in one document ⇒ exactly three grids. Record axis named `t`. |
| `golden/*.json` | The derived plan each binding must reproduce. |

## The inputs, and why they are what they are

A case supplies the document **and** the flat state element names. It does *not*
run a build. That is deliberate: the cell-key scheme (`name[i,j,…]`, 1-based,
column-major, dim 0 fastest) is itself specified by RFC §7 and is byte-identical
across bindings, so making it an input keeps the corpus on the derivation seam
instead of dragging a compiler, a solver, and their version skew into a metadata
test. Element *i* of `slot_names` is flat index *i*.

## The golden's representation contract

- **`flat_indices`** are **0-based**, in **row-major (C-order)** cell order within
  `shape` — the layout a Zarr writer's buffer wants, with the column-major →
  row-major transposition already applied. Rust's `VarGridding` stores exactly
  this; Julia stores 1-based indices in enumeration order plus a `cart` map and
  converts with `row_major_flat_indices`. One representation, so the comparison
  is on values rather than on either binding's internal convention.
- **`vars[].dims`** is the **on-disk** dimension list: record axis first, then the
  variable's spatial axes. A scalar's dims are therefore exactly `[time_dim]`.
- **`dims`** on a grid is its *spatial* axes only, `[name, length]` pairs in
  first-seen order. The record count is deliberately absent: a plan is derived
  once and stays valid however many records get written.
- **Grid order** is first-seen spatial-dim-signature order, where the signature is
  the **sorted set** of a variable's dim names — so axis order does not fragment a
  grid, and every scalar (empty signature) lands in one shared 0-D grid.
- **Variable order** within a grid is sorted by base name.
- `chunk_shape` / `shard_shape` are **not** here. They are writer policy, chosen
  by the sink, not derived from the document.

## Runners

Both bindings assert against the **same** committed golden, so golden agreement
*is* cross-binding agreement (the rule `CONFORMANCE_SPEC.md` §5.7.7 already uses).

* **Julia** — `pkg/EarthSciAST.jl/test/output_derivation_conformance_test.jl`
  (in `runtests.jl`; needs no solver and no EarthSciIO)
* **Rust** — `pkg/earthsci-ast-rs/tests/output_derivation_conformance.rs`

Run both in one shot:

```sh
tests/conformance/output_derivation/run_output_derivation_conformance.sh
```

Each runner *renders* the production `derive_output_plan` result into the golden's
shape and compares. Neither re-derives anything in the adapter, so a derivation
bug cannot hide behind the test.

## Adding a case

1. Add the `.esm` under `fixtures/`.
2. Add a `cases[]` entry naming its `slot_names` (flat order) and `observed`.
3. Write the expected plan to `golden/<id>.json` **by hand** — a golden blessed
   from an implementation's own output only pins that implementation's current
   behaviour, which is precisely the failure this corpus exists to prevent.
4. Run both runners.
