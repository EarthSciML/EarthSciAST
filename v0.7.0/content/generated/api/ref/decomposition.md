---
title: "decomposition"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Decomposition` | not exported | not exported | `Decomposition` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Decomposition
Decomposition(axes::Vector{Pair{String, Union{Nothing, Int64}}}, faces::Vector{Pair{String, String}})
Decomposition(axes, faces)
Decomposition(; axes, faces)
```

```julia
Decomposition(; axes, faces = [])
```

A horizontal decomposition (API_SPEC §5.8): the index sets a tiling cuts, each
with its period (`nothing` when the axis is not periodic; otherwise the axis's
global extent), and the face sets that stagger off a cut axis (`"lon_nodes" =>
"lon"`). Every other index set is whole on every tile.

```julia
dec = Decomposition(axes = ["lon" => (period = 144,), "lat" => (period = nothing,)],
                    faces = ["lon_nodes" => "lon"])
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/range_restricted.jl#L25)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Decomposition {
    pub axes: Vec<AxisCut>,
    pub faces: Vec<(String, String)>,
}
```

The horizontal decomposition a tile cuts (RFC U3 §1): the decomposed index
sets and the face sets that stagger off them, `(face set, cell set)`.
Every other index set is whole on every tile.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L70) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Decomposition.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
