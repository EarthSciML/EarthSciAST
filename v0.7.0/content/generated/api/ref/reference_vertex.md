---
title: "reference_vertex"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ReferenceVertex` | `ReferenceVertex` | `ReferenceVertex` | `ReferenceVertex` | `ReferenceVertex` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ReferenceVertex
ReferenceVertex(key::String, kind::String, name::String, op::Union{Nothing, String}, node_id::Union{Nothing, String}, path::Union{Nothing, String})
ReferenceVertex(key, kind, name, op, node_id, path)
```

```julia
ReferenceVertex
```

A vertex in the reference graph, addressed by a kind-namespaced `key`
(`"$kind:$name"`). For a node vertex, `name` is the node's stable address: its
explicit `id` when present, else its structural path (e.g.
`equations/0/rhs/expr`). `op`, `node_id`, and `path` are diagnostic metadata.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/reference_graph.jl#L75)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface ReferenceVertex {
    key: string;
    kind: VertexKind;
    name: string;
    op?: string;
    nodeId?: string;
    path?: string;
}
```

A vertex in the reference graph, addressed by a kind-namespaced `key`.

`key` is `` `${kind}:${name}` ``. For a `node` vertex, `name` is the node's
stable address: its explicit `id` when it has one, else its structural path
(e.g. `equations/0/rhs/expr`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/reference-resolution.ts#L99)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ReferenceVertex
ReferenceVertex(key: str, kind: str, name: str, op: str | None = None, node_id: str | None = None, path: str | None = None)
```

A vertex in the reference graph, addressed by a kind-namespaced `key`.

`key` is `f"{kind}:{name}"`. For a `NODE` vertex `name` is the
node's stable address: its explicit `id` when it has one, else its
structural path (e.g. `equations/0/rhs/expr`). `node_id` records the
explicit id (if any), `op` the operator, and `path` the structural path,
for diagnostics.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L105)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ReferenceVertex {
    pub key: String,
    pub kind: VertexKind,
    pub name: String,
    pub op: Option<String>,
    pub node_id: Option<String>,
    pub path: Option<String>,
}
```

A vertex in the reference graph, addressed by a kind-namespaced `key`.

`key` is `"{kind}:{name}"`. For a `VertexKind::Node` vertex `name` is the
node's stable address: its explicit `id` when present, else its structural
path (e.g. `equations/0/rhs/expr`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/reference_resolution.rs#L149) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ReferenceVertex.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ReferenceVertex struct {
	Key    string
	Kind   VertexKind
	Name   string
	Op     string
	NodeID string
	Path   string
}
```

ReferenceVertex is a vertex in the reference graph, addressed by a kind-namespaced Key.

Key is "&lt;kind&gt;:&lt;name&gt;". For a VertexKindNode vertex, Name is the node's STABLE ADDRESS: its explicit `id` when it has one, else its structural path (e.g. `equations/0/rhs/expr`). NodeID records the explicit id (empty when absent), Op the operator, and Path the structural path — all three for diagnostics.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L128) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ReferenceVertex)

</div>

</div>
