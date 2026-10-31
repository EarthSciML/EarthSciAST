---
title: "dimension"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `Dimension` | `Dimension` |


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
pub enum Dimension {
    Mass,
    Length,
    Time,
    Current,
    Temperature,
    Amount,
    Luminosity,
    Angle,
}
```

Base physical dimensions — the eight canonical axes shared across the
bindings (`m kg s mol K A cd rad`).

`Angle` is a full axis rather than a synonym for dimensionless, matching the
Go reference. The trigonometric functions therefore accept an angle OR a
dimensionless argument (see `propagate_transcendental_dim`); `exp`/`log` still
demand strict dimensionlessness.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/units.rs#L409) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.Dimension.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Dimension [8]Rat
func (d Dimension) Divide(other Dimension) Dimension
func (d Dimension) DivideChecked(other Dimension) (Dimension, bool)
func (d Dimension) Equal(other Dimension) bool
func (d Dimension) IsDimensionless() bool
func (d Dimension) Multiply(other Dimension) Dimension
func (d Dimension) MultiplyChecked(other Dimension) (Dimension, bool)
func (d Dimension) Power(n int) Dimension
func (d Dimension) PowerRat(e Rat) Dimension
func (d Dimension) PowerRatChecked(e Rat) (Dimension, bool)
func (d Dimension) String() string
```

Dimension is a vector of RATIONAL exponents over the 7 SI base units plus radian. Index order: m, kg, s, mol, K, A, cd, rad.

**Methods**

```go
func (d Dimension) Divide(other Dimension) Dimension
```

Divide subtracts component-wise exponents. It panics with errExponentOverflow on overflow; see DivideChecked.

```go
func (d Dimension) DivideChecked(other Dimension) (Dimension, bool)
```

DivideChecked is Divide that reports an exponent overflow instead.

```go
func (d Dimension) Equal(other Dimension) bool
```

Equal reports whether two dimensions denote the same exponent vector.

```go
func (d Dimension) IsDimensionless() bool
```

IsDimensionless reports whether every exponent is zero.

```go
func (d Dimension) Multiply(other Dimension) Dimension
```

Multiply adds component-wise exponents. It panics with errExponentOverflow on overflow; see MultiplyChecked.

```go
func (d Dimension) MultiplyChecked(other Dimension) (Dimension, bool)
```

MultiplyChecked is Multiply that reports an exponent overflow instead.

```go
func (d Dimension) Power(n int) Dimension
```

Power scales each exponent by the integer n.

```go
func (d Dimension) PowerRat(e Rat) Dimension
```

PowerRat scales each exponent by the rational e — the operation `sqrt` and a fractional literal exponent both need. It panics with errExponentOverflow on overflow; see PowerRatChecked.

```go
func (d Dimension) PowerRatChecked(e Rat) (Dimension, bool)
```

PowerRatChecked is PowerRat that reports an exponent overflow instead.

```go
func (d Dimension) String() string
```

String renders a dimension vector in SI-base notation (e.g. "m\*kg/s^2", "1/s^(1/2)").

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L169) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Dimension)

</div>

</div>
