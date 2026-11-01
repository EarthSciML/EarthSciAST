---
title: "to_json_graph"
description: "Stable function · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_json_graph` | `toJsonGraph` | `to_json_graph` | `to_json_graph` | `ToJSONGraph` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_json_graph(graph::Graph{ComponentNode, CouplingEdge})
to_json_graph(graph::Graph{VariableNode, DependencyEdge})
```

```julia
to_json_graph(graph) -> String
```

Export graph to the JSON adjacency list of esm-libraries-spec §4.8.3.

Three top-level keys:

* `nodes` — each node's own fields, prefixed with the `id` that keys it (a
  component node's `id`, a variable node's `name`);
* `edges` — `{"source", "target", "data"}`, endpoints by node key with the edge
  payload under `data`;
* `adjacency` — every node key mapped to its UNDIRECTED neighbours, matching
  [`adjacency`](/generated/api/extension/julia#x-adjacency).

Pinned by `tests/conformance/graph/cases.json` at the level of the top-level
keys, the node ids, the edge endpoints and the adjacency map; the per-node and
per-edge payloads are this binding's own and are not.

The canonical name across the bindings is `to_json_graph` (API_SPEC.md §8
item 8) — the spelling TypeScript (`toJsonGraph`), Python and Rust already
use — because §8 item 2 gave `to_json` to the DOCUMENT serializer, and one
binding cannot make one name mean both without dispatch a caller can only
discover by reading the source. Julia's `to_json(::Graph)` methods stay one
minor as a deprecated alias (§10) and render byte-identical output.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/graph.jl#L890)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toJsonGraph<N extends object, E>(graph: Graph<N, E>): string
```

Export graph as JSON adjacency list format for web consumption.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/graph.ts#L1242)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_json_graph(graph: Graph[Any, Any]) -> str
```

Render `graph` as the JSON adjacency list of esm-libraries-spec §4.8.3.

Three top-level keys:

* `nodes` — each node's own fields, prefixed with the `id` that keys it
  (a component node's `id`, a variable node's `name`);
* `edges` — `{"source", "target", "data"}`, endpoints by node key with
  the edge payload under `data`;
* `adjacency` — every node key mapped to its UNDIRECTED neighbours, which
  is what `Graph.adjacency` returns.

Pinned by `tests/conformance/graph/cases.json` at the level of the
top-level keys, the node ids, the edge endpoints and the adjacency map; the
per-node and per-edge payloads are this binding's own and are not.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L930)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_json_graph<G: Graph>(graph: &G) -> String
```

Render `graph` as a JSON adjacency-list document (esm-libraries-spec
§4.8.3). Named `to_json_graph`, not `to_json`, because `to_json` is the
DOCUMENT serializer (API_SPEC.md §8 item 2). See [`to_dot`](/generated/api/ref/to_dot).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/graph.rs#L1467) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_json_graph.html)

**Example** (`expression_graph`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];
let graph = expression_graph(model);
let json = to_json_graph(&graph);
println!("{json}");
assert!(json.contains("\"lambda\"") && json.contains("\"N\""));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/graphs.rs#L22-L27">docs/api/examples/rust/graphs.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToJSONGraph(g Graph) (string, error)
```

ToJSONGraph renders a graph as a JSON adjacency list.

Canonical `to_json_graph` (API\_SPEC.md §8 item 8) — NOT `ToJSON`, which is the DOCUMENT serializer settled by §8 item 2 and cannot carry both meanings. It accepts a \*ComponentGraph or an \*ExpressionGraph.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/graph_export.go#L71) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToJSONGraph)

</div>

</div>
