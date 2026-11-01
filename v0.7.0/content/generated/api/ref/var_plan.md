---
title: "var_plan"
description: "Stable type · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `VarPlan` | outside profile | not exported | `VarPlan` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct VarPlan
VarPlan(name::String, dims::Vector{String}, attrs::Dict{String, Any}, dtype::String, gridding::VarGridding)
VarPlan(name, dims, attrs, dtype, gridding)
```

```julia
VarPlan(name, dims, attrs, dtype, gridding)
```

One output variable as a writer sees it: the on-disk `name`, its ordered on-disk
`dims` (record axis first, then spatial axes — a scalar's dims are exactly
`[time_dim]`), the CF `attrs` retained from the document, the element `dtype`, and
the [`VarGridding`](/generated/api/ref/var_gridding) that scatters a flat state into it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/data_output.jl#L847)

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
pub struct VarPlan {
    pub name: String,
    pub dims: Vec<String>,
    pub attrs: Map<String, Value>,
    pub dtype: &'static str,
    pub gridding: VarGridding,
}

impl VarPlan { pub fn values_per_record(&self) -> usize }
```

One output variable: what a writer declares, plus the inversion that fills
it. Field-for-field the shape of `earthsciio::format::WriteVar` once
`Self::gridding` has scattered the trajectory into `data`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/data_output.rs#L916) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.VarPlan.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
