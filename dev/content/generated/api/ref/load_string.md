---
title: "load_string"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `load_string` | `loadString` | `load_string` | `load_string` | `LoadString` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
load_string(json::AbstractString; base_path, metaparameters, injected_imports)
load_string(io::IO; base_path, metaparameters, injected_imports)
```

```julia
load_string(json::AbstractString; base_path=nothing, metaparameters=Dict{String,Int}()) -> EsmFile
load_string(io::IO; base_path=nothing, metaparameters=Dict{String,Int}()) -> EsmFile
```

Parse an ESM document from JSON TEXT — held as a `String`, or streamed from an
`IO` the method reads to a string first (the `::IO` method is a sanctioned
Julia decoration on the canonical `load_string`, not a fourth entry point:
`JSON3.read` and `read` accept both shapes too).

Runs the SAME pipeline [`load_path`](/generated/api/ref/load_path) and [`load_document`](/generated/api/ref/load_document) run —
`_load_document`: top-level `{ref}` inlining, version gates, schema
validation, template lowering, coercion, and nested subsystem-ref resolution.
(Before that was shared, a stream-loaded document kept its subsystem refs as
unresolved `SubsystemRef`s, which `flatten` silently SKIPS: the same document
loaded from a stream flattened to a strictly smaller system, with no error.)
`base_path` anchors relative `expression_template_imports` refs and nested
`{ref}`s (esm-spec §9.7.2, §4.7), defaulting to `pwd()` for that; left at
`nothing` the document has no location of its own, so a relative
`coupling_import` ref resolves against `flatten`'s own `base_path` instead
(§10.10 -> §4.7). `metaparameters` binds the document's open metaparameters at
the loader API (esm-spec §9.7.6).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/resolve.jl#L318)

**Example** (`load`)

```julia
doc = load_path(joinpath(FIXTURES, "decay.esm"))
@assert doc isa EsmFile
@assert collect(keys(doc.models)) == ["Decay"]

# The same document from a JSON string already in memory.
json = read(joinpath(FIXTURES, "decay.esm"), String)
from_string = load_string(json)
@assert collect(keys(from_string.models)) == ["Decay"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/documents.jl#L7-L14">docs/api/examples/julia/documents.jl</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/documents.jl#L33-L51">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function loadString(json: string, options?: LoadOptions): EsmFile
```

Parse an ESM document from JSON TEXT.

**Parameters**

- `json` — The document as a JSON string
- `options` — Optional load-time settings (see [`LoadOptions`](/generated/api/ref/load_options))

**Returns**

Typed EsmFile object

**Throws**

- [`ParseError`](/generated/api/ref/parse_error) — When JSON parsing fails or version is incompatible
- [`SchemaValidationError`](/generated/api/ref/schema_validation_error) — When schema validation fails

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/parse.ts#L391)

**Example** (`load`)

```typescript
// From a file on disk:
const doc = loadPath(decayPath)
assert.deepEqual(Object.keys(doc.models ?? {}), ['Decay'])
assert.equal(doc.metadata.name, 'Decay')

// From JSON text you already hold (a fetch response, a database row, ...):
const text = readFileSync(decayPath, 'utf8')
const same = loadString(text)
const model = same.models!.Decay
// A `models` entry is a Model or, before `resolveSubsystemRefs`, a `{ ref }` mount.
assert.ok(!('ref' in model))
assert.deepEqual(Object.keys(model.variables), ['N', 'lambda', 'half_life'])
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/load.ts#L11-L22">docs/api/examples/typescript/load.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
load_string(json_text: str, *, metaparameters: dict[str, int] | None = None, base_path: str | os.PathLike[str] | None = None) -> EsmFile
```

Parse an ESM document from JSON TEXT.

**Parameters**

- `json_text` (`str`) — The document as a JSON string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L2881)

**Example** (`load`)

```python
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
assert list(doc.models) == ["Decay"]

text = (FIXTURES / "decay.esm").read_text()
same = earthsci_ast.load_string(text)
assert list(same.models["Decay"].variables) == ["N", "lambda", "half_life"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L14-L19">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn load_string(json_str: &str) -> Result<EsmFile, EsmError>
```

Load and parse an ESM file from JSON string

This function performs both JSON parsing and schema validation.
It will throw an error for malformed JSON or schema violations.

**Arguments**

* `json_str` - The JSON string to parse

**Returns**

* `Ok(EsmFile)` - Successfully parsed and validated ESM file
* `Err(EsmError)` - Parse error or schema validation error

**Examples**

```rust
use earthsci_ast::load_string;

let json = r#"
{
  "esm": "1.0.0",
  "metadata": {
    "name": "test_model"
  },
  "models": {
    "simple": {
      "variables": {},
      "equations": []
    }
  }
}
"#;

let esm_file = load_string(json).expect("Failed to load ESM file");
assert_eq!(esm_file.esm, "1.0.0");
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/parse.rs#L93) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.load_string.html)

**Example** (`load`)

```rust
let doc = load_path(fixture("decay.esm"))?;
let models = doc.models.as_ref().expect("decay.esm has models");
assert_eq!(models.keys().collect::<Vec<_>>(), ["Decay"]);
assert_eq!(doc.metadata.name.as_deref(), Some("Decay"));

let text = std::fs::read_to_string(fixture("decay.esm"))?;
let same = load_string(&text)?;
assert_eq!(same.models.as_ref().unwrap().len(), 1);

// A document that is not valid JSON is an error, not a panic.
assert!(load_string("{ not json").is_err());
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/load.rs#L12-L22">docs/api/examples/rust/load.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func LoadString(jsonStr string, opts ...LoadOption) (*ESMFile, error)
```

LoadString parses an ESM file from JSON TEXT and validates it against the JSON schema

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/parse.go#L326) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LoadString)

**Example** (`load`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
fmt.Println(sortedKeys(doc.Models))

text, err := os.ReadFile(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
fromText, err := esm.LoadString(string(text))
if err != nil {
	log.Fatal(err)
}
fmt.Println(fromText.Metadata.Name, len(fromText.Models["Decay"].Equations))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/load_test.go#L14-L28">docs/api/examples/go/load_test.go</a></p>

</div>

</div>
