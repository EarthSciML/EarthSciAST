---
title: "expression_graph (function)"
description: "Stable function · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `expression_graph` | `expressionGraph` | `expression_graph` | `expression_graph` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
expression_graph(file::EsmFile; merge_coupled)
expression_graph(model::Model)
expression_graph(rxn_sys::ReactionSystem)
expression_graph(equation::Equation)
expression_graph(reaction::Reaction)
expression_graph(expr::ASTExpr)
```

```julia
expression_graph(file::EsmFile; merge_coupled::Bool = false) -> Graph{VariableNode, DependencyEdge}
expression_graph(model::Model) -> Graph{VariableNode, DependencyEdge}
expression_graph(system::ReactionSystem) -> Graph{VariableNode, DependencyEdge}
expression_graph(equation::Equation) -> Graph{VariableNode, DependencyEdge}
expression_graph(reaction::Reaction) -> Graph{VariableNode, DependencyEdge}
expression_graph(expr::ASTExpr) -> Graph{VariableNode, DependencyEdge}
```

The variable-level dependency graph (esm-libraries-spec §4.8.2): one
[`VariableNode`](/generated/api/ref/variable_node) per variable, and a [`DependencyEdge`](/generated/api/ref/dependency_edge) from each
variable an equation or reaction reads to the variable it defines.

For a whole file, every model and reaction system (and their subsystems) is
walked and node names are scoped as `Component.variable`; with
`merge_coupled = true` each `variable_map` coupling entry also adds an edge
from its `from` variable to its `to` variable. A standalone model, reaction
system, equation or reaction yields bare names. An expression has no name of
its own, so every free variable in it feeds a synthetic `expr_result` node.

**Examples**
```julia
graph = expression_graph(file)         # every component, scoped names
graph = expression_graph(model)        # one model, bare names
graph = expression_graph(parse_expression("k * (T_wall - T_air)"))
[e.source.name for e in graph.edges]   # the three free variables
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/graph.jl#L598)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function expressionGraph(target: EsmFile | Model | ReactionSystem | Equation | Reaction | Expr, options?: { mergeCoupled?: boolean; merge_coupled?: boolean }): Graph<VariableNode, DependencyEdge>
```

Extract a variable-level dependency graph from an ESM file, model, reaction
system, equation, reaction, or expression. Nodes are variables/parameters/
species; edges represent dependencies (ESM Libraries Specification §4.8).

**Parameters**

- `target` — The target to analyze (EsmFile, Model, ReactionSystem, Equation, Reaction, or Expr)
- `options` — Optional settings. `mergeCoupled` folds `variable_map` coupling
    entries into cross-system edges (EsmFile targets only). `merge_coupled` is a
    deprecated alias accepted for back-compat.

**Returns**

Graph with VariableNode nodes and DependencyEdge edges

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/graph.ts#L870)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
expression_graph(target: EsmFile | Model | ReactionSystem | Equation | Reaction | Expr, merge_coupled: bool = False) -> Graph[VariableNode, DependencyEdge]
```

Build the variable-dependency graph of `target`.

`target` may be an [`EsmFile`](/generated/api/ref/esm_file), a
[`Model`](/generated/api/ref/model), a
[`ReactionSystem`](/generated/api/ref/reaction_system), an
[`Equation`](/generated/api/ref/equation), a
[`Reaction`](/generated/api/ref/reaction), or a bare expression — the same
six granularities the other bindings accept.

For a whole file every node name is scoped `Component.variable`; for a
standalone target the names stay bare.

`merge_coupled` folds the file's `variable_map` coupling entries into
cross-system edges. It is off by default, matching TypeScript's
`mergeCoupled` default and Rust's and Go's unconditional behaviour (Julia
always adds them).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L719)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn expression_graph<T>(input: &T) -> ExpressionGraph where T: ExpressionGraphInput
```

Build an expression graph from various ESM components

**Arguments**

* `input` - Can be an ESM file, model, reaction system, equation, reaction, or expression

**Returns**

* `ExpressionGraph` - Graph showing variable dependencies

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/graph.rs#L519) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.expression_graph.html)

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

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
