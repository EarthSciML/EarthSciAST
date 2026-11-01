---
title: "Graphs"
description: "Component, expression and reference graphs of a document, and exporting them as DOT, Mermaid or JSON."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`build_reference_graph`](/generated/api/ref/build_reference_graph) | function | Julia, TypeScript, Python, Rust, Go | Resolve the reference edges of one `model` dict into a graph. |
| [`component_graph`](/generated/api/ref/component_graph-function) | function | Julia, TypeScript, Python, Rust | Generate component-level graph showing systems and their couplings. |
| [`expression_graph`](/generated/api/ref/expression_graph-function) | function | Julia, TypeScript, Python, Rust | The variable-level dependency graph (esm-libraries-spec §4.8.2): one `VariableNode` per variable, and a `DependencyEdge` from each variable an equation or reaction reads to the… |
| [`resolve_references`](/generated/api/ref/resolve_references) | function | Julia, TypeScript, Python, Rust, Go | Resolve reference edges for every model in `document`. |
| [`to_dot`](/generated/api/ref/to_dot) | function | Julia, TypeScript, Python, Rust, Go | Export graph to DOT format for Graphviz rendering. |
| [`to_json_graph`](/generated/api/ref/to_json_graph) | function | Julia, TypeScript, Python, Rust, Go | Export graph to the JSON adjacency list of esm-libraries-spec §4.8.3. |
| [`to_mermaid`](/generated/api/ref/to_mermaid) | function | Julia, TypeScript, Python, Rust, Go | Export graph to Mermaid format for markdown embedding. |
| [`component_graph`](/generated/api/ref/component_graph-type) | type | TypeScript, Rust, Go | System graph representation with components and couplings |
| [`component_node`](/generated/api/ref/component_node) | type | Julia, TypeScript, Python, Rust, Go | Component-level node representing a model, reaction system, data source, or operator. |
| [`coupling_edge`](/generated/api/ref/coupling_edge) | type | Julia, TypeScript, Python, Rust, Go | Edge representing coupling between components. |
| [`dependency_edge`](/generated/api/ref/dependency_edge) | type | Julia, TypeScript, Python, Rust, Go | Edge representing dependency between variables. |
| [`edge_kind`](/generated/api/ref/edge_kind) | type | TypeScript, Python, Rust, Go | The three kinds of reference edge (RFC §6.1 "Propagation"). |
| [`expression_graph`](/generated/api/ref/expression_graph-type) | type | Rust, Go | Expression graph representing variable dependencies within expressions |
| [`expression_graph_options`](/generated/api/ref/expression_graph_options) | type | Rust, Go | Settings for `expression_graph_with_options`. |
| [`graph`](/generated/api/ref/graph) | type | Julia, TypeScript, Python, Rust, Go | Generic graph structure with nodes and edges. |
| [`graph_edge`](/generated/api/ref/graph_edge) | type | Python, Go | One directed edge: node keys plus the edge payload. |
| [`reference_edge`](/generated/api/ref/reference_edge) | type | Julia, TypeScript, Python, Rust, Go | A directed `source → target` edge: *source references / depends on target*. |
| [`reference_graph`](/generated/api/ref/reference_graph) | type | Julia, TypeScript, Python, Rust, Go | The resolved reference DAG for one model — the partition pass's input. |
| [`reference_vertex`](/generated/api/ref/reference_vertex) | type | Julia, TypeScript, Python, Rust, Go | A vertex in the reference graph, addressed by a kind-namespaced `key` (`"$kind:$name"`). |
| [`variable_node`](/generated/api/ref/variable_node) | type | Julia, TypeScript, Python, Rust, Go | Variable-level node for expression graphs. |
| [`vertex_kind`](/generated/api/ref/vertex_kind) | type | TypeScript, Python, Rust, Go | The three kinds of vertex in the reference graph. |
| [`reference_resolution_error`](/generated/api/ref/reference_resolution_error) | error | Julia, TypeScript, Python, Rust, Go | A reference could not be resolved, or the reference graph has a cycle. |

[All topics](/generated/api)
