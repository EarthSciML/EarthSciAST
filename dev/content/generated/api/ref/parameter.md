---
title: "parameter"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `Parameter` | not exported | `Parameter` | not exported | `Parameter` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct Parameter
Parameter(name::String; ...)
Parameter(name::String, default::Union{Nothing, Real}; description, units, default_units, shape, distribution, update)
```

```julia
Parameter
```

A reaction system's parameter (`reaction_systems.*.parameters.*`) — the
reaction-side twin of a [`ModelVariable`](/generated/api/ref/model_variable) of `ParameterVariable` type,
and it carries the SAME value model (esm-spec §5.4, §6.3): a `default`, a
`distribution`, a `shape`, and an `update` rule set.

`esm-schema.json`'s `Parameter` declares NO required properties, so `default`
is optional: a parameter valued by a `distribution` — or one whose whole value
is supplied by an `update` binding to a data source — is a legal document with
no `default` at all. It is `Union{Float64,Nothing}` for exactly that reason.

`shape` / `distribution` / `update` are here for the same reason they are on
`ModelVariable`: the schema defines them and a field this struct does not hold
is a field `load` silently drops. `update` is the load-bearing one — an
`update` block is the only channel binding a parameter to a data source
(§5.4), so dropping it does not just lose annotation, it turns a data-driven
parameter into a constant.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L1787)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class Parameter
Parameter(name: str, value: float | Expr, units: str | None = None, default_units: str | None = None, description: str | None = None, uncertainty: float | None = None, shape: list[str] | None = None, distribution: Distribution | None = None, update: ParameterUpdate | list[ParameterUpdate] | None = None)
```

A parameter for reaction systems.

Carries the same value machinery as a model `parameter` (schema
`$defs/Parameter`): a fixed `default` (`value` here) OR a `distribution`,
plus an optional `update` saying when it refreshes and what from, and a
`shape` naming the index sets an arrayed parameter is declared over.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L533)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Parameter struct {
	Units   *string `json:"units,omitempty"`
	Default any     `json:"default,omitempty"`
	// DefaultUnits declares the units the scalar `default` is expressed in when
	// they differ from `units`. `omitempty`: optional, usually absent.
	DefaultUnits *string `json:"default_units,omitempty"`
	Description  *string `json:"description,omitempty"`
	// Shape lists index-set names for an arrayed parameter, exactly as
	// ModelVariable.Shape does — and for the same reason it is a POINTER to a
	// slice rather than a plain one. `omitempty` on a `*[]string` omits only the
	// NIL pointer (the key was absent); a pointer to an EMPTY slice still emits
	// `"shape": []`. That distinction is load-bearing here: esm-schema.json
	// REQUIRES `shape` on a parameter whose `update` kind is `schedule`, `data`,
	// or `remesh` (esm-spec §5.4), and every such parameter in the corpus is a
	// scalar authored as `"shape": []`. A plain `[]string` would collapse the
	// authored empty array into an omitted key and re-emit a schema-INVALID
	// document. Read it through Dims().
	Shape *[]string `json:"shape,omitempty"`
	// Distribution draws the parameter's value from a closed-set distribution
	// instead of fixing it at `default` (mutually exclusive with it).
	Distribution *Distribution `json:"distribution,omitempty"`
	// Update is the ParameterUpdateSpec union — one ParameterUpdate object or an
	// ordered array of two or more — held as `any` for the same reason
	// ModelVariable.Update is. Read it through UpdateRules().
	Update any `json:"update,omitempty"`
}

func (p *Parameter) ClearDims()

func (p Parameter) Dims() []string

func (p Parameter) HasUpdate() bool

func (p *Parameter) SetDims(dims []string)

func (p *Parameter) SetUpdate(rules []ParameterUpdate)

func (p *Parameter) UnmarshalJSON(data []byte) error

func (p Parameter) UpdateRules() []ParameterUpdate
```

Parameter represents a reaction-system parameter — rate constant, temperature, photolysis rate.

It carries the SAME value machinery as a model `parameter` (esm-schema.json `$defs/Parameter`, whose own description says so): a fixed `default` or a `distribution`, an optional `shape`, and an optional `update` saying when it refreshes. Modelling only units/default/description made the type lossy in a way that changed MEANING rather than presentation: an `update` block is the only channel binding a parameter to a `data_sources` entry (esm-spec §5.4), so dropping it silently converted a data-driven parameter into a constant held at its `default`.

**Methods**

```go
func (p *Parameter) ClearDims()
```

ClearDims removes the `shape` key entirely.

```go
func (p Parameter) Dims() []string
```

Dims returns the parameter's declared index-set axes, treating an absent `shape` and an authored empty one alike (both are scalar). Mirrors ModelVariable.Dims.

```go
func (p Parameter) HasUpdate() bool
```

HasUpdate reports whether the parameter carries any update rule.

```go
func (p *Parameter) SetDims(dims []string)
```

SetDims sets the parameter's `shape` to the given axes, materializing the pointer. Passing a nil slice records an authored `"shape": []`; call ClearDims to drop the key entirely. Mirrors ModelVariable.SetDims.

```go
func (p *Parameter) SetUpdate(rules []ParameterUpdate)
```

SetUpdate stores the given rules in the canonical spelling of the union: a lone rule as the OBJECT form (a one-element array is invalid per esm-spec §5.4) and two or more as the array form. No rules clears the field.

```go
func (p *Parameter) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for Parameter. Decodes `default` through UnmarshalExpression so an integer-valued default keeps its int wire shape (RFC §5.4.1); a plain decode would coerce it to float64 and re-emit "1.0". `shape` and `update` are decoded exactly as ModelVariable decodes them — the pointer-to-slice keeps an authored `"shape": []` distinguishable from an absent key, and unmarshalParameterUpdateSpec normalizes the §5.4 union.

```go
func (p Parameter) UpdateRules() []ParameterUpdate
```

UpdateRules returns the parameter's update rules in declaration order, flattening both spellings of the ParameterUpdateSpec union (esm-spec §5.4). Mirrors ModelVariable.UpdateRules.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L442) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Parameter)

</div>

</div>
