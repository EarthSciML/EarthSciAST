---
title: "value_invention_result"
description: "Stable type · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `ValueInventionResult` | `ValueInventionResult` | not exported |


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
class ValueInventionResult
ValueInventionResult(extents: dict[str, int] = dict(), members: dict[str, list[Any]] = dict(), vi_var_names: set[str] = set())
```

Result of [`materialize_value_invention`](/generated/api/ref/materialize_value_invention).

- `extents` — `from_faq` producer id → derived index-set cardinality (the
  dense extent `[1, n]` the resolver consumes).
- `members` — `from_faq` producer id → the distinct member keys in
  §5.5.1 sorted order (for byte-identity assertions).
- `vi_var_names` — value-invention LHS vars to drop from the ODE.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-py/src/earthsci_ast/value_invention.py#L826)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ValueInventionResult {
    pub extents: HashMap<String, i64>,
    pub members: HashMap<String, Vec<Key>>,
    pub vi_var_names: HashSet<String>,
}
```

Result of [`materialize_value_invention`](/generated/api/ref/materialize_value_invention).

- `extents` — `from_faq` producer id → derived index-set cardinality (the
  dense extent `[1, n]` the resolver consumes).
- `members` — `from_faq` producer id → the distinct member keys in §5.5.1
  sorted order (for byte-identity assertions).
- `vi_var_names` — value-invention LHS vars to drop from the ODE.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-rs/src/value_invention.rs#L116) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ValueInventionResult.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
