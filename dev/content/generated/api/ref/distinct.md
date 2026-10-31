---
title: "distinct"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `distinct` | `distinct` | not exported |


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
distinct(rows: Iterable[Any]) -> list[Any]
```

Set semantics over `rows`: sort by the §5.5.1 total order, then drop
**adjacent** duplicates (rule 2).

The returned order **is** the sorted order — never first-seen / `set`
iteration order. A pure function of the input multiset, so duplicate,
reversed, and permuted inputs all collapse to the identical output.

`rows` is any iterable of order-comparable keys: integer / categorical
scalars, or tuples thereof (a `list` row is normalised to a `tuple`).
Floats in keys raise [`FloatKeyError`](/generated/api/ref/float_key_error) (rule 1). Mirrors the DuckDB
oracle `SELECT DISTINCT … ORDER BY …`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L179)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn distinct(rows: &[Key]) -> Vec<Key>
```

Set semantics over `rows`: sort by the §5.5.1 total order, then drop
**adjacent** duplicates (rule 2). The returned order **is** the sorted order
— never first-seen / insertion order. A pure function of the input multiset,
so duplicate, reversed, and permuted inputs all collapse to the identical
output.

Mirrors the DuckDB oracle `SELECT DISTINCT … ORDER BY …`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/relational.rs#L303) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.distinct.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
