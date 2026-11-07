---
title: "partition"
description: "Stable type · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | outside profile | `Partition` | `Partition` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Partition
Partition(class_summary: dict[str, int], materialization_points: list[MaterializationPoint] = list(), hot_tree_empty: bool = True, event_handler_empty: bool = True)
Partition.thresholds: list[str]  # property
```

The result of the cadence-partition pass over one model.

- `class_summary` — annotated nodes counted by derived class.
- `materialization_points` — where the frontier cut fires (expr-edge cuts
  inside the hot tree + whole-equation output buffers folded out of it).
- `hot_tree_empty` — no node classifies `continuous` (a pure-topology
  rule contributes nothing to the per-step RHS).
- `event_handler_empty` — nothing materialises at the `discrete` cadence.

**Members**

- `thresholds` — The materialization threshold multiset (sorted) — the conformance key.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/cadence.py#L717)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Partition {
    pub class_summary: ClassSummary,
    pub materialization_points: Vec<MaterializationPoint>,
    pub hot_tree_empty: bool,
    pub event_handler_empty: bool,
}
```

The partition of one model: the class summary, the materialization-point set,
and the hot-tree / per-event-handler emptiness (§5.7.5 three execution
outputs). Guards (§5.7.6) are checked during [`partition_model`](/generated/api/extension/rust#x-partition_model); a violation
is an `Err`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/cadence.rs#L760) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Partition.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
