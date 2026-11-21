---
title: "to_mermaid"
description: "Stable function · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_mermaid` | `toMermaid` | `to_mermaid` | `to_mermaid` | `ToMermaid` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_mermaid(graph::Graph{ComponentNode, CouplingEdge})
to_mermaid(graph::Graph{VariableNode, DependencyEdge})
```

Export graph to Mermaid format for markdown embedding.

Node ids are sanitized to plain identifiers (`model.x` → `model_x`) and
labels are quoted, so dotted/scoped names render correctly. Edges carry a
quoted label — the coupling label (component graph) or dependency
relationship (expression graph) — matching the DOT emitter and Mermaid's
`A -->|"label"| B` labeled-edge syntax.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/graph.jl#L843)

**Example** (`component_graph`)

```julia
graph = component_graph(doc)
@assert [n.name for n in graph.nodes] == ["Heater", "Box"]

mermaid = to_mermaid(graph)
println(mermaid)
@assert occursin("Heater -.->|\"T\"| Box", mermaid)
@assert startswith(to_dot(graph), "digraph")
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/coupling.jl#L27-L33">docs/api/examples/julia/coupling.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toMermaid<N extends object, E>(graph: Graph<N, E>): string
```

Export graph as Mermaid flowchart format for Markdown embedding.

The header is `graph TD`. §4.8.3 requires a Mermaid export and specifies no
syntax for it, so the cross-binding tie-break is the majority, applied to the
keyword and the direction independently: `graph` beats `flowchart` 4-1
(Python, Go, Rust and Julia against this binding) and `TD` beats `LR` 3-2
(this binding, Python and Julia against Go and Rust). `graph` is Mermaid's
legacy spelling of `flowchart`; both render, and the majority points at
`graph`. `tests/conformance/graph/cases.json` pins it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/graph.ts#L1143)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/typescript/component_graph.ts#L9-L20">docs/api/examples/typescript/component_graph.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_mermaid(graph: Graph[Any, Any]) -> str
```

Render `graph` as a Mermaid flowchart for Markdown embedding.

Node ids are sanitized to plain identifiers (`Chem.O3` → `Chem_O3`) and
labels are quoted, so scoped names render correctly. Edges carry a quoted
label — the coupling label for a component graph, the dependency
relationship for an expression graph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L889)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_mermaid<G: Graph>(graph: &G) -> String
```

Render `graph` as Mermaid (esm-libraries-spec §4.8.3). See [`to_dot`](/generated/api/ref/to_dot).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/graph.rs#L1460) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_mermaid.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/graphs.rs#L9-L18">docs/api/examples/rust/graphs.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToMermaid(g Graph) (string, error)
```

ToMermaid renders a graph in Mermaid format.

Canonical `to_mermaid` (API\_SPEC.md §8 item 8). It accepts a \*ComponentGraph or an \*ExpressionGraph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/graph_export.go#L55) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToMermaid)

</div>

</div>
