---
title: "reference_edge"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ReferenceEdge` | `ReferenceEdge` | `ReferenceEdge` | `ReferenceEdge` | `ReferenceEdge` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ReferenceEdge
ReferenceEdge(source::String, target::String, kind::String)
ReferenceEdge(source, target, kind)
```

```julia
ReferenceEdge
```

A directed `source → target` edge: *source references / depends on target*.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/reference_graph.jl#L92)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface ReferenceEdge {
    source: string;
    target: string;
    kind: EdgeKind;
}
```

A directed `source → target` edge: *source references / depends on target*.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/reference-resolution.ts#L109)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ReferenceEdge
ReferenceEdge(source: str, target: str, kind: str)
```

A directed `source → target` edge: *source references/depends on target*.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L124)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ReferenceEdge {
    pub source: String,
    pub target: String,
    pub kind: EdgeKind,
}
```

A directed `source → target` edge: *source references / depends on target*.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/reference_resolution.rs#L160) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ReferenceEdge.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ReferenceEdge struct {
	Source string
	Target string
	Kind   EdgeKind
}
```

ReferenceEdge is a directed source → target edge: SOURCE REFERENCES / DEPENDS ON TARGET.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L139) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ReferenceEdge)

</div>

</div>
