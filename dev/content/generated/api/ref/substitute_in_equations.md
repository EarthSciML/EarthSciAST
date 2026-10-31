---
title: "substitute_in_equations"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `substitute_in_equations` | `substituteInEquations` | not exported | not exported | `SubstituteInEquations` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
substitute_in_equations(model::Model, bindings::Dict{String, ASTExpr})
```

```julia
substitute_in_equations(model::Model, bindings::Dict{String, ASTExpr}) -> Model
```

Apply substitutions across all equations in a model.

Replaces variables according to the bindings dictionary.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/edit.jl#L249)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function substituteInEquations(model: Model, bindings: Record<string, Expr>): Model
```

**Deprecated.** The name understates its blast radius; call `substituteInModel`
  (exported from `substitute.js`) directly. Retained as a public back-compat
  export (re-exported via `index.ts` and `analysis/index.ts`).

Apply substitutions across a model.

NOTE: despite its name, this does NOT touch only equations — it is
a thin alias for [`substituteInModel`](/generated/api/ref/substitute_in_model) and therefore also rewrites
observed-variable expressions, event expression positions, and inline
subsystems. See `substituteInModel` for the full list of rewritten sites.

**Parameters**

- `model` — Model to apply substitutions to
- `bindings` — Variable name to expression mappings

**Returns**

New model with substitutions applied

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L233)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func SubstituteInEquations(model Model, bindings map[string]Expression) (Model, error)
```

SubstituteInEquations applies `bindings` across a model.

Despite the historical name — carried from the other bindings — this does NOT touch only equations: it is a thin alias for SubstituteInModel and therefore also rewrites every Expression position the model's variables carry and every event expression position. Prefer calling SubstituteInModel directly; this exists so the §4.2 operation set is complete under the name the spec and the other bindings use.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L893) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SubstituteInEquations)

</div>

</div>
