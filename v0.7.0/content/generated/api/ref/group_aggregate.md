---
title: "group_aggregate"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `group_aggregate` | `group_aggregate` | not exported |


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
group_aggregate(rows: Iterable[Any], *, key: Callable[[Any], Any], value: Callable[[Any], Any], op: Callable[[Any, Any], Any]) -> list[tuple[Any, Any]]
```

Group-by + semiring aggregate (rule 5).

Bucket `rows` by `key(row)` (hashing only to bucket), combine the
`value(row)`s within each group with the semiring `op` (`⊕`), and emit
`(key, aggregate)` pairs **sorted by the canonical key**.

`op` MUST be associative + commutative (every registry `⊕` — `+`,
`*`, `min`, `max`, `&`, `|`, count — is) so the result is
independent of input / bucket order. For a **floating-point** `op` the
per-bucket reduction is done **sequentially in canonical (sorted) value
order** (rule 5) so the last-ULP result is reproducible; the exact / integer
path uses the same canonical order (immaterial there, but keeps one code
path). Group keys must be non-float (rule 1); values may be floats. Mirrors
the DuckDB oracle `SELECT key, ⊕(value) … GROUP BY key ORDER BY key`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/relational.py#L339)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn group_aggregate(rows: &[(Key, Num)], op: SemiringOp) -> Vec<(Key, Num)>
```

Group-by + semiring aggregate (rule 5). Bucket `rows` by their [`Key`](/generated/api/extension/rust#x-key)
(hashing only to bucket, via `IndexMap`), combine each group's [`Num`](/generated/api/extension/rust#x-num)
values with the semiring `op` (`⊕`), and emit `(key, aggregate)` pairs
**sorted by the canonical key**.

`op` is associative + commutative (every registry `⊕`), so the result is
independent of input / bucket order. The per-bucket reduction is a **left
fold over the values in canonical (sorted) order** so that a **floating-point**
`op` produces a reproducible last-ULP result (rule 5); the integer path uses
the same canonical order (immaterial there, but one code path).

Mirrors the DuckDB oracle `SELECT key, ⊕(value) … GROUP BY key ORDER BY key`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/relational.rs#L475) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.group_aggregate.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
