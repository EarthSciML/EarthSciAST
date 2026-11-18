"""
Root of this package's exception hierarchy.

Every exception `EarthSciAST` raises subtypes [`EarthSciASTError`](@ref), so a
caller can bracket a whole pipeline with ONE `catch` clause instead of naming
each of the concrete types. This mirrors the Python binding, where
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

`EarthSciASTError <: Exception`, so a plain `catch e` / `e isa Exception`
catches every one of them too.

Members span the whole pipeline: load/parse (`ParseError`,
`SchemaValidationError`, `SubsystemRefError`), the
load-time lowering passes (`ExpressionTemplateError`, `EnumLoweringError`),
flattening (the `flatten_errors.jl` types, under [`FlattenError`](@ref)), units
(`UnitConversionError`), evaluation and simulation (`TreeWalkError`,
`SimulateError`, `RefreshError`, `OutputError`), editing (`EditError`), and
the namespaced submodule `Relational` (`Relational.FloatKeyError`).

Every exported subtype stores its diagnostic code in its first field, `code`,
and all of them are read with the same four accessors ([`error_code`](@ref),
[`error_message`](@ref), [`error_path`](@ref), [`error_file`](@ref)) and print
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
"""
abstract type EarthSciASTError <: Exception end

# ---------------------------------------------------------------------------
# The one diagnostic shape
# ---------------------------------------------------------------------------

"""
    error_code(e::EarthSciASTError) -> String

The diagnostic code `e` carries: a value of [`ERROR_CODES`](@ref) for a
failure the bindings share, an `E_TREEWALK_*` / `E_DIRECT_*` code for a
Julia-evaluator failure, or `""` when the failure has no code (a malformed JSON
text, a misuse of an editing function). Every exported error type stores it in
its FIRST field, `code`.
"""
error_code(e::EarthSciASTError)::String = _string_field(e, :code)

"""
    error_message(e::EarthSciASTError) -> String

The human-readable text of `e`, without its type name, code or location. Codes
and messages pinned by the conformance corpus are this text.
"""
error_message(e::EarthSciASTError)::String =
    hasfield(typeof(e), :message) ? _string_field(e, :message) : _string_field(e, :msg)

"""
    error_path(e::EarthSciASTError) -> String

The RFC 6901 pointer, into the document named by [`error_file`](@ref), of the
construct `e` is about; `""` when the failure has no single location.
"""
error_path(e::EarthSciASTError)::String = _string_field(e, :path)

"""
    error_file(e::EarthSciASTError) -> String

The canonical key (absolute path or URL) of the document `e` is about when a
load read more than one, `""` for the document the caller handed over.
"""
error_file(e::EarthSciASTError)::String = _string_field(e, :file)

# The `String` field `f` of `e`, `""` when `e` has no such field or it holds
# something else (a `QualifiedReferenceError.path` is a component list).
function _string_field(e, f::Symbol)::String
    hasfield(typeof(e), f) || return ""
    v = getfield(e, f)
    return v isa AbstractString ? String(v) : ""
end

"""
    showerror(io, e::EarthSciASTError)

Every error of this package prints the same way:

    TypeName [code]: message (at /pointer in file)

The `[code]` is left out when the code is empty, and the parenthesis when the
error has neither a path nor a file. A type changes what it prints only by
defining [`error_message`](@ref).
"""
function Base.showerror(io::IO, e::EarthSciASTError)
    print(io, nameof(typeof(e)))
    code = error_code(e)
    isempty(code) || print(io, " [", code, "]")
    print(io, ": ", error_message(e))
    path = error_path(e)
    file = error_file(e)
    if !isempty(path) || !isempty(file)
        print(io, " (")
        isempty(path) || print(io, "at ", path)
        isempty(path) || isempty(file) || print(io, " ")
        isempty(file) || print(io, "in ", file)
        print(io, ")")
    end
    return nothing
end

"""
    _is_resource_error(e) -> Bool

True for the exceptions that mean THE PROCESS ran out of something, not that
the DOCUMENT is wrong: `OutOfMemoryError`, `StackOverflowError` and
`InterruptException`.

Several passes bracket a speculative evaluation in a broad `catch` and, on
failure, either decline (fall through to a slower form) or rebrand the failure
as the diagnostic that describes the document — "this RHS does not const-fold",
say. Both readings are wrong for a resource error. A rebranded one is worse
than merely wrong: `TreeWalkError` is on the `_foldable_failure` allowlist and
is swallowed outright at several `err isa TreeWalkError || rethrow()` sites, so
wrapping an `OutOfMemoryError` in one can turn running out of memory into a
silent decline several frames up. Test-side corpus sweeps then record it as an
ordinary "this model cannot build standalone" skip and stay green.

So every such site MUST let these three through unwrapped before it decides
anything. The sweeps keep their own copy of this predicate
(`corpus_is_resource_error` in test/testutils.jl) as a backstop, but the
library is expected not to make it fire.
"""
_is_resource_error(e) =
    e isa OutOfMemoryError || e isa StackOverflowError || e isa InterruptException
