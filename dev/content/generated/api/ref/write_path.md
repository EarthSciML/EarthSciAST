---
title: "write_path"
description: "Stable function · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `write_path` | `writePath` | `write_path` | `write_path` | `WritePath` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
write_path(file::EsmFile, path::AbstractString)
```

```julia
write_path(file::EsmFile, path::AbstractString) -> Nothing
```

Write an `EsmFile` to `path` as wire-form JSON. Returns `nothing`: call
[`to_json`](/generated/api/ref/to_json) when you want the string. Argument order is data-first
(`write_path(file, path)`), matching `write(io, x)`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/EarthSciAST.jl/src/serialize.jl#L550)

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
# The new equation, read from Typst math under the names it uses.
eq = parse_math("(dif italic(\"decayed\"))/(dif t) = lambda N", ["decayed", "lambda", "N"], :typst)
edited = add_equation(edited, Equation(expression_from_json(eq["lhs"]), expression_from_json(eq["rhs"])))
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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/julia/editing.jl#L7-L31">docs/api/examples/julia/editing.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function writePath(file: EsmFile, path: string, options?: ToJsonOptions): void
```

Write an `EsmFile` to `path` as wire-form JSON. Returns nothing: no
function in this API both writes and hands back the payload — call
[`toJson`](/generated/api/ref/to_json) when you want the string.

Requires synchronous file access (Node).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-ts/src/serialize.ts#L130)

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
// The new equation, read from Typst math under the names it uses.
const fraction = parseMath('fraction = N/100', ['fraction', 'N'], 'typst') as Equation
const edited = addEquation(withVar, fraction)
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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/typescript/edit.ts#L23-L50">docs/api/examples/typescript/edit.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
write_path(esm_file: EsmFile, path: str | Path) -> None
```

Write an ESM file to `path` as JSON. Returns `None`: no function in
this API both writes and hands back the payload — call [`to_json`](/generated/api/ref/to_json)
when you want the string.

**Raises**

- `OSError` — If writing to file fails

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-py/src/earthsci_ast/serialize.py#L1298)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/python/documents.py#L120-L147">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn write_path<P: AsRef<Path>>(esm_file: &EsmFile, path: P) -> Result<(), EsmError>
```

Write an ESM file to `path` as pretty-printed JSON.

Returns `Ok(())`, never the payload: no function in this API both writes
and hands back the serialized bytes — call [`to_json`](/generated/api/ref/to_json) when you want the
string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-rs/src/serialize.rs#L109) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.write_path.html)

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
    lb: None,
    ub: None,
};
let model = add_variable(model, "M", product)?;
// The new equation, read from Typst math under the names it uses.
let names = ["M", "N", "lambda"].map(String::from);
let eq = parse_math("(dif M)/(dif t) = lambda N", &names, DocumentFormat::Typst)?;
let model = add_equation(&model, serde_json::from_value::<Equation>(eq)?)?;
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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/rust/edit.rs#L12-L50">docs/api/examples/rust/edit.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func WritePath(file *ESMFile, path string) error
```

WritePath writes an ESM file to path as indented canonical JSON. It returns only an error, never the payload: no function in this API both writes and hands back the serialized bytes — call ToJSON when you want the string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/pkg/earthsci-ast-go/pkg/esm/serialize.go#L154) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#WritePath)

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
// Typst math under the names it uses; an `=` at the top makes it an
// equation, a map with `lhs` and `rhs`.
read, err := esm.ParseMath("decayed = 100 - N", []string{"decayed", "N"}, esm.DocumentTypst)
if err != nil {
	log.Fatal(err)
}
sides := read.(map[string]any)
model = esm.AddEquation(model, esm.Equation{LHS: sides["lhs"], RHS: sides["rhs"]})
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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/9c3b4aa7587e650335b61c9c6c286eeeaab7f644/docs/api/examples/go/edit_test.go#L23-L57">docs/api/examples/go/edit_test.go</a></p>

</div>

</div>
