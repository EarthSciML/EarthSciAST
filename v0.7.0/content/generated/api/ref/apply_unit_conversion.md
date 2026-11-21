---
title: "apply_unit_conversion"
description: "Stable function · Units"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Units](/generated/api/topics/units)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `apply_unit_conversion`, `apply_unit_conversion!` | not exported | `apply_unit_conversion` | not exported | not exported |


**Note:** multiple spellings exported by: julia


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

Exported as `apply_unit_conversion` and `apply_unit_conversion!`. Both names refer to the same operation.

**`apply_unit_conversion`**

```julia
apply_unit_conversion(values::AbstractArray, conversion; variable_name)
```

```julia
apply_unit_conversion(values, conversion; variable_name) -> Array
```

Non-mutating [`apply_unit_conversion!`](/generated/api/ref/apply_unit_conversion): returns a converted copy, or
`values` itself when there is nothing to apply.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/unit_conversion.jl#L122)

**`apply_unit_conversion!`**

```julia
apply_unit_conversion!(values::AbstractVector{Float64}, conversion; variable_name)
```

```julia
apply_unit_conversion!(values, conversion; variable_name) -> values
```

Apply `conversion` to `values` IN PLACE, producing the variable's declared units
(esm-spec §8.5).

A factor (or a closed expression, which folds to one) multiplies; a factor of
exactly `1.0` leaves the values untouched rather than round-tripping them through
a multiply. An open expression is COMPILED ONCE and then evaluated per element
with the raw value bound to its single free variable; more than one free variable
is an error, since there is no second column to bind it to.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/unit_conversion.jl#L82)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
apply_unit_conversion(values: Any, conversion: Any, *, variable_name: str) -> Any
```

Apply `conversion` to `values`.

Accepts Python scalars, numpy arrays, xarray DataArrays, or anything
supporting numeric multiplication. If `conversion` is a constant
(number or closed expression), multiplies `values` by that constant.
If it is an open expression, evaluates it once per element with the raw
value bound to the expression's single free variable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/data_sources/variables.py#L99)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this function.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
