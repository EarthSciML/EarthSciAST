---
title: "remove_event"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `remove_event` | `removeEvent` | `remove_event`, `remove_event_from_model` | not exported | `RemoveEvent` |


**Note:** spelling differs from the §2 rule: python=remove_event_from_model (expected remove_event); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
remove_event(model::Model, description::String)
```

```julia
remove_event(model::Model, description::String) -> Model
```

Remove events whose `description` field equals `description` from a model.

Events carry no dedicated identifier in the ESM schema, so the `description`
string is the only name-like field available and is used as the match key.
Searches both continuous and discrete events. Throws [`EditError`](/generated/api/ref/edit_error) if
no event matches.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/edit.jl#L383)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function removeEvent(model: Model, name: string): Model
```

Remove events from a model by name.

Remove-ALL semantics: EVERY event whose `name` matches is removed, not just
the first. Containers are tried in order — if any continuous event matches,
only continuous events are filtered; otherwise discrete events are filtered
(a name present in both containers is removed only from `continuous_events`).
If the filtered container ends up empty, its key is dropped per the
module-wide drop-when-empty convention (see `withCollection`).

**Parameters**

- `model` — Model to remove event(s) from
- `name` — Event name to remove

**Returns**

New model with matching event(s) removed

**Throws**

- EntityNotFoundError if no event with that name exists

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/edit.ts#L398)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `remove_event` and `remove_event_from_model`. Both names refer to the same operation.

**`remove_event`**

```python
remove_event(model: Model, event_name: str, validate_after_edit: bool = True) -> EditResult
```

Remove an event from a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L835)

**`remove_event_from_model`**

```python
remove_event_from_model(model: Model, event_name: str, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`remove_event`](/generated/api/ref/remove_event). Remove an event from a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L1009)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RemoveEvent(model Model, name string) (Model, error)
```

RemoveEvent returns a copy of `model` with every event named `name` removed.

Remove-ALL semantics: EVERY event whose name matches is removed, not just the first. Containers are tried in order — if any continuous event matches, only continuous events are filtered; otherwise discrete events are filtered, so a name present in both containers is removed only from ContinuousEvents.

Returns \*EntityNotFoundError when no event carries that name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/edit.go#L1024) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RemoveEvent)

</div>

</div>
