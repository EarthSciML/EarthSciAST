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
ValueInventionResult(extents: dict[str, int] = dict(), members: dict[str, list[Any]] = dict(), assignments: dict[str, list[int]] = dict(), groups: dict[str, list[float]] = dict(), join_key_buffers: dict[str, list[float]] = dict(), join_key_index_sets: dict[str, str] = dict(), vi_var_names: set[str] = set())
```

Result of [`materialize_value_invention`](/generated/api/ref/materialize_value_invention).

- `extents` — `from_faq` producer id → derived index-set cardinality (the
  dense extent `[1, n]` the resolver consumes).
- `members` — `from_faq` producer id → the distinct member tuples in
  §5.5.1 sorted order (for byte-identity assertions).
- `assignments` — arg-witness map var → the integer nearest-generator INDEX
  buffer, dense in output-index order (the SCVT assignment; §5.7 rule 6,
  byte-identical across bindings).
- `groups` — the downstream GROUPED / DERIVED buffers keyed on an arg-witness
  assignment, dense in output-index order: a grouped semiring reduction
  (`num[g] = Σ_{p:assign=g} rho_p·x_p`, run through
  [`relational.group_aggregate`](/generated/api/ref/group_aggregate), §5.5 rule 5) and an elementwise derived
  buffer (`centroid[g] = num[g]/den[g]`) — the SCVT centroid-update step.
- `join_key_buffers` — skolem BIN map var → the dense per-cell 48-bit bin
  code buffer (a list of floats, dense in output-index order), the broad-phase
  equi-join column `rg_src_bin` / `rg_tgt_bin` an aggregate `join.on`
  gates on. Each code is the interpreter's own
  `numpy_interpreter._skolem_code` of the materialised skolem key, so a
  buffer is **byte-identical** to the per-cell key the interpreter computes
  (`EvalContext.join_key_buffers`). The
  distinct value-invention primitives (distinct / rank) return SETS and
  arg-witness returns an ARG; this is the setup-materialised join column.
- `join_key_index_sets` — skolem BIN map var → its 1-D declared-shape index
  set name, so the join resolver maps the key column to the range symbol whose
  `{"from": <set>}` matches (`EvalContext.join_key_index_sets`).
- `vi_var_names` — value-invention LHS vars to drop from the ODE.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/value_invention.py#L1249)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ValueInventionResult {
    pub extents: HashMap<String, i64>,
    pub members: HashMap<String, Vec<Key>>,
    pub assignments: HashMap<String, Vec<i64>>,
    pub groups: HashMap<String, Vec<f64>>,
    pub vi_var_names: HashSet<String>,
    pub map_codes: HashMap<String, Vec<f64>>,
}
```

Result of [`materialize_value_invention`](/generated/api/ref/materialize_value_invention).

- `extents` — `from_faq` producer id → derived index-set cardinality (the
  dense extent `[1, n]` the resolver consumes).
- `members` — `from_faq` producer id → the distinct member keys in §5.5.1
  sorted order (for byte-identity assertions).
- `assignments` — arg-witness map var → the integer nearest-generator INDEX
  buffer, dense in output-index order (the SCVT assignment; §5.7 rule 6,
  byte-identical across bindings).
- `groups` — the downstream GROUPED / DERIVED buffers keyed on an arg-witness
  assignment, dense in output-index order: a grouped semiring reduction
  (`num[g] = Σ_{p:assign=g} rho_p·x_p`, run through [`group_aggregate`](/generated/api/ref/group_aggregate), §5.5
  rule 5) and an elementwise derived buffer (`centroid[g] = num[g]/den[g]`) —
  the SCVT centroid-update step.
- `vi_var_names` — value-invention LHS vars to drop from the ODE.
- `map_codes` — each skolem MAP buffer (a broad-phase bin key per cell, the
  column a `join.on` gate compares), dense in output-index order, as one
  integer code per key: the key's 1-based position in the sorted set of
  every map's keys. Codes are equal exactly where keys are, across all maps
  of one build, so a gate on two buffers compares codes as it would keys.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/value_invention.rs#L127) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ValueInventionResult.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
