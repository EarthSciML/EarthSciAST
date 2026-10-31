---
title: "substitute_with_context"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `substitute_with_context` | `SubstituteWithContext` |


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
pub fn substitute_with_context(expr: &Expr, substitutions: &HashMap<String, Expr>, context: &ScopedContext) -> Expr
```

Substitute variables in an expression with scoped reference resolution
(esm-spec §2.3.3).

Resolution order per variable leaf: exact-name substitution, then scoped
resolution of the name via `context` (substituting the resolved name if it
has a binding, else rewriting the leaf to the resolved name), else the
leaf is left unchanged. Traversal and metadata preservation are identical
to [`substitute`](/generated/api/ref/substitute).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/substitute.rs#L398) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.substitute_with_context.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SubstituteWithContext(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string) (Expression, error)
```

SubstituteWithContext performs variable substitution in a SCOPE CONTEXT: the (file, currentSystem) pair against which a dotted binding key like "OtherModel.x" is resolved. Canonical `substitute_with_context` (API\_SPEC.md §8 item 9) — the family was spelled `*WithScoped` here and `*_with_context` in Rust, which names the same context a `ScopedContext`.

Passing a nil file and an empty currentSystem disables dotted-name resolution and makes this exactly Substitute.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/substitute.go#L232) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteWithContext)

</div>

</div>
