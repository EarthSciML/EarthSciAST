---
title: "group_gridding_by_grid"
description: "Stable function · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `group_gridding_by_grid` | outside profile | not exported | `group_gridding_by_grid` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
group_gridding_by_grid(gridding::AbstractVector{VarGridding})
```

```julia
group_gridding_by_grid(gridding) -> Vector{Vector{VarGridding}}
```

Partition output variables into GRIDS by their spatial-dim signature (RFC §9):
variables that live on the same set of axes form one grid, so an atmosphere over
`[lev, lat, lon]` and an ocean over `[depth, lat, lon]` split into two grids by
construction (grids are emergent, not declared). The signature is the SORTED set of
a variable's `dimnames`, so axis order does not fragment a grid and every scalar
(empty signature) lands in ONE shared 0-D grid. Groups come back in
first-seen signature order (deterministic). One Sink per returned group is the RFC's
recommended multi-grid decomposition — each grid gets its own cadence, chunking, and
checkpoint frequency; restrict a sink to a grid's variables via `build_zarr_sink`'s
`variables` keyword.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/data_output.jl#L749)

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
pub fn group_gridding_by_grid(gridding: Vec<VarGridding>) -> Vec<Vec<VarGridding>>
```

Partition output variables into GRIDS by their spatial-dim signature
(RFC §9): variables over the same set of axes form one grid, so an
atmosphere over `[lev, lat, lon]` and an ocean over `[depth, lat, lon]`
split by construction. The signature is the SORTED SET of a variable's
`dim_names`, so axis order does not fragment a grid, and every scalar
(empty signature) lands in one shared 0-D grid. Groups come back in
first-seen signature order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/data_output.rs#L803) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.group_gridding_by_grid.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
