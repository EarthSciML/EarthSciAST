---
title: "exact_scale"
description: "Stable type · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `ExactScale` | `ExactScale` |


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
pub struct ExactScale {
    /* private fields */
}

impl ExactScale { pub fn one() -> Self }

impl ExactScale { pub fn integer(n: u64) -> Self }

impl ExactScale { pub fn ratio(num: u64, den: u64) -> Self }

impl ExactScale { pub fn power_of_ten(k: i32) -> Self }

impl ExactScale { pub fn pi() -> Self }

impl ExactScale { pub fn decimal(s: &str) -> Self }

impl ExactScale { pub fn multiply(&self, other: &Self) -> Self }

impl ExactScale { pub fn divide(&self, other: &Self) -> Self }

impl ExactScale { pub fn power(&self, exponent: Rational) -> Self }

impl ExactScale { pub fn is_one(&self) -> bool }

impl ExactScale { pub fn to_f64(&self) -> f64 }

impl ExactScale { pub fn ratio_string(&self) -> Option<String> }
```

The EXACT scale of a unit relative to SI (esm-spec §4.8.1 "Scales are EXACT").

Stored as a product of prime powers and a power of π, each with a rational
exponent: `mi` is 2⁴·3²·5⁻³·11·127. Multiplying units adds exponents, dividing
subtracts them and a rational power multiplies them, so a composite unit's scale
never rounds and `sqrt(km)` stays exact. Equality is exact, which is what lets a
checker decide `m + km` or `m/s = mi/h` without a floating-point tolerance. The
floating-point `Unit::scale` is kept for NUMERIC conversion only.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/units.rs#L208) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ExactScale.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ExactScale struct {
	// contains filtered or unexported fields
}

func (e ExactScale) Div(o ExactScale) ExactScale

func (e ExactScale) DivChecked(o ExactScale) (ExactScale, bool)

func (e ExactScale) Equal(o ExactScale) bool

func (e ExactScale) Float() float64

func (e ExactScale) IsOne() bool

func (e ExactScale) Mul(o ExactScale) ExactScale

func (e ExactScale) MulChecked(o ExactScale) (ExactScale, bool)

func (e ExactScale) Pow(r Rat) ExactScale

func (e ExactScale) PowChecked(r Rat) (ExactScale, bool)

func (e ExactScale) RatioString() (string, bool)

func (e ExactScale) String() string
```

ExactScale is the EXACT scale of a unit relative to SI (esm-spec §4.8.1 "Scales are EXACT"): a product of prime powers and a power of pi, each with a rational exponent, so mi is 2^4 \* 3^2 \* 5^-3 \* 11 \* 127. Multiplying units adds exponents, dividing subtracts them and a rational power multiplies them, so a composite unit's scale never rounds. The zero value is exactly 1. Every scale AGREEMENT (m + km, m/s = mi/h) is decided with Equal; the float Scale on Unit is kept for numeric conversion only.

**Methods**

```go
func (e ExactScale) Div(o ExactScale) ExactScale
```

Div is the exact scale of a quotient of units. It panics with errExponentOverflow on overflow; see DivChecked.

```go
func (e ExactScale) DivChecked(o ExactScale) (ExactScale, bool)
```

DivChecked is Div that reports an exponent overflow instead.

```go
func (e ExactScale) Equal(o ExactScale) bool
```

Equal reports whether two exact scales are the same number.

```go
func (e ExactScale) Float() float64
```

Float is the nearest float64, for diagnostics and numeric conversion. Two scales are never compared through it.

```go
func (e ExactScale) IsOne() bool
```

IsOne reports whether the scale is exactly 1.

```go
func (e ExactScale) Mul(o ExactScale) ExactScale
```

Mul is the exact scale of a product of units. It panics with errExponentOverflow on overflow; see MulChecked.

```go
func (e ExactScale) MulChecked(o ExactScale) (ExactScale, bool)
```

MulChecked is Mul that reports an exponent overflow instead.

```go
func (e ExactScale) Pow(r Rat) ExactScale
```

Pow is the exact scale of a unit raised to a rational power. It panics with errExponentOverflow on overflow; see PowChecked.

```go
func (e ExactScale) PowChecked(r Rat) (ExactScale, bool)
```

PowChecked is Pow that reports an exponent overflow instead.

```go
func (e ExactScale) RatioString() (string, bool)
```

RatioString renders the scale as "p/q", "p/q\*pi" or "p/q\*pi^k" in lowest terms ("/q" omitted when it is 1) -- the spelling tests/conformance/unit\_registry pins. ok is false when an exponent is not whole (sqrt(km)).

```go
func (e ExactScale) String() string
```

String renders the scale for a diagnostic.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/units.go#L500) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExactScale)

</div>

</div>
