---
title: "continuous_event"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ContinuousEvent` | not exported | `ContinuousEvent` | `ContinuousEvent` | `ContinuousEvent` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ContinuousEvent <: EventType
ContinuousEvent(conditions::Vector{ASTExpr}, affects::Vector{AffectEquation}; affect_neg, root_find, reinitialize, description, name)
```

```julia
ContinuousEvent <: EventType
```

Event triggered by zero-crossing of condition expressions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L780)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ContinuousEvent
ContinuousEvent(name: str, conditions: list[Expr] = list(), affects: list[AffectEquation] = list(), affect_neg: list[AffectEquation] | None = None, root_find: Literal['left', 'right'] | None = None, reinitialize: bool = False, priority: int = 0, description: str | None = None)
```

An event that occurs when a condition becomes true during continuous
evolution. Affects UNKNOWNS ONLY (esm-spec §5.5); a parameter that changes on
a zero crossing declares `update: {kind: "crossing", ...}` on itself.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L854)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ContinuousEvent {
    pub name: Option<String>,
    pub conditions: Vec<Expr>,
    pub affects: Vec<AffectEquation>,
    pub affect_neg: Option<Vec<AffectEquation>>,
    pub root_find: Option<RootFindDirection>,
    pub reinitialize: Option<bool>,
    pub description: Option<String>,
}
```

Continuous event that fires on zero-crossings

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/events.rs#L65) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ContinuousEvent.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ContinuousEvent struct {
	Name         *string          `json:"name,omitempty"`
	Conditions   []Expression     `json:"conditions"`
	Affects      []AffectEquation `json:"affects"`
	AffectNeg    []AffectEquation `json:"affect_neg,omitempty"`
	RootFind     *string          `json:"root_find,omitempty"` // "left" (default) or "right"
	Reinitialize *bool            `json:"reinitialize,omitempty"`
	Description  *string          `json:"description,omitempty"`
}
```

ContinuousEvent represents a continuous event. As with DiscreteEvent, every affect LHS must name an unknown; a parameter that changes on a zero crossing declares `update: {kind: "crossing", ...}` on itself (esm-spec 5.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L743) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ContinuousEvent)

</div>

</div>
