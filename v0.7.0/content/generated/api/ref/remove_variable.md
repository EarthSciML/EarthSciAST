---
title: "remove_variable"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `remove_variable` | `removeVariable` | `remove_variable`, `remove_variable_from_model` | `remove_variable` | `RemoveVariable` |


**Note:** spelling differs from the §2 rule: python=remove_variable_from_model (expected remove_variable); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
remove_variable(model::Model, name::String)
```

```julia
remove_variable(model::Model, name::String) -> Model
```

Remove a variable from a model.

Creates a new model without the specified variable. Warns about dependencies
but does not automatically update equations that reference the variable.
Throws [`EditError`](/generated/api/ref/edit_error) if the variable does not exist.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/edit.jl#L130)

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
function removeVariable(model: Model, name: string): Model
```

Remove a variable from a model, with reference checking

**Parameters**

- `model` — Model to remove variable from
- `name` — Variable name to remove

**Returns**

New model with variable removed

**Throws**

- VariableInUseError if variable is still referenced
- EntityNotFoundError if variable doesn't exist

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/edit.ts#L86)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `remove_variable` and `remove_variable_from_model`. Both names refer to the same operation.

**`remove_variable`**

```python
remove_variable(model: Model, var_name: str, validate_after_edit: bool = True) -> EditResult
```

Remove a variable from a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L769)

**`remove_variable_from_model`**

```python
remove_variable_from_model(model: Model, var_name: str, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`remove_variable`](/generated/api/ref/remove_variable). Remove a variable from a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L901)

**Example** (`rename_variable`)

```python
renamed = earthsci_ast.rename_variable(doc.models["Decay"], "lambda", "k").modified_object
assert "k" in renamed.variables and "lambda" not in renamed.variables
assert earthsci_ast.to_ascii(renamed.equations[1]) == "half_life = log(2) / k"

trimmed = earthsci_ast.remove_variable(renamed, "N0")
assert "N0" not in trimmed.modified_object.variables
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/documents.py#L150-L155">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn remove_variable(model: &Model, var_name: &str) -> EditResult<Model>
```

Remove a variable from a model

**Arguments**

* `model` - The model to modify
* `var_name` - Name of the variable to remove

**Returns**

* `EditResult<Model>` - New model without the variable

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/edit.rs#L166) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.remove_variable.html)

**Example** (`remove_variable`)

```rust
let model = &reread.models.as_ref().unwrap()["Decay"];
let trimmed = remove_variable(model, "half_life")?;
assert!(!trimmed.variables.contains_key("half_life"));
// Removing a name that is not there is an error, not a no-op.
assert!(remove_variable(&trimmed, "half_life").is_err());
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/edit.rs#L50-L54">docs/api/examples/rust/edit.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RemoveVariable(model Model, name string) (Model, error)
```

RemoveVariable returns a copy of `model` without the variable `name`, after checking that nothing still references it.

Returns \*EntityNotFoundError when the variable does not exist, and \*VariableInUseError when it is still read from any expression site (see modelExpressionSites) or written by any event affect. A site reported from more than one position — an equation matching in both `lhs` and `rhs` — is collapsed to a single reference, preserving discovery order.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/edit.go#L316) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RemoveVariable)

</div>

</div>
