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

Each concrete subtype has its own fields, messages and `Base.showerror` method,
and `EarthSciASTError <: Exception`, so a plain `catch e` / `e isa Exception`
catches every one of them too.

Members span the whole pipeline: load/parse (`ParseError`,
`SchemaValidationError`, `ExpressionParseError`, `SubsystemRefError`), the
load-time lowering passes (`ExpressionTemplateError`, `ClosedFunctionError`),
flattening (the eight `flatten_errors.jl` types), units
(`UnitConversionError`), evaluation and simulation (`TreeWalkError`,
`SimulateError`, `RefreshError`, `OutputError`), editing (`EditError`), and
the two namespaced submodules (`Cadence.CadenceError`,
`Relational.FloatKeyError`).

A handful of subtypes are INTERNAL control-flow signals rather than user-facing
diagnostics — `EarthSciAST`-private types whose names begin with `_`
(`_UnitParseError`, `_CodegenDecline`, `_StencilFallback`,
`_BroadcastBudgetExceeded`). They are caught by their concrete type at the
throw's immediate call site and never escape the package; they subtype this
root only so the rule "every exception in the package is an
`EarthSciASTError`" has no exceptions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/errors.jl#L14)

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

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/errors.py#L6)

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
