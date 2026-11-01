---
title: "reference_graph"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ReferenceGraph` | `ReferenceGraph` | `ReferenceGraph` | `ReferenceGraph` | `ReferenceGraph` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
mutable struct ReferenceGraph
ReferenceGraph(model::String, vertices::OrderedCollections.OrderedDict{String, ReferenceVertex}, edges::Vector{ReferenceEdge}, out::OrderedCollections.OrderedDict{String, Vector{String}}, incoming::OrderedCollections.OrderedDict{String, Vector{String}})
ReferenceGraph(model, vertices, edges, out, incoming)
ReferenceGraph()
ReferenceGraph(model::AbstractString)
```

```julia
ReferenceGraph
```

The resolved reference DAG for one model — the partition pass's input. Edges
point from a vertex to a vertex it *depends on*, so a bottom-up
(`topological_order`) walk visits each vertex after its dependencies —
the order `class(n) = max(class(inputs))` propagation needs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/reference_graph.jl#L103)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class ReferenceGraph
new ReferenceGraph(model?: string): ReferenceGraph
readonly ReferenceGraph.prototype.model: string
readonly ReferenceGraph.prototype.vertices: Map<string, ReferenceVertex>
readonly ReferenceGraph.prototype.edges: ReferenceEdge[]
ReferenceGraph.prototype.ensureVertex(vertex: ReferenceVertex): void
ReferenceGraph.prototype.addEdge(source: string, target: string, kind: EdgeKind): void
ReferenceGraph.prototype.dependencies(key: string): string[]
ReferenceGraph.prototype.dependents(key: string): string[]
ReferenceGraph.prototype.edgesOfKind(kind: EdgeKind): ReferenceEdge[]
ReferenceGraph.prototype.detectCycle(): string[] | null
ReferenceGraph.prototype.topologicalOrder(): string[]
```

The resolved reference DAG for one model — the partition pass's input.

Vertices are keyed by their kind-namespaced `key`. Edges point from a vertex
to a vertex it *depends on*, so a bottom-up `topologicalOrder` walk
visits each vertex after its dependencies — exactly the order
`class(n) = max(class(inputs))` propagation needs.

**Members**

- `vertices` — Insertion-ordered `key -> vertex`.
- `dependencies` — Vertices `key` references / depends on (its out-neighbours).
- `dependents` — Vertices that reference / depend on `key` (its in-neighbours).
- `detectCycle` — A reference cycle as a vertex-key path, or `null` if acyclic.
  
  Three-colour DFS over the dependency edges, traversing sorted keys and
  sorted neighbours so the reported path is deterministic and matches the
  other bindings. The returned path is `[v, …, v]` (the repeated vertex
  closes the cycle).
- `topologicalOrder` — Bottom-up order (dependencies before dependents).
  
  Throws [`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error) (`E_REF_CYCLE`) if the graph is
  cyclic — a cycle among reference edges is an out-of-scope
  implicit/iterative solve (RFC §6.1 "Acyclicity").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/reference-resolution.ts#L134)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ReferenceGraph
ReferenceGraph(model: str = '', vertices: dict[str, ReferenceVertex] = dict(), edges: list[ReferenceEdge] = list(), _out: dict[str, list[str]] = dict(), _in: dict[str, list[str]] = dict())
ReferenceGraph.dependencies(key: str) -> list[str]
ReferenceGraph.dependents(key: str) -> list[str]
ReferenceGraph.edges_of_kind(kind: str) -> list[ReferenceEdge]
ReferenceGraph.detect_cycle() -> list[str] | None
ReferenceGraph.topological_order() -> list[str]
```

The resolved reference DAG for one model — the partition pass's input.

Vertices are keyed by their kind-namespaced `key`. `edges` point from a
vertex to a vertex it *depends on*, so a bottom-up
(`topological_order`) walk visits each vertex after its dependencies —
exactly the order `class(n) = max(class(inputs))` propagation needs.

**Members**

- `dependencies` — Vertices `key` references / depends on (its out-neighbours).
- `dependents` — Vertices that reference / depend on `key` (its in-neighbours).
- `detect_cycle` — Return a reference cycle as a vertex-key path, or `None` if acyclic.
- `topological_order` — Bottom-up order (dependencies before dependents).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L133)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ReferenceGraph {
    pub model: String,
    pub vertices: IndexMap<String, ReferenceVertex>,
    pub edges: Vec<ReferenceEdge>,
    /* private fields */
}

impl ReferenceGraph { pub fn dependencies(&self, key: &str) -> Vec<String> }

impl ReferenceGraph { pub fn dependents(&self, key: &str) -> Vec<String> }

impl ReferenceGraph { pub fn edges_of_kind(&self, kind: EdgeKind) -> Vec<&ReferenceEdge> }

impl ReferenceGraph { pub fn detect_cycle(&self) -> Option<Vec<String>> }

impl ReferenceGraph { pub fn topological_order(&self) -> Result<Vec<String>, ReferenceResolutionError> }
```

The resolved reference DAG for one model — the partition pass's input.

Edges point from a vertex to a vertex it *depends on*, so a bottom-up
(`topological_order`) walk visits each
vertex after its dependencies — the order `class(n) = max(class(inputs))`
propagation needs.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/reference_resolution.rs#L173) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ReferenceGraph.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ReferenceGraph struct {
	// Model is the name of the model this graph was built for.
	Model string
	// Edges are the reference edges in discovery order.
	Edges []ReferenceEdge
	// contains filtered or unexported fields
}

func (g *ReferenceGraph) Dependencies(key string) []string

func (g *ReferenceGraph) Dependents(key string) []string

func (g *ReferenceGraph) DetectCycle() []string

func (g *ReferenceGraph) EdgesOfKind(kind EdgeKind) []ReferenceEdge

func (g *ReferenceGraph) Len() int

func (g *ReferenceGraph) TopologicalOrder() ([]string, error)

func (g *ReferenceGraph) Vertex(key string) (ReferenceVertex, bool)

func (g *ReferenceGraph) VertexKeys() []string

func (g *ReferenceGraph) Vertices() []ReferenceVertex
```

ReferenceGraph is the resolved reference DAG for one model — the partition pass's input.

Vertices are keyed by their kind-namespaced Key. Edges point from a vertex to a vertex it DEPENDS ON, so a bottom-up (TopologicalOrder) walk visits each vertex after its dependencies — exactly the order class(n) = max(class(inputs)) propagation needs.

**Methods**

```go
func (g *ReferenceGraph) Dependencies(key string) []string
```

Dependencies returns the vertices `key` references / depends on (its out-neighbours), in discovery order.

```go
func (g *ReferenceGraph) Dependents(key string) []string
```

Dependents returns the vertices that reference / depend on `key` (its in-neighbours), in discovery order.

```go
func (g *ReferenceGraph) DetectCycle() []string
```

DetectCycle returns a reference cycle as a vertex-key path, or nil when the graph is acyclic.

Three-colour DFS over the dependency edges, made deterministic by visiting starts and neighbours in sorted-key order. The returned path is \[v, …, v\] (the repeated vertex closes the cycle).

```go
func (g *ReferenceGraph) EdgesOfKind(kind EdgeKind) []ReferenceEdge
```

EdgesOfKind returns every edge of the given kind, in discovery order.

```go
func (g *ReferenceGraph) Len() int
```

Len returns the number of vertices.

```go
func (g *ReferenceGraph) TopologicalOrder() ([]string, error)
```

TopologicalOrder returns a bottom-up order (dependencies before dependents).

Returns a \*ReferenceResolutionError with code E\_REF\_CYCLE if the graph is cyclic — a cycle among reference edges is an out-of-scope implicit/iterative solve (RFC §6.1 "Acyclicity").

Two deliberate passes rather than one Kahn sweep: DetectCycle's DFS reports the actual cycle PATH (Kahn's leftover-vertex set cannot name the path), and the wave loop below emits ready vertices in sorted-key order per wave, keeping the materialization order deterministic. Document node counts are small, so the O(V²) scan is irrelevant; after the cycle check the no-progress break is unreachable.

```go
func (g *ReferenceGraph) Vertex(key string) (ReferenceVertex, bool)
```

Vertex returns the vertex with the given key.

```go
func (g *ReferenceGraph) VertexKeys() []string
```

VertexKeys returns every vertex key in discovery order.

```go
func (g *ReferenceGraph) Vertices() []ReferenceVertex
```

Vertices returns every vertex in discovery order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L152) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ReferenceGraph)

</div>

</div>
