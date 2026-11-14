---
title: "stripped"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `stripped` | not exported | `stripped` | `stripped` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
stripped(prob::EsmProblem)
```

```julia
stripped(prob::EsmProblem) -> StrippedConstructs
```

What `strip` removed from `prob` (API_SPEC §5.8), flattened and namespaced.
Empty when nothing was.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/EarthSciAST.jl/src/strip_expose.jl#L79)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
stripped(prob: Any) -> StrippedConstructs
```

What `strip` removed from `prob` (API_SPEC §5.8). Empty when nothing was.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-py/src/earthsci_ast/strip.py#L544)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn stripped(prob: &EsmProblem) -> &StrippedConstructs
```

What `ProblemOptions::strip` removed from `prob`, flattened and
namespaced (API_SPEC §5.8, "The stripped object"). Empty when nothing was.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/ae13cc8f0c7013724cd3011b89390f836e34b5ad/pkg/earthsci-ast-rs/src/problem.rs#L1207) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.stripped.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
