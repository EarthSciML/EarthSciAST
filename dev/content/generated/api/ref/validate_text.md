---
title: "validate_text"
description: "Stable function · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `validate_text` | `validateText` | `validate_text` | `validate_complete`, `validate_text` | `ValidateText` |


**Note:** spelling differs from the §2 rule: rust=validate_complete (expected validate_text); multiple spellings exported by: rust


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
validate_text(text::AbstractString; base_path)
```

```julia
validate_text(text::AbstractString; base_path=pwd()) -> ValidationResult
```

Validate an ESM document held as JSON **text**, INCLUDING the failures that
happen while loading it.

The text twin of [`validate_path`](/generated/api/ref/validate_path), and the same shape: `validate` itself
takes a TYPED document in every binding (API_SPEC.md §8 item 13), and the two
convenience entry points that do the reading carry names that say so.

The same function exists in every binding: Go `ValidateText`, Python
`validate_text`, Rust `validate_text`, TypeScript `validateText`.

A load failure becomes a **verdict** in the returned `ValidationResult` rather
than an exception. A caller asking "is this document valid?" wants an answer for
a malformed document too, and this is the entry point that has to give one: text
is the only input that can carry SCHEMA errors at all, since a typed `EsmFile`
can exist only by having already passed the schema at load. Measured against the
other four before writing this — Python's `validate_text` and Go's `ValidateText`
both return `is_valid=false` with populated `schema_errors` for schema-invalid
AND for malformed text, and neither raises — so three channels are rendered:

- a `SchemaValidationError` carries its structured `SchemaError`s straight
  through into `schema_errors`;
- an ordinary `ParseError` (no `code`) is malformed JSON: not a schema
  violation of any node, so it becomes one `SchemaError` at the document root
  under the `parse` keyword, which is where Go and Python put it too;
- a rejection carrying a `(code, path)` shape — an unresolvable `{ref}`, the
  §11.4.1 `ic_in_reaction_system` case — becomes a `StructuralError`, through
  the same `load_failure_structural_error` [`validate_path`](/generated/api/ref/validate_path)
  uses.

Anything else still propagates.

> **Note**
>
> [`validate_path`](/generated/api/ref/validate_path) renders only the third of those three and still
> RAISES on schema-invalid or malformed input, so the two entry points
> differ on bad input.

`base_path` anchors relative §9.7.2 template imports and §4.7 `{ref}`s, since
text carries no location of its own. Note that `load_string` does not resolve
subsystem `$ref` MOUNTS — a document carrying those wants
`validate_path` — the same split Python and Go document for their text entry
points.

**Examples**
```julia
result = validate_text(read("model.esm", String); base_path=dirname("model.esm"))
result.is_valid
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/validate.jl#L822)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function validateText(text: string, options?: ValidateOptions): ValidationResult
```

Validate ESM JSON **text**: parse it, then run [`validate`](/generated/api/ref/validate) on the result.

A malformed document does not throw — it comes back as a `ValidationResult`
carrying a single `json_parse_error` schema error, the same envelope the old
string-accepting `validate()` produced.

The canonical name is `validate_text` (API_SPEC.md §8 item 13). There is no
`validatePath` counterpart in this binding: `@earthsciml/ast` is built for
the browser as well as Node, and the package has no filesystem story on the
public surface for a synchronous read. Read the file yourself and call
`validateText`, passing `basePath` so relative `{ref}` targets still resolve.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/validate/orchestrator.ts#L499)

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
validate_text(text: str, *, base_path: str | None = None) -> ValidationResult
```

Validate an ESM document held as JSON **text** (API_SPEC.md §8 item 13).

Convenience over `validate(load_string(text))` that additionally reports a
LOAD failure as a [`ValidationResult`](/generated/api/ref/validation_result) instead of raising. Text carries
no location of its own, so pass `base_path` when the document has relative
§4.7 mounts or §9.7.2 template imports — a conformance harness holding
fixture text should pass the fixture's directory.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/validation.py#L426)

**Example** (`validate_text`)

```python
bad_text = (FIXTURES / "invalid.esm").read_text()
report = earthsci_ast.validate_text(bad_text)
assert [e.code for e in report.structural_errors] == ["undefined_variable"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L61-L63">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

Exported as `validate_complete` and `validate_text`. Both names refer to the same operation.

**`validate_complete`**

```rust
pub fn validate_complete(json_str: &str, base_path: Option<&Path>) -> ValidationResult
```

**Deprecated** since 0.2.0: renamed to `validate_text` (API_SPEC.md §8 item 13)

Deprecated alias of [`validate_text`](/generated/api/ref/validate_text).

API_SPEC.md §8 item 13 makes `validate` take a typed document everywhere
and names the text convenience `validate_text`. This alias is deprecated
and will be removed at the next major (API_SPEC.md §10).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/validate.rs#L707) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.validate_complete.html)

**`validate_text`**

```rust
pub fn validate_text(json_str: &str, base_path: Option<&Path>) -> ValidationResult
```

Validate an ESM file completely (schema + structural validation)

This is the main validation function that performs both schema and structural validation.
Most users should use this function instead of the lower-level `validate()`.

**Arguments**

* `json_str` - The original JSON string to validate
* `base_path` - Directory anchoring relative §4.7 subsystem refs and §9.7
  template-import refs (esm-spec §9.7.2). `None` anchors them at the process
  current directory; a caller that loaded the
  document from a known file MUST pass the file's own directory so relative
  refs resolve the same way `load_path` resolves them — otherwise a valid
  document with relative refs is wrongly rejected.

**Returns**

* `ValidationResult` - Comprehensive validation results with both schema and structural errors

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/validate.rs#L628) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.validate_text.html)

**Example** (`validate`)

```rust
let good = load_path(fixture("decay.esm"))?;
let result = validate(&good);
assert!(result.is_valid);
assert!(result.schema_errors.is_empty() && result.structural_errors.is_empty());

// invalid.esm is well-formed JSON that matches the schema, so it loads;
// validation then reports the undeclared variable `k` as a structural
// error. Validation returns a result object, it does not fail.
let bad = load_path(fixture("invalid.esm"))?;
let result = validate(&bad);
assert!(!result.is_valid);
for err in &result.structural_errors {
    println!("{}: [{:?}] {}", err.path, err.code, err.message);
}
assert!(result.structural_errors.iter().any(|e| e.message.contains("'k'")));

// `validate_text` starts from the JSON text, so a document that does not
// even load is reported in the same result shape instead of as an error.
let text = std::fs::read_to_string(fixture("invalid.esm"))?;
let from_text = validate_text(&text, None);
assert!(!from_text.is_valid);
let not_json = validate_text("{ \"esm\": ", None);
assert!(!not_json.is_valid);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/validate.rs#L8-L30">docs/api/examples/rust/validate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ValidateText(jsonStr string, opts ...LoadOption) *ValidationResult
```

ValidateText validates an ESM document supplied as JSON TEXT: the schema check the document AS WRITTEN must pass, then — only if it passes — the semantic checks Validate runs over the parsed form.

Canonical `validate_text` (API\_SPEC.md §8 item 13). Text is the only input that can carry SCHEMA errors, so text is where the schema pass belongs.

LoadOptions are forwarded to the parse. WithBasePath is the one that matters for text read from disk: it is what lets relative §9.7 template-library imports resolve. Subsystem `$ref` MOUNTS are resolved by LoadPath and not by LoadString, so a document carrying those wants LoadPath followed by Validate rather than ValidateText — the same split the conformance adapter makes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/validate.go#L170) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ValidateText)

**Example** (`validate`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
fmt.Println(esm.Validate(doc).IsValid)

// invalid.esm is schema-clean but its equation reads an undeclared `k`.
text, err := os.ReadFile(fixture("invalid.esm"))
if err != nil {
	log.Fatal(err)
}
result := esm.ValidateText(string(text))
fmt.Println(result.IsValid)
for _, e := range result.StructuralErrors {
	fmt.Println(e.Code, e.Path)
	fmt.Println(e.Message)
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/validate_test.go#L15-L31">docs/api/examples/go/validate_test.go</a></p>

</div>

</div>
