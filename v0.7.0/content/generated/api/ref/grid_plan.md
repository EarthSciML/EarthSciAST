---
title: "grid_plan"
description: "Stable type · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `GridPlan` | outside profile | not exported | `GridPlan` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct GridPlan
GridPlan(dims::Vector{Pair{String, Int64}}, time_dim::String, coords::Vector{DimCoord}, vars::Vector{VarPlan})
GridPlan(dims, time_dim, coords, vars)
```

```julia
GridPlan(dims, time_dim, coords, vars)
```

One emergent grid (RFC §9): the ordered SPATIAL `dims` (`name => length`; empty
for the scalar grid — the record axis is not included, see `time_dim`), the
record-axis name, the grid's CF dimension [`DimCoord`](/generated/api/extension/julia#x-dimcoord)s, and its
[`VarPlan`](/generated/api/ref/var_plan)s. The record COUNT is deliberately not part of the plan: a plan
is derived once and stays valid however many records get written.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/data_output.jl#L863)

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
pub struct GridPlan {
    pub dims: Vec<(String, usize)>,
    pub time_dim: String,
    pub coords: Vec<CoordPlan>,
    pub vars: Vec<VarPlan>,
}

impl GridPlan { pub fn dim_len(&self, dim: &str) -> Option<usize> }
```

One grid: a set of variables sharing a spatial-dim signature, with the
coordinates and dimension lengths that describe it (RFC §9). The RFC's
recommended decomposition is one Sink — one store or group — per grid.

Converting to `earthsciio::format::OutputSchema` is mechanical:
`OutputSchema::dims` is `[(time_dim, n_records)]` followed by
`Self::dims`; `coords` is `Self::coords` plus a `WriteCoord` for the
time axis built from the output times; `vars` is one `WriteVar` per
[`VarPlan`](/generated/api/ref/var_plan) whose `data` is `VarPlan::gridding` scattered across every
record. The record count is deliberately NOT part of the plan: a plan is
derived once and stays valid however many records get written.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/data_output.rs#L950) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.GridPlan.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
