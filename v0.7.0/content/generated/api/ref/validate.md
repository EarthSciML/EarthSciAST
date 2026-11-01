---
title: "validate"
description: "Stable function · Validation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Validation](/generated/api/topics/validation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `validate` | `validate` | `validate` | `validate` | `Validate` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
validate(file::EsmFile)
```

```julia
validate(file::EsmFile) -> ValidationResult
```

Complete validation combining schema, structural, and unit validation.
Returns ValidationResult with all errors and warnings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/validate.jl#L721)

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
function validate(document: EsmFile | object, options?: ValidateOptions): ValidationResult
```

Validate a TYPED ESM DOCUMENT and return a structured validation result.

API_SPEC.md §8 item 13: `validate` takes a typed document in EVERY binding.
To validate JSON text, call [`validateText`](/generated/api/ref/validate_text).

Passing a string is rejected at compile time by the signature and at runtime
by an explicit guard, rather than silently doing something else.

**Parameters**

- `document` — a loaded ESM document (or a plain object of the same shape)
- `options` — Optional `ValidateOptions`; pass `basePath` to let
    relative `{ref}` / template-import targets be opened and resolved.

**Returns**

ValidationResult with validation status and errors

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/validate/orchestrator.ts#L473)

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
validate(esm_file: EsmFile, *, base_path: str | None = None) -> ValidationResult
```

Validate a parsed ESM document against structural and unit requirements.

`esm_file` is a **typed** [`EsmFile`](/generated/api/ref/esm_file) — the
one input type `validate` accepts in every binding (API_SPEC.md §8
item 13). It does **not** accept a path, JSON text or a raw `dict`; use
the explicit entry points instead:

* a filesystem path -> [`validate_path`](/generated/api/ref/validate_path);
* JSON text -> [`validate_text`](/generated/api/ref/validate_text);
* an already-decoded `dict` -> `validate(load_document(data))`.

This function implements comprehensive validation including:
1. Equation-unknown balance
2. Reference integrity (variable refs, scoped refs, event affects, coupling refs, operator refs)
3. Reaction consistency (species declared, positive stoichiometries, no null-null, rate refs)
4. Event consistency (condition types, affect vars, functional affect refs)

**Parameters**

- `esm_file` (`EsmFile`) — The parsed [`EsmFile`](/generated/api/ref/esm_file) to validate.
- `base_path` (`str | None`) — Directory that relative `{"ref": ...}` subsystem/model mounts
  (§4.7) and `expression_template_imports` (§9.7.2) resolve against.

  A document that came through [`load_path`](/generated/api/ref/load_path) resolved its mounts
  already, so this mainly matters on the [`validate_text`](/generated/api/ref/validate_text) /
  [`validate_path`](/generated/api/ref/validate_path) paths, which forward it to the loader: text
  carries no location of its own, and without an anchor every
  subsystem-ref and template-import fixture becomes unsatisfiable. A
  MISSING target then yields `unresolved_subsystem_ref` (or the
  template-import equivalent) at the mount's pointer, and a PRESENT one
  validates through.

**Returns**

- `ValidationResult` — ValidationResult containing schema_errors, structural_errors, unit_warnings, and is_valid flag

**Raises**

- `TypeError` — if `esm_file` is not an [`EsmFile`](/generated/api/ref/esm_file).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/validation.py#L179)

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
pub fn validate(esm_file: &EsmFile) -> ValidationResult
```

Perform structural validation on an ESM file

**Note**: This function performs ONLY structural validation, not schema validation.
For comprehensive validation (both schema and structural), use `validate_text()` instead.

This function runs the structural checks (delegating to
`crate::structural` and `crate::coupling`):
- All variable references are defined (including scoped refs resolved via
  the subsystem hierarchy)
- Equation-unknown balance (ODE count vs. state variables)
- Observed variables carry expressions
- Discrete/continuous event references
- Reaction species/stoichiometry consistency
- Coupling-entry well-formedness
- Dimensional consistency of equations — reported as `unit_warnings`,
  never as errors

**Arguments**

* `esm_file` - The ESM file to validate (already parsed and schema-validated)

**Returns**

* `ValidationResult` - Structural validation results (schema_errors will always be empty)

**Examples**

```rust
use earthsci_ast::{validate, load_string, EsmFile, Metadata};

let json_str = r#"
{
  "esm": "1.0.0",
  "metadata": {"name": "test"},
  "models": {"simple": {"variables": {}, "equations": []}}
}
"#;

// First load and parse (includes schema validation)
let esm_file = load_string(json_str).unwrap();

// Then do structural validation
let result = validate(&esm_file);
assert!(result.is_valid);
assert!(result.schema_errors.is_empty()); // Always empty for this function
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/validate.rs#L481) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.validate.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/validate.rs#L8-L30">docs/api/examples/rust/validate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Validate(file *ESMFile) *ValidationResult
```

Validate performs semantic validation of an already-parsed ESM document and returns the four-field ValidationResult of esm-libraries-spec §3.4.

Canonical `validate` (API\_SPEC.md §8 items 12 and 13): the input is a TYPED DOCUMENT in every binding, and the return is the four-field shape in every binding. ValidateStructural still offers the message-oriented DetailedValidationResult form.

SchemaErrors is always EMPTY, exactly as Rust's `validate` documents: a \*ESMFile can only exist by having come through LoadString/LoadPath/ LoadDocument, all of which schema-validate and refuse to return a document that fails. Validating text that has NOT been through the schema is ValidateText's job.

IsValid counts hard structural errors only. Warning-level findings (StructuralError.Level == "warning", e.g. duplicate\_reaction\_species) are advisory and do not invalidate the document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/validate.go#L116) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Validate)

**Example** (`edit`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}

units, desc := "mol", "Amount decayed so far"
model := esm.AddVariable(doc.Models["Decay"], "decayed", esm.ModelVariable{
	Type: "unknown", Units: &units, Description: &desc,
})
eq, err := esm.ParseEquation("decayed = 100 - N")
if err != nil {
	log.Fatal(err)
}
model = esm.AddEquation(model, *eq)
doc.Models["Decay"] = model
fmt.Println(len(model.Equations), esm.Validate(doc).IsValid)

text, err := esm.ToJSON(doc)
if err != nil {
	log.Fatal(err)
}
fmt.Println(strings.Contains(text, `"decayed"`))

path := filepath.Join(dir, "decay-edited.esm")
if err := esm.WritePath(doc, path); err != nil {
	log.Fatal(err)
}
reread, err := esm.LoadPath(path)
if err != nil {
	log.Fatal(err)
}
fmt.Println(sortedKeys(reread.Models["Decay"].Variables))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/go/edit_test.go#L23-L54">docs/api/examples/go/edit_test.go</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/go/validate_test.go#L15-L31">docs/api/examples/go/validate_test.go</a></p>

</div>

</div>
