---
title: "geometry_error"
description: "Stable error · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `GeometryError` | `GeometryError` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this error.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class GeometryError(EarthSciAstError)
```

A polygon-clip / area evaluation failed (bad operand, degenerate input).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/geometry.py#L62)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct GeometryError {
    /* private fields */
}

impl GeometryError { pub fn is_degenerate_operand(&self) -> bool }

impl GeometryError { pub fn message(&self) -> &str }
```

An error from the geometry kernel — a degenerate input ring or a failed clip.
Wraps the human-readable reason reported by the underlying engine. (It no
longer carries a "spherical backend unavailable" case: since the kernel is
pure Rust it links on every target, wasm included.)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/geometry.rs#L90) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.GeometryError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
