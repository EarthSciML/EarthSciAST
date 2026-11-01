---
title: "substitute_in_model"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `substituteInModel` | `substitute_in_model` | `substitute_in_model` | `SubstituteInModel` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function substituteInModel(model: Model, bindings: Record<string, Expr>, context?: SubstitutionContext): Model
```

Apply substitution across an ENTIRE model, not just its equations.

The rewritten expression sites are, exhaustively (this is the single write
definition of "a model's expression sites"; `edit.ts`'s read-side
`forEachModelExpressionSite` MUST cover the same set):
  - every equation `lhs` / `rhs`;
  - every observed variable's `expression`;
  - every continuous event's `conditions[]`, `affects[].rhs`, and
    `affect_neg[].rhs`;
  - every discrete event's condition-`trigger.expression` and `affects[].rhs`;
  - recursively, every inline-model subsystem (data loaders and unresolved
    `{ref}` subsystems pass through unchanged).

Event affect `lhs` values are write-TARGET names (`string`), not expression
read-sites, and are intentionally left untouched — substitution replaces
references, not assignment targets.

Returns a new model with substitutions applied (immutable).

**Parameters**

- `model` — Model to substitute into
- `bindings` — Variable name to expression mappings
- `context` — Optional context for resolving scoped references

**Returns**

New model with substitutions applied

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/substitute.ts#L174)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
substitute_in_model(model, bindings: dict[str, Expr])
```

Apply substitutions to all expressions in a model.

**Parameters**

- `model` — Model object or dict to perform substitutions on
- `bindings` (`dict[str, Expr]`) — Dictionary mapping variable names to replacement expressions

**Returns**

New model (same type as input) with substitutions applied

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/substitute.py#L106)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn substitute_in_model(model: &Model, substitutions: &HashMap<String, Expr>) -> Model
```

Substitute variables in all expressions within a model (equations plus
discrete/continuous events; other model fields are cloned unchanged).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/substitute.rs#L215) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.substitute_in_model.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SubstituteInModel(model Model, bindings map[string]Expression) (Model, error)
```

SubstituteInModel performs substitution across an entire model. It is the scope-free case of SubstituteInModelWithContext (file=nil disables dotted-name resolution), so it delegates rather than duplicating the traversal.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/substitute.go#L165) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInModel)

</div>

</div>
