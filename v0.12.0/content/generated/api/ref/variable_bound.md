---
title: "variable_bound"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `VariableBound` | `VariableBound` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub enum VariableBound {
    Number(Number),
    Reference(String),
    Expression(Expr),
}

impl VariableBound { pub fn as_number(&self) -> Option<f64> }

impl VariableBound { pub fn as_reference(&self) -> Option<&str> }

impl VariableBound { pub fn map_references(&self, f: impl FnOnce(&Expr) -> Expr) -> VariableBound }
```

One bound of a model variable (esm-spec §6.3.2): the `lb` or `ub` field.

`#[serde(untagged)]`, so a number round-trips as the number written (held
as a `serde_json::Number`, so `0` stays `0` and `0.5` stays `0.5`) and a
reference as the string written.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-rs/src/types/model.rs#L487) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.VariableBound.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type VariableBound struct {
	Number any
	Ref    *string
}

func (b VariableBound) MarshalJSON() ([]byte, error)

func (b *VariableBound) UnmarshalJSON(data []byte) error
```

VariableBound is one bound of a model variable (esm-spec §6.3.2): a number in the variable's declared `units`, or a reference to another variable, written and resolved as a variable reference in the model's expressions. Exactly one of Number and Ref is set.

Number holds an int64 or a float64, decoded by the int/float rule every numeric literal follows (normalizeJSONNumber): a token with '.', 'e' or 'E' is a float64, any other an int64 (a float64 only beyond the int64 range). So a bound stays the number written (esm-spec §6.3.2, "Round-trip"): an integer keeps every digit, and a float is emitted as a float — `1.0` stays `1.0` rather than collapsing to `1` as the document form does elsewhere. A reference is emitted as the string written.

**Methods**

```go
func (b VariableBound) MarshalJSON() ([]byte, error)
```

MarshalJSON writes the bound as a JSON number or a JSON string.

```go
func (b *VariableBound) UnmarshalJSON(data []byte) error
```

UnmarshalJSON reads a bound that is a JSON number or a JSON string. Whether the string names a variable is the validator's question, not the decoder's.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/00808ba516066c29654f9613e987190c0347e352/pkg/earthsci-ast-go/pkg/esm/variable_bounds.go#L29) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#VariableBound)

</div>

</div>
