# ---------------------------------------------------------------------------
# Document-scoped solver hints (esm-spec §2.2)
# ---------------------------------------------------------------------------
#
# The `solver` block records numerics the document knows about *itself* —
# stiffness, integration tolerances, and a splitting hint — which each binding
# maps to its own integrator.
#
# Every field is ADVISORY: a binding may ignore any or all of them and still
# conform. Advisory governs the MECHANISM, never the OUTCOME — the
# CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
# the error band is untouched by this block and is not excused by it.
#
# This file carries the two parts that are NOT advisory: the spec-version gate
# (§2.2.4) and the §2.2.2 tolerance resolution order. The `Solver` type itself
# lives in types.jl beside `Tolerance`, the quantity it must not be confused
# with.

"""
    reject_solver_pre_v11(raw_data)

Reject a top-level `solver` block in a file declaring `esm` < 1.1.0.

The block arrives at `esm: 1.1.0`; a document declaring an earlier version that
carries one is rejected with `solver_version_too_old` (esm-spec §2.2.4).
Mirrors [`reject_template_imports_pre_v08`](@ref).
"""
function reject_solver_pre_v11(raw_data)
    raw_data === nothing && return
    _is_object(raw_data) || return
    _raw_haskey(raw_data, "solver") || return
    esm_raw = _raw_get(raw_data, "esm")
    esm_raw === nothing && return
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", string(esm_raw))
    m === nothing && return
    major = parse(Int, m.captures[1])
    minor = parse(Int, m.captures[2])
    (major, minor) >= (1, 1) && return
    throw(ExpressionTemplateError(
        ERROR_CODES.SOLVER_VERSION_TOO_OLD,
        "the top-level `solver` block requires esm >= 1.1.0; " *
        "file declares $(string(esm_raw)). Offending path: /solver"))
end

"""
    resolve_tolerances(solver; abstol=nothing, reltol=nothing) -> (abstol, reltol)

Resolve integration tolerances most-specific first (esm-spec §2.2.2):

1. An explicit argument at the `solve` call site — wins outright.
2. Otherwise the document's `solver.abstol` / `solver.reltol`.
3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).

The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
`abstol` on the default — the same per-field fall-through §6.6.4 uses.

These are INTEGRATION tolerances, a DIFFERENT QUANTITY from the [`Tolerance`](@ref)
an assertion is COMPARED at (§6.6.4), which resolves on its own chain.
"""
function resolve_tolerances(solver; abstol=nothing, reltol=nothing)
    doc_abstol = solver === nothing ? nothing : solver.abstol
    doc_reltol = solver === nothing ? nothing : solver.reltol
    a = abstol !== nothing ? abstol :
        (doc_abstol !== nothing ? doc_abstol : DEFAULT_SIM_ABSTOL)
    r = reltol !== nothing ? reltol :
        (doc_reltol !== nothing ? doc_reltol : DEFAULT_SIM_RELTOL)
    return (a, r)
end
