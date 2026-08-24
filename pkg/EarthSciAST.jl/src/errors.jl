"""
Root of this package's exception hierarchy.

Every exception `EarthSciAST` raises subtypes [`EarthSciASTError`](@ref), so a
caller can bracket a whole pipeline with ONE `catch` clause instead of naming
each of the three dozen concrete types. This mirrors the Python binding, where
`earthsci_ast.errors.EarthSciAstError` has been the documented root of the
hierarchy from the start, and TypeScript's `EsmDiagnosticError`.

This file is included FIRST, before `types.jl`, so every later `struct … <:
EarthSciASTError` resolves the supertype. It deliberately has no dependencies.
"""

"""
    EarthSciASTError <: Exception

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

The concrete subtypes keep their existing names, fields, messages and
`Base.showerror` methods — introducing this supertype is purely ADDITIVE, and
`EarthSciASTError <: Exception`, so every pre-existing `catch e` /
`e isa Exception` site is unaffected.

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
"""
abstract type EarthSciASTError <: Exception end
