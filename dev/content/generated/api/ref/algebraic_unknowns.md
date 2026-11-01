---
title: "algebraic_unknowns"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `algebraic_unknowns` | `algebraicUnknowns` | `algebraic_unknowns` | `algebraic_unknowns` | `AlgebraicUnknowns` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
algebraic_unknowns(model::Model)
```

```julia
algebraic_unknowns(model::Model) -> Vector{String}
```

The unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`) — those an equation
never names as a derivative target or a bare-variable LHS (esm-spec §6.3.1).
Sorted lexicographically.

Defined as the complement so that [`ode_states`](/generated/api/ref/ode_states),
[`observed_unknowns`](/generated/api/ref/observed_unknowns) and `algebraic_unknowns` PARTITION the unknowns by
construction: an unknown with no equation of its own lands here rather than
vanishing (the equation balance, not the classification, is what reports it).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/classification.jl#L242)

**Example** (`inspect`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/documents.jl#L55-L68">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function algebraicUnknowns(model: Model): string[]
```

Unknowns constrained only implicitly — no equation names them on its LHS
(`H*H*SO4 ~ Ksp`). Everything left once the ODE states and the observed
unknowns are removed; defining this set by elimination is what makes the
three sets a partition by construction.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/classification.ts#L264)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/inspect.ts#L21-L41">docs/api/examples/typescript/inspect.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
algebraic_unknowns(model: Any) -> list[str]
```

Unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`), sorted.

Defined as the complement, which is what makes the three sets a partition by
construction rather than by coincidence.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L419)

**Example** (`inspect`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/documents.py#L68-L82">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn algebraic_unknowns(model: &Model) -> Vec<String>
```

Unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`).

Names are sorted lexicographically, not in declaration order (API_SPEC.md §5.3).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/classification.rs#L360) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.algebraic_unknowns.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/inspect.rs#L11-L29">docs/api/examples/rust/inspect.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func AlgebraicUnknowns(model *Model) []string
```

AlgebraicUnknowns returns the model's unknowns constrained only IMPLICITLY — those that are neither differentiated nor DEFINED, so the only equations mentioning them have an expression LHS naming no single variable (`H*H*SO4 ~ Ksp`) or mention them on a right-hand side. Sorted lexicographically.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/classify.go#L87) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#AlgebraicUnknowns)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/inspect_test.go#L14-L31">docs/api/examples/go/inspect_test.go</a></p>

</div>

</div>
