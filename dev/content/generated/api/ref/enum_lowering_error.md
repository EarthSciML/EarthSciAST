---
title: "enum_lowering_error"
description: "Stable error · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `EnumLoweringError` | `EnumLoweringError` | `EnumLoweringError` | `EnumLoweringError` | `EnumLoweringError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct EnumLoweringError <: EarthSciASTError
EnumLoweringError(code::String, message::String)
EnumLoweringError(code, message)
```

```julia
EnumLoweringError <: EarthSciASTError
```

Raised when enum lowering (esm-spec §9.3) fails, carrying the stable diagnostic
`code` as a structured field rather than interpolated into the message — the
same shape as [`ClosedFunctionError`](/generated/api/ref/closed_function_error), and the same error TYPE the four
other bindings raise here (`EnumLoweringError` in TypeScript, Python and Rust;
`DiagnosticError` in Go). Julia raised `ParseError` from this pass until
API_SPEC.md §8 item 15, which made a caller's `catch e; e isa ParseError` the
only portable way to handle a failure that is not a parse failure at all.

Codes: `enum_op_malformed`, `unknown_enum`, `unknown_enum_symbol`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/registered_functions.jl#L1402)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class EnumLoweringError extends EsmDiagnosticError
new EnumLoweringError(code: string, message: string): EnumLoweringError
```

Error thrown by [`lowerEnums`](/generated/api/ref/lower_enums) (and so by loading) when an `enum` op
cannot be lowered. `code` is `enum_op_malformed`, `unknown_enum` or
`unknown_enum_symbol`, as listed above; the message is `[code] message`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-enums.ts#L42)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class EnumLoweringError(EarthSciAstError, ValueError)
EnumLoweringError(code: str, message: str)
```

Raised when enum lowering (esm-spec §9.3) fails.

Carries the stable diagnostic `code` (`unknown_enum` /
`unknown_enum_symbol` / `enum_duplicate_value`) as a structured attribute — like
`ClosedFunctionError` — instead of interpolating it into the message
text. Also subclasses `ValueError`, so `except ValueError` catches
it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/registered_functions.py#L653)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub type EnumLoweringError = DiagnosticError;
```

Stable diagnostic codes raised by the enum-lowering pass. Mirrors the
codes emitted by the TS / Python / Julia / Go bindings.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/lower_enums.rs#L25) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/type.EnumLoweringError.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type EnumLoweringError struct {
	Code    string
	Message string
}

func (e *EnumLoweringError) DiagnosticCode() string

func (e *EnumLoweringError) Error() string
```

EnumLoweringError carries the spec-defined diagnostic codes for the load-time lowering pass:

- unknown\_enum         — `enum` op names an undeclared enum.
- unknown\_enum\_symbol  — `enum` op names a symbol not declared under that enum.
- enum\_duplicate\_value — two symbols of one enum map to the same integer.

**Methods**

```go
func (e *EnumLoweringError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *EnumLoweringError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/lower_enums.go#L23) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#EnumLoweringError)

</div>

</div>
