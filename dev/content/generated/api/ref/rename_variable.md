---
title: "rename_variable"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `rename_variable` | `renameVariable` | `rename_variable`, `rename_variable_in_model` | not exported | `RenameVariable` |


**Note:** spelling differs from the §2 rule: python=rename_variable_in_model (expected rename_variable); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
rename_variable(model::Model, old_name::String, new_name::String)
```

```julia
rename_variable(model::Model, old_name::String, new_name::String) -> Model
```

Rename a variable throughout the model.

Updates the variable definition and all references in equations.
Throws [`EditError`](/generated/api/ref/edit_error) if `old_name` does not exist.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/edit.jl#L165)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/editing.jl#L33-L48">docs/api/examples/julia/editing.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function renameVariable(model: Model, oldName: string, newName: string): Model
```

Rename a variable throughout a model.

The rewrite covers exactly the expression sites `removeVariable` scans (via
`substituteInModel` — equations, observed-variable expressions, event
conditions/triggers/affect RHSs, and inline subsystems), so a rename never
leaves a dangling reference in a site the removal guard would have flagged.

**Parameters**

- `model` — Model to rename variable in
- `oldName` — Current variable name
- `newName` — New variable name

**Returns**

New model with variable renamed

**Throws**

- EntityNotFoundError if variable doesn't exist

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/edit.ts#L143)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `rename_variable` and `rename_variable_in_model`. Both names refer to the same operation.

**`rename_variable`**

```python
rename_variable(model: Model, old_name: str, new_name: str, validate_after_edit: bool = True) -> EditResult
```

Rename a variable in a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L761)

**`rename_variable_in_model`**

```python
rename_variable_in_model(model: Model, old_name: str, new_name: str, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`rename_variable`](/generated/api/ref/rename_variable). Rename a variable in a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L889)

**Example** (`rename_variable`)

```python
renamed = earthsci_ast.rename_variable(doc.models["Decay"], "lambda", "k").modified_object
assert "k" in renamed.variables and "lambda" not in renamed.variables
assert earthsci_ast.to_ascii(renamed.equations[1]) == "half_life = log(2) / k"

trimmed = earthsci_ast.remove_variable(renamed, "N0")
assert "N0" not in trimmed.modified_object.variables
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L150-L155">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func RenameVariable(model Model, oldName, newName string) (Model, error)
```

RenameVariableInFile when the document is available; it resolves scoped references and rewrites coupling endpoints too. TypeScript's renameVariable has exactly this limitation, for exactly this reason: it calls substituteInModel without the esmFile context that its own scoped-reference resolution requires.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/edit.go#L628) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#RenameVariable)

</div>

</div>
