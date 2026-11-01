---
title: "discrete_event"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DiscreteEvent` | not exported | `DiscreteEvent` | `DiscreteEvent` | `DiscreteEvent` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DiscreteEvent <: EventType
DiscreteEvent(trigger::DiscreteEventTrigger, affects::Vector{AffectEquation}; reinitialize, description, name)
```

```julia
DiscreteEvent <: EventType
```

Event triggered by discrete triggers whose symbolic `affects` are
[`AffectEquation`](/generated/api/ref/affect_equation)s (`lhs` target name, `rhs` new-value expression) —
the schema's `AffectEquation` shape, shared with `ContinuousEvent`.

An event affects **unknowns only** (esm-spec §5.4, §6.3.1). A handler that
computes a new value lives on the parameter it writes (`update.handler`,
[`FunctionalUpdate`](/generated/api/ref/functional_update)), and a parameter that changes during a run declares
its own [`ParameterUpdate`](/generated/api/ref/parameter_update). An `affects` LHS naming a parameter is the
`event_affects_parameter` diagnostic.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L817)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DiscreteEvent
DiscreteEvent(name: str, trigger: DiscreteEventTrigger, affects: list[AffectEquation] = list(), priority: int = 0, reinitialize: bool | None = None, description: str | None = None)
DiscreteEvent.reinitializes: bool  # property
```

An event that occurs at discrete time points.

Affects UNKNOWNS ONLY (esm-spec §5.5). A parameter that changes at
discrete times declares that in its own `update` block
([`ParameterUpdate`](/generated/api/ref/parameter_update)), not here.

**Members**

- `reinitializes` — The effective flag: an unspelled `reinitialize` means `False`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L886)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct DiscreteEvent {
    pub name: Option<String>,
    pub trigger: DiscreteEventTrigger,
    pub affects: Option<Vec<AffectEquation>>,
    pub reinitialize: Option<bool>,
    pub description: Option<String>,
}
```

Discrete event that can modify the system

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/events.rs#L6) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DiscreteEvent.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DiscreteEvent struct {
	Name         string               `json:"name,omitempty"`
	Trigger      DiscreteEventTrigger `json:"trigger"`
	Affects      []AffectEquation     `json:"affects,omitempty"`
	Reinitialize *bool                `json:"reinitialize,omitempty"`
	Description  *string              `json:"description,omitempty"`
}
```

DiscreteEvent represents a discrete event. From esm 1.0.0 an event may affect UNKNOWNS ONLY (`event_affects_parameter` otherwise): a parameter that changes during a run carries its own `update` block, so there is no `discrete_parameters` list and no `functional_affect` here.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L732) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DiscreteEvent)

</div>

</div>
