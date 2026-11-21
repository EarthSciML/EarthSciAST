---
title: "remove_equation"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `remove_equation` | `removeEquation` | `remove_equation`, `remove_equation_from_model` | `remove_equation` | not exported |


**Note:** spelling differs from the §2 rule: python=remove_equation_from_model (expected remove_equation); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
remove_equation(model::Model, index::Int64)
remove_equation(model::Model, lhs_pattern::ASTExpr)
```

```julia
remove_equation(model::Model, index::Int) -> Model
remove_equation(model::Model, lhs_pattern::ASTExpr) -> Model
```

Remove an equation from a model.

Can remove by index (1-based) or by matching the left-hand side expression.
Throws [`EditError`](/generated/api/ref/edit_error) if the index is out of bounds or no equation
matches the pattern.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/edit.jl#L217)

**Example** (`rename_variable`)

```julia
renamed = rename_variable(model, "lambda", "k")
@assert parameters(renamed) == ["k"]
@assert to_ascii(renamed.equations[1]) == "D(N)/Dt = (-k) * N"

# Drop the half_life equation, then the variable it defined.
trimmed = remove_variable(remove_equation(model, 2), "half_life")
@assert unknowns(trimmed) == ["N"]
@assert length(trimmed.equations) == 1

# Editing a variable that does not exist raises an EditError.
try
    rename_variable(model, "nope", "k")
    error("expected an EditError")
catch e
    @assert e isa EditError
end
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/editing.jl#L33-L48">docs/api/examples/julia/editing.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function removeEquation(model: Model, indexOrLhs: number | Expr): Model
```

Remove an equation from a model

**Parameters**

- `model` — Model to remove equation from
- `indexOrLhs` — Either the numeric index or the LHS expression of the equation

**Returns**

New model with equation removed

**Throws**

- EntityNotFoundError if equation not found

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/edit.ts#L192)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `remove_equation` and `remove_equation_from_model`. Both names refer to the same operation.

**`remove_equation`**

```python
remove_equation(model: Model, index: int, validate_after_edit: bool = True) -> EditResult
```

Remove an equation from a model by index.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L781)

**`remove_equation_from_model`**

```python
remove_equation_from_model(model: Model, index: int, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`remove_equation`](/generated/api/ref/remove_equation). Remove an equation from a model by index.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L925)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn remove_equation(model: &Model, index: usize) -> EditResult<Model>
```

Remove an equation from a model by index

**Arguments**

* `model` - The model to modify
* `index` - Index of the equation to remove

**Returns**

* `EditResult<Model>` - New model without the equation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/edit.rs#L202) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.remove_equation.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
