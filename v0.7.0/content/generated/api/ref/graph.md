---
title: "graph"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Graph` | `Graph` | `Graph` | `Graph` | `Graph` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Graph
Graph(nodes::Vector{N}, edges::Array{@NamedTuple{source::N, target::N, data::E}, 1}) where {N, E}
```

Generic graph structure with nodes and edges.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/graph.jl#L17)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface Graph<N, E> {
    kind?: GraphKind;
    nodes: N[];
    edges: Array<{
        source: string;
        target: string;
        data: E;
    }>;
    adjacency(node: string): string[];
    predecessors(node: string): string[];
    successors(node: string): string[];
}
```

Directed graph with node/edge lists plus adjacency, predecessor, and
successor lookups (ESM Libraries Specification §4.8). Nodes are addressed by
a string key (`ComponentNode.id` / `VariableNode.name`); edges reference
those keys through `source`/`target`.

**Properties**

- `kind` — Which of the two §4.8 graphs this is. Carried explicitly because the DOT
  and Mermaid exporters name the graph in their header
  (`digraph ComponentGraph` / `digraph ExpressionGraph`) and an EMPTY graph —
  `tests/valid/data_sources_only.esm` produces two — has no node to sniff.
  The other bindings get this from their type system (Julia dispatches on
  `Graph{ComponentNode,CouplingEdge}`, Python reads `node_type`, Go and Rust
  have two distinct structs); TypeScript's `Graph` is one generic interface,
  so it carries the tag.
- `nodes` — All nodes in the graph
- `edges` — All edges in the graph
- `adjacency` — Get adjacent nodes for a given node
- `predecessors` — Get predecessor nodes for a given node
- `successors` — Get successor nodes for a given node

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/graph.ts#L102)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Graph(Generic[N, E])
Graph(nodes: list[N] = list(), edges: list[GraphEdge[E]] = list(), node_type: type | None = None)
Graph.adjacency(node: str) -> list[str]
Graph.predecessors(node: str) -> list[str]
Graph.successors(node: str) -> list[str]
```

A directed graph with node/edge lists and adjacency lookups (§4.8).

Nodes are addressed by their string key; edges reference those keys. A
lookup on a known but unconnected node returns `[]`, and so does a lookup
on an unknown key.

**Members**

- `adjacency` — Every neighbour of `node`, in either direction.
- `predecessors` — Nodes with an edge pointing AT `node`.
- `successors` — Nodes `node` has an edge pointing TO.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L205)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub trait Graph {
    fn render_dot(&self) -> String;
    fn render_mermaid(&self) -> String;
    fn render_json_graph(&self) -> String;
}
```

The graph kinds the esm-libraries-spec §4.8.3 text exporters render.

API_SPEC.md §8 item 8 rules the canonical renderer trio to be
[`to_dot`](/generated/api/ref/to_dot) / [`to_mermaid`](/generated/api/ref/to_mermaid) / [`to_json_graph`](/generated/api/ref/to_json_graph), one free function each,
dispatching on the graph kind — the spelling TypeScript, Python and Julia
already share. This trait is that dispatch: it is implemented by
[`ComponentGraph`](/generated/api/ref/component_graph-type) and [`ExpressionGraph`](/generated/api/ref/expression_graph-type) and by nothing else, and each
method forwards to the graph's own inherent renderer, so the rendered
bytes are unchanged (they are pinned by `tests/conformance/graph`).

It is deliberately NOT re-exported from the crate root: §8 item 8 adds
three functions to the surface, not a fourth name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/graph.rs#L1417) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/trait.Graph.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Graph interface {
	// contains filtered or unexported methods
}
```

Graph is the domain of the three graph renderers — ToDOT, ToMermaid and ToJSONGraph — and is satisfied by exactly the two graph types this package builds: \*ComponentGraph (BuildComponentGraph) and \*ExpressionGraph (BuildExpressionGraph).

The other bindings express the same trio as one overloaded/duck-typed function per format (API\_SPEC.md §8 item 8). Go has no overloading, so the union is spelled as an interface with an UNEXPORTED marker method: the set of implementations is closed to this package, which is what makes the type switch inside each renderer total rather than merely conventional.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/graph_export.go#L24) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Graph)

</div>

</div>
