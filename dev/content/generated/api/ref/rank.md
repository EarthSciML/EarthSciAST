---
title: "rank"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `rank` | `rank` | not exported |


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
rank(rows: Iterable[Any], *, base: int = 0) -> Ranking
```

Dense integer renumbering (rule 3): assign IDs by position in the sorted
[`distinct`](/generated/api/ref/distinct) sequence.

`base` is the emission base — Python's native **0-based** is the default
(the canonical numbering the conformance suite asserts on); pass `base=1`
for a 1-based numbering. Equivalent to SQL `dense_rank() OVER (ORDER BY …)`
over the deduplicated rows.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L261)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn rank(rows: &[Key]) -> Ranking
```

Dense integer renumbering (rule 3) at Rust's native **0-based** emission:
assign IDs by position in the sorted [`distinct`](/generated/api/ref/distinct) sequence. Equivalent to SQL
`dense_rank() OVER (ORDER BY …)` over the deduplicated rows.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/relational.rs#L445) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.rank.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
