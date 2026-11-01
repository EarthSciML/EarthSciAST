---
title: "derive_output_gridding"
description: "Stable function · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `derive_output_gridding` | outside profile | not exported | `derive_output_gridding` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
derive_output_gridding(var_map::AbstractDict)
derive_output_gridding(var_map::AbstractDict, meta::OutputMeta)
```

```julia
derive_output_gridding(var_map) -> Vector{VarGridding}
```

Invert the flat `var_map` (state-element name → flat index) into one
[`VarGridding`](/generated/api/ref/var_gridding) per output base-variable (RFC §7). Groups the cell keys by
base name via `_parse_cell_key` (a key with no `[…]` suffix is a scalar
variable), derives each axis length as the max cell index along that axis, and
records the flat-index → `CartesianIndex` scatter map. Base-variable order is the
first-seen order in `var_map`'s iteration, made deterministic by sorting on the
base name so the derived schema is reproducible.

A gridded variable's cells must be **dense**: exactly one cell per grid position.
An incomplete grid (a hole, which would leave an uninitialized value on disk) or a
double-covered one (which would silently drop a cell) is an [`OutputError`](/generated/api/ref/output_error),
not a silent mis-write.

---

```julia
derive_output_gridding(var_map, meta::OutputMeta) -> Vector{VarGridding}
```

Doc-aware [`derive_output_gridding`](/generated/api/ref/derive_output_gridding): first invert the flat `var_map`
(shape + scatter map, the language-neutral core), then rename each variable's axes
from positional `<base>_d0` to its REAL declared dim names via `meta.var_dims`
(RFC §7 → §8). A variable with no declared `shape` in `meta` (a scalar, or a
`var_map` built without a document) keeps its positional names. Validates that the
declared dim count and each `index_sets` length agree with the shape recovered
from the flat state — a mismatch means the document and the built state disagree,
which must fail loudly rather than mislabel an axis.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/data_output.jl#L349)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn derive_output_gridding(slot_names: &[String]) -> Result<Vec<VarGridding>, OutputError>
```

Invert the flat state-element names into one [`VarGridding`](/generated/api/ref/var_gridding) per output
base-variable (RFC §7), the flat index of a name being its position in
`slot_names` — the shape `Solution::state_variable_names` already has.

Base-variable order is sorted by base name, matching Julia, so a derived
plan is reproducible and cross-language comparable.

**Errors**
See [`OutputError`](/generated/api/ref/output_error): a ragged rank, a duplicated scalar key, a 0 index, or
a grid the cells do not densely cover.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/data_output.rs#L441) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.derive_output_gridding.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
