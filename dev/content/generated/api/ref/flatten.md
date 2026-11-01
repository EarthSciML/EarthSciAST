---
title: "flatten"
description: "Stable function · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `flatten` | `flatten` | `flatten` | `flatten` | `Flatten` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
flatten(file::EsmFile; base_path, load_ref)
flatten(model::Model; name)
flatten(rsys::ReactionSystem; name)
```

```julia
flatten(file::EsmFile; base_path=".", load_ref=nothing) -> FlattenedSystem
```

Flatten the coupled systems in `file` into a single symbolic representation
per spec §4.7.5 (+ §4.7.6 for hybrid dimension-promoted cases).

`coupling_import` entries (esm-spec §10.10) are expanded first; `base_path`
anchors their `ref`s and `load_ref` optionally overrides the resolver (see
[`expand_coupling_imports`](/generated/api/ref/expand_coupling_imports)).

Throws `ConflictingDerivativeError` if any species is both the LHS of an
explicit `D(X, t) = ...` equation and a reactant/product of a reaction — such
a system is over-determined.

INVARIANT (esm-spec §9.6.4 Option B): `flatten` ALWAYS carries surviving
`apply_expression_template` references — MODEL-equation references ride into
the `FlattenedSystem` (namespacing scopes their `bindings`), resolvable against
the merged `template_registry` it also carries. Reaction-system RATE references
never survive: they are expanded eagerly at collect (`_collect_reaction_system!`),
before namespacing. Consumers that need the Option-A expanded image call
[`expand_flattened_refs`](/generated/api/extension/julia#x-expand_flattened_refs) at their own boundary (RFC
out-of-line-expression-templates §7.7); the tree-walk build expands at its entry
with site recording (the compile-once tier).

---

```julia
flatten(model::Model; name::String="anonymous") -> FlattenedSystem
```

Convenience: wrap a single Model in a synthetic EsmFile (with a default system
name) and run the full flattener. This is the call path used by
`ModelingToolkit.System(::Model)` in the Julia extension (see gt-fpw).

---

```julia
flatten(rsys::ReactionSystem; name::String="anonymous") -> FlattenedSystem
```

Convenience: wrap a ReactionSystem in a synthetic EsmFile and flatten.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/flatten.jl#L1149)

**Example** (`flatten`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/julia/coupling.jl#L7-L23">docs/api/examples/julia/coupling.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function flatten(file: EsmFile, options?: FlattenOptions): FlattenedSystem
```

Flatten a coupled multi-system ESM file into a single unified system
(esm-libraries-spec §4.7.5).

The result is the canonical intermediate representation: dot-namespaced
variables carrying their full declared metadata, equations as Expression trees,
coupling rules resolved INTO the equation set, and the registries needed to
consume it without re-reading the source document.

**Throws**

- [`FlattenError`](/generated/api/ref/flatten_error) — when the file has no models and no reaction systems, or
    when a variable carries a type esm 1.0.0 removed.
- [`ConflictingDerivativeError`](/generated/api/ref/conflicting_derivative_error) — when two source systems define
    non-additive equations for the same dependent variable.
- [`CoupleMultiplicativeNoTendencyError`](/generated/api/ref/couple_multiplicative_no_tendency_error) — when a `couple` connector
    equation with `transform: "multiplicative"` targets something with no
    `D(to)` tendency to multiply (esm-spec §10.3).
- [`DomainUnitMismatchError`](/generated/api/ref/domain_unit_mismatch_error) — when an `identity` `variable_map` bridges two
    variables whose declared, non-empty units differ.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/flatten.ts#L3002)

**Example** (`flatten`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/typescript/flatten.ts#L9-L28">docs/api/examples/typescript/flatten.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
flatten(esm_file: EsmFile, base_path: str = '.', load_ref=None) -> FlattenedSystem
```

Flatten a coupled multi-system EsmFile per spec §4.7.5.

The result is the canonical intermediate representation: dot-namespaced
variables, equations as Expr trees, coupling rules resolved into the
equation set, and metadata recording what happened.

`base_path` / `load_ref` are only consulted when the file carries a
`coupling_import` coupling entry (esm-spec §10.10): each such entry loads
the referenced coupling-library file (via `load_ref(ref, base_path)`,
defaulting to a disk reader relative to `base_path`) and expands into
concrete edges spliced in its position, before the coupling-rule step.

**Raises**

- `ValueError` — If the file has no models, no reaction systems, and nothing to flatten.
- [`ConflictingDerivativeError`](/generated/api/ref/conflicting_derivative_error) — If two source systems define non-additive equations for the same
  dependent variable.
- [`DomainUnitMismatchError`](/generated/api/ref/domain_unit_mismatch_error) — If an `identity`-transform `variable_map` bridges two variables whose
  declared, non-empty units differ (spec §4.7.6).
- [`ExpressionTemplateError`](/generated/api/ref/expression_template_error) — For any esm-spec §10.11 coupling-import / coupling-library diagnostic.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L3281)

**Example** (`flatten`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/python/flatten.py#L11-L31">docs/api/examples/python/flatten.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn flatten(file: &EsmFile) -> Result<FlattenedSystem, FlattenError>
```

Flatten a coupled [`EsmFile`](/generated/api/ref/esm_file) into a single unified [`FlattenedSystem`](/generated/api/ref/flattened_system).

Implements spec §4.7.5 + §4.7.6 at the Core tier. Pipeline:

1. Lower every reaction system to ODE equations ([`crate::reactions::lower_reactions_to_equations`](/generated/api/ref/lower_reactions_to_equations)).
2. Namespace every variable, parameter, and equation by dot-notation.
3. Derive `FlattenedSystem::independent_variables` from the flattened
   equations (§4.7.6) — an undiscretized spatial operator names an axis
   here, it is NOT rejected. No `dimension_mapping` inspection is performed:
   `slice` / `project` / `regrid` are not checked at this tier.
4. Apply coupling rules in order: `operator_compose`, `couple`,
   `variable_map` (see §4.7.1–§4.7.4).
5. Detect `FlattenError::ConflictingDerivative` — species that end up
   with both an explicit `D(X, t)` equation and reaction-derived rate
   without an explicit `operator_compose` to merge them.
6. Collect into [`FlattenedSystem`](/generated/api/ref/flattened_system) with metadata provenance.

**Errors**

Returns [`FlattenError`](/generated/api/ref/flatten_error) per §4.7.6.10 error taxonomy.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/flatten.rs#L867) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.flatten.html)

**Example** (`flatten`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/flatten.rs#L8-L27">docs/api/examples/rust/flatten.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func Flatten(file *ESMFile) (*FlattenedSystem, error)
```

Flatten takes an ESMFile containing multiple models and/or reaction systems and returns a FlattenedSystem with dot-namespaced variables (esm-libraries-spec §4.7.5).

The algorithm:

1. Collect every component into a per-system bag, lowering reaction systems to ODE equations and namespacing every reference.
2. Expand `coupling_import` entries, then apply the coupling rules into the per-component equation sets.
3. Assemble one flat system, collect and namespace events, run the pointwise spatial lift, resolve every right-hand-side structural `D` (§4.7.5 step 3a), pass the domain through and derive the independent variables.
4. Derive the canonical step-4 fields: the §6.3.1 subsets, the deferred `ic` equations, and the merged expression-template registry.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/flatten.go#L2736) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Flatten)

**Example** (`flatten`)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/go/flatten_test.go#L14-L30">docs/api/examples/go/flatten_test.go</a></p>

</div>

</div>
