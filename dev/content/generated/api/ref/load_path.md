---
title: "load_path"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `load_path` | `loadPath` | `load_path` | `load_path` | `LoadPath` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
load_path(path::AbstractString; metaparameters)
```

```julia
load_path(path::AbstractString; metaparameters=Dict{String,Int}()) -> EsmFile
```

Read and parse an ESM document from a filesystem path.
Automatically resolves any subsystem references (local or remote) relative
to the directory containing the file. `metaparameters` binds the ROOT
document's open metaparameters at the loader API (esm-spec §9.7.6 binding
site 4): already-closed edge bindings win, API bindings beat `default`s.

One of three load entry points, each named for what its argument is: a file
path here, JSON text for [`load_string`](/generated/api/ref/load_string), and an already-parsed document
for [`load_document`](/generated/api/ref/load_document).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/resolve.jl#L59)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/documents.jl#L7-L14">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function loadPath(path: string, options?: LoadOptions): EsmFile
```

Read and parse an ESM document from a filesystem path.

The file's own directory anchors relative `expression_template_imports`
refs and `{ref}` subsystem refs unless `options.basePath` overrides it.
Requires synchronous file access (Node); browser hosts should read the
bytes themselves and call [`loadString`](/generated/api/ref/load_string).

**Parameters**

- `path` — Filesystem path to the `.esm` document
- `options` — Optional load-time settings (see [`LoadOptions`](/generated/api/ref/load_options))

**Returns**

Typed EsmFile object

**Throws**

- [`ParseError`](/generated/api/ref/parse_error) — When JSON parsing fails or version is incompatible
- [`SchemaValidationError`](/generated/api/ref/schema_validation_error) — When schema validation fails

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/parse.ts#L376)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/load.ts#L11-L22">docs/api/examples/typescript/load.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
load_path(path: str | Path, *, metaparameters: dict[str, int] | None = None, base_path: str | os.PathLike[str] | None = None) -> EsmFile
```

Read and parse an ESM document from a filesystem path.

`base_path` defaults to the file's own directory.

**Parameters**

- `path` (`str | Path`) — Filesystem path to the `.esm` document.
- `metaparameters` (`dict[str, int] | None`) — See [`load_string`](/generated/api/ref/load_string).
- `base_path` (`str | os.PathLike[str] | None`) — Overrides the file's own directory as the ref anchor.

**Raises**

- `FileNotFoundError` — If the file path doesn't exist.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/parse.py#L2623)

**Example** (`load`)

```python
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
assert list(doc.models) == ["Decay"]

text = (FIXTURES / "decay.esm").read_text()
same = earthsci_ast.load_string(text)
assert list(same.models["Decay"].variables) == ["N", "lambda", "half_life"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L14-L19">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn load_path<P: AsRef<Path>>(path: P) -> Result<EsmFile, EsmError>
```

Load an ESM file from a filesystem path.

Reads the file, resolves any subsystem references relative to the file's
directory, validates against the schema, and deserializes into an
[`EsmFile`](/generated/api/ref/esm_file).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/parse.rs#L435) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.load_path.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/load.rs#L12-L22">docs/api/examples/rust/load.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func LoadPath(path string, opts ...LoadOption) (*ESMFile, error)
```

LoadPath reads an ESM document from the specified filesystem path and validates it against the JSON schema. After parsing, it resolves any subsystem references relative to the file's directory.

It takes a filesystem path; LoadString takes JSON text and LoadDocument an already-decoded document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/parse.go#L91) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LoadPath)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/edit_test.go#L23-L54">docs/api/examples/go/edit_test.go</a></p>

**Example** (`flatten`)

```go
doc, err := esm.LoadPath(fixture("coupled.esm"))
if err != nil {
	log.Fatal(err)
}
flat, err := esm.Flatten(doc)
if err != nil {
	log.Fatal(err)
}
for _, v := range flat.StateVariables {
	fmt.Println("state:", v.Name)
}
for _, v := range flat.Parameters {
	fmt.Println("parameter:", v.Name)
}
for _, eq := range flat.Equations {
	fmt.Println(esm.ToASCII(eq.LHS), "=", esm.ToASCII(eq.RHS))
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/flatten_test.go#L14-L30">docs/api/examples/go/flatten_test.go</a></p>

**Example** (`inspect`)

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
for _, name := range sortedKeys(doc.Models) {
	model := doc.Models[name]
	fmt.Println(name, sortedKeys(model.Variables))

	fmt.Println("ODE states:", esm.ODEStates(&model))
	fmt.Println("observed:", esm.ObservedUnknowns(&model))
	fmt.Println("algebraic:", esm.AlgebraicUnknowns(&model))
	fmt.Println("constant parameters:", esm.ConstantParameters(&model))

	fmt.Println(esm.IsODEState(&model, "N"), esm.IsODEState(&model, "half_life"))
	if def, ok := esm.ObservedDefinition(&model, "half_life"); ok {
		fmt.Println("half_life =", esm.ToASCII(def))
	}
}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/inspect_test.go#L14-L31">docs/api/examples/go/inspect_test.go</a></p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/load_test.go#L14-L28">docs/api/examples/go/load_test.go</a></p>

**Example** (`reactions`)

```go
doc, err := esm.LoadPath(fixture("ozone.esm"))
if err != nil {
	log.Fatal(err)
}
system := doc.ReactionSystems["Ozone"]
odes, err := esm.DeriveODEs(&system)
if err != nil {
	log.Fatal(err)
}
for _, eq := range odes.Equations {
	fmt.Println(esm.ToASCII(eq.LHS), "=", esm.ToASCII(eq.RHS))
}

// One row per species, one column per reaction.
fmt.Println(esm.StoichiometricMatrix(&system))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/reactions_test.go#L13-L27">docs/api/examples/go/reactions_test.go</a></p>

</div>

</div>
