---
title: "flattened_variable"
description: "Stable type · Flatten"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Flatten](/generated/api/topics/flatten)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `FlattenedVariable` | `FlattenedVariable` | not exported | `FlattenedVariable` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface FlattenedVariable {
    name: string;
    type: FlattenedVariableRole;
    units?: string;
    default?: number;
    description?: string;
    sourceSystem?: string;
    shape?: string[];
    update?: ParameterUpdateSpec;
    distribution?: Distribution;
}
```

One variable of the flattened system, carrying the COMPLETE declared metadata
step 4 requires ("Full metadata, not names"): a consumer must be able to build
a solver problem from the flattened form alone, without re-reading the source
document.

**Properties**

- `name` — Dot-namespaced name, e.g. `"OU.theta"`.
- `type` — The DERIVED role — see [`FlattenedVariableRole`](/generated/api/extension/typescript#x-flattenedvariablerole).
- `default` — For an unknown, its value at t=0; for a parameter, its constant value.
- `sourceSystem` — The namespaced prefix of the component that declared it.
- `shape` — Ordered index-set names for an arrayed variable; absent means scalar.
- `update` — The declared cadence machinery (parameters only), with its expression
  slots — a `condition` / `crossing` `when` and the value `expression` —
  namespaced like any other reference (§4.7.5 step 2).
- `distribution` — The declared sampling law, carried verbatim (parameters only).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/flatten.ts#L266)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/typescript/flatten.ts#L9-L28">docs/api/examples/typescript/flatten.ts</a></p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FlattenedVariable
FlattenedVariable(name: str, type: str, units: str | None = None, default: Any = None, description: str | None = None, source_system: str | None = None, shape: list[str] | None = None, update: Any = None, distribution: Any = None, element_type: str | None = None)
```

A single variable in the flattened system.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L251)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/docs/api/examples/python/flatten.py#L11-L31">docs/api/examples/python/flatten.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type FlattenedVariable struct {
	// Name is the dot-namespaced name ("OU.theta").
	Name string
	// Role is the DERIVED role (esm-spec §6.3.1), never a declared type:
	// "state" (an unknown the solver advances or solves for), "observed" (an
	// unknown a bare-variable-LHS equation defines, eliminable by inlining),
	// "parameter", or "species" (a reaction-system state).
	Role string
	// SourceSystem is the component the variable came from.
	SourceSystem string
	Units        *string
	Default      any
	Description  *string
	// Shape lists the index-set names an arrayed variable is shaped over; nil
	// for a scalar.
	Shape []string
	// Update carries the declared cadence machinery verbatim (one
	// ParameterUpdate or an ordered []ParameterUpdate); read it through
	// UpdateRules.
	Update       any
	Distribution *Distribution
}

func (fv FlattenedVariable) DeclaredType() string

func (fv FlattenedVariable) UpdateRules() []ParameterUpdate
```

FlattenedVariable is one variable of the flattened system, carrying the FULL declared metadata step 4 requires ("Full metadata, not names"): a consumer must be able to build a solver problem from the flattened form alone, without re-reading the source document.

**Methods**

```go
func (fv FlattenedVariable) DeclaredType() string
```

DeclaredType is the two-type esm 1.0.0 declaration ("unknown" / "parameter") the variable's derived Role was computed from. FlattenedSystem.DeclaredTypes collects it for every variable.

```go
func (fv FlattenedVariable) UpdateRules() []ParameterUpdate
```

UpdateRules returns the variable's update rules in declaration order, flattening both spellings of the ParameterUpdateSpec union (esm-spec §5.4).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/flatten.go#L239) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FlattenedVariable)

</div>

</div>
