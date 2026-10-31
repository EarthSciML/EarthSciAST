---
title: "edge_kind"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `EdgeKind` | `EdgeKind` | `EdgeKind` | `EdgeKind` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const EdgeKind: { readonly RANGE_FROM: "range_from"; readonly FROM_FAQ: "from_faq"; readonly JOIN_FACTOR: "join_factor"; }
type EdgeKind = (typeof EdgeKind)[keyof typeof EdgeKind];
```

The three kinds of reference edge (RFC §6.1 "Propagation").

**Properties**

- `RANGE_FROM` — aggregate node → the index set it iterates (`ranges[*].from`).
- `FROM_FAQ` — `kind: "derived"` index set → the node that materializes it (`from_faq`).
- `JOIN_FACTOR` — aggregate node → a factor named by `join.on`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/reference-resolution.ts#L82)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class EdgeKind
```

The three kinds of reference edge (RFC §6.1 "Propagation").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L94)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum EdgeKind {
    RangeFrom,
    FromFaq,
    JoinFactor,
}
```

The three kinds of reference edge (RFC §6.1 "Propagation").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/reference_resolution.rs#L134) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.EdgeKind.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type EdgeKind string
```

EdgeKind is one of the three kinds of reference edge (RFC §6.1 "Propagation").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L107) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EdgeKind)

</div>

</div>
