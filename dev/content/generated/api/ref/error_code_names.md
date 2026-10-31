---
title: "error_code_names"
description: "Stable function · Errors"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Errors](/generated/api/topics/errors)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `error_code_names` | not exported | not exported | `error_code_names` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
error_code_names()
```

```julia
error_code_names() -> Vector{String}
```

Every diagnostic code string in [`ERROR_CODES`](/generated/api/ref/error_codes), sorted. Handy for
cross-binding vocabulary diffs and for asserting in tests that a raise site
uses a registered code.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/error_codes.jl#L418)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn error_code_names() -> Vec<&'static str>
```

Every diagnostic code string in [`ERROR_CODES`](/generated/api/ref/error_codes), sorted. Handy for
cross-binding vocabulary diffs and for asserting in a test that a raise
site uses a registered code. Mirrors Julia's `error_code_names()`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/diagnostic.rs#L615) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.error_code_names.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
