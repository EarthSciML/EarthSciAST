---
title: "convert_units"
description: "Stable function · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `convertUnits` | `convert_units` | `convert_units` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function convertUnits(value: number, from: string, to: string): number
```

Convert a numeric value from one unit string to another.

**Throws**

- [`UnitConversionError`](/generated/api/ref/unit_conversion_error) — when the unit strings have incompatible dimensions
    or cannot be parsed.

**Example**

```typescript
convertUnits(1, 'km', 'm')            // 1000
convertUnits(0, 'Celsius', 'K')       // 273.15
convertUnits(1, 'atm', 'Pa')          // 101325
convertUnits(1, 'Dobson', 'molec/m^2') // 2.6867e20
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/unit-conversion.ts#L1101)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
convert_units(value: float, from_unit: str, to_unit: str) -> UnitConversionResult
```

Convenience function to convert units.

**Parameters**

- `value` (`float`) — Numeric value to convert
- `from_unit` (`str`) — Source unit string
- `to_unit` (`str`) — Target unit string

**Returns**

- `UnitConversionResult` — UnitConversionResult with conversion result

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/units.py#L2449)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn convert_units(value: f64, from_unit: &Unit, to_unit: &Unit) -> Result<f64, UnitError>
```

Convert between compatible units

**Arguments**

* `value` - Value to convert
* `from_unit` - Source unit
* `to_unit` - Target unit

**Returns**

* `Result<f64, UnitError>` - Converted value or error

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/units.rs#L3441) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.convert_units.html)

**Example** (`convert_units`)

```rust
let km = parse_unit("km")?;
let m = parse_unit("m")?;
assert_eq!(convert_units(2.5, &km, &m)?, 2500.0);

// Incompatible dimensions are an error.
assert!(convert_units(1.0, &km, &parse_unit("s")?).is_err());
```

<p class="api-src">From <a href="https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/docs/api/examples/rust/units.rs#L12-L17">docs/api/examples/rust/units.rs</a></p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
