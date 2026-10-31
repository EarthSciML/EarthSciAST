---
title: "unknowns"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `unknown_names`, `unknowns` | `unknowns` | `unknowns` | not exported | not exported |


**Note:** spelling differs from the §2 rule: julia=unknown_names (expected unknowns); multiple spellings exported by: julia


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

Exported as `unknown_names` and `unknowns`. Both names refer to the same operation.

**`unknown_names`**

```julia
unknown_names(model::Model)
```

```julia
unknown_names(model::Model) -> Vector{String}
```

Deprecated alias of [`unknowns`](/generated/api/ref/unknowns) (API_SPEC.md §8 item 6). Kept exported —
not merely for one minor — because the bare canonical name collides in Julia's
flat namespace; both spellings are in the surface manifest.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L45)

**`unknowns`**

```julia
unknowns(model::Model)
```

```julia
unknowns(model::Model) -> Vector{String}
```

Every `unknown` declared by `model`, sorted lexicographically. The union of
[`ode_states`](/generated/api/ref/ode_states), [`observed_unknowns`](/generated/api/ref/observed_unknowns) and
[`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns), which partition it.

This is the canonical cross-binding name (API_SPEC.md §8 item 6): TypeScript
spells it `unknowns` and Python `unknowns`. [`unknown_names`](/generated/api/ref/unknowns) is a
Julia-only alias, kept exported because the
bare name collides badly in Julia's flat namespace — `ModelingToolkit.unknowns`
is the obvious clash, and a consumer doing `using EarthSciAST, ModelingToolkit`
needs a spelling that cannot be ambiguous.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L14)

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
function unknowns(model: Model): string[]
```

Names of every variable declared `unknown`, sorted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/classification.ts#L160)

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
unknowns(model: Any) -> list[str]
```

Every variable declared `type: "unknown"`, sorted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L234)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/documents.py#L68-L82">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
