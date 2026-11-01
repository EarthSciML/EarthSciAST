---
title: "edit_error"
description: "Stable error · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `EditError` | not exported | not exported | `EditError` | `EditError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct EditError <: EarthSciASTError
EditError(msg::String)
EditError(msg)
```

```julia
EditError(msg)
```

Exception thrown when an editing operation cannot be applied — e.g. removing
a variable, equation, reaction, event, or coupling entry that does not exist,
or extracting a missing component. Throwing (rather than warning and
returning the input unchanged) makes failed edits visible programmatically.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/edit.jl#L13)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/editing.jl#L33-L48">docs/api/examples/julia/editing.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum EditError {
    ComponentNotFound(String),
    InvalidOperation(String),
    VariableExists(String),
    EquationIndexError(usize),
    SpeciesNotFound(String),
    ReactionIndexError(usize),
    EventIndexError(usize),
    CouplingIndexError(usize),
}
```

Errors that can occur during editing operations

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/edit.rs#L13) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.EditError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type EditError struct {
	Code    string
	Message string
}

func (e *EditError) DiagnosticCode() string

func (e *EditError) Error() string
```

EditError is the base diagnostic for a failed editing operation, and the error type for failures with no more specific type. It mirrors Julia's catch-all `EditError` and Rust's `EditError` enum.

**Methods**

```go
func (e *EditError) DiagnosticCode() string
```

DiagnosticCode exposes the stable code.

```go
func (e *EditError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/edit.go#L74) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EditError)

</div>

</div>
