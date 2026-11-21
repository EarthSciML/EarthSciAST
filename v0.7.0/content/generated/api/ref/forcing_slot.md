---
title: "forcing_slot"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ForcingSlot` | not exported | not exported | `ForcingSlot` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ForcingSlot
ForcingSlot(name::String, shape::Vector{Int64}, kind::Symbol)
ForcingSlot(name, shape, kind)
```

```julia
ForcingSlot
```

One buffer of a [`ForcingSet`](/generated/api/ref/forcing_set-type) ([`forcing_slots`](/generated/api/extension/julia#x-forcing_slots)): the flattened
`name`, its resolved `shape` (empty for a 0-d input) and its `kind`: `:forcing`
(an externally fed parameter: its `update` takes its value from a data source or
a handler) or `:array_parameter` (any other parameter the program reads as a
run-time array: a shaped parameter with a value under
`esm_problem(…; runtime_array_parameters = true)`, or one whose buffer the
caller bound through `param_arrays`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/rhs_program.jl#L34)

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
pub struct ForcingSlot {
    pub name: String,
    pub shape: Vec<usize>,
    pub kind: SlotKind,
}

impl ForcingSlot { pub fn len(&self) -> usize }

impl ForcingSlot { pub fn is_empty(&self) -> bool }
```

One buffer of a [`ForcingSet`](/generated/api/ref/forcing_set-type): the variable it serves, its shape, and its
kind. The buffer holds `shape`'s element count (one for a 0-d slot),
column-major, first index fastest.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/simulate_array/range/forcing.rs#L140) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ForcingSlot.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
