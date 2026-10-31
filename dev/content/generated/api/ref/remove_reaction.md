---
title: "remove_reaction"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `remove_reaction` | `removeReaction` | `remove_reaction`, `remove_reaction_from_system` | `remove_reaction` | `RemoveReaction` |


**Note:** spelling differs from the §2 rule: python=remove_reaction_from_system (expected remove_reaction); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
remove_reaction(system::ReactionSystem, id::String)
```

```julia
remove_reaction(system::ReactionSystem, id::String) -> ReactionSystem
```

Remove a reaction by its ID.

Throws [`EditError`](/generated/api/ref/edit_error) if no reaction has the given ID.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/edit.jl#L282)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function removeReaction(system: ReactionSystem, id: string): ReactionSystem
```

Remove a reaction from a reaction system

**Parameters**

- `system` — ReactionSystem to remove reaction from
- `id` — Reaction ID to remove

**Returns**

New reaction system with reaction removed

**Throws**

- EntityNotFoundError if reaction not found

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L261)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `remove_reaction` and `remove_reaction_from_system`. Both names refer to the same operation.

**`remove_reaction`**

```python
remove_reaction(reaction_system: ReactionSystem, reaction_name: str, validate_after_edit: bool = True) -> EditResult
```

Remove a reaction from a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L795)

**`remove_reaction_from_system`**

```python
remove_reaction_from_system(reaction_system: ReactionSystem, reaction_name: str, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`remove_reaction`](/generated/api/ref/remove_reaction). Remove a reaction from a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L949)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn remove_reaction(system: &ReactionSystem, index: usize) -> EditResult<ReactionSystem>
```

Remove a reaction from a reaction system by index

**Arguments**

* `system` - The reaction system to modify
* `index` - Index of the reaction to remove

**Returns**

* `EditResult<ReactionSystem>` - New reaction system without the reaction

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/edit.rs#L352) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.remove_reaction.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RemoveReaction(system ReactionSystem, id string) (ReactionSystem, error)
```

RemoveReaction returns a copy of `system` without the reaction whose ID is `id`.

Returns \*EntityNotFoundError when no reaction has that ID, and \*EditError (invalid\_operation) when the removal would empty the system: the schema requires a reaction system to retain at least one reaction, so the sole remaining reaction is still required.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L915) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RemoveReaction)

</div>

</div>
