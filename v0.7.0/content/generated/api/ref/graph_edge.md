---
title: "graph_edge"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `GraphEdge` | not exported | `GraphEdge` |


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
class GraphEdge(Generic[E])
GraphEdge(source: str, target: str, data: E)
```

One directed edge: node keys plus the edge payload.

Mirrors the `{source, target, data}` triple TypeScript, Go and Julia all
use. `source` / `target` are node KEYS (a [`ComponentNode`](/generated/api/ref/component_node)'s
`id`, a [`VariableNode`](/generated/api/ref/variable_node)'s `name`), not the node objects.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L119)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type GraphEdge[N any, E any] struct {
	Source N `json:"source"`
	Target N `json:"target"`
	Data   E `json:"data"`
}
```

GraphEdge represents an edge in a directed graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/graph.go#L13) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#GraphEdge)

</div>

</div>
