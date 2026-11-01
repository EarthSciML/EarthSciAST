---
title: "remove_species"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `remove_species` | `removeSpecies` | `remove_species`, `remove_species_from_system` | `remove_species` | `RemoveSpecies` |


**Note:** spelling differs from the §2 rule: python=remove_species_from_system (expected remove_species); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
remove_species(system::ReactionSystem, name::String)
```

```julia
remove_species(system::ReactionSystem, name::String) -> ReactionSystem
```

Remove a species from a reaction system.

Warns about dependent reactions but does not automatically update them.
Throws [`EditError`](/generated/api/ref/edit_error) if the species does not exist.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/edit.jl#L322)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function removeSpecies(system: ReactionSystem, name: string): ReactionSystem
```

Remove a species from a reaction system, with reference checking

**Parameters**

- `system` — ReactionSystem to remove species from
- `name` — Species name to remove

**Returns**

New reaction system with species removed

**Throws**

- VariableInUseError if species is still referenced in reactions
- EntityNotFoundError if species doesn't exist

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/edit.ts#L306)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `remove_species` and `remove_species_from_system`. Both names refer to the same operation.

**`remove_species`**

```python
remove_species(reaction_system: ReactionSystem, species_name: str, validate_after_edit: bool = True) -> EditResult
```

Remove a species from a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L811)

**`remove_species_from_system`**

```python
remove_species_from_system(reaction_system: ReactionSystem, species_name: str, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`remove_species`](/generated/api/ref/remove_species). Remove a species from a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L973)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn remove_species(system: &ReactionSystem, species_name: &str) -> EditResult<ReactionSystem>
```

Remove a species from a reaction system

**Arguments**

* `system` - The reaction system to modify
* `species_name` - Name of the species to remove

**Returns**

* `EditResult<ReactionSystem>` - New reaction system without the species

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/edit.rs#L316) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.remove_species.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RemoveSpecies(system ReactionSystem, name string) (ReactionSystem, error)
```

RemoveSpecies returns a copy of `system` without the species `name`, after checking that no reaction still references it.

Returns \*EntityNotFoundError when the species does not exist, and \*VariableInUseError when it appears among any reaction's substrates or products, or is read by any reaction's rate expression. Constraint equations are scanned too — they are ordinary expression sites over the same names.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/edit.go#L953) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RemoveSpecies)

</div>

</div>
