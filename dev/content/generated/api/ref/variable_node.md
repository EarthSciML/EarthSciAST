---
title: "variable_node"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `VariableNode` | `VariableNode` | `VariableNode` | `VariableNode` | `VariableNode` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct VariableNode
VariableNode(name::String, kind::String, units::Union{Nothing, String}, system::String)
VariableNode(name, kind, units, system)
```

Variable-level node for expression graphs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/graph.jl#L50)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface VariableNode {
    name: string;
    kind: 'state' | 'algebraic' | 'parameter' | 'observed' | 'brownian' | 'discrete' | 'species';
    units?: string;
    system: string;
}
```

Graph node representing a variable/parameter/species in the system

**Properties**

- `name` — Unique identifier for this variable (scoped, e.g., "Transport.temperature")
- `kind` — The variable's DERIVED category (esm-spec §6.3.1), not its declared type.
  The format declares only `unknown` and `parameter`; these are the finer
  categories a consumer of the graph actually wants, recovered from the
  equations and from each parameter's `distribution` / `update`.
  
  `state` is an ODE state, `observed` an unknown some equation DEFINES (its
  LHS naming it, bare or indexed), `algebraic` one that is only implicitly
  CONSTRAINED (no equation names it on its LHS), `brownian` a
  wiener-updated parameter, `discrete` a parameter with any other update,
  `parameter` a sampled or constant one, and `species` a reaction-system
  species.
- `units` — Units if specified
- `system` — System/component this variable belongs to

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/graph.ts#L127)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class VariableNode
VariableNode(name: str, kind: str, units: str | None = None, system: str = DEFAULT_SYSTEM)
```

A variable, parameter or species in the expression graph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L169)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct VariableNode {
    pub name: String,
    pub kind: VariableKind,
    pub units: Option<String>,
    pub system: String,
}
```

Node representing a variable in an expression graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/graph.rs#L406) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.VariableNode.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type VariableNode struct {
	// Name is the node's identity: the SCOPED name within the graph
	// ("Component.variable", "Component.Sub.variable"), or the bare name when
	// the owning system is the synthetic "default" scope — i.e. when a bare
	// Model / ReactionSystem / Equation / Reaction / Expr was graphed directly.
	Name string `json:"name"`
	// Kind is one of the NodeKind* graph kinds above.
	Kind   string  `json:"kind"`
	Units  *string `json:"units,omitempty"`
	System string  `json:"system"`
}
```

VariableNode represents a node in the expression graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/graph.go#L96) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VariableNode)

</div>

</div>
