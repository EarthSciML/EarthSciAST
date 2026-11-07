---
title: "model_variable"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ModelVariable` | not exported | `ModelVariable` | `ModelVariable` | `ModelVariable` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ModelVariable
ModelVariable(type::ModelVariableType; default, description, units, default_units, shape, location, distribution, update, element_type)
```

```julia
ModelVariable
```

A model variable: an `unknown` the solver solves for, or a `parameter` supplied
to it (esm-spec §6.3).

An unknown carries no `expression` — its behaviour is stated by the model's
`equations` and nowhere else, so an observed unknown's defining right-hand side
is reached through [`observed_definitions`](/generated/api/ref/observed_definitions), never off the variable.

Parameter-only value fields:
- `distribution`: draw the value from a [`Distribution`](/generated/api/ref/distribution) instead of fixing
  it at `default` (mutually exclusive with `default`).
- `update`: when the parameter refreshes and what from — a vector of
  [`ParameterUpdate`](/generated/api/ref/parameter_update) rules applied in declaration order. `nothing` means
  the parameter never changes after setup. The wire form is a single object for
  one rule and an array for two or more (a one-element array is invalid), so
  `length(update)` alone decides the emitted spelling and the round trip is
  stable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L1131)

**Example** (`edit`)

```julia
doc = load_path(joinpath(FIXTURES, "decay.esm"))
model = doc.models["Decay"]

# Edits return a new Model; the original is left alone.
decayed = ModelVariable(
    UnknownVariable; default = 0.0, units = "mol",
    description = "Amount that has decayed"
)
edited = add_variable(model, "decayed", decayed)
edited = add_equation(edited, parse_equation("D(decayed, t) = lambda * N"))
@assert ode_states(model) == ["N"]
@assert ode_states(edited) == ["N", "decayed"]

doc.models["Decay"] = edited
@assert validate(doc).is_valid

json = to_json(doc)
@assert occursin("\"decayed\"", json)

path = joinpath(mktempdir(), "decay_edited.esm")
write_path(doc, path)
reloaded = load_path(path)
@assert sort(ode_states(reloaded.models["Decay"])) == ["N", "decayed"]
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/docs/api/examples/julia/editing.jl#L7-L29">docs/api/examples/julia/editing.jl</a></p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ModelVariable
ModelVariable(type: Literal['unknown', 'parameter'], units: str | None = None, default: Any | None = None, default_units: str | None = None, description: str | None = None, shape: list[str] | None = None, location: str | None = None, element_type: str | None = None, distribution: Distribution | None = None, update: ParameterUpdate | list[ParameterUpdate] | None = None)
```

A variable in a mathematical model — either an `unknown` the solver
solves for, or a `parameter` supplied to it. There is no third kind.

Everything else a solver needs is DERIVED, never declared, and
`earthsci_ast.classification` is the one place that derivation lives:
whether an unknown is an ODE state, observed or algebraic follows from the
model's EQUATIONS (there is no `expression` field on a variable), and
whether a parameter is Brownian, discrete, sampled or constant follows from
its `distribution` and `update`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L436)

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
pub struct ModelVariable {
    pub var_type: VariableType,
    pub units: Option<String>,
    pub default: Option<InlineValue>,
    pub default_units: Option<String>,
    pub element_type: Option<String>,
    pub description: Option<String>,
    pub shape: Option<Vec<String>>,
    pub location: Option<String>,
    pub distribution: Option<Distribution>,
    pub update: Option<ParameterUpdateSpec>,
}

impl ModelVariable { pub fn default_scalar(&self) -> Option<f64> }

impl ModelVariable { pub fn default_array(&self) -> Option<Result<(Vec<usize>, Vec<f64>), String>> }

impl ModelVariable { pub fn for_each_expression(&self, f: &mut impl FnMut(&Expr)) }

impl ModelVariable { pub fn for_each_expression_at(&self, f: &mut impl FnMut(&Expr, &str)) }

impl ModelVariable { pub fn for_each_expression_mut(&mut self, f: &mut impl FnMut(&mut Expr)) }

impl ModelVariable { pub fn try_for_each_expression_mut<E>(&mut self, f: &mut impl FnMut(&mut Expr) -> Result<(), E>) -> Result<(), E> }

impl ModelVariable { pub fn update_sources(&self) -> Vec<&str> }
```

Variable within a model

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/model.rs#L375) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ModelVariable.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ModelVariable struct {
	Type string `json:"type"` // "unknown" or "parameter"
	// ElementType is the floating-point precision of THIS variable and of the
	// arithmetic over it, overriding `domain.element_type` (esm-spec §11.3.1).
	// Nil means the declaring document's. This binding does not evaluate
	// precision; it carries the declaration so it survives load -> emit — and a
	// §4.7 mount writes a leaf's `domain.element_type` here ("Working precision
	// crosses a mount"), so dropping the field would discard that at the edge.
	ElementType *string `json:"element_type,omitempty"`
	Units       *string `json:"units,omitempty"`
	Default     any     `json:"default,omitempty"`
	// DefaultUnits declares the units the scalar `default` is expressed in when
	// they differ from `units`. The value is converted at load. A conversion that
	// is AFFINE (degC<->K) cannot be expressed as a scalar factor, so declaring
	// one here is a `unit_inconsistency` -- see checkDefaultUnits.
	DefaultUnits *string `json:"default_units,omitempty"`
	Description  *string `json:"description,omitempty"`
	// Shape lists index-set names for arrayed variables, drawn from the
	// document-scoped `index_sets` registry (ESMFile.IndexSets). A nil pointer
	// means the key is absent (scalar); a pointer to an EMPTY slice is the
	// authored `"shape": []`, which is also scalar but must survive the
	// round-trip verbatim -- esm 1.0.0 REQUIRES the key on a parameter whose
	// update is `schedule` / `data` / `remesh` (esm-spec 5.4), so silently
	// dropping an empty shape re-emits a schema-INVALID document. Use Dims() to
	// read the axes without caring which spelling arrived.
	Shape *[]string `json:"shape,omitempty"`
	// Location tags the variable's staggered-grid location
	// (e.g., "cell_center", "edge_normal", "vertex"). Empty means
	// no explicit staggering. See discretization RFC 10.2.
	Location string `json:"location,omitempty"`
	// Distribution is parameter-only: draw the value from a closed-set
	// distribution instead of fixing it at `default` (mutually exclusive with
	// it). With no Update the draw happens ONCE at setup (the UQ / ensemble
	// case); with `update.kind: "wiener"` it is redrawn every step with sqrt(dt)
	// scaling, which makes the enclosing model an SDE (esm-spec 6.3).
	Distribution *Distribution `json:"distribution,omitempty"`
	// Update is parameter-only: WHEN this parameter refreshes and WHAT from
	// (esm-spec 5.4). The wire shape is the ParameterUpdateSpec union -- either
	// one ParameterUpdate object or an ordered array of two or more -- and is
	// held as `any` (carrying ParameterUpdate or []ParameterUpdate) so the
	// reflection-based canonical emitter still walks into it and normalises the
	// floats inside. Read it through UpdateRules() rather than type-switching at
	// each site.
	Update any `json:"update,omitempty"`
}

func (mv *ModelVariable) ClearDims()

func (mv ModelVariable) Dims() []string

func (mv ModelVariable) HasUpdate() bool

func (mv *ModelVariable) SetDims(dims []string)

func (mv *ModelVariable) SetUpdate(rules []ParameterUpdate)

func (mv *ModelVariable) UnmarshalJSON(data []byte) error

func (mv ModelVariable) UpdateRules() []ParameterUpdate
```

ModelVariable represents a variable in a mathematical model.

esm 1.0.0 declares exactly TWO variable types (esm-spec 6.3): `unknown` (a quantity the solver solves for, whose behaviour is stated by the model's `equations` and NOWHERE else) and `parameter` (a quantity supplied to the solver, valued by `default` or a `distribution` and optionally refreshed by an `update`). Everything finer a solver needs -- which unknowns are ODE states, observed, or algebraic; which parameters are Brownian, discrete, sampled, or constant -- is DERIVED by the classification functions in classify.go (esm-spec 6.3.1) and MUST NOT be read off a declared type.

**Methods**

```go
func (mv *ModelVariable) ClearDims()
```

ClearDims removes the `shape` key entirely.

```go
func (mv ModelVariable) Dims() []string
```

Dims returns the variable's declared index-set axes, treating an absent `shape` and an authored empty one alike (both are scalar). It is the accessor every consumer that only cares about dimensionality should use.

```go
func (mv ModelVariable) HasUpdate() bool
```

HasUpdate reports whether the variable carries any update rule.

```go
func (mv *ModelVariable) SetDims(dims []string)
```

SetDims sets the variable's `shape` to the given axes, materializing the pointer. Passing a nil slice records an authored `"shape": []` (a scalar with the key present); call ClearDims to drop the key entirely.

```go
func (mv *ModelVariable) SetUpdate(rules []ParameterUpdate)
```

SetUpdate stores the given rules in the canonical spelling of the union: a lone rule as the OBJECT form (a one-element array is invalid per esm-spec 5.4) and two or more as the array form. No rules clears the field.

```go
func (mv *ModelVariable) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for ModelVariable.

Two fields need hand decoding. `shape` is a POINTER to a slice so that an authored `"shape": []` survives the round-trip (esm 1.0.0 requires the key on a schedule/data/remesh parameter, so dropping it re-emits an invalid document), and `update` is the ParameterUpdateSpec union — a single rule object or an ordered array of two or more — normalized into `any` holding ParameterUpdate or \[\]ParameterUpdate.

```go
func (mv ModelVariable) UpdateRules() []ParameterUpdate
```

UpdateRules returns the parameter's update rules in declaration order, flattening both spellings of the ParameterUpdateSpec union (esm-spec 5.4). A variable with no `update` returns nil.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L165) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ModelVariable)

</div>

</div>
