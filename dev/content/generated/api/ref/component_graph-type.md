---
title: "component_graph (type)"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `ComponentGraph` | not exported | `ComponentGraph` | `ComponentGraph` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface ComponentGraph {
    nodes: ComponentNode[];
    edges: CouplingEdge[];
}
```

System graph representation with components and couplings

**Properties**

- `nodes` — All components in the system
- `edges` — All coupling relationships

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/graph.ts#L86)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/component_graph.ts#L9-L20">docs/api/examples/typescript/component_graph.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ComponentGraph {
    pub nodes: Vec<ComponentNode>,
    pub edges: Vec<CouplingEdge>,
}

impl ComponentGraph { pub fn adjacency(&self, id: &str) -> Vec<String> }

impl ComponentGraph { pub fn predecessors(&self, id: &str) -> Vec<String> }

impl ComponentGraph { pub fn successors(&self, id: &str) -> Vec<String> }

impl ComponentGraph { pub fn to_dot(&self) -> String }

impl ComponentGraph { pub fn to_mermaid(&self) -> String }

impl ComponentGraph { pub fn to_json_graph(&self) -> String }
```

Component graph representing model structure

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/graph.rs#L124) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ComponentGraph.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/graphs.rs#L9-L18">docs/api/examples/rust/graphs.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ComponentGraph struct {
	Nodes []ComponentNode                          `json:"nodes"`
	Edges []GraphEdge[ComponentNode, CouplingEdge] `json:"edges"`
}

func (g *ComponentGraph) Adjacency(node ComponentNode) []ComponentAdjacency

func (g *ComponentGraph) Predecessors(node ComponentNode) []ComponentNode

func (g *ComponentGraph) Successors(node ComponentNode) []ComponentNode
```

ComponentGraph is a specialized graph for system components

**Methods**

```go
func (g *ComponentGraph) Adjacency(node ComponentNode) []ComponentAdjacency
```

Adjacency returns the neighbours of a node in the component graph, together with the coupling edge that reaches each (esm-libraries-spec §4.8.3). Adjacency is UNDIRECTED: an edge in either direction makes its other endpoint a neighbour, regardless of whether the coupling is bidirectional. One entry is returned per incident edge.

```go
func (g *ComponentGraph) Predecessors(node ComponentNode) []ComponentNode
```

Predecessors returns the distinct nodes with an edge pointing TO the given node, in sorted-ID order. A bidirectional coupling is still one DIRECTED edge: its `Bidirectional` flag styles the export, it does not add a reverse dependency.

```go
func (g *ComponentGraph) Successors(node ComponentNode) []ComponentNode
```

Successors returns the distinct nodes the given node has an edge pointing TO, in sorted-ID order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/graph.go#L141) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ComponentGraph)

</div>

</div>
