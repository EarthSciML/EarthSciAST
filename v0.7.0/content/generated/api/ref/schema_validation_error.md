---
title: "schema_validation_error"
description: "Stable error · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SchemaValidationError` | `SchemaValidationError` | `SchemaValidationError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct SchemaValidationError <: EarthSciASTError
SchemaValidationError(message::String, errors::Vector{SchemaError})
SchemaValidationError(message, errors)
```

```julia
SchemaValidationError
```

Exception thrown when schema validation fails.
Contains detailed error information including paths and messages.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/validate.jl#L146)

**Example** (`load_errors`)

```julia
# Text that is not JSON at all raises a ParseError...
try
    load_string("{not json")
    error("expected a ParseError")
catch e
    @assert e isa ParseError
    println(sprint(showerror, e))
end

# ...and JSON that breaks the schema raises a SchemaValidationError, whose
# `errors` field lists each failure.
try
    load_string("""{"esm": "1.0.0"}""")
    error("expected a SchemaValidationError")
catch e
    @assert e isa SchemaValidationError
    @assert !isempty(e.errors)
    println(sprint(showerror, e))
end
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/documents.jl#L33-L51">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class SchemaValidationError extends EsmDiagnosticError
new SchemaValidationError(message: string, errors: SchemaError[]): SchemaValidationError
```

Schema validation error - thrown when schema validation fails

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/parse.ts#L86)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class SchemaValidationError(EarthSciAstError)
```

Exception raised when schema validation fails.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L112)

**Example** (`validate`)

```python
result = earthsci_ast.validate(doc)
assert result.is_valid
assert result.schema_errors == [] and result.structural_errors == []

# validate_path reports problems in the result; it does not raise.
bad = earthsci_ast.validate_path(FIXTURES / "invalid.esm")
assert not bad.is_valid
error = bad.structural_errors[0]
print(error.code, error.path, error.message)
assert error.code == "undefined_variable"
assert "'k'" in error.message

# Loading the same file raises, because loading validates too.
try:
    earthsci_ast.load_path(FIXTURES / "invalid.esm")
except earthsci_ast.SchemaValidationError as exc:
    assert "'k'" in str(exc)
else:
    raise AssertionError("loading invalid.esm should fail")
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/documents.py#L38-L56">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
