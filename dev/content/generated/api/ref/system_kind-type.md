---
title: "system_kind (type)"
description: "Stable type · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `SystemKind` | not exported | `SystemKind` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

Julia does not export this type.

**Planned:** RULED (phase 6, API_SPEC.md §8 item 11): the family is three distinct questions plus one composition. `system_kind(model)` derives, `declared_system_kind(model)` reads the field, and `effective_system_kind(model)` is `declared ?? derived` — the question a caller choosing a solver actually asks. `declared_system_kind_mismatch` is deleted. TypeScript has all three as of phase 6; Julia, Python and Go still owe `effective_system_kind`. The function/type pair stays (they are distinct symbols under the (name, kind) identity rule).

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
type SystemKind = 'ode' | 'nonlinear' | 'sde' | 'pde';
```

The MTK system type a model maps to.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/classification.ts#L34)

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

Python does not export this type.

**Planned:** RULED (phase 6, API_SPEC.md §8 item 11): the family is three distinct questions plus one composition. `system_kind(model)` derives, `declared_system_kind(model)` reads the field, and `effective_system_kind(model)` is `declared ?? derived` — the question a caller choosing a solver actually asks. `declared_system_kind_mismatch` is deleted. TypeScript has all three as of phase 6; Julia, Python and Go still owe `effective_system_kind`. The function/type pair stays (they are distinct symbols under the (name, kind) identity rule).

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum SystemKind {
    Sde,
    Pde,
    Nonlinear,
    Ode,
}

impl SystemKind { pub fn as_str(self) -> &'static str }
```

The derived system kind (esm-spec §6.3.1).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/classification.rs#L45) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.SystemKind.html)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/rust/inspect.rs#L11-L29">docs/api/examples/rust/inspect.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

Go does not export this type.

**Planned:** RULED (phase 6, API_SPEC.md §8 item 11): the family is three distinct questions plus one composition. `system_kind(model)` derives, `declared_system_kind(model)` reads the field, and `effective_system_kind(model)` is `declared ?? derived` — the question a caller choosing a solver actually asks. `declared_system_kind_mismatch` is deleted. TypeScript has all three as of phase 6; Julia, Python and Go still owe `effective_system_kind`. The function/type pair stays (they are distinct symbols under the (name, kind) identity rule).

</div>

</div>
