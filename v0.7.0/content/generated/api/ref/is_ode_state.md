---
title: "is_ode_state"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `is_ode_state` | `isOdeState` | `is_ode_state` | `is_ode_state` | `IsODEState` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
is_ode_state(model::Model, name::AbstractString)
```

```julia
is_ode_state(model::Model, name::AbstractString) -> Bool
```

Membership test for [`ode_states`](/generated/api/ref/ode_states).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/classification.jl#L152)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function isOdeState(model: Model, name: string): boolean
```

Membership test for [`odeStates`](/generated/api/ref/ode_states).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/classification.ts#L192)

**Example** (`inspect`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/typescript/inspect.ts#L21-L41">docs/api/examples/typescript/inspect.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
is_ode_state(model: Any, name: str) -> bool
```

Membership test for [`ode_states`](/generated/api/ref/ode_states) — the replacement for every
`variable.type == "state"` branch.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L353)

**Example** (`system_kind`)

```python
assert earthsci_ast.system_kind(model) == "ode"
assert earthsci_ast.is_ode_state(model, "N")
assert not earthsci_ast.is_ode_state(model, "half_life")

definitions = earthsci_ast.observed_definitions(model)
assert earthsci_ast.to_ascii(definitions["half_life"]) == "log(2) / lambda"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/documents.py#L87-L92">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn is_ode_state(model: &Model, name: &str) -> bool
```

Membership test for [`ode_states`](/generated/api/ref/ode_states).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/classification.rs#L365) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.is_ode_state.html)

**Example** (`inspect`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/rust/inspect.rs#L11-L29">docs/api/examples/rust/inspect.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func IsODEState(model *Model, name string) bool
```

IsODEState reports whether the named variable is an unknown appearing under a time derivative on some equation LHS. It is the membership test for ODEStates and the replacement for every `variable.Type == "state"` branch.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/classify.go#L46) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#IsODEState)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/go/inspect_test.go#L14-L31">docs/api/examples/go/inspect_test.go</a></p>

</div>

</div>
