---
title: "skolem_edge"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `skolem_edge` | `skolem_edge` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
skolem_edge(a: Any, b: Any) -> tuple[Any, Any]
```

Canonical key for an **undirected** pair (a symmetric relation):
`(min(a, b), max(a, b))`.

The deterministic, content-addressed identity of a mesh edge (RFC §5.5
generalises ESI `pack`). It is **not** a hash (rule 4) — the tuple itself
is the key, so the dense ID later assigned by [`rank`](/generated/api/ref/rank) is reproducible
across bindings. `a` and `b` must be order-comparable and non-float.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L147)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn skolem_edge(a: Key, b: Key) -> Key
```

Canonical key for an **undirected** pair (a symmetric relation):
`(min(a,b), max(a,b))`. The deterministic, content-addressed identity of a
mesh edge (RFC §5.5 generalises ESI `pack`). It is **not** a hash (rule 4) —
the tuple itself is the key, so the dense ID later assigned by [`rank`](/generated/api/ref/rank) is
reproducible across bindings. Equal components are preserved (`(7,7)`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/relational.rs#L274) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.skolem_edge.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
