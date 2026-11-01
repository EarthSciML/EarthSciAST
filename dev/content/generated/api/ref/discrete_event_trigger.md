---
title: "discrete_event_trigger"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DiscreteEventTrigger` | not exported | `DiscreteEventTrigger` | `DiscreteEventTrigger` | `DiscreteEventTrigger` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
abstract type DiscreteEventTrigger
```

```julia
abstract type DiscreteEventTrigger end
```

Abstract base type for discrete event triggers.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L736)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DiscreteEventTrigger
DiscreteEventTrigger(type: Literal['condition', 'periodic', 'preset_times'], value: float | Expr | str, initial_offset: float | None = None)
```

Trigger condition for a discrete event.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L875)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum DiscreteEventTrigger {
    Condition { expression: Expr },
    Periodic { interval: f64, initial_offset: Option<f64> },
    PresetTimes { times: Vec<f64> },
}
```

Trigger condition for discrete events

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/events.rs#L35) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.DiscreteEventTrigger.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DiscreteEventTrigger struct {
	Type          string     `json:"type"`                     // "condition", "periodic", "preset_times"
	Expression    Expression `json:"expression,omitempty"`     // for condition
	Interval      *float64   `json:"interval,omitempty"`       // for periodic
	InitialOffset *float64   `json:"initial_offset,omitempty"` // for periodic
	Times         []float64  `json:"times,omitempty"`          // for preset_times
}
```

DiscreteEventTrigger represents different trigger types for discrete events

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L720) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DiscreteEventTrigger)

</div>

</div>
