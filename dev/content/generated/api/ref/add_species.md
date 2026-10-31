---
title: "add_species"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `add_species` | `addSpecies` | `add_species`, `add_species_to_system` | `add_species` | `AddSpecies` |


**Note:** spelling differs from the §2 rule: python=add_species_to_system (expected add_species); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
add_species(system::ReactionSystem, name::String, species::Species)
```

```julia
add_species(system::ReactionSystem, name::String, species::Species) -> ReactionSystem
```

Add a new species to a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/edit.jl#L299)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function addSpecies(system: ReactionSystem, name: string, species: Species): ReactionSystem
```

Add a new species to a reaction system

**Parameters**

- `system` — ReactionSystem to add species to
- `name` — Species name
- `species` — Species definition

**Returns**

New reaction system with species added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L288)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `add_species` and `add_species_to_system`. Both names refer to the same operation.

**`add_species`**

```python
add_species(reaction_system: ReactionSystem, species: Species, validate_after_edit: bool = True) -> EditResult
```

Add a species to a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L803)

**`add_species_to_system`**

```python
add_species_to_system(reaction_system: ReactionSystem, species: Species, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`add_species`](/generated/api/ref/add_species). Add a species to a reaction system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L961)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn add_species(system: &ReactionSystem, name: &str, species: Species) -> EditResult<ReactionSystem>
```

Add a species to a reaction system

**Arguments**

* `system` - The reaction system to modify
* `name` - Unique species name (used as the map key)
* `species` - The species to add

**Returns**

* `EditResult<ReactionSystem>` - New reaction system with the added species

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/edit.rs#L289) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.add_species.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func AddSpecies(system ReactionSystem, name string, species Species) ReactionSystem
```

AddSpecies returns a copy of `system` carrying `species` under `name`. An existing species of that name is replaced.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L939) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AddSpecies)

</div>

</div>
