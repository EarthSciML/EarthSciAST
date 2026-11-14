---
title: "stripped_constructs"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `StrippedConstructs` | not exported | `StrippedConstructs` | `StrippedConstructs` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct StrippedConstructs
StrippedConstructs(strip::Vector{String}, events::Vector{Any}, parameter_updates::Vector{Any}, z_layout::Vector{Any}, z0::Vector{Union{Nothing, Float64}}, residuals::Vector{Any})
StrippedConstructs(strip, events, parameter_updates, z_layout, z0, residuals)
```

```julia
StrippedConstructs
```

What `esm_problem(…; strip)` removed (API_SPEC §5.8, "The stripped object"):
the events, the stripped parameter updates, the residuals of the implicit
equations, and the `z` layout with its starting values. Read it with
[`stripped`](/generated/api/ref/stripped); [`canonical_json`](/generated/api/ref/canonical_json) gives its canonical JSON.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/EarthSciAST.jl/src/strip_expose.jl#L13)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class StrippedConstructs
StrippedConstructs(strip: list[str] = list(), events: list[dict[str, Any]] = list(), parameter_updates: list[dict[str, Any]] = list(), unknowns: list[str] = list(), z_layout: dict[str, dict[str, Any]] = dict(), z0: list[float | None] = list(), residuals: list[dict[str, Any]] = list())
StrippedConstructs.is_empty() -> bool
StrippedConstructs.removed_classes() -> list[str]
StrippedConstructs.to_json() -> dict[str, Any]
StrippedConstructs.canonical_json() -> str
```

What `strip` removed (API_SPEC §5.8, "The stripped object").

**Members**

- `canonical_json` — Compact, keys ascending, numbers in CONFORMANCE_SPEC §5.5.3.1 form.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-py/src/earthsci_ast/strip.py#L40)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct StrippedConstructs {
    /* private fields */
}

impl StrippedConstructs { pub fn strip(&self) -> StripSet }

impl StrippedConstructs { pub fn events(&self) -> &[StrippedEvent] }

impl StrippedConstructs { pub fn parameter_updates(&self) -> &[StrippedUpdate] }

impl StrippedConstructs { pub fn algebraic_unknowns(&self) -> Vec<&str> }

impl StrippedConstructs { pub fn z_layout(&self) -> &[ZBlock] }

impl StrippedConstructs { pub fn n_z(&self) -> usize }

impl StrippedConstructs { pub fn z0(&self) -> &[Option<f64>] }

impl StrippedConstructs { pub fn residuals(&self) -> &[StrippedResidual] }

impl StrippedConstructs { pub fn is_empty(&self) -> bool }

impl StrippedConstructs { pub fn removed_classes(&self) -> Vec<&'static str> }

impl StrippedConstructs { pub fn to_json(&self) -> Value }

impl StrippedConstructs { pub fn canonical_json(&self) -> String }
```

What `strip` removed (API_SPEC §5.8, "The stripped object"). Empty when
nothing was requested or nothing was found.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-rs/src/strip.rs#L196) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.StrippedConstructs.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
