---
title: "closed_function_error"
description: "Stable error · Expressions"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Expressions](/generated/api/topics/expressions)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ClosedFunctionError` | `ClosedFunctionError` | not exported | `ClosedFunctionError` | `ClosedFunctionError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ClosedFunctionError <: EarthSciASTError
ClosedFunctionError(code::String, message::String)
ClosedFunctionError(code, message)
```

```julia
ClosedFunctionError(code::String, message::String)
```

Raised by the closed function registry when the spec contract is violated.
`code` is one of the stable diagnostic codes pinned by esm-spec §9.1–§9.2:

- `unknown_closed_function` — `fn`-op `name` is not in the v0.3.0 set.
- `closed_function_arity` — wrong number of arguments for the named function.
- `closed_function_overflow` — integer-typed result would overflow Int32.
- `searchsorted_non_monotonic` — `xs` is not non-decreasing.
- `searchsorted_nan` — `xs` contains a NaN entry (checked before monotonicity).
- `interp_axis_not_const` — `interp.searchsorted`'s `xs` is not a rank-1 array
  of numbers (a scalar, a nested array); checked before `searchsorted_nan`.
- `interp_non_monotonic_axis` — `interp.linear` / `interp.bilinear` axis is
  not strictly increasing (esm-spec §9.2; equal-adjacent rejected because the
  blend denominator would be zero).
- `interp_axis_length_mismatch` — `interp.linear`: `len(table) != len(axis)`;
  `interp.bilinear`: `len(table) != len(axis_x)`, or any inner row length
  differs from `len(axis_y)`.
- `interp_nan_in_axis` — any `axis` (or `axis_x`, `axis_y`) contains a value
  that is not finite (NaN, +Inf or -Inf; ruling Q-113).
- `interp_axis_too_short` — any axis has fewer than 2 entries.
- `interp_table_not_const` / `interp_axis_not_const` — table / axis (or
  `interp.searchsorted` `xs`) argument is not a literal `const`-op array of
  the required rank (e.g. a variable reference, a scalar `const`, a nested
  array where a flat one belongs; ruling Q-108). Raised at load and by
  `validate()` on every `interp.*` `fn` node (load_time_checks.jl), by the
  build's const-arg protocol and the MTK lowering, and — for a value of the
  wrong rank — by `evaluate_closed_function` itself.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/registered_functions.jl#L95)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class ClosedFunctionError extends EsmDiagnosticError
new ClosedFunctionError(code: ClosedFunctionErrorCode, message: string): ClosedFunctionError
```

Error thrown by closed function dispatch and load-time table validation.
`code` identifies the spec-pinned diagnostic; cross-binding harnesses
compare against this exact string.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-ts/src/closed-functions.ts#L46)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this error.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ClosedFunctionError {
    pub code: String,
    pub message: String,
}

impl ClosedFunctionError { pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self }
```

Error type for closed-function dispatch failures (esm-spec §9.1–§9.2).

The `code` field carries one of the stable diagnostic codes pinned by the
spec; downstream tooling pattern-matches on these strings. The set is
kept in lockstep with the Julia / Python / TypeScript / Go bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/registered_functions.rs#L36) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ClosedFunctionError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ClosedFunctionError struct {
	Code    string
	Message string
}

func (e *ClosedFunctionError) DiagnosticCode() string

func (e *ClosedFunctionError) Error() string
```

ClosedFunctionError carries the spec-defined diagnostic codes pinned by esm-spec §9.1–§9.2 / §9.3:

- unknown\_closed\_function     — `fn` name is not in the v0.3.0 set.
- closed\_function\_arity       — wrong number of arguments.
- closed\_function\_overflow    — integer-typed result would overflow Int32.
- searchsorted\_non\_monotonic  — xs is not non-decreasing.
- searchsorted\_nan            — xs contains a NaN entry (checked before monotonicity).
- interp\_axis\_not\_const       — an axis, or searchsorted's xs, is not a rank-1 `const` array (checked before searchsorted\_nan).
- interp\_table\_not\_const      — an interp.linear/bilinear table is not a `const` array of rank 1 (linear) or rank 2 (bilinear).
- interp\_non\_monotonic\_axis   — interp.linear/bilinear axis is not strictly increasing.
- interp\_axis\_length\_mismatch — table shape disagrees with axis length(s).
- interp\_nan\_in\_axis          — interp.linear/bilinear axis contains NaN.
- interp\_axis\_too\_short       — interp.linear/bilinear axis has fewer than 2 entries.

**Methods**

```go
func (e *ClosedFunctionError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *ClosedFunctionError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/registered_functions.go#L66) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ClosedFunctionError)

</div>

</div>
