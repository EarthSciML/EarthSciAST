---
title: "skolem"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `skolem` | `skolem` | not exported |


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
skolem(components: Sequence[Any], *, symmetric: bool = False) -> tuple[Any, ...]
```

Canonical-tuple Skolem key (rule 4).

For a `symmetric` relation the components are sorted (generalising
[`skolem_edge`](/generated/api/ref/skolem_edge) to arity > 2); for a directed relation the order is
preserved, so `(1, 2)` and `(2, 1)` stay distinct. Never a `hash()` —
the tuple *is* the content-addressed key. The dense ID then comes from
[`rank`](/generated/api/ref/rank).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L160)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn skolem(components: Vec<Key>, symmetric: bool) -> Key
```

Canonical-tuple Skolem key (rule 4). For a `symmetric` relation the
components are sorted (generalising [`skolem_edge`](/generated/api/ref/skolem_edge) to arity > 2); for a
directed relation the order is preserved, so `(1, 2)` and `(2, 1)` stay
distinct. Never a native hash — the tuple *is* the content-addressed key; the
dense ID then comes from [`rank`](/generated/api/ref/rank).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/relational.rs#L287) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.skolem.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
