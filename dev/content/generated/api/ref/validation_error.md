---
title: "validation_error"
description: "Stable type · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `ValidationError` | `ValidationError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface ValidationError {
    path: string;
    message: string;
    code: string;
    details: Record<string, unknown>;
}
```

Validation error with structured details

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/validate/types.ts#L13)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/validate.ts#L11-L34">docs/api/examples/typescript/validate.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ValidationError
ValidationError(path: str, message: str, code: str = '', details: dict[str, Any] = None)
```

Represents a single validation error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/validation.py#L51)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L38-L56">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this type.</p>

</div>

</div>
