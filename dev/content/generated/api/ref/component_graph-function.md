---
title: "component_graph (function)"
description: "Stable function · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `component_graph` | `componentGraph` | `component_graph` | `component_graph` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
component_graph(file::EsmFile)
```

```julia
component_graph(file::EsmFile) -> Graph{ComponentNode, CouplingEdge}
```

Generate component-level graph showing systems and their couplings.

Creates nodes for each model, reaction system, and data source. Operators are
NOT given nodes: a `CouplingOperatorApply` entry only registers an operator
(the operator lives in the file's `operators` section), so it contributes no
node or edge here. Creates edges based on the remaining coupling entries with
appropriate types and labels.

**Arguments**
- `file::EsmFile`: Input ESM file

**Returns**
- `Graph{ComponentNode, CouplingEdge}`: Component graph with coupling relationships

**Example**
```julia
graph = component_graph(file)
# Access nodes and edges
for node in graph.nodes
    println("Component: $(node.name) ($(node.type))")
end
for edge in graph.edges
    println("Coupling: $(edge.from) --[$(edge.label)]--> $(edge.to)")
end
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/graph.jl#L140)

**Example** (`component_graph`)

```julia
graph = component_graph(doc)
@assert [n.name for n in graph.nodes] == ["Heater", "Box"]

mermaid = to_mermaid(graph)
println(mermaid)
@assert occursin("Heater -.->|\"T\"| Box", mermaid)
@assert startswith(to_dot(graph), "digraph")
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/coupling.jl#L27-L33">docs/api/examples/julia/coupling.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function componentGraph(file: EsmFile): Graph<ComponentNode, CouplingEdge>
```

Extract the system graph from an ESM file.
Returns a directed graph (ESM Libraries Specification §4.8) where nodes are
model components and edges are coupling rules, with adjacency helpers.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/graph.ts#L464)

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

```python
component_graph(file: EsmFile) -> Graph[ComponentNode, CouplingEdge]
```

Build the component/coupling graph of `file`.

Nodes are the file's models and reaction systems. Edges come from the
coupling entries that name two DECLARED components:

* `operator_compose` and `couple` — a single `systems[0] → systems[1]` edge (every binding records one directed edge, not a pair);
* `variable_map` — an edge between the two endpoints' owning components,
  labelled with the source variable.

`operator_apply`, `callback`, `event` and `coupling_import` name no
two concrete components and contribute no edge, as in every binding. An
endpoint that is not a declared node is skipped rather than fabricated.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L276)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn component_graph(esm_file: &EsmFile) -> ComponentGraph
```

Build a component graph from an ESM file

**Arguments**

* `esm_file` - The ESM file to analyze

**Returns**

* Component graph showing structure and coupling

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/graph.rs#L227) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.component_graph.html)

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

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
