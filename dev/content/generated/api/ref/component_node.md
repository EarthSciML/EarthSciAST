---
title: "component_node"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ComponentNode` | `ComponentNode` | `ComponentNode` | `ComponentNode` | `ComponentNode` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ComponentNode
ComponentNode(id::String, name::String, type::String, description::Union{Nothing, String}, reference, metadata::Dict{String, Any})
ComponentNode(id, name, type, description, reference, metadata)
```

Component-level node representing a model, reaction system, data source, or operator.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/graph.jl#L25)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface ComponentNode {
    id: string;
    name: string;
    type: 'model' | 'reaction_system';
    description?: string;
    reference?: Reference;
    metadata: {
        var_count: number;
        eq_count: number;
        species_count: number;
    };
}
```

Graph node representing a component in the system

**Properties**

- `id` — Unique identifier for this component
- `name` — Display name for the component
- `type` — Type of component. From 1.0.0 there is no `data_loader`: a data source is
  ingest configuration, not a component, so it is neither a graph node nor a
  coupling endpoint (esm-spec §5.5).
- `description` — Optional description
- `reference` — Optional reference information
- `metadata` — Metadata with counts for this component

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/graph.ts#L41)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ComponentNode
ComponentNode(id: str, name: str, type: str, description: str | None = None, reference: Reference | None = None, metadata: dict[str, Any] = dict())
```

A model or reaction system in the component graph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L133)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ComponentNode {
    pub id: String,
    pub component_type: ComponentType,
    pub name: Option<String>,
    pub metadata: ComponentMetadata,
}
```

Node in the component graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/graph.rs#L153) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ComponentNode.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ComponentNode struct {
	ID   string `json:"id"`
	Type string `json:"type"` // "model" or "reaction_system"
	Name string `json:"name"`
	// Metadata holds the three summary counts §4.8.1 defines. It replaces the
	// four optional VariableCount/EquationCount/SpeciesCount/ReactionCount
	// pointers: the graph vocabulary has no separate reaction count, a reaction
	// system reporting its reactions through EqCount instead.
	Metadata ComponentCounts `json:"metadata"`
}
```

ComponentNode represents a node in the component graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/graph.go#L39) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ComponentNode)

</div>

</div>
