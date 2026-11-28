---
title: "rhs_selection"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `RhsSelection` | not exported | not exported | `RhsSelection` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct RhsSelection
RhsSelection(; writes, terms)
RhsSelection(writes::W, terms::T) where {W, T}
```

```julia
RhsSelection(; writes = :all, terms = :all)
```

Writable state names and term origins passed to [`select`](/generated/api/ref/select).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/operator_ir.jl#L6)

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
pub struct RhsSelection {
    pub writes: Option<Vec<String>>,
    pub terms: Option<Vec<TermOrigin>>,
}
```

Which terms and which variables an operator keeps (API_SPEC §5.8,
`select`). `None` keeps every term, or writes every state.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/simulate_array/range/mod.rs#L67) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.RhsSelection.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
