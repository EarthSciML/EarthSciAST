---
title: "substitute_in_reaction_system"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `substituteInReactionSystem` | `substitute_in_reaction_system` | `substitute_in_reaction_system` | `SubstituteInReactionSystem` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function substituteInReactionSystem(system: ReactionSystem, bindings: Record<string, Expr>, context?: SubstitutionContext): ReactionSystem
```

Apply substitution across all rate expressions in a reaction system.
Returns a new reaction system with substitutions applied (immutable).

**Parameters**

- `system` — ReactionSystem to substitute into
- `bindings` — Variable name to expression mappings
- `context` — Optional context for resolving scoped references

**Returns**

New reaction system with substitutions applied

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/substitute.ts#L257)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
substitute_in_reaction_system(system, bindings: dict[str, Expr])
```

Apply substitutions to all expressions in a reaction system.

**Parameters**

- `system` — Reaction system object or dict to perform substitutions on
- `bindings` (`dict[str, Expr]`) — Dictionary mapping variable names to replacement expressions

**Returns**

New reaction system (same type as input) with substitutions applied

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/substitute.py#L155)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn substitute_in_reaction_system(reaction_system: &ReactionSystem, substitutions: &HashMap<String, Expr>) -> ReactionSystem
```

Substitute variables in all reaction-rate expressions within a reaction
system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/substitute.rs#L221) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.substitute_in_reaction_system.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SubstituteInReactionSystem(system ReactionSystem, bindings map[string]Expression) (ReactionSystem, error)
```

SubstituteInReactionSystem performs substitution across an entire reaction system. Scope-free delegation to SubstituteInReactionSystemWithContext.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/substitute.go#L171) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInReactionSystem)

</div>

</div>
