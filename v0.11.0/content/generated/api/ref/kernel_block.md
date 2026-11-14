---
title: "kernel_block"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `KernelBlock` | not exported | not exported | `KernelBlock` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct KernelBlock
KernelBlock(label::String, offset::Int64, shape::Vector{Int64})
KernelBlock(label, offset, shape)
```

```julia
KernelBlock(label, offset, shape)
```

One output's block of a kernel's `out` (`offset` 1-based).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/EarthSciAST.jl/src/strip_expose.jl#L607)

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
pub struct KernelBlock {
    pub label: String,
    pub offset: usize,
    pub shape: Vec<usize>,
}
```

One output's block of a kernel's `out` (0-based `offset`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-rs/src/simulate_array/range/kernels.rs#L216) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.KernelBlock.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
