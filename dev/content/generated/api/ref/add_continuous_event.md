---
title: "add_continuous_event"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `add_continuous_event` | `addContinuousEvent` | `add_continuous_event`, `add_continuous_event_to_model` | not exported | `AddContinuousEvent` |


**Note:** spelling differs from the §2 rule: python=add_continuous_event_to_model (expected add_continuous_event); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
add_continuous_event(model::Model, event::ContinuousEvent)
```

```julia
add_continuous_event(model::Model, event::ContinuousEvent) -> Model
```

Add a continuous event to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/edit.jl#L359)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function addContinuousEvent(model: Model, event: ContinuousEvent): Model
```

Add a continuous event to a model

**Parameters**

- `model` — Model to add event to
- `event` — Continuous event to add

**Returns**

New model with event added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/edit.ts#L361)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `add_continuous_event` and `add_continuous_event_to_model`. Both names refer to the same operation.

**`add_continuous_event`**

```python
add_continuous_event(model: Model, event: ContinuousEvent, validate_after_edit: bool = True) -> EditResult
```

Add a continuous event to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L819)

**`add_continuous_event_to_model`**

```python
add_continuous_event_to_model(model: Model, event: ContinuousEvent, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`add_continuous_event`](/generated/api/ref/add_continuous_event). Add a continuous event to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L985)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func AddContinuousEvent(model Model, event ContinuousEvent) Model
```

AddContinuousEvent returns a copy of `model` with `event` appended.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/edit.go#L1003) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AddContinuousEvent)

</div>

</div>
