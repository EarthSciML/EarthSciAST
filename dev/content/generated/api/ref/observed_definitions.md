---
title: "observed_definitions"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `observed_definitions` | `observedDefinitions` | `observed_definitions` | `observed_definitions` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
observed_definitions(model::Model)
```

```julia
observed_definitions(model::Model) -> Dict{String,ASTExpr}
```

Each observed unknown mapped to its DEFINING EQUATION's right-hand side.

An observed's definition lives in the model's `equations` array, as the
bare-variable-LHS equation whose LHS names it; this is the way to read it.

An unknown that is also an ODE state is excluded (a `D(y)` equation defines
`y`'s dynamics, not `y` itself). Where more than one equation has the same
bare-variable LHS the FIRST wins, matching the reference implementation.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L167)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/julia/documents.jl#L55-L68">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function observedDefinitions(model: Model, options?: { bareOnly?: boolean }): Map<string, Expression>
```

The DEFINING EXPRESSION of every observed unknown: the RHS of the equation
whose LHS names it, bare (`y ~ f(…)`) or indexed (`y[i] ~ f(…)`).

An observed unknown's definition lives in the model's `equations` array, not
on its variable declaration; every pass that needs the definition reads it
through this function.

Only the first equation for a name is recorded: a second one is an unbalanced
system, which `validateEquationBalance` reports rather than this.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/classification.ts#L238)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/inspect.ts#L21-L41">docs/api/examples/typescript/inspect.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
observed_definitions(model: Any, bare_only: bool = False) -> dict[str, Any]
```

Map each observed unknown to its DEFINING equation's RHS.

An observed unknown is one an equation defines with a bare-variable LHS;
its definition lives in the model's `equations` (esm-spec §6.3.1), and
this function reads it from there. The FIRST defining equation wins, so classification does not
depend on equation order for the *set* it returns.

An indexed LHS (`y[i] ~ f(i)`, the arrayed-observed form) defines its base
array, so it is credited here too: its cadence must resolve through its RHS
exactly as a scalar observed's does, and refusing to credit it would seed a
const-backed geometry array CONTINUOUS and stop it folding. Pass
`bare_only` to restrict to the strict `y ~ f(…)` form — see
`inlined_unknowns` for what that distinction is for.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L362)

**Example** (`system_kind`)

```python
assert earthsci_ast.system_kind(model) == "ode"
assert earthsci_ast.is_ode_state(model, "N")
assert not earthsci_ast.is_ode_state(model, "half_life")

definitions = earthsci_ast.observed_definitions(model)
assert earthsci_ast.to_ascii(definitions["half_life"]) == "log(2) / lambda"
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L87-L92">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn observed_definitions(model: &Model) -> BTreeMap<String, Expr>
```

Each observed unknown's defining RHS, keyed by name.

An observed's definition lives in the model's `equations` (esm-spec
§6.3.1): the equation whose left-hand side is the bare variable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/classification.rs#L408) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.observed_definitions.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
