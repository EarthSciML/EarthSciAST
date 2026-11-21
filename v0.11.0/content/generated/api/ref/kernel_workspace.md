---
title: "kernel_workspace"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `KernelWorkspace` | not exported | not exported | `KernelWorkspace` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct KernelWorkspace
KernelWorkspace(kernel::Kernel, ws::EarthSciAST.RhsWorkspace, u::Vector{Float64}, aux::Vector{Float64}, p::Vector{Float64}, du::Vector{Float64})
KernelWorkspace(kernel, ws, u, aux, p, du)
```

<p class="api-absent">No docstring.</p>

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/EarthSciAST.jl/src/strip_expose.jl#L640)

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
pub struct KernelWorkspace {
    /* private fields */
}
```

A kernel's buffers, one per concurrent caller. `Send`, not `Sync`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-rs/src/simulate_array/range/kernels.rs#L268) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.KernelWorkspace.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
