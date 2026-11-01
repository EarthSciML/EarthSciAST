---
title: "affect_equation"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `AffectEquation` | not exported | `AffectEquation` | `AffectEquation` | `AffectEquation` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct AffectEquation
AffectEquation(lhs::String, rhs::ASTExpr)
AffectEquation(lhs, rhs)
```

```julia
AffectEquation(lhs::String, rhs::ASTExpr)
```

Assignment equation for discrete events.
- `lhs`: target variable name (string)
- `rhs`: expression for the new value

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L713)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class AffectEquation
AffectEquation(lhs: str, rhs: Expr)
```

Equation that affects a variable (assignment-like).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L311)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct AffectEquation {
    pub lhs: String,
    pub rhs: Expr,
}
```

Equation that modifies state/parameters when event fires

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/events.rs#L55) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.AffectEquation.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type AffectEquation struct {
	LHS string     `json:"lhs"` // variable name
	RHS Expression `json:"rhs"` // expression
}

func (ae *AffectEquation) UnmarshalJSON(data []byte) error
```

AffectEquation represents an equation that affects a variable (for events)

**Methods**

```go
func (ae *AffectEquation) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for AffectEquation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L146) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AffectEquation)

</div>

</div>
