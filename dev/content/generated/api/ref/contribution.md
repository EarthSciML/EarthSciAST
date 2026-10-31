---
title: "contribution"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Contribution` | `Contribution` | `Contribution` | `Contribution` | `Contribution` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Contribution
Contribution(expr::ASTExpr, origins::Vector{TermOrigin})
Contribution(expr, origins)
```

```julia
Contribution(expr, origins)
```

One summand of a flattened equation's right-hand side, with its authors.

`origins` is non-empty and deduplicated in first-appearance order for every
equation `flatten` produces. It has more than one entry only where a
non-additive merge (a multiplicative `couple`, or an `operator_compose`
`translate` factor over a multi-contribution equation) collapsed several
contributions into one indivisible expression. An EMPTY `origins` means "author
unknown": the keyword copy constructor `FlattenedSystem(flat; equations = eqs)`
produces it when a caller replaces the equations without their contributions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/term_provenance.jl#L56)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface Contribution {
    expr: Expression;
    origins: TermOrigin[];
}
```

One summand of a flattened equation's right-hand side, with its authors.

`origins` is deduplicated in first-appearance order. It has more than one
entry only where a non-additive merge (a multiplicative `couple`, or an
`operator_compose` `translate` factor applied to a multi-contribution
equation) collapsed several contributions into one indivisible expression.
Flatten never produces an empty `origins`; an equation built outside flatten
may carry one, meaning "author unknown".

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/flatten-contributions.ts#L34)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Contribution
Contribution(expr: Expr, origins: list[TermOrigin])
```

One summand of a flattened equation's right-hand side, with its authors.

`origins` is non-empty and deduplicated in first-appearance order. It has
more than one entry only where a non-additive merge (a multiplicative
`couple`, or an `operator_compose` `translate` factor applied to a
multi-contribution equation) collapsed several contributions into one
indivisible expression. Provenance lives here, beside the expression tree,
never on a node: `expr` is an ordinary expression and compares, hashes and
canonicalizes as one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L346)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Contribution {
    pub expr: Expr,
    pub origins: Vec<TermOrigin>,
}
```

One summand of a flattened equation's right-hand side, with its authors
(esm-libraries-spec §4.7.5, "Per-term provenance").

`origins` is deduplicated in first-appearance order, and non-empty except
on an equation assembled without provenance (origin unknown). It has more
than one entry only where several contributions collapsed into one
indivisible expression: a non-additive merge (a multiplicative `couple`, or
an `operator_compose` `translate` factor applied to a multi-contribution
equation), or a caller's edit to a right-hand side the list no longer sums
to (`FlattenedSystem::equation_contributions`). Provenance lives here,
beside the expression tree, never on a node, so `expr` compares, hashes and
interns as any expression.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/flatten.rs#L487) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Contribution.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Contribution struct {
	Expr    Expression   `json:"expr"`
	Origins []TermOrigin `json:"origins"`
}
```

Contribution is one summand of a flattened equation's right-hand side, with its authors.

Origins is deduplicated in first-appearance order. It has more than one entry only where a non-additive merge (a multiplicative `couple`, or an `operator_compose` translate factor applied to a multi-contribution equation) collapsed several contributions into one indivisible expression. Flatten never produces an empty Origins; an equation built outside flatten may carry one, meaning "author unknown".

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/flatten_contributions.go#L32) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Contribution)

</div>

</div>
