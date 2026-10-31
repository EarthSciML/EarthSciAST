---
title: "unit"
description: "Stable type · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `Unit` | `Unit` |


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
pub struct Unit {
    /* private fields */
}

impl Unit { pub fn scale(&self) -> f64 }

impl Unit { pub fn exact_scale(&self) -> &ExactScale }

impl Unit { pub fn same_unit(&self, other: &Unit) -> bool }

impl Unit { pub fn same_dimensions(&self, other: &Unit) -> bool }

impl Unit { pub fn dimensionless() -> Self }

impl Unit { pub fn base(dimension: Dimension, power: i32, scale: f64) -> Self }

impl Unit { pub fn base_rational(dimension: Dimension, power: Rational, scale: f64) -> Self }

impl Unit { pub fn is_compatible(&self, other: &Unit) -> bool }

impl Unit { pub fn is_dimensionless(&self) -> bool }

impl Unit { pub fn is_pure_number(&self) -> bool }

impl Unit { pub fn is_plane_angle(&self) -> bool }

impl Unit { pub fn is_pure_angle(&self) -> bool }

impl Unit { pub fn multiply(&self, other: &Unit) -> Unit }

impl Unit { pub fn divide(&self, other: &Unit) -> Unit }

impl Unit { pub fn power(&self, exponent: i32) -> Unit }

impl Unit { pub fn power_rational(&self, exponent: Rational) -> Unit }

impl Unit { pub fn propagate(expr: &Expr, env: &HashMap<String, Unit>) -> Result<Unit, UnitError> }
```

Represents a physical unit with dimensions

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/units.rs#L391) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Unit.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Unit struct {
	Dim    Dimension
	Scale  float64
	Symbol string
	// Exact is the scale every agreement is decided on (esm-spec §4.8.1). Its
	// zero value is exactly 1, so a unit literal with Scale 1 needs no Exact.
	Exact ExactScale
}

func (u Unit) Divide(other Unit) Unit

func (u Unit) DivideChecked(other Unit) (Unit, error)

func (u Unit) Multiply(other Unit) Unit

func (u Unit) MultiplyChecked(other Unit) (Unit, error)

func (u Unit) Power(n int) Unit

func (u Unit) PowerRat(e Rat) Unit

func (u Unit) PowerRatChecked(e Rat) (Unit, error)
```

Unit is a named physical unit with a dimension vector and a scale factor relative to the canonical SI combination represented by Dim.

**Methods**

```go
func (u Unit) Divide(other Unit) Unit
```

Divide returns the quotient of two units. It panics with errExponentOverflow on overflow; see DivideChecked.

```go
func (u Unit) DivideChecked(other Unit) (Unit, error)
```

DivideChecked is Divide that returns errExponentOverflow instead of panicking.

```go
func (u Unit) Multiply(other Unit) Unit
```

Multiply returns the product of two units (dimensions add, scales multiply). It panics with errExponentOverflow on overflow; see MultiplyChecked.

```go
func (u Unit) MultiplyChecked(other Unit) (Unit, error)
```

MultiplyChecked is Multiply that returns errExponentOverflow instead of panicking.

```go
func (u Unit) Power(n int) Unit
```

Power raises a unit to an integer power.

```go
func (u Unit) PowerRat(e Rat) Unit
```

PowerRat raises a unit to a RATIONAL power (`s^(-1/2)`, `sqrt(m^3)`). It panics with errExponentOverflow on overflow; see PowerRatChecked.

```go
func (u Unit) PowerRatChecked(e Rat) (Unit, error)
```

PowerRatChecked is PowerRat that returns errExponentOverflow instead of panicking.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L763) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Unit)

</div>

</div>
