---
title: "coupling_edge"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `CouplingEdge` | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` | `CouplingEdge` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct CouplingEdge
CouplingEdge(id::String, from::String, to::String, type::String, label::String, description::Union{Nothing, String}, coupling::CouplingEntry)
CouplingEdge(id, from, to, type, label, description, coupling)
```

Edge representing coupling between components.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L37)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface CouplingEdge {
    id: string;
    from: string;
    to: string;
    type: CouplingEntry['type'];
    label: string;
    description?: string;
    coupling: CouplingEntry;
}
```

Graph edge representing a coupling relationship

**Properties**

- `id` — Unique identifier for this edge
- `from` — Source component ID
- `to` — Target component ID
- `type` — Type of coupling
- `label` — Display label for the edge
- `description` — Optional description
- `coupling` — Full coupling entry for editing

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/graph.ts#L68)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class CouplingEdge
CouplingEdge(id: str, from_component: str, to_component: str, type: str, label: str, description: str | None = None, coupling: Any = None)
```

A coupling relationship between two components.

`from_component` / `to_component` spell the wire keys `from` / `to`,
which are Python keywords; the package already uses this convention for
`VariableMapCoupling`'s `from_var` /
`to_var`. [`to_json`](/generated/api/ref/to_json) emits them under the wire spellings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L148)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct CouplingEdge {
    pub from: String,
    pub to: String,
    pub coupling_type: CouplingEdgeKind,
    pub label: String,
    pub data: Value,
}
```

Edge in the component graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/graph.rs#L203) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.CouplingEdge.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type CouplingEdge struct {
	Type          CouplingKind `json:"type"` // coupling type
	Label         *string      `json:"label,omitempty"`
	Description   *string      `json:"description,omitempty"`
	Bidirectional bool         `json:"bidirectional"`
	CouplingEntry any          `json:"coupling_entry"`
}
```

CouplingEdge represents an edge in the component graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L70) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#CouplingEdge)

</div>

</div>
