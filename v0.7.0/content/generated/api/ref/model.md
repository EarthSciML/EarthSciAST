---
title: "model"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Model` | not exported | `Model` | `Model` | `Model` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Model <: EarthSciAST.SubsystemNode
Model(variables::AbstractDict{String, ModelVariable}, equations::Vector{Equation}, discrete_events::Vector{DiscreteEvent}, continuous_events::Vector{ContinuousEvent}, subsystems::AbstractDict{String}; tolerance, tests, analyses, initialization_equations, guesses, system_kind, reference)
Model(variables::AbstractDict{String, ModelVariable}, equations::Vector{Equation}; discrete_events, continuous_events, subsystems, tolerance, tests, analyses, initialization_equations, guesses, system_kind, reference)
```

```julia
Model
```

ODE-based model component containing variables, equations, and optional subsystems.
Supports hierarchical composition through subsystems. A subsystem value is a
child `Model` or — only until references are resolved — a `SubsystemRef`; the
field is typed by their shared supertype, `OrderedDict{String,SubsystemNode}`.

`variables` and `subsystems` are `OrderedDict`s, and the parser populates them in
DOCUMENT ORDER. That is not a convenience: esm-libraries-spec §4.7.5 step 4 makes
the flattened system's ordering normative (variables in the order their component
declares them), and a flattener can only inherit an order the IR preserved. A
plain `Dict` here leaked its hash order all the way out to `flatten`'s
`parameters`, which a consumer reads POSITIONALLY as the parameter vector.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L1692)

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

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Model
Model(name: str, variables: dict[str, ModelVariable] = dict(), equations: list[Equation] = list(), metadata: dict[str, Any] = dict(), subsystems: dict[str, Model] = dict(), tolerance: Tolerance | None = None, tests: list[Test] = list(), analyses: list[Analysis] = list(), initialization_equations: list[Equation] = list(), guesses: dict[str, float | Expr] = dict(), system_kind: str | None = None, continuous_events: list[ContinuousEvent] = list(), discrete_events: list[DiscreteEvent] = list(), reference: Reference | None = None)
```

A mathematical model containing variables and equations.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L486)

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

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/python/documents.py#L68-L82">docs/api/examples/python/documents.py</a></p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct Model {
    pub name: Option<String>,
    pub reference: Option<Reference>,
    pub variables: IndexMap<String, ModelVariable>,
    pub equations: Vec<Equation>,
    pub discrete_events: Option<Vec<DiscreteEvent>>,
    pub continuous_events: Option<Vec<ContinuousEvent>>,
    pub subsystems: Option<IndexMap<String, Value>>,
    pub description: Option<String>,
    pub tolerance: Option<Tolerance>,
    pub tests: Option<Vec<ModelTest>>,
    pub analyses: Option<Vec<ModelAnalysis>>,
    pub initialization_equations: Option<Vec<Equation>>,
    pub guesses: Option<HashMap<String, Value>>,
    pub system_kind: Option<String>,
}
```

ODE-based model component

**`name` / `description` are NOT schema keys**

The schema's `Model` is `additionalProperties: false` and declares neither
`name` (a model's name is its key in the `models` map) nor `description`.
Both fields below are therefore schema-INVALID the moment they are set, and
`save()` will happily emit a document that fails its own schema. They are
harmless only while they stay `None`, which is what every load-parsed model
leaves them as — no deserializer ever fills them, because the wire form has
no such keys.

They are not dead, though: [`crate::update_model_metadata`](/generated/api/extension/rust#x-update_model_metadata) — a tier-
`extension`, Rust-only entry in `api-surface.json` — sets both, so its ONLY
observable effect is to make a valid document invalid. `graph.rs` also reads
`name` for a component-node label, where it is always `None` in practice.
They are part of the published API surface, so they stay; leave them
`None`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/model.rs#L313) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Model.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Model struct {
	Reference        *Reference               `json:"reference,omitempty"`
	Variables        map[string]ModelVariable `json:"variables"`
	Equations        []Equation               `json:"equations"`
	DiscreteEvents   []DiscreteEvent          `json:"discrete_events,omitempty"`
	ContinuousEvents []ContinuousEvent        `json:"continuous_events,omitempty"`
	Subsystems       map[string]any           `json:"subsystems,omitempty"`
	// Tolerance is the model-level default numerical tolerance applied to
	// inline tests that do not override it (esm-spec §6.6).
	Tolerance *Tolerance `json:"tolerance,omitempty"`
	// Tests are inline validation tests for this model (esm-spec §6.6).
	Tests []Test `json:"tests,omitempty"`
	// Analyses are inline illustrative runs + plot specs (esm-spec §6.7).
	Analyses []Analysis `json:"analyses,omitempty"`
	// InitializationEquations hold only at t=0 (not dynamically time-stepped).
	// Used by models that must solve an auxiliary system before the main
	// time-stepping begins (e.g. aerosol equilibrium, plume rise). See gt-ebuq.
	InitializationEquations []Equation `json:"initialization_equations,omitempty"`
	// Guesses provides initial-guess seeds for nonlinear solvers during
	// initialization, keyed by variable name. Values may be numeric literals
	// or Expression graphs (serialized as interface{}).
	Guesses map[string]any `json:"guesses,omitempty"`
	// SystemKind discriminates the MTK system type this model maps to.
	// One of "ode" (default), "nonlinear", "sde", "pde".
	SystemKind *string `json:"system_kind,omitempty"`
}

func (m *Model) UnmarshalJSON(data []byte) error
```

Model represents an ODE system

**Methods**

```go
func (m *Model) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for Model. Decodes `guesses` values through UnmarshalExpression so integer-valued initial guesses keep their int wire shape (RFC §5.4.1); every other field decodes exactly as its struct tags specify (via the alias type, which does not carry this method and so uses the default struct decoder). The embedded `Guesses` shadows the alias's field so the raw guess objects are captured here rather than decoded lossily.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L386) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Model)

</div>

</div>
