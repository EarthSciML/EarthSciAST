---
title: "dependency_edge"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DependencyEdge` | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` | `DependencyEdge` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DependencyEdge
DependencyEdge(source::String, target::String, relationship::String, equation_index::Union{Nothing, Int64}, expression::Union{Nothing, ASTExpr})
DependencyEdge(source, target, relationship, equation_index, expression)
```

Edge representing dependency between variables.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/graph.jl#L62)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface DependencyEdge {
    source: string;
    target: string;
    relationship: 'additive' | 'multiplicative' | 'rate' | 'stoichiometric';
    equation_index: number;
    expression: Expr;
}
```

Graph edge representing a dependency between variables.

The `equation_index` sentinel `NON_EQUATION_INDEX` (`-1`) marks a
dependency that does not originate from a positionally-numbered equation or
reaction — a coupling variable map, or the synthetic `expr_result` edges of a
BARE-EXPRESSION target. (An observed unknown's definition IS one of the
model's equations from 1.0.0, so its edges carry that equation's index.)

**Properties**

- `source` — Source variable name
- `target` — Target variable name
- `relationship` — PROVENANCE category of the dependency — which structural site produced it,
  NOT a classification of the operators involved. See `EDGE_PROVENANCE`
  for the mapping. These values are fixed labels and do NOT track the
  actual operator: an equation edge is always `'additive'` (even for
  `w = u * v`) and an observed-definition edge is always `'multiplicative'`
  (even for `w = u + v`), regardless of the `+`/`*`/etc. actually used. Do
  not read arithmetic meaning into them.
- `equation_index` — Position of the equation/reaction that created this dependency, or
  `NON_EQUATION_INDEX` (`-1`) when the dependency has no positional
  equation (coupling maps and bare-expression targets).
- `expression` — The expression that created this dependency

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/graph.ts#L159)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DependencyEdge
DependencyEdge(source: str, target: str, relationship: str, equation_index: int | None = None, expression: Expr | None = None)
```

A dependency between two variables.

`relationship` is a PROVENANCE label, not a claim about the arithmetic:
an equation edge is always `additive` even for `w = u * v`. The
vocabulary (`additive` / `multiplicative` / `rate` /
`stoichiometric`) is shared by every binding.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/graph.py#L186)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct DependencyEdge {
    pub source: String,
    pub target: String,
    pub relationship: DependencyRelationship,
    pub equation_index: Option<i64>,
    pub expression: Option<Expr>,
}
```

Edge representing dependencies between variables in an expression graph

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/graph.rs#L467) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DependencyEdge.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DependencyEdge struct {
	Source        string     `json:"source"`
	Target        string     `json:"target"`
	Relationship  string     `json:"relationship"` // "additive", "multiplicative", "rate", "stoichiometric"
	EquationIndex *int       `json:"equation_index,omitempty"`
	Expression    Expression `json:"expression,omitempty"`
}
```

DependencyEdge represents an edge in the expression graph. Source and Target are node keys (VariableNode.Name), i.e. scoped names.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/graph.go#L110) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DependencyEdge)

</div>

</div>
