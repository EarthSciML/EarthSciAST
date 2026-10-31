---
title: "parameter_update"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ParameterUpdate` | not exported | `ParameterUpdate` | `ParameterUpdate` | `ParameterUpdate` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ParameterUpdate
ParameterUpdate(kind::AbstractString; times, interval, initial_offset, when, direction, source, hook, expression, from, handler)
```

```julia
ParameterUpdate
```

One rule saying WHEN a parameter refreshes and WHAT it refreshes from
(esm-spec §5.4). One mechanism covers a Wiener noise source
(`kind: "wiener"`), a refresh on a schedule, from data or on a remesh
(`schedule` / `data` / `remesh`), and a change when a condition holds or a
crossing occurs (`condition` / `crossing`).

Trigger fields by kind: `schedule` uses `times` / `interval` /
`initial_offset`; `condition` and `crossing` use `when` (plus `direction` for
`crossing`); `data` uses `source`; `remesh` uses `hook`; `wiener` uses none.
Value forms: exactly one of `expression`, `from`, `handler` for every kind
except `wiener`, which resamples the parameter's own `distribution`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/types.jl#L973)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ParameterUpdate
ParameterUpdate(kind: Literal['wiener', 'schedule', 'condition', 'crossing', 'data', 'remesh'], times: list[float] | None = None, interval: float | None = None, initial_offset: float | None = None, when: Expr | None = None, direction: str | None = None, source: str | None = None, hook: str | None = None, expression: Expr | None = None, from_source: DataSourceBinding | None = None, handler: FunctionalUpdate | None = None)
```

One rule declaring WHEN a parameter refreshes and WHAT from (esm-spec
§5.4). Six kinds, and this single dataclass carries the union of their
slots — only those belonging to `kind` are ever populated or emitted.

`wiener` is a driving stochastic process: it takes no value form (it
resamples the parameter's own `distribution`) and requires one. The other
five each take EXACTLY ONE value form — `expression`, `from_source`
(wire key `from`), or `handler`.

`schedule` fires at preset `times` and/or every `interval`;
`condition` at the end of any step where `when` is true; `crossing`
when `when` crosses zero (located by root-finding); `data` when the
named `data_sources` entry advances a record; `remesh` on a
mesh-topology change. ParameterUpdate is also the SOLE seed of the DISCRETE
cadence class (CONFORMANCE_SPEC §5.7.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L397)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum ParameterUpdate {
    Wiener,
    Schedule { times: Option<Vec<f64>>, interval: Option<f64>, initial_offset: Option<f64>, value: UpdateValue },
    Condition { when: Expr, value: UpdateValue },
    Crossing { when: Expr, direction: Option<String>, value: UpdateValue },
    Data { source: String, value: UpdateValue },
    Remesh { hook: Option<String>, value: UpdateValue },
}

impl ParameterUpdate { pub fn kind(&self) -> &'static str }

impl ParameterUpdate { pub fn value(&self) -> Option<&UpdateValue> }

impl ParameterUpdate { pub fn value_mut(&mut self) -> Option<&mut UpdateValue> }

impl ParameterUpdate { pub fn when(&self) -> Option<&Expr> }

impl ParameterUpdate { pub fn when_mut(&mut self) -> Option<&mut Expr> }

impl ParameterUpdate { pub fn data_source(&self) -> Option<&str> }
```

One update rule: WHEN a parameter refreshes, and WHAT from
(esm-spec §5.4). Every kind except `wiener` carries exactly one value form
— `expression`, `from`, or `handler` — held in the flattened
[`UpdateValue`](/generated/api/extension/rust#x-updatevalue); `wiener` carries none, because the parameter's
`distribution` IS its value.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/model.rs#L801) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.ParameterUpdate.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ParameterUpdate struct {
	Kind string `json:"kind"`

	// --- schedule ---
	Times         []float64 `json:"times,omitempty"`
	Interval      *float64  `json:"interval,omitempty"`
	InitialOffset *float64  `json:"initial_offset,omitempty"`

	// --- condition / crossing ---
	When Expression `json:"when,omitempty"`
	// Direction is crossing-only: "up" | "down" | "any" (default "any").
	Direction string `json:"direction,omitempty"`

	// --- data ---
	// Source names a `data_sources` key; it MUST resolve
	// (`data_source_undefined`, esm-spec 8.5).
	Source string `json:"source,omitempty"`

	// --- remesh ---
	Hook string `json:"hook,omitempty"`

	// --- the three value forms; exactly one is set on a non-wiener rule ---
	Expression Expression         `json:"expression,omitempty"`
	From       *DataSourceBinding `json:"from,omitempty"`
	Handler    *FunctionalUpdate  `json:"handler,omitempty"`
}

func (u ParameterUpdate) IsBrownian() bool

func (u *ParameterUpdate) UnmarshalJSON(data []byte) error
```

ParameterUpdate is ONE rule of a parameter's `update` block (esm-spec 5.4): WHEN the parameter refreshes (Kind, plus the kind's own trigger fields) and WHAT from (exactly one of Expression / From / Handler -- except `wiener`, which takes none because it resamples the parameter's own Distribution).

It collapses three 0.x constructs: the `brownian` variable type (now `wiener`), the `discrete` type's RefreshTrigger (now `schedule` / `data` / `remesh`), and the `discrete_parameters` event lists with their `functional_affect` (now `condition` / `crossing` carrying a Handler).

**Methods**

```go
func (u ParameterUpdate) IsBrownian() bool
```

IsBrownian reports whether this rule is the driving Wiener process.

```go
func (u *ParameterUpdate) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for ParameterUpdate: `when` and `expression` are Expression positions and must go through UnmarshalExpression so a numeric literal keeps its int/float wire shape and an operator object becomes an ExprNode rather than a raw map.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L309) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParameterUpdate)

</div>

</div>
