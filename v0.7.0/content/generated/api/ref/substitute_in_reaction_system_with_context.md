---
title: "substitute_in_reaction_system_with_context"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `substitute_in_reaction_system_with_context` | `SubstituteInReactionSystemWithContext` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn substitute_in_reaction_system_with_context(reaction_system: &ReactionSystem, substitutions: &HashMap<String, Expr>, context: &ScopedContext) -> ReactionSystem
```

[`substitute_in_reaction_system`](/generated/api/ref/substitute_in_reaction_system) with scoped reference resolution.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/substitute.rs#L474) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.substitute_in_reaction_system_with_context.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SubstituteInReactionSystemWithContext(system ReactionSystem, bindings map[string]Expression, file *ESMFile, systemName string) (ReactionSystem, error)
```

SubstituteInReactionSystemWithContext performs substitution across an entire reaction system with scoped reference support.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/substitute.go#L325) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInReactionSystemWithContext)

</div>

</div>
