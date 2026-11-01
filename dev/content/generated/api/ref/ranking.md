---
title: "ranking"
description: "Stable type · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `Ranking` | `Ranking` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Ranking
Ranking(order: list[Any], ids: dict[Any, int], base: int)
Ranking.__getitem__(key: Any) -> int
```

Result of [`rank`](/generated/api/ref/rank).

- `order` — the distinct tuples in §5.5.1 total order.
- `ids`   — `ids[t]` is the dense integer assigned to tuple `t`.
- `base`  — the emission base. Python emits **0-based** (the canonical
  numbering; `CONFORMANCE_SPEC.md` §5.5.1 rule 3). The conformance adapter
  declares this base and the harness normalises via
  `canonical = reported − base`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L241)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Ranking {
    pub order: Vec<Key>,
    pub id: IndexMap<Key, i64>,
    pub base: i64,
}

impl Ranking { pub fn dense_ids(&self) -> Vec<i64> }

impl Ranking { pub fn canonical_dense_ids(&self) -> Vec<i64> }
```

Result of [`rank`](/generated/api/ref/rank).

- `order` — the distinct tuples in §5.5.1 total order.
- `id` — `id[t]` is the dense integer assigned to tuple `t` (insertion order
  equals sorted order, since it is filled in `order` sequence).
- `base` — the emission base. Rust emits **0-based** (`CONFORMANCE_SPEC.md`
  §5.5.1 rule 3, the canonical numbering); the conformance adapter recovers
  the canonical 0-based ID via `canonical = reported − base`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/relational.rs#L418) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Ranking.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
