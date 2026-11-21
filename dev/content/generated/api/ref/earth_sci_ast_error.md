---
title: "earth_sci_ast_error"
description: "Stable error · Errors"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Errors](/generated/api/topics/errors)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `EarthSciASTError` | not exported | `EarthSciAstError` | not exported | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
abstract type EarthSciASTError <: Exception
```

```julia
EarthSciASTError <: Exception
```

Abstract supertype of every exception raised by `EarthSciAST`.

Catching this one type catches them all:

```julia
try
    file = load_path("model.esm")
    flat = flatten(file)
catch e
    e isa EarthSciASTError || rethrow()
    @warn "ESM pipeline failed" exception = e
end
```

`EarthSciASTError <: Exception`, so a plain `catch e` / `e isa Exception`
catches every one of them too.

Members span the whole pipeline: load/parse (`ParseError`,
`SchemaValidationError`, `SubsystemRefError`), the
load-time lowering passes (`ExpressionTemplateError`, `EnumLoweringError`),
flattening (the `flatten_errors.jl` types, under [`FlattenError`](/generated/api/ref/flatten_error)), units
(`UnitConversionError`), evaluation and simulation (`TreeWalkError`,
`SimulateError`, `RefreshError`, `OutputError`), editing (`EditError`), and
the namespaced submodule `Relational` (`Relational.FloatKeyError`).

Every exported subtype stores its diagnostic code in its first field, `code`,
and all of them are read with the same four accessors ([`error_code`](/generated/api/extension/julia#x-error_code),
[`error_message`](/generated/api/extension/julia#x-error_message), [`error_path`](/generated/api/extension/julia#x-error_path), [`error_file`](/generated/api/extension/julia#x-error_file)) and print
through one `showerror`.

A handful of subtypes are INTERNAL control-flow signals rather than user-facing
diagnostics — `EarthSciAST`-private types whose names begin with `_`
(`_CanonFail`, `_Decline`,
`_BroadcastBudgetExceeded`). They are caught by their concrete type at the
throw's immediate call site and never escape the package; they subtype this
root so that every exception the package raises is an `EarthSciASTError`. The
one signal outside the root is `_HaloDone` (range/tile.jl), which leaves a
build at the range seam: no `catch` of an `EarthSciASTError` between the seam
and its handler may swallow it.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/EarthSciAST.jl/src/errors.jl#L14)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this error.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class EarthSciAstError(Exception)
```

Root of the earthsci_ast exception hierarchy.

Every exception raised by this package derives from this class, so callers
can catch all package errors with a single `except EarthSciAstError`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/1b8dd9b3a909d0f577bce67589773106fbd2ec95/pkg/earthsci-ast-py/src/earthsci_ast/errors.py#L6)

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
