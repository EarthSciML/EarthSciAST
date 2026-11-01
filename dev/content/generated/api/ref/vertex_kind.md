---
title: "vertex_kind"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `VertexKind` | `VertexKind` | `VertexKind` | `VertexKind` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const VertexKind: { readonly NODE: "node"; readonly INDEX_SET: "index_set"; readonly FACTOR: "factor"; }
type VertexKind = (typeof VertexKind)[keyof typeof VertexKind];
```

The three kinds of vertex in the reference graph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/reference-resolution.ts#L74)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class VertexKind
```

The three kinds of vertex in the reference graph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L86)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum VertexKind {
    Node,
    IndexSet,
    Factor,
}
```

The three kinds of vertex in the reference graph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/reference_resolution.rs#L123) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.VertexKind.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type VertexKind string
```

VertexKind is one of the three kinds of vertex in a reference graph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L94) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VertexKind)

</div>

</div>
