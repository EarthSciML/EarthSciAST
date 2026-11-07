---
title: "parameters"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `parameter_names`, `parameters` | `parameters` | not exported | not exported | not exported |


**Note:** spelling differs from the §2 rule: julia=parameter_names (expected parameters); multiple spellings exported by: julia


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

Exported as `parameter_names` and `parameters`. Both names refer to the same operation.

**`parameter_names`**

```julia
parameter_names(model::Model)
```

```julia
parameter_names(model::Model) -> Vector{String}
```

Deprecated alias of [`parameters`](/generated/api/ref/parameters) (API_SPEC.md §8 item 6). Kept exported
for the same namespace reason as [`unknown_names`](/generated/api/ref/unknowns).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/classification.jl#L54)

**`parameters`**

```julia
parameters(model::Model)
parameters(x::Union{EarthSciAST.RhsProgram, EarthSciAST.TileProgram})
parameters(lp::EarthSciAST.LaneProgram)
```

```julia
parameters(model::Model) -> Vector{String}
```

Every `parameter` declared by `model`, sorted lexicographically. The union of
[`brownian_parameters`](/generated/api/ref/brownian_parameters), [`discrete_parameters`](/generated/api/ref/discrete_parameters),
[`sampled_parameters`](/generated/api/ref/sampled_parameters) and [`constant_parameters`](/generated/api/ref/constant_parameters), which partition
it.

The canonical cross-binding name; see [`unknowns`](/generated/api/ref/unknowns) for why the
[`parameter_names`](/generated/api/ref/parameters) alias stays exported alongside it.

---

```julia
parameters(prog) -> Vector{ParamSlot}
```

The entries of a vector `p` (API_SPEC §5.8): sorted flattened parameter names,
the positional order the compiled program indexes, each with its default.
Build a vector with [`parameter_vector`](/generated/api/extension/julia#x-parameter_vector); `rhs!` also takes the Problem's
NamedTuple `prob.p`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/classification.jl#L31)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/documents.jl#L55-L68">docs/api/examples/julia/documents.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function parameters(model: Model): string[]
```

Names of every variable declared `parameter`, sorted.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/classification.ts#L169)

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

<p class="api-absent">Python does not export this function.</p>

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
