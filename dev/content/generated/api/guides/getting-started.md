---
title: "Getting started"
description: "Load a document, check it, look inside, print it, change it, flatten a coupled one, derive a reaction system's equations, and simulate."
weight: 10
api_tabs: true
---

This guide takes one small document through everything a binding does with
it, in the order you would usually meet those steps. Each step shows the same
task in every binding; pick your language on any tab and the rest of the site
follows. Every snippet is cut from a program that runs, and checks its own
result, in CI.

The examples use four small documents from
[`docs/api/examples/fixtures/`](https://github.com/EarthSciML/EarthSciAST/tree/main/docs/api/examples/fixtures):

- `decay.esm` — one model, `Decay`: an amount `N` that decays at rate
  `lambda`, with its half-life as an observed quantity, `half_life = ln 2 / lambda`.
- `invalid.esm` — a model whose equation uses a variable, `k`, that it never
  declares.
- `coupled.esm` — two models, `Heater` and `Box`, where the heater's
  temperature is mapped onto the box's wall temperature.
- `ozone.esm` — the NO–NO₂–O₃ photostationary cycle written as a reaction
  system of two reactions.

## Load a document

A document can be read from a file path or from a string of JSON. Either way,
loading parses the JSON, checks it against the schema, and runs the load-time
passes a document needs before it can be used, such as resolving subsystem
references and expanding expression templates. A document that is not valid
JSON, or does not match the schema, fails here with an error. The result is the binding's
in-memory document, whose sections mirror the file: its `models`,
`reaction_systems`, `coupling` and so on.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

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

</div>

</div>


See [`load_path`](/generated/api/ref/load_path),
[`load_string`](/generated/api/ref/load_string) and
[`load_document`](/generated/api/ref/load_document) for the options each one
takes.

## Validate it

Loading already rejects a document that does not match the schema. Validation
goes further: it applies the structural rules of the specification, such as
every variable an equation uses being declared, and checks units. A document
can be valid JSON, match the schema, and still fail here, as `invalid.esm`
does: its equation multiplies by `k`, which no variable declares.

Validation reports rather than raises. It returns a result that says whether
the document is valid and lists what is wrong, sorted into schema errors,
structural errors and unit warnings, each with a diagnostic code that is the
same in every binding and a message for people.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/documents.jl#L18-L29">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/validate.ts#L11-L34">docs/api/examples/typescript/validate.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L38-L56">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/validate.rs#L8-L30">docs/api/examples/rust/validate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/validate_test.go#L15-L31">docs/api/examples/go/validate_test.go</a></p>

</div>

</div>


## Look inside: models, variables and their roles

A model's variables are declared as unknowns or parameters, but what each one
*is* depends on its equations. `N` has a time derivative, so it is a state that
a solver integrates. `half_life` is defined by an algebraic equation from a
parameter, so it is an observed quantity: computed from the others, never
integrated. `lambda` is a constant parameter. The classification functions
derive these roles the same way in every binding
([esm-spec §6.3.1](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-spec.md)).


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
model = doc.models["Decay"]
@assert sort(collect(keys(model.variables))) == ["N", "half_life", "lambda"]

# The two declared kinds...
@assert unknowns(model) == ["N", "half_life"]
@assert parameters(model) == ["lambda"]

# ...and what each unknown is, derived from the equations.
@assert ode_states(model) == ["N"]                 # has a D(N)/dt equation
@assert observed_unknowns(model) == ["half_life"]  # defined explicitly
@assert algebraic_unknowns(model) == String[]      # none solved implicitly

defs = observed_definitions(model)
@assert to_ascii(defs["half_life"]) == "log(2) / lambda"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/documents.jl#L55-L68">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const doc = loadPath(fixture('decay.esm'))
assert.deepEqual(Object.keys(doc.models ?? {}), ['Decay'])
const model = doc.models!.Decay
assert.ok(!('ref' in model)) // narrows away an unresolved `{ ref }` mount

// The document declares only `unknown` and `parameter`; everything else is derived.
assert.deepEqual(Object.keys(model.variables), ['N', 'lambda', 'half_life'])
assert.deepEqual(unknowns(model), ['N', 'half_life'])
assert.deepEqual(parameters(model), ['lambda'])

// N has a time derivative; half_life is defined by an explicit equation.
assert.deepEqual(odeStates(model), ['N'])
assert.deepEqual(observedUnknowns(model), ['half_life'])
assert.deepEqual(algebraicUnknowns(model), [])
assert.equal(isOdeState(model, 'N'), true)
assert.deepEqual(constantParameters(model), ['lambda'])
assert.equal(systemKind(model), 'ode')

// Each observed's defining expression:
const defs = observedDefinitions(model)
assert.equal(toAscii(defs.get('half_life')!), 'log(2) / lambda')
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/inspect.ts#L21-L41">docs/api/examples/typescript/inspect.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
model = doc.models["Decay"]
for name, var in model.variables.items():
    print(f"{name}: {var.type} [{var.units}]")
assert {n: v.type for n, v in model.variables.items()} == {
    "N": "unknown",
    "lambda": "parameter",
    "half_life": "unknown",
}

# The file declares only "unknown" and "parameter"; the finer classes are derived.
assert earthsci_ast.ode_states(model) == ["N"]
assert earthsci_ast.observed_unknowns(model) == ["half_life"]
assert earthsci_ast.algebraic_unknowns(model) == []
assert earthsci_ast.constant_parameters(model) == ["lambda"]
assert earthsci_ast.unknowns(model) == ["N", "half_life"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L68-L82">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];

// Declared variables, in document order, with their declared type.
for (name, var) in &model.variables {
    println!("{name}: {:?} [{}]", var.var_type, var.units.as_deref().unwrap_or(""));
}
assert_eq!(model.variables.keys().collect::<Vec<_>>(), ["N", "lambda", "half_life"]);
assert_eq!(model.variables["lambda"].var_type, VariableType::Parameter);

// Both N and half_life are declared `unknown`; their equations decide
// the class. `D(N) = ...` makes N a state, `half_life = ...` makes
// half_life an observed.
assert_eq!(ode_states(model), ["N"]);
assert_eq!(observed_unknowns(model), ["half_life"]);
assert!(algebraic_unknowns(model).is_empty());
assert_eq!(constant_parameters(model), ["lambda"]);
assert!(is_ode_state(model, "N") && !is_ode_state(model, "half_life"));
assert_eq!(system_kind(model), SystemKind::Ode);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/inspect.rs#L11-L29">docs/api/examples/rust/inspect.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

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

</div>

</div>


The [Variable classification](/generated/api/topics/classification) topic lists
the rest, including the parameter kinds for discrete, sampled and Brownian
parameters.

## Display equations

The display functions render an expression, an equation, or a larger part of
a document for people to read: plain text, Unicode with sub- and superscripts,
or LaTeX for papers and notebooks.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
decay_eq = model.equations[1]
println(to_unicode(decay_eq))
@assert to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
@assert to_latex(decay_eq) == raw"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
@assert to_ascii(decay_eq) == "D(N)/Dt = (-lambda) * N"

# Expressions display the same way.
@assert to_unicode(model.equations[2].rhs) == "ln(2)/λ"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/documents.jl#L72-L79">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const model = loadPath(fixture('decay.esm')).models!.Decay
const [decay, halfLife] = model.equations

assert.equal(toUnicode(decay), '∂N/∂t = (−λ)·N')
assert.equal(toLatex(decay), '\\frac{\\partial N}{\\partial t} = (-\\lambda) \\cdot N')
assert.equal(toAscii(decay), 'D(N)/Dt = (-lambda) * N')

// A single expression renders the same way.
assert.equal(toUnicode(halfLife.rhs), 'ln(2)/λ')

// So does a whole model: a summary line followed by its equations.
assert.equal(toUnicode(model).split('\n').length, 3)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/display.ts#L9-L21">docs/api/examples/typescript/display.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
decay_eq, half_life_eq = model.equations
print(earthsci_ast.to_unicode(decay_eq))
print(earthsci_ast.to_latex(decay_eq))
print(earthsci_ast.to_ascii(half_life_eq))
assert earthsci_ast.to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
assert earthsci_ast.to_latex(decay_eq) == r"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
assert earthsci_ast.to_ascii(half_life_eq) == "half_life = log(2) / lambda"

# A whole model renders as a one-line summary.
assert earthsci_ast.to_unicode(model) == "Model: Decay (1 state, 1 parameter, 1 observed, 2 equations)"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L97-L106">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
let doc = load_path(fixture("decay.esm"))?;
let model = &doc.models.as_ref().unwrap()["Decay"];
let decay = &model.equations[0];

let unicode = to_unicode(decay);
let latex = to_latex(decay);
let ascii = to_ascii(decay);
println!("{unicode}\n{latex}\n{ascii}");
assert_eq!(ascii, "D(N)/Dt = (-lambda) * N");
assert!(unicode.contains('λ'));
assert!(latex.contains("\\lambda"));

// The same functions take a single expression, or a whole model (which
// renders a summary).
assert_eq!(to_ascii(&model.equations[1].rhs), "log(2) / lambda");
assert!(to_unicode(model).contains("half_life"));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/display.rs#L8-L23">docs/api/examples/rust/display.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
doc, err := esm.LoadPath(fixture("decay.esm"))
if err != nil {
	log.Fatal(err)
}
model := doc.Models["Decay"]
decay := model.Equations[0]
fmt.Println(esm.ToUnicode(decay))
fmt.Println(esm.ToLatex(decay))
fmt.Println(esm.ToASCII(decay))

// A single expression renders the same way.
fmt.Println(esm.ToUnicode(model.Equations[1].RHS))
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/display_test.go#L13-L24">docs/api/examples/go/display_test.go</a></p>

</div>

</div>


## Build and change expressions

Expressions are trees of operators and their arguments. You can build one
directly, or parse it from text, then ask which variables it uses and
substitute values or other expressions into it.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
# Parse from text, or build the tree directly.
expr = parse_expression("k * x + y")
built = OpExpr("+", [OpExpr("*", [VarExpr("k"), VarExpr("x")]), VarExpr("y")])
@assert to_ascii(expr) == to_ascii(built) == "k * x + y"

@assert free_variables(expr) == Set(["k", "x", "y"])

# `substitute` takes a Dict{String,ASTExpr}: give the value type explicitly.
replaced = substitute(expr, Dict{String, ASTExpr}("y" => parse_expression("2 * x")))
@assert to_ascii(replaced) == "k * x + 2 * x"
@assert free_variables(replaced) == Set(["k", "x"])

# Constant subexpressions fold away.
@assert to_ascii(simplify(parse_expression("x * (1 + 1)"))) == "x * 2"

# An equation parses the same way, with D(x, t) for a time derivative.
eq = parse_equation("D(x, t) = -k * x")
@assert eq isa Equation
@assert to_unicode(eq) == "∂x/∂t = −k·x"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/expressions.jl#L5-L23">docs/api/examples/julia/expressions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
// Expressions are plain JSON trees; build one directly ...
const built: Expr = { op: '*', args: ['k', { op: '-', args: ['T_wall', 'T_air'] }] }

// ... or parse the text form, which is the inverse of `toAscii`.
const parsed = parseExpression('k * (T_wall - T_air)')
assert.deepEqual(parsed, built)
assert.deepEqual([...freeVariables(parsed)].sort(), ['T_air', 'T_wall', 'k'])
assert.equal(contains(parsed, 'T_wall'), true)

// Substitution is single-pass and returns a new tree.
const bound = substitute(parsed, { T_wall: 300, k: 0.05 })
assert.equal(toAscii(bound), '0.05 * (300 - T_air)')
assert.deepEqual([...freeVariables(bound)], ['T_air'])
assert.equal(toAscii(simplify(substitute(parsed, { T_wall: 300, T_air: 300 }))), '0')

const eq = parseEquation('D(T_air) = k * (T_wall - T_air)')
assert.deepEqual(eq.rhs, built)

assert.throws(() => parseExpression('k * (T_wall'), ExpressionParseError)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/expressions.ts#L16-L34">docs/api/examples/typescript/expressions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
# An expression is a number, a variable name, or an operator node.
exchange = ExprNode(op="*", args=["k", ExprNode(op="-", args=["T_wall", "T_air"])])
assert earthsci_ast.free_variables(exchange) == {"k", "T_wall", "T_air"}

# Text parses to the same tree that to_ascii prints.
parsed = earthsci_ast.parse_expression("k * (T_wall - T_air)")
assert earthsci_ast.to_ascii(parsed) == earthsci_ast.to_ascii(exchange)

# Substitution replaces names with numbers or with other expressions.
fixed = earthsci_ast.substitute(exchange, {"k": 0.05, "T_wall": ExprNode(op="+", args=["T0", 10])})
assert earthsci_ast.to_ascii(fixed) == "0.05 * (T0 + 10 - T_air)"
assert earthsci_ast.free_variables(fixed) == {"T0", "T_air"}
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/expressions.py#L8-L19">docs/api/examples/python/expressions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
// Parse the text form (the same syntax `to_ascii` prints) ...
let rate = parse_expression("k * A - x")?;
assert_eq!(to_ascii(&rate), "k * A - x");

// ... or a whole equation.
let eq = parse_equation("D(x)/Dt = k * A - x")?;
assert_eq!(to_ascii(&eq.lhs), "D(x)/Dt");

let mut names: Vec<String> = free_variables(&rate).into_iter().collect();
names.sort();
assert_eq!(names, ["A", "k", "x"]);

// Replace `k` with `2 * j`.
let subs = HashMap::from([("k".to_string(), parse_expression("2 * j")?)]);
let replaced = substitute(&rate, &subs);
assert_eq!(to_ascii(&replaced), "2 * j * A - x");

// Expressions are also plain Rust values.
let one = Expr::Variable("x".to_string());
assert_eq!(to_ascii(&one), "x");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/expressions.rs#L13-L32">docs/api/examples/rust/expressions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
parsed, err := esm.ParseExpression("k * (T_wall - T_air)")
if err != nil {
	log.Fatal(err)
}
fmt.Println(sortedKeys(esm.FreeVariables(parsed)))

// The same tree, built directly: an operator node is an ExprNode, a
// variable is a string and a number is a float64.
built := esm.ExprNode{Op: "*", Args: []any{
	"k",
	esm.ExprNode{Op: "-", Args: []any{"T_wall", "T_air"}},
}}
fmt.Println(esm.ToASCII(built) == esm.ToASCII(parsed))

substituted, err := esm.Substitute(parsed, map[string]esm.Expression{
	"T_wall": 290.0,
	"k":      esm.ExprNode{Op: "/", Args: []any{1.0, "tau"}},
})
if err != nil {
	log.Fatal(err)
}
fmt.Println(esm.ToASCII(substituted))
fmt.Println(sortedKeys(esm.FreeVariables(substituted)))

value, err := esm.Evaluate(substituted, map[string]float64{"tau": 20, "T_air": 280})
if err != nil {
	log.Fatal(err)
}
fmt.Println(value)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/go/expressions_test.go#L14-L42">docs/api/examples/go/expressions_test.go</a></p>

</div>

</div>


## Edit a document

The editing operations add, remove and rename the parts of a document. Here a
new variable and an equation for it are added to the `Decay` model, and the
result is serialized back to JSON and written to a file. A document you have
edited can be loaded again, by this binding or any other.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

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


## Flatten a coupled document

A document with several components and coupling between them is turned into
one system by flattening. Each variable gets a name qualified by its component
(`Heater.T`, `Box.T_air`), and the coupling is applied: here, `Box.T_wall` is
replaced by `Heater.T`, so the box's air temperature now follows the heater.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
doc = load_path(joinpath(FIXTURES, "coupled.esm"))
sys = flatten(doc)
@assert sys isa FlattenedSystem

# Every name is qualified by the component it came from.
@assert collect(keys(sys.state_variables)) == ["Heater.T", "Box.T_air"]
# The param_to_var variable_map replaced the parameter Box.T_wall with the
# state Heater.T, so Box.T_wall is not a parameter of the flattened system...
@assert collect(keys(sys.parameters)) == ["Heater.rate", "Box.k"]

# ...and the equations read Heater.T where Box.T_wall was.
equations = [to_ascii(eq) for eq in sys.equations]
foreach(println, equations)
@assert equations == [
    "D(Heater.T)/Dt = Heater.rate",
    "D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)",
]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/coupling.jl#L7-L23">docs/api/examples/julia/coupling.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const doc = loadPath(fixture('coupled.esm'))
const flat = flatten(doc)

// Variables are namespaced by the system that declared them.
assert.deepEqual(Object.keys(flat.stateVariables), ['Heater.T', 'Box.T_air'])
assert.deepEqual(Object.keys(flat.parameters), ['Heater.rate', 'Box.k'])
assert.equal(flat.stateVariables['Box.T_air'].units, 'K')

// The `param_to_var` variable_map replaces the box's wall-temperature
// parameter with the heater's temperature: `Box.T_wall` is gone from the
// parameters above, and the box equation reads `Heater.T` in its place.
const equations = flat.equations.map((eq) => toAscii(eq))
assert.deepEqual(equations, [
  'D(Heater.T)/Dt = Heater.rate',
  'D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)',
])
assert.deepEqual(
  flat.equations.map((eq) => eq.sourceSystem),
  ['Heater', 'Box'],
)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/flatten.ts#L9-L28">docs/api/examples/typescript/flatten.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
coupled = earthsci_ast.load_path(FIXTURES / "coupled.esm")
flat = earthsci_ast.flatten(coupled)

# Every name is now qualified by the model it came from.
assert list(flat.state_variables) == ["Heater.T", "Box.T_air"]
assert {"Heater.rate", "Box.k"} <= set(flat.parameters)
for name, var in flat.state_variables.items():
    print(f"{name}: {var.units}, default {var.default}")

for eq in flat.equations:
    print(eq.lhs_str, "=", eq.rhs_str)
heater, box = flat.equations
assert earthsci_ast.to_ascii(heater.rhs) == "Heater.rate"

# The param_to_var variable_map replaced the box's wall-temperature parameter
# with the heater's temperature: it is gone from the equations AND from the
# parameters.
assert earthsci_ast.to_ascii(box.rhs) == "Box.k * (Heater.T - Box.T_air)"
assert "Box.T_wall" not in earthsci_ast.free_variables(box.rhs)
assert "Box.T_wall" not in flat.parameters
assert flat.metadata.source_systems == ["Heater", "Box"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/flatten.py#L11-L31">docs/api/examples/python/flatten.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
let doc = load_path(fixture("coupled.esm"))?;
let flat = flatten(&doc)?;

// Every name is namespaced by its model.
let states: Vec<&String> = flat.state_variables.keys().collect();
let params: Vec<&String> = flat.parameters.keys().collect();
println!("states: {states:?}\nparameters: {params:?}");
assert_eq!(states, ["Heater.T", "Box.T_air"]);
assert!(flat.parameters.contains_key("Heater.rate") && flat.parameters.contains_key("Box.k"));

// The param_to_var coupling replaces the box's wall-temperature
// parameter Box.T_wall with the heater's state Heater.T: the parameter
// is gone, and the box's equation reads Heater.T instead.
assert!(!flat.parameters.contains_key("Box.T_wall"));
for eq in &flat.equations {
    println!("{}", to_ascii(eq));
}
assert_eq!(flat.equations.len(), 2);
let box_eq = to_ascii(&flat.equations[1]);
assert_eq!(box_eq, "D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)");
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/flatten.rs#L8-L27">docs/api/examples/rust/flatten.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

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

</div>

</div>


Flattening reports problems with the coupling as errors of its own; the
[Flatten](/generated/api/topics/flatten) topic lists them.

## Derive equations from reactions

A reaction system lists species, parameters and reactions. Deriving its
ordinary differential equations applies mass-action kinetics: each reaction
consumes its substrates and makes its products at a rate given by its rate
constant times the product of its substrates. For `ozone.esm`, `d[O3]/dt` is
`jNO2·[NO2] − k1·[NO]·[O3]`.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
doc = load_path(joinpath(FIXTURES, "ozone.esm"))
rs = doc.reaction_systems["Ozone"]
@assert rs isa ReactionSystem
@assert length(rs.reactions) == 2

odes = derive_odes(rs)  # a Model with one D(species)/dt per species
for eq in odes.equations
    println(to_ascii(eq))
end
@assert [to_ascii(eq) for eq in odes.equations] == [
    "D(O3)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2",
    "D(NO)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2",
    "D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2",
]

# Rows are species (O3, NO, NO2), columns are reactions (R1, R2).
@assert stoichiometric_matrix(rs) == [-1.0 1.0; -1.0 1.0; 1.0 -1.0]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/reactions.jl#L7-L23">docs/api/examples/julia/reactions.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
const doc = loadPath(fixture('ozone.esm'))
const system = doc.reaction_systems!.Ozone
assert.ok(!('ref' in system)) // narrows away an unresolved `{ ref }` mount

// Mass-action kinetics: one ODE per species.
const odes = deriveOdes(system)
assert.deepEqual(odeStates(odes).sort(), ['NO', 'NO2', 'O3'])
assert.deepEqual(
  odes.equations.map((eq) => toAscii(eq)),
  [
    'D(O3)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2',
    'D(NO)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2',
    'D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2',
  ],
)

// Net stoichiometry: rows are species, columns are reactions.
const { matrix, species, reactions } = stoichiometricMatrix(system)
assert.deepEqual(species, ['O3', 'NO', 'NO2'])
assert.deepEqual(reactions, ['R1', 'R2'])
assert.deepEqual(matrix, [
  [-1, 1],
  [-1, 1],
  [1, -1],
])
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/reactions.ts#L9-L33">docs/api/examples/typescript/reactions.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
doc = earthsci_ast.load_path(FIXTURES / "ozone.esm")
system = doc.reaction_systems["Ozone"]
assert [s.name for s in system.species] == ["O3", "NO", "NO2"]
assert [r.id for r in system.reactions] == ["R1", "R2"]

odes = earthsci_ast.derive_odes(system)
for eq in odes.equations:
    print(earthsci_ast.to_ascii(eq))

# One equation per species, in declaration order; rate constants become parameters.
assert earthsci_ast.ode_states(odes) == ["NO", "NO2", "O3"]
assert [eq.lhs.args[0] for eq in odes.equations] == ["O3", "NO", "NO2"]
assert odes.variables["k1"].type == "parameter"
assert earthsci_ast.to_ascii(odes.equations[2]) == "D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/reactions.py#L13-L26">docs/api/examples/python/reactions.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
let doc = load_path(fixture("ozone.esm"))?;
let system = &doc.reaction_systems.as_ref().unwrap()["Ozone"];

// derive_odes turns the reactions into an ordinary model: one
// differential equation per species, with mass-action rate laws.
let model = derive_odes(system)?;
for eq in &model.equations {
    println!("{}", to_ascii(eq));
}
let mut states = ode_states(&model);
states.sort();
assert_eq!(states, ["NO", "NO2", "O3"]);
let no2 = model.equations.iter().find(|eq| to_ascii(&eq.lhs) == "D(NO2)/Dt").unwrap();
assert_eq!(to_ascii(&no2.rhs), "k1 * NO * O3 + -1 * jNO2 * NO2");
assert_eq!(model.equations.len(), 3);
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/reactions.rs#L8-L22">docs/api/examples/rust/reactions.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

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


## Simulate

Julia, Python and Rust can integrate a document; TypeScript and Go read, check
and transform documents but deliberately do not simulate them. Simulation
follows the SciML vocabulary in every binding that has it: build a *problem*
from the document, then *solve* it over a time span. Starting from
`N = 100` with `lambda = 0.1 /s`, after one half-life (`ln 2 / 0.1 ≈ 6.93 s`)
half the amount is left, and the observed `half_life` can be read from the
solution like any state.


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
prob = esm_problem(joinpath(FIXTURES, "decay.esm"), (0.0, 10.0))
@assert prob isa EsmProblem

λ = 0.1
sol = solve(prob, Tsit5(); saveat = [0.0, log(2) / λ, 10.0], reltol = 1.0e-8)
@assert sol.retcode == ReturnCode.Success

# A solution is indexed by the flattened variable name, as a Symbol.
N = sol[Symbol("Decay.N")]
@assert N[1] == 100.0
@assert isapprox(N[2], 50.0; rtol = 1.0e-5)  # half left after one half-life

# Observed variables are read off the problem. half_life is a scalar field.
half_life = only(observed_field(prob, "half_life"))
@assert half_life ≈ log(2) / λ
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/simulate.jl#L8-L22">docs/api/examples/julia/simulate.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript" data-gap="true">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">No example: TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
prob = earthsci_ast.esm_problem(doc, (0.0, 10.0))

half_life = math.log(2) / 0.1
sol = earthsci_ast.solve(prob, saveat=[0.0, half_life, 10.0])
assert sol.retcode == earthsci_ast.ReturnCode.Success

# A solution is indexed by variable name.
n = sol["N"]
print("N at t = 0, ln 2 / λ, 10:", n)
assert math.isclose(n[1], 50.0, rel_tol=1e-3)
assert math.isclose(n[-1], 100.0 * math.exp(-1.0), rel_tol=1e-3)

# Observed variables are read the same way.
assert math.isclose(sol["half_life"][-1], half_life, rel_tol=1e-9)
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/simulate.py#L12-L26">docs/api/examples/python/simulate.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
let path = fixture("decay.esm");
let prob = esm_problem(path.as_path(), (0.0, 10.0), ProblemOptions::default())?;

// Sample the solution at t = ln 2 / λ, one half-life in.
let lambda = 0.1_f64;
let t_half = 2.0_f64.ln() / lambda;
let opts = SolveOptions {
    saveat: Some(vec![0.0, t_half]),
    ..Default::default()
};
let sol = solve(&prob, &opts)?;
assert_eq!(sol.retcode, ReturnCode::Success);

// States are read by name; a bare name resolves when it is unique.
let n = sol.get("N").expect("N is a state");
assert!((n[0] - 100.0).abs() < 1e-9);
assert!((n[1] - 50.0).abs() < 1e-3, "N(ln 2 / λ) = {}", n[1]);

// half_life is an observed: computed from the solution, not stored in it.
let half_life = observed_trajectory(&prob, &sol, "half_life")?;
assert!(half_life.iter().all(|h| (h - t_half).abs() < 1e-9));
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/simulate.rs#L13-L33">docs/api/examples/rust/simulate.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go" data-gap="true">
<p class="api-tab-label">Go</p>

<p class="api-absent">No example: Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>


## Where next

- The [API reference](/generated/api) has a page for each operation, with
  every binding's signature and documentation side by side.
- [File structure](/file-structure) describes each section of an `.esm`
  document.
