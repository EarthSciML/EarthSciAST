---
title: "kernel"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Kernel` | not exported | not exported | `Kernel` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Kernel
Kernel(name::String, prog::EarthSciAST.RhsProgram, direct::Bool, map::Bool, aux_plan::Vector{NTuple{4, Int64}}, p_map::Vector{Int64}, out_plan::Vector{Tuple{Int64, Int64, Int64}}, layout::Vector{KernelBlock}, n_u::Int64, n_z::Int64, n_p::Int64, out_len::Int64)
Kernel(name, prog, direct, map, aux_plan, p_map, out_plan, layout, n_u, n_z, n_p, out_len)
```

```julia
Kernel
```

A compiled kernel (API_SPEC §5.8, "Strip and expose"). Evaluate it with
[`kernel!`](/generated/api/extension/julia#x-kernel) on a [`kernel_workspace`](/generated/api/extension/julia#x-kernel_workspace) per concurrent caller.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/EarthSciAST.jl/src/strip_expose.jl#L618)

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
pub struct Kernel {
    /* private fields */
}

impl Kernel { pub fn name(&self) -> &str }

impl Kernel { pub fn layout(&self) -> &[KernelBlock] }

impl Kernel { pub fn len(&self) -> usize }

impl Kernel { pub fn is_empty(&self) -> bool }

impl Kernel { pub fn is_map(&self) -> bool }

impl Kernel { pub fn new_workspace(&self) -> KernelWorkspace }

impl Kernel { pub fn eval_into(&self, u: &[f64], z: &[f64], p: &[f64], t: f64, dt: f64, forcing: &ForcingSet, out: &mut [f64], ws: &mut KernelWorkspace) -> Result<(), RhsError> }
```

A compiled kernel (API_SPEC §5.8). `Send + Sync`; a clone shares it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-rs/src/simulate_array/range/kernels.rs#L232) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Kernel.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
