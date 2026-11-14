---
title: "var_gridding"
description: "Stable type · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `VarGridding` | outside profile | not exported | `VarGridding` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct VarGridding
VarGridding(base::String, shape::Vector{Int64}, dimnames::Vector{String}, flat_indices::Vector{Int64}, cart::Vector{CartesianIndex})
VarGridding(base, shape, dimnames, flat_indices, cart)
```

```julia
VarGridding
```

The gridded layout of one output base-variable, derived from a flat `var_map`
(RFC §7). Scatter a flat state vector `u` into this variable's gridded array with
`grid[cart[k]] = u[flat_indices[k]]` — placement is by explicit `CartesianIndex`,
so it is correct regardless of enumeration order.

* `base::String` — the variable's base name (the cell key minus its `[…]`).
* `shape::Vector{Int}` — the gridded spatial shape. **Empty** for a scalar
  variable: a scalar is genuinely 0-spatial-dimensional, its gridded array is a
  0-d `Array{Float64,0}`, and its on-disk dims are exactly `[time_dim]` (RFC
  §16.12; see the reconciliation note there).
* `dimnames::Vector{String}` — one positional dim name per axis of `shape`
  (`"<base>_d0"`, …), replaced by the real `index_sets` names once an
  [`OutputMeta`](/generated/api/ref/output_meta) has been applied. Empty for a scalar.
* `flat_indices::Vector{Int}` — the flat `u` indices of this variable's cells.
* `cart::Vector{CartesianIndex}` — the 1-based grid position of each
  `flat_indices` entry (same order); `CartesianIndex()` for a scalar.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/data_output.jl#L321)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct VarGridding {
    pub base: String,
    pub shape: Vec<usize>,
    pub dim_names: Vec<String>,
    pub flat_indices: Vec<usize>,
}

impl VarGridding { pub fn n_cells(&self) -> usize }

impl VarGridding { pub fn is_scalar(&self) -> bool }

impl VarGridding { pub fn cart(&self, cell: usize) -> Vec<usize> }

impl VarGridding { pub fn scatter(&self, flat_u: &[f64], out: &mut [f64]) -> Result<(), OutputError> }

impl VarGridding { pub fn scatter_record(&self, flat_u: &[f64], out: &mut [f64], record: usize) -> Result<(), OutputError> }

impl VarGridding { pub fn gather(&self, grid: &[f64], flat_u: &mut [f64]) -> Result<(), OutputError> }
```

The gridded layout of one output base-variable, derived from the flat
state-element names (RFC §7).

The inversion is baked into `Self::flat_indices`: it is indexed by
**row-major (C-order) offset** within `Self::shape` and holds the
*column-major* flat state index that feeds that cell. Scattering is
therefore a single linear pass with the transposition already applied —
`out[o] = u[flat_indices[o]]` — which is exactly the layout
`earthsciio::format::WriteVar::data` requires.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/data_output.rs#L289) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.VarGridding.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
