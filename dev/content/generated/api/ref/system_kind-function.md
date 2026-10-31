---
title: "system_kind (function)"
description: "Stable function · Variable classification"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Variable classification](/generated/api/topics/classification)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `system_kind` | `systemKind` | `system_kind` | `system_kind` | `SystemKind` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
system_kind(model::Model)
system_kind(flat::FlattenedSystem)
```

```julia
system_kind(model::Model) -> String
```

Derive what the `system_kind` field declares (esm-spec §6.3.1). Four conditions
tested **in this order**, first match winning:

| # | Condition | Result |
|---|---|---|
| 1 | any parameter in [`brownian_parameters`](/generated/api/ref/brownian_parameters) | `"sde"` |
| 2 | any equation contains a spatial derivative | `"pde"` |
| 3 | no time-derivative equation at all | `"nonlinear"` |
| 4 | otherwise | `"ode"` |

Both orderings are load-bearing. `"pde"` precedes `"nonlinear"` so a
steady-state PDE (`laplacian(phi) ~ f`, no ∂/∂t) is a PDE rather than falling
through to `"nonlinear"`. `"sde"` precedes `"pde"` because there is no
`SPDESystem` constructor to select, so a model that is both assembles as an SDE.

The rule is stated over the EQUATIONS and not over a `domain` block: `domain`
says nothing about space, so a domain-based test is not implementable.

A binding uses this derivation when the `system_kind` field is absent — see
[`effective_system_kind`](/generated/api/ref/effective_system_kind), which composes it with
[`declared_system_kind`](/generated/api/ref/declared_system_kind) — and reports `system_kind_mismatch` when a
present field contradicts it.

---

```julia
system_kind(flat::FlattenedSystem) -> String
```

Derive what a flattened system's `system_kind` field would declare (esm-spec
§6.3.1), over the FLATTENED form rather than a component.

Row 1 of the derivation tests `brownian_parameters` FIRST, and it reads the
bucket the `FlattenedSystem` carries. That is precisely what the bucket is for: a
flattened representation that dropped it could not report `"sde"`, and a consumer
would integrate a stochastic system as a deterministic one.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/classification.jl#L392)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function systemKind(model: Model): SystemKind
```

The system kind DERIVED from the equations and the parameter updates.

FIRST match wins, and the order is normative
(`tests/conformance/classification/manifest.json`, `system_kind_order`):

  1. `sde`       — any Brownian parameter.
  2. `pde`       — any equation contains a spatial derivative.
  3. `nonlinear` — no time-derivative equation at all.
  4. `ode`       — otherwise.

Two orderings that look equivalent are not. `pde` is tested BEFORE
`nonlinear`, so a steady-state PDE (`laplacian(phi) ~ f`, no time derivative)
is `pde`. `sde` is tested BEFORE `pde`, so a model carrying both a wiener
parameter and a spatial derivative is `sde` — not because it is not spatial,
but because there is no SPDESystem constructor to select.

Detection is a property of the EQUATIONS and never of the `domain` block,
which carries nothing spatial.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/classification.ts#L348)

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
system_kind(model: Any) -> str
```

Derive the model's MTK system kind (esm-spec §6.3.1).

Four rows tested IN ORDER, first match wins — the order is normative:

1. any Brownian parameter → `"sde"` (there is no SPDESystem, so this wins
   even over a spatial derivative);
2. any spatial derivative in any equation → `"pde"`;
3. no time-derivative equation at all → `"nonlinear"`;
4. otherwise → `"ode"`.

A binding uses this derivation whenever the `system_kind` FIELD is absent,
and reports `system_kind_mismatch` when a present field contradicts it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/classification.py#L524)

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
pub fn system_kind(model: &Model) -> SystemKind
```

The DERIVED system kind (esm-spec §6.3.1), which a binding uses when the
`system_kind` field is absent and checks against when it is present.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/classification.rs#L400) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.system_kind.html)

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

```go
func SystemKind(model *Model) string
```

SystemKind derives what the `system_kind` field declares (esm-spec §6.3.1), testing four conditions IN ORDER and taking the first that holds:

1. any Brownian parameter                   =&gt; "sde"
2. any equation holds a spatial derivative  =&gt; "pde"
3. no time-derivative equation at all       =&gt; "nonlinear"
4. otherwise                                =&gt; "ode"

The order is normative and two orderings that look interchangeable are not. "pde" is tested BEFORE "nonlinear" so a steady-state PDE (laplacian(phi) ~ f, which has no time derivative) does not fall through to "nonlinear"; "sde" is tested BEFORE "pde" because there is no SPDESystem constructor to select for a model that is both.

Detection is a property of the EQUATIONS, never of the `domain` block: v0.8.0 removed Domain.spatial, so `domain` carries nothing spatial and the earlier "spatial domain plus differential operators" rule named a test no binding could perform. A vestigial `domain` parameter outlived that removal by two releases, unread by this body and by EffectiveSystemKind's, and is gone as of API\_SPEC.md §8 item 11: `system_kind(model)` takes the model and nothing else in all five bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/classify.go#L184) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SystemKind)

</div>

</div>
