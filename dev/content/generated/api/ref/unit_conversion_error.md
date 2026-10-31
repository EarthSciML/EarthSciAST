---
title: "unit_conversion_error"
description: "Stable error · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `UnitConversionError` | `UnitConversionError` | `UnitConversionError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct UnitConversionError <: EarthSciASTError
UnitConversionError(msg::String)
UnitConversionError(msg)
```

A `unit_conversion` that cannot be parsed or applied.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/unit_conversion.jl#L30)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class UnitConversionError extends EsmDiagnosticError
new UnitConversionError(message: string): UnitConversionError
```

Error thrown when a unit string cannot be parsed (unknown unit name,
malformed number or exponent, unbalanced parentheses, trailing input) or when
[`convertUnits`](/generated/api/ref/convert_units) is asked to convert between incompatible dimensions.
`code` is always `unit_error` ([`ERROR_CODES`](/generated/api/ref/error_codes).UNIT_ERROR); the message
names the offending unit string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/unit-conversion.ts#L279)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class UnitConversionError(EarthSciAstError, ValueError)
```

Raised when unit_conversion cannot be applied.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/data_sources/variables.py#L29)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this error.</p>

</div>

</div>
