---
title: "value_invention_error"
description: "Stable error · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `ValueInventionError` | `ValueInventionError` | not exported |


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
class ValueInventionError(EarthSciAstError)
ValueInventionError(message: str, code: str | None = None)
```

A value-invention build-time materialisation error. `code` is the
diagnostic code when the error carries one (`KEY_OUT_OF_RANGE`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-py/src/earthsci_ast/value_invention.py#L38)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ValueInventionError {
    pub message: String,
    pub code: Option<&'static str>,
}

impl ValueInventionError { pub fn new(message: impl Into<String>) -> Self }

impl ValueInventionError { pub fn with_code(code: &'static str, message: impl Into<String>) -> Self }
```

A value-invention build-time materialisation error (the Rust analog of
Julia's `TreeWalkError` value-invention codes).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-rs/src/value_invention.rs#L47) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ValueInventionError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
