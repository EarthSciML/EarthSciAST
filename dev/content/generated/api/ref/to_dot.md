---
title: "to_dot"
description: "Stable function · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_dot` | `toDot` | `to_dot` | `to_dot` | `ToDOT` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_dot(graph::Graph{ComponentNode, CouplingEdge})
to_dot(graph::Graph{VariableNode, DependencyEdge})
```

Export graph to DOT format for Graphviz rendering.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L800)

**Example** (`component_graph`)

```julia
graph = component_graph(doc)
@assert [n.name for n in graph.nodes] == ["Heater", "Box"]

mermaid = to_mermaid(graph)
println(mermaid)
@assert occursin("Heater -.->|\"T\"| Box", mermaid)
@assert startswith(to_dot(graph), "digraph")
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/coupling.jl#L27-L33">docs/api/examples/julia/coupling.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toDot<N extends object, E>(graph: Graph<N, E>): string
```

Export graph as Graphviz DOT format.
Node shapes: box for models and reaction systems, diamond for operators.
Edge styles: solid for compose, dashed for variable_map.

The header NAMES the graph — `digraph ComponentGraph` / `digraph
ExpressionGraph`. §4.8.3 requires a DOT export and specifies no syntax for it,
so the cross-binding tie-break is the majority: Python, Go, Rust and Julia all
emitted the named form and this binding alone emitted a bare `digraph {`.
`tests/conformance/graph/cases.json` pins it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/graph.ts#L993)

**Example** (`component_graph`)

```typescript
const doc = loadPath(fixture('coupled.esm'))
const graph = componentGraph(doc)

assert.deepEqual(graph.nodes.map((n) => n.id), ['Heater', 'Box'])
assert.deepEqual(graph.successors('Heater'), ['Box'])
const [edge] = graph.edges
assert.equal(edge.data.type, 'variable_map')

// Render for a Markdown page or for Graphviz.
const mermaid = toMermaid(graph)
assert.match(mermaid, /Heater -\.->\|T\| Box/)
assert.match(toDot(graph), /"Heater" -> "Box"/)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/component_graph.ts#L9-L20">docs/api/examples/typescript/component_graph.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_dot(graph: Graph[Any, Any]) -> str
```

Render `graph` as Graphviz DOT.

Component nodes are coloured by type and coupling edges by kind; variable
nodes are shaped by their derived kind and dependency edges styled by
relationship. The `digraph ComponentGraph` / `digraph ExpressionGraph`
headers are what Julia, Rust and Go all emit (TypeScript writes a bare
`digraph`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L844)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_dot<G: Graph>(graph: &G) -> String
```

Render `graph` as Graphviz DOT (esm-libraries-spec §4.8.3).

The canonical free-function spelling (API_SPEC.md §8 item 8). Equivalent to
the graph's own `to_dot` method; the byte-level output is pinned by
`tests/conformance/graph/cases.json`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/graph.rs#L1455) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_dot.html)

**Example** (`component_graph`)

```rust
let doc = load_path(fixture("coupled.esm"))?;
let graph = component_graph(&doc);
let ids: Vec<&str> = graph.nodes.iter().map(|n| n.id.as_str()).collect();
assert_eq!(ids, ["Box", "Heater"]);
assert_eq!(graph.edges.len(), 1);
assert_eq!((graph.edges[0].from.as_str(), graph.edges[0].to.as_str()), ("Heater", "Box"));

let dot = to_dot(&graph);
assert!(dot.starts_with("digraph"));
assert!(to_mermaid(&graph).contains("Heater"));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/graphs.rs#L9-L18">docs/api/examples/rust/graphs.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToDOT(g Graph) (string, error)
```

ToDOT renders a graph in DOT (Graphviz) format.

Canonical `to_dot` (API\_SPEC.md §8 item 8). It accepts a \*ComponentGraph or an \*ExpressionGraph; the emitted text is pinned across bindings by tests/conformance/graph/cases.json.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph_export.go#L40) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToDOT)

</div>

</div>
