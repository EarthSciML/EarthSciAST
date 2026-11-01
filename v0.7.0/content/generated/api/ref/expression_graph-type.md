---
title: "expression_graph (type)"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `ExpressionGraph` | `ExpressionGraph` |


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

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ExpressionGraph {
    pub nodes: Vec<VariableNode>,
    pub edges: Vec<DependencyEdge>,
}

impl ExpressionGraph { pub fn adjacency(&self, name: &str) -> Vec<String> }

impl ExpressionGraph { pub fn predecessors(&self, name: &str) -> Vec<String> }

impl ExpressionGraph { pub fn successors(&self, name: &str) -> Vec<String> }

impl ExpressionGraph { pub fn to_dot(&self) -> String }

impl ExpressionGraph { pub fn to_mermaid(&self) -> String }

impl ExpressionGraph { pub fn to_json_graph(&self) -> String }
```

Expression graph representing variable dependencies within expressions

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/graph.rs#L397) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ExpressionGraph.html)

**Example** (`expression_graph`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];
let graph = expression_graph(model);
let json = to_json_graph(&graph);
println!("{json}");
assert!(json.contains("\"lambda\"") && json.contains("\"N\""));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/graphs.rs#L22-L27">docs/api/examples/rust/graphs.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ExpressionGraph struct {
	Nodes []VariableNode                            `json:"nodes"`
	Edges []GraphEdge[VariableNode, DependencyEdge] `json:"edges"`
}

func (g *ExpressionGraph) AdjacencyVariable(node VariableNode) []VariableAdjacency

func (g *ExpressionGraph) PredecessorsVariable(node VariableNode) []VariableNode

func (g *ExpressionGraph) SuccessorsVariable(node VariableNode) []VariableNode
```

ExpressionGraph is a specialized graph for variable dependencies

**Methods**

```go
func (g *ExpressionGraph) AdjacencyVariable(node VariableNode) []VariableAdjacency
```

AdjacencyVariable returns the neighbours of a node in the expression graph, together with the dependency edge that reaches each. Adjacency is UNDIRECTED; one entry is returned per incident edge.

```go
func (g *ExpressionGraph) PredecessorsVariable(node VariableNode) []VariableNode
```

PredecessorsVariable returns the distinct nodes with a dependency edge pointing TO the given variable node, in sorted-name order.

```go
func (g *ExpressionGraph) SuccessorsVariable(node VariableNode) []VariableNode
```

SuccessorsVariable returns the distinct nodes the given variable node has a dependency edge pointing TO, in sorted-name order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/graph.go#L147) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraph)

</div>

</div>
