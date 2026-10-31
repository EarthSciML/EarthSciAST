---
title: "evaluate_closed_function"
description: "Stable function · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `evaluate_closed_function` | not exported | not exported | `evaluate_closed_function` | `EvaluateClosedFunction` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
evaluate_closed_function(name::String, args::AbstractVector)
```

```julia
evaluate_closed_function(name::String, args::Vector) -> Any
```

Dispatch a closed function call. `name` is the dotted-module spec name
(e.g. `"datetime.julian_day"`); `args` is a vector of evaluated argument
values. Integer-typed results are returned as `Int32` to make the integer
contract explicit to callers; float-typed results are `Float64`.

This entry point PINS its float-typed results to `Float64` (it infers as the
concrete `Union{Float64,Int32}`, which the tree-walk RHS depends on for its
zero-allocation property). Most of the registry tolerates an AD dual argument
anyway, because the answer does not depend on the dual part:

- `datetime.year` … `datetime.is_leap_year` — piecewise constant in their
  argument, so they take the dual's primal (see `_value`) and return `Int32`.
- `interp.searchsorted` — the query may be a dual; the result is a discrete
  `Int32` index that carries no derivative.

The three float-RETURNING functions (`interp.linear`, `interp.bilinear`,
`datetime.julian_day`) cannot honour the `Float64` pin on a dual, so they throw
here. Differentiating call sites use [`evaluate_closed_function_ad`](/generated/api/extension/julia#x-evaluate_closed_function_ad)
instead, which is the same registry without the pin.

For `interp.searchsorted` the second argument must be the table (a
`Vector{<:Real}`) — the caller is responsible for extracting the array
from a `const`-op AST node before invoking this function.

Throws [`ClosedFunctionError`](/generated/api/ref/closed_function_error) on contract violations.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/registered_functions.jl#L240)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn evaluate_closed_function(name: &str, args: &[ClosedArg]) -> Result<ClosedValue, ClosedFunctionError>
```

Dispatch a closed function call. `name` is the dotted-module spec path
(e.g. `"datetime.julian_day"`); `args` is the list of evaluated argument
values. Returns [`ClosedValue`](/generated/api/extension/rust#x-closedvalue) so callers can preserve the integer/float
distinction; promotion to `f64` is available via `ClosedValue::as_f64`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/registered_functions.rs#L170) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.evaluate_closed_function.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func EvaluateClosedFunction(name string, args []any) (any, error)
```

EvaluateClosedFunction dispatches a closed function call. `name` is the dotted-module spec name (e.g. "datetime.julian\_day"); `args` is a slice of evaluated argument values. Integer-typed results are returned as int32 to make the integer contract explicit; float-typed results are float64. For interp.searchsorted, the second argument MUST be the inline table extracted from the `const`-op AST node — the caller is responsible for that extraction.

Returns \*ClosedFunctionError on contract violations.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/registered_functions.go#L141) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EvaluateClosedFunction)

</div>

</div>
