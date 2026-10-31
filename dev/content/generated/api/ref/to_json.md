---
title: "to_json"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `to_json` | `toJson` | `to_json` | `to_json` | `ToJSON` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
to_json(graph::Graph{ComponentNode, CouplingEdge})
to_json(graph::Graph{VariableNode, DependencyEdge})
to_json(file::EsmFile)
```

```julia
to_json(file::EsmFile) -> String
```

Serialize an `EsmFile` to wire-form JSON. PURE — it never touches disk;
[`write_path`](/generated/api/ref/write_path) is the writer.

No function in this API both writes and hands back the payload.

Takes no `indent` option, unlike the Python and TypeScript twins: JSON3 emits
the single-line form and its `indent=` keyword is a silent no-op in the pinned
version, and offering an option that does nothing would be worse than not
offering it. (Byte-canonical output is a separate concern
with its own path — see `emit_esm_string` / esm-spec §9.6.4 rule 5.)

A document carrying surviving template references emits in the canonical
reference-preserving byte form instead.

---

```julia
to_json(graph::Graph) -> String
```

Deprecated alias of [`to_json_graph`](/generated/api/ref/to_json_graph), kept one minor per API_SPEC.md
§10. `to_json` is the document serializer (`to_json(::EsmFile)` in
serialize.jl); these two `Graph` methods are the pre-§8 spelling of the graph
renderer and delegate to it unchanged.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/serialize.jl#L570)

**Example** (`edit`)

```julia
doc = load_path(joinpath(FIXTURES, "decay.esm"))
model = doc.models["Decay"]

# Edits return a new Model; the original is left alone.
decayed = ModelVariable(
    UnknownVariable; default = 0.0, units = "mol",
    description = "Amount that has decayed"
)
edited = add_variable(model, "decayed", decayed)
edited = add_equation(edited, parse_equation("D(decayed, t) = lambda * N"))
@assert ode_states(model) == ["N"]
@assert ode_states(edited) == ["N", "decayed"]

doc.models["Decay"] = edited
@assert validate(doc).is_valid

json = to_json(doc)
@assert occursin("\"decayed\"", json)

path = joinpath(mktempdir(), "decay_edited.esm")
write_path(doc, path)
reloaded = load_path(path)
@assert sort(ode_states(reloaded.models["Decay"])) == ["N", "decayed"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/editing.jl#L7-L29">docs/api/examples/julia/editing.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function toJson(file: EsmFile, options?: ToJsonOptions): string
```

Serialize an `EsmFile` to wire-form JSON. PURE — it never touches disk;
[`writePath`](/generated/api/ref/write_path) is the writer.

**Parameters**

- `file` — The `EsmFile` to serialize.
- `options` — Optional behavior controls (see [`ToJsonOptions`](/generated/api/extension/typescript#x-tojsonoptions)).

**Returns**

Wire-form JSON string.

**Throws**

- `CanonicalNonfiniteError` — In `canonical: true` mode, if a
    `NumericLiteral` leaf holds NaN or ±Infinity (RFC §5.4.6 forbids
    non-finite numbers in the canonical wire form).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/serialize.ts#L76)

**Example** (`edit`)

```typescript
const doc = loadPath(fixture('decay.esm'))
const model = doc.models!.Decay
assert.ok(!('ref' in model)) // narrows away an unresolved `{ ref }` mount

// Edits never mutate: each returns a new model.
const withVar = addVariable(model, 'fraction', {
  type: 'unknown',
  units: '1',
  description: 'Fraction of the initial amount remaining',
})
const edited = addEquation(withVar, parseEquation('fraction = N / 100'))
assert.equal(model.equations.length, 2)
assert.equal(edited.equations.length, 3)
assert.deepEqual(observedUnknowns(edited), ['fraction', 'half_life'])

const newDoc = { ...doc, models: { ...doc.models, Decay: edited } }

// `toJson` returns the text; `writePath` writes it and returns nothing.
const json = toJson(newDoc)
const reloaded = loadString(json).models!.Decay
assert.match(json, /"fraction"/)

const outPath = join(outDir, 'decay_edited.esm')
writePath(newDoc, outPath)
assert.equal(readFileSync(outPath, 'utf8'), json)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/edit.ts#L22-L47">docs/api/examples/typescript/edit.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
to_json(esm_file: EsmFile, *, indent: int | None = 2) -> str
```

Serialize an ESM file to a JSON string. PURE — never touches disk.

To write a file, use [`write_path`](/generated/api/ref/write_path).

**Parameters**

- `esm_file` (`EsmFile`) — The EsmFile object to serialize
- `indent` (`int | None`) — Indentation for the emitted JSON; `None` or `0` for the
  single-line compact form (see [`to_json_compact`](/generated/api/ref/to_json_compact))

**Returns**

- `str` — JSON string representation of the ESM file

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/serialize.py#L1252)

**Example** (`edit`)

```python
# Edits return a new model in `modified_object`; the input is left unchanged.
edited = earthsci_ast.add_variable(
    model, "N0", ModelVariable(type="parameter", units="mol", default=100.0)
).modified_object
edited = earthsci_ast.add_variable(
    edited, "fraction", ModelVariable(type="unknown", units="1")
).modified_object
step = earthsci_ast.add_equation(
    edited, Equation(lhs="fraction", rhs=ExprNode(op="/", args=["N", "N0"]))
)
assert step.success, step.errors
doc.models["Decay"] = step.modified_object
assert "fraction" not in model.variables  # the original model is untouched

assert earthsci_ast.validate(doc).is_valid
assert earthsci_ast.observed_unknowns(doc.models["Decay"]) == ["fraction", "half_life"]

text = earthsci_ast.to_json(doc)
assert json.loads(text)["models"]["Decay"]["equations"][-1] == {
    "lhs": "fraction",
    "rhs": {"op": "/", "args": ["N", "N0"]},
}

with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "decay_edited.esm"
    earthsci_ast.write_path(doc, out)
    reread = earthsci_ast.load_path(out)
assert list(reread.models["Decay"].variables) == ["N", "lambda", "half_life", "N0", "fraction"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L111-L138">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn to_json(esm_file: &EsmFile) -> Result<String, EsmError>
```

Serialize an ESM file to JSON string

This function converts an `EsmFile` struct back to a JSON string.
The output will be pretty-printed for human readability.

**Arguments**

* `esm_file` - The ESM file to serialize

**Returns**

* `Ok(String)` - Successfully serialized JSON string
* `Err(EsmError)` - Serialization error

**Examples**

```rust
use earthsci_ast::{EsmFile, Metadata, to_json};

let esm_file = EsmFile {
    esm: "1.0.0".to_string(),
    metadata: Metadata {
        name: Some("test_model".to_string()),
        ..Default::default()
    },
    ..Default::default()
};

let json = to_json(&esm_file).expect("Failed to serialize ESM file");
assert!(json.contains("\"esm\": \"1.0.0\""));
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/serialize.rs#L37) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.to_json.html)

**Example** (`edit`)

```rust
let mut doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];

// Track the decay product M. Edits return a new model; the input is
// left unchanged.
let product = ModelVariable {
    var_type: VariableType::Unknown,
    units: Some("mol".to_string()),
    default: Some(0.0.into()),
    description: Some("Amount produced".to_string()),
    default_units: None,
    element_type: None,
    shape: None,
    location: None,
    distribution: None,
    update: None,
};
let model = add_variable(model, "M", product)?;
let model = add_equation(&model, parse_equation("D(M)/Dt = lambda * N")?)?;
assert_eq!(model.variables.len(), 4);
assert_eq!(model.equations.len(), 3);

// Adding a name that is already declared is an error.
assert!(add_variable(&model, "N", model.variables["N"].clone()).is_err());

doc.models.as_mut().unwrap().insert("Decay".to_string(), model);

let json = to_json(&doc)?;
assert!(json.contains("\"M\""));

let out = std::env::temp_dir().join("decay_with_product.esm");
write_path(&doc, &out)?;
let reread = load_string(&std::fs::read_to_string(&out)?)?;
assert_eq!(reread.models.as_ref().unwrap()["Decay"].variables.len(), 4);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/edit.rs#L12-L45">docs/api/examples/rust/edit.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ToJSON(file *ESMFile) (string, error)
```

ToJSON validates an ESM file and returns it as an indented canonical JSON string. PURE — it never touches disk; WritePath is the writer.

Go was the only binding whose NAMES already distinguished serializing from writing (Serialize/SaveToFile) — and the only one whose names matched nobody else's. These are those functions under the shared names.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/serialize.go#L102) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ToJSON)

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

</div>

</div>
