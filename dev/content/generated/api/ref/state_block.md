---
title: "state_block"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `StateBlock` | not exported | not exported | `StateBlock` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct StateBlock
StateBlock(name::String, offset::Int64, shape::Vector{Int64})
StateBlock(name, offset, shape)
```

```julia
StateBlock
```

One block of a program's `u` ([`state_layout`](/generated/api/extension/julia#x-state_layout)): the flattened state
`name`, the 1-based `offset` of its first element, and its `shape` (empty for a
0-d state). Column-major, first index fastest.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/rhs_program.jl#L54)

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
pub struct StateBlock {
    pub name: String,
    pub flat_offset: usize,
    pub shape: Vec<usize>,
}
```

One state variable's block of `u` (API_SPEC §5.8): `shape` column-major
from `flat_offset`, first index fastest.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/simulate_array/range/forcing.rs#L119) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StateBlock.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
