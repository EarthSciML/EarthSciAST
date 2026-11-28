---
title: "validate_path"
description: "Stable function · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `validate_path` | not exported | `validate_path` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
validate_path(path::AbstractString)
```

```julia
validate_path(path::AbstractString) -> ValidationResult
```

Validate the document at `path`, INCLUDING the failures that happen while
loading it; [`validate`](/generated/api/ref/validate) itself takes a TYPED document in every binding
(API_SPEC.md §8 item 13). A load failure is a verdict, not an exception, as in
[`validate_text`](/generated/api/ref/validate_text), which renders it the same way. `load_path` still
throws, for callers that want the exception.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/validation/validate.jl#L425)

**Example** (`validate`)

```julia
result = validate(doc)
@assert result isa ValidationResult
@assert result.is_valid

# A document that loads fine but uses a variable it never declares. Validation
# reports the problem in the result rather than throwing.
bad = validate_path(joinpath(FIXTURES, "invalid.esm"))
@assert !bad.is_valid
err = only(bad.structural_errors)
println(err.path, ": ", err.message)
@assert err.message == "Variable 'k' referenced in equation is not declared"
@assert err.path == "/models/Broken/equations/0/rhs"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/julia/documents.jl#L19-L30">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
validate_path(path: str, *, base_path: str | None = None) -> ValidationResult
```

Validate the ESM document stored at `path` (API_SPEC.md §8 item 13).

Convenience over `validate(load_path(path))` that additionally reports a
LOAD failure as a [`ValidationResult`](/generated/api/ref/validation_result) instead of raising.
`base_path` defaults to the file's own directory inside [`load_path`](/generated/api/ref/load_path),
so relative §4.7 mounts resolve without being told where they are.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-py/src/earthsci_ast/validation.py#L501)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/python/documents.py#L38-L56">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
