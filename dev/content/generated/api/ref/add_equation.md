---
title: "add_equation"
description: "Stable function · Editing"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Editing](/generated/api/topics/editing)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `add_equation` | `addEquation` | `add_equation`, `add_equation_to_model` | `add_equation` | `AddEquation` |


**Note:** spelling differs from the §2 rule: python=add_equation_to_model (expected add_equation); multiple spellings exported by: python


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
add_equation(model::Model, equation::Equation)
```

```julia
add_equation(model::Model, equation::Equation) -> Model
```

Add a new equation to a model.

Appends the equation to the end of the equations list.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/edit.jl#L203)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/editing.jl#L7-L29">docs/api/examples/julia/editing.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function addEquation(model: Model, equation: Equation): Model
```

Add a new equation to a model

**Parameters**

- `model` — Model to add equation to
- `equation` — Equation to add

**Returns**

New model with equation added

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/edit.ts#L177)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/edit.ts#L22-L47">docs/api/examples/typescript/edit.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

Exported as `add_equation` and `add_equation_to_model`. Both names refer to the same operation.

**`add_equation`**

```python
add_equation(model: Model, equation: Equation, validate_after_edit: bool = True) -> EditResult
```

Add an equation to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L775)

**`add_equation_to_model`**

```python
add_equation_to_model(model: Model, equation: Equation, validate_after_edit: bool = True) -> EditResult
```

Deprecated alias for [`add_equation`](/generated/api/ref/add_equation). Add an equation to a model.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/edit.py#L913)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L111-L138">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn add_equation(model: &Model, equation: Equation) -> EditResult<Model>
```

Add an equation to a model

**Arguments**

* `model` - The model to modify
* `equation` - The equation to add

**Returns**

* `EditResult<Model>` - New model with the added equation

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/edit.rs#L186) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.add_equation.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/edit.rs#L12-L45">docs/api/examples/rust/edit.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func AddEquation(model Model, equation Equation) Model
```

AddEquation returns a copy of `model` with `equation` appended.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/edit.go#L840) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AddEquation)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/edit_test.go#L23-L54">docs/api/examples/go/edit_test.go</a></p>

</div>

</div>
