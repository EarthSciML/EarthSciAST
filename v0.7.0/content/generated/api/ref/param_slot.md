---
title: "param_slot"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ParamSlot` | not exported | not exported | `ParamSlot` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ParamSlot
ParamSlot(name::String, default::Union{Nothing, Float64})
ParamSlot(name, default)
```

```julia
ParamSlot
```

One entry of a program's parameter vector ([`parameters`](/generated/api/ref/parameters)): the flattened
parameter `name` and its declared `default` (`nothing` when it declares none).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/rhs_program.jl#L21)

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
pub struct ParamSlot {
    pub name: String,
    pub default: Option<f64>,
}
```

One positional parameter of a program: `p[k]` is `RhsProgram::parameters``[k]`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/simulate_array/range/forcing.rs#L109) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ParamSlot.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
