---
title: "validation_result"
description: "Stable type · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ValidationResult` | `ValidationResult` | `ValidationResult` | `ValidationResult` | `ValidationResult` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ValidationResult
ValidationResult(is_valid::Bool, schema_errors::Vector{SchemaError}, structural_errors::Vector{StructuralError}, unit_warnings::Vector{UnitWarning})
ValidationResult(is_valid, schema_errors, structural_errors, unit_warnings)
ValidationResult(schema_errors::Vector{SchemaError}, structural_errors::Vector{StructuralError}; unit_warnings)
```

```julia
ValidationResult
```

Combined validation result containing schema errors, structural errors,
unit warnings, and overall validation status.

The four-field shape (`is_valid`, `schema_errors`, `structural_errors`,
`unit_warnings`) is pinned by `ESM_COMPLIANCE_VALIDATION_MATRIX.md` VALID-03-A.

`unit_warnings` mirrors the TS/Python/Go bindings' `ValidationResult` shape:
unit findings appear both here (as [`UnitWarning`](/generated/api/ref/unit_warning) records) and as
promoted `unit_inconsistency` entries in `structural_errors`. Unit warnings
never affect `is_valid` on their own — the promoted structural errors do.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/validate.jl#L121)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/documents.jl#L18-L29">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface ValidationResult {
    is_valid: boolean;
    schema_errors: ValidationError[];
    structural_errors: ValidationError[];
    unit_warnings: UnitWarning[];
}
```

Structured validation result

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/validate/types.ts#L23)

**Example** (`validate`)

```typescript
// A good document validates cleanly.
const good = validate(loadPath(fixture('decay.esm')))
assert.equal(good.is_valid, true)
assert.deepEqual(good.structural_errors, [])

// `validate` reports problems in its result; it does not throw. invalid.esm
// uses a variable `k` that its model never declares.
const bad = validateText(readFileSync(fixture('invalid.esm'), 'utf8'))
assert.equal(bad.is_valid, false)
assert.equal(bad.schema_errors.length, 0)
const [err] = bad.structural_errors
assert.equal(err.code, 'undefined_variable')
assert.equal(err.path, '/models/Broken/equations/0/rhs')
assert.match(err.message, /Variable "k" referenced in equation is not declared/)

// Loading a structurally invalid document still succeeds. Unit warnings found
// while loading go to `console.warn` unless you collect them yourself.
const warnings: UnitWarning[] = []
const broken = loadPath(fixture('invalid.esm'), { onUnitWarning: (w) => warnings.push(w) })
assert.equal(validate(broken).is_valid, false)
assert.match(warnings[0].message, /Unknown variable: k/)

// Text that is not JSON at all is a `ParseError`, thrown at load time.
assert.throws(() => loadString('{ not json'), ParseError)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/typescript/validate.ts#L11-L34">docs/api/examples/typescript/validate.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ValidationResult
ValidationResult(is_valid: bool, schema_errors: list[ValidationError], structural_errors: list[ValidationError], unit_warnings: list[UnitWarning] = None)
```

Represents the result of validation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/validation.py#L114)

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

```rust
pub struct ValidationResult {
    pub schema_errors: Vec<SchemaError>,
    pub structural_errors: Vec<StructuralError>,
    pub unit_warnings: Vec<UnitWarning>,
    pub is_valid: bool,
}

impl ValidationResult { pub fn has_errors(&self) -> bool }

impl ValidationResult { pub fn errors(&self) -> Vec<StructuralError> }
```

Result of structural validation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/validate.rs#L24) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ValidationResult.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ValidationResult struct {
	SchemaErrors     []SchemaError     `json:"schema_errors"`
	StructuralErrors []StructuralError `json:"structural_errors"`
	UnitWarnings     []UnitWarning     `json:"unit_warnings"`
	IsValid          bool              `json:"is_valid"`
}
```

ValidationResult holds the result of validation per ESM Libraries Spec Section 3.4

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/validate.go#L75) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ValidationResult)

</div>

</div>
