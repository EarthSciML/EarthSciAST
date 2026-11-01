---
title: "add_discrete_event"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `add_discrete_event` | `addDiscreteEvent` | `add_discrete_event`, `add_discrete_event_to_model` | not exported | `AddDiscreteEvent` |


**Note:** spelling differs from the §2 rule: python=add_discrete_event_to_model (expected add_discrete_event); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
add_discrete_event(model::Model, event::DiscreteEvent)
```

```julia
add_discrete_event(model::Model, event::DiscreteEvent) -> Model
```

Add a discrete event to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/edit.jl#L371)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function addDiscreteEvent(model: Model, event: DiscreteEvent): Model
```

Add a discrete event to a model

**Parameters**

- `model` — Model to add event to
- `event` — Discrete event to add

**Returns**

New model with event added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/edit.ts#L375)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `add_discrete_event` and `add_discrete_event_to_model`. Both names refer to the same operation.

**`add_discrete_event`**

```python
add_discrete_event(model: Model, event: DiscreteEvent, validate_after_edit: bool = True) -> EditResult
```

Add a discrete event to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L827)

**`add_discrete_event_to_model`**

```python
add_discrete_event_to_model(model: Model, event: DiscreteEvent, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`add_discrete_event`](/generated/api/ref/add_discrete_event). Add a discrete event to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L997)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func AddDiscreteEvent(model Model, event DiscreteEvent) Model
```

AddDiscreteEvent returns a copy of `model` with `event` appended.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/edit.go#L1010) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AddDiscreteEvent)

</div>

</div>
