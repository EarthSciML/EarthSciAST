---
title: "add_reaction"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `add_reaction` | `addReaction` | `add_reaction`, `add_reaction_to_system` | `add_reaction` | `AddReaction` |


**Note:** spelling differs from the §2 rule: python=add_reaction_to_system (expected add_reaction); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
add_reaction(system::ReactionSystem, reaction::Reaction)
```

```julia
add_reaction(system::ReactionSystem, reaction::Reaction) -> ReactionSystem
```

Add a new reaction to a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/edit.jl#L270)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function addReaction(system: ReactionSystem, reaction: Reaction): ReactionSystem
```

Add a new reaction to a reaction system

**Parameters**

- `system` — ReactionSystem to add reaction to
- `reaction` — Reaction to add

**Returns**

New reaction system with reaction added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L247)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `add_reaction` and `add_reaction_to_system`. Both names refer to the same operation.

**`add_reaction`**

```python
add_reaction(reaction_system: ReactionSystem, reaction: Reaction, validate_after_edit: bool = True) -> EditResult
```

Add a reaction to a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L787)

**`add_reaction_to_system`**

```python
add_reaction_to_system(reaction_system: ReactionSystem, reaction: Reaction, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`add_reaction`](/generated/api/ref/add_reaction). Add a reaction to a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L937)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn add_reaction(system: &ReactionSystem, reaction: Reaction) -> EditResult<ReactionSystem>
```

Add a reaction to a reaction system

**Arguments**

* `system` - The reaction system to modify
* `reaction` - The reaction to add

**Returns**

* `EditResult<ReactionSystem>` - New reaction system with the added reaction

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/edit.rs#L336) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.add_reaction.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func AddReaction(system ReactionSystem, reaction Reaction) ReactionSystem
```

AddReaction returns a copy of `system` with `reaction` appended.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L902) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AddReaction)

</div>

</div>
