---
title: "kernel_set"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `KernelSet` | not exported | not exported | `KernelSet` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct KernelSet
KernelSet(kernels::OrderedCollections.OrderedDict{String, Kernel}, rhs::EarthSciAST.RhsProgram)
KernelSet(kernels, rhs)
```

```julia
KernelSet
```

The kernels of one [`compile_kernels`](/generated/api/ref/compile_kernels) call: `ks["name"]`, with one
`u` layout ([`state_layout`](/generated/api/extension/julia#x-state_layout)), one `z` layout ([`z_layout`](/generated/api/extension/julia#x-z_layout)), one
parameter vector ([`parameters`](/generated/api/ref/parameters), [`parameter_vector`](/generated/api/extension/julia#x-parameter_vector)) and one
forcing signature ([`forcing_slots`](/generated/api/extension/julia#x-forcing_slots), [`default_forcing_set`](/generated/api/ref/default_forcing_set)).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/EarthSciAST.jl/src/strip_expose.jl#L648)

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
pub struct KernelSet {
    /* private fields */
}

impl KernelSet { pub fn get(&self, name: &str) -> Option<&Kernel> }

impl KernelSet { pub fn names(&self) -> Vec<&str> }

impl KernelSet { pub fn state_layout(&self) -> &[StateBlock] }

impl KernelSet { pub fn z_layout(&self) -> &[StateBlock] }

impl KernelSet { pub fn n_states(&self) -> usize }

impl KernelSet { pub fn n_z(&self) -> usize }

impl KernelSet { pub fn parameters(&self) -> &[ParamSlot] }

impl KernelSet { pub fn parameter_vector(&self, overrides: &HashMap<String, f64>) -> Result<Vec<f64>, SimulateError> }

impl KernelSet { pub fn forcing_slots(&self) -> &[ForcingSlot] }

impl KernelSet { pub fn default_forcing(&self) -> ForcingSet }
```

The kernels of one [`compile_kernels`](/generated/api/ref/compile_kernels) call, sharing one `u` / `z` layout,
one parameter vector and one forcing signature.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-rs/src/simulate_array/range/kernels.rs#L389) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.KernelSet.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
