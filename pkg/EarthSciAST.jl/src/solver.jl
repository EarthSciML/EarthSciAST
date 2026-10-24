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
    reject_solver_external_pre_v13(raw_data)

Reject `solver.external` in a file declaring `esm` < 1.3.0.

The field arrives at `esm: 1.3.0`; a document declaring an earlier version whose
`solver` block carries it is rejected with `solver_external_version_too_old`
at `/solver/external` (esm-spec §2.2.4 requirement 4). Runs before schema
validation and after [`reject_solver_pre_v11`](@ref), so a document below 1.1.0
reports the block itself as too new. A 1.1.0 or 1.2.0 block without `external`
stays valid.
"""
function reject_solver_external_pre_v13(raw_data)
    raw_data === nothing && return
    _is_object(raw_data) || return
    solver = _raw_get(raw_data, "solver")
    (solver !== nothing && _is_object(solver)) || return
    _raw_haskey(solver, "external") || return
    esm_raw = _raw_get(raw_data, "esm")
    esm_raw === nothing && return
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", string(esm_raw))
    m === nothing && return
    major = parse(Int, m.captures[1])
    minor = parse(Int, m.captures[2])
    (major, minor) >= (1, 3) && return
    throw(ExpressionTemplateError(
        ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
        "`solver.external` requires esm >= 1.3.0; " *
        "file declares $(string(esm_raw)). Offending path: /solver/external"))
end

# The §2.2.6 refusal: `external` names its run configuration literally, so a
# `${...}` would make the numerics depend on the environment the document is
# run in. Quoted with plain quotes rather than `repr`, which escapes the `$`.
function _solver_external_unresolved_error(external::AbstractString)
    return ExpressionTemplateError(
        ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED,
        "/solver/external: \"$(external)\" carries an unexpanded '\${...}' variable. " *
        "esm-spec §2.2.6 does not expand environment variables into a run " *
        "configuration's location: numerics chosen by the environment are not " *
        "reproducible. Write a path relative to this document, or pass the run " *
        "configuration at the call site.")
end

function _reject_solver_external_unresolved(raw_data)
    _is_object(raw_data) || return
    solver = _raw_get(raw_data, "solver")
    (solver !== nothing && _is_object(solver)) || return
    external = _raw_get(solver, "external")
    external isa AbstractString || return
    occursin("\${", external) && throw(_solver_external_unresolved_error(external))
    return
end

# The §2.2.6 *D* a load records: the absolute directory the document was read
# from (`load_path`), or the base a string / in-memory load was given or
# defaulted to (`pwd()`). A URL base (a remotely loaded mount leaf, whose
# `solver` block never crosses the mount) records nothing.
function _solver_external_base(base_path::AbstractString)
    match(_URL_TEMPLATE_SCHEME_RE, base_path) === nothing || return nothing
    return _absolute_url_base(base_path)
end

"""
    solver_external_location(file::EsmFile; base_path=nothing) -> Union{String,Nothing}

Where the document's `solver.external` points (esm-spec §2.2.6), or `nothing`
when its `solver` block carries no `external`.

| Form | Test on the string | Location |
|---|---|---|
| URL | matches `^[A-Za-z][A-Za-z0-9+.-]*://` | unchanged |
| Absolute path | begins with `/` | dot segments removed, prefixed `file://` |
| Relative path | anything else | joined onto *D*, dot segments removed, prefixed `file://` |

*D* is `base_path` when given (a relative `base_path` is taken against the
working directory), else the directory recorded at load — the directory of the
file read, or the working directory for a string load — else, for a block built
in memory, the working directory now.

Purely lexical (RFC 3986 §5.2.4, never `realpath`): it never touches the
filesystem or the network, and a location that does not exist resolves
normally. The document keeps the authored string; this is the only place the
resolved form appears. Only the root document's block is consulted — a mounted
document's `solver` block does not cross the mount (§4.7).
"""
function solver_external_location(file::EsmFile;
                                  base_path::Union{Nothing,AbstractString}=nothing)
    s = file.solver
    (s === nothing || s.external === nothing) && return nothing
    t = s.external
    occursin("\${", t) && throw(_solver_external_unresolved_error(t))
    match(_URL_TEMPLATE_SCHEME_RE, t) === nothing || return t
    startswith(t, "/") && return "file://" * _remove_url_dot_segments(t)
    base = base_path !== nothing ? _absolute_url_base(base_path) :
           something(s.base_dir, _absolute_url_base(pwd()))
    return "file://" * _remove_url_dot_segments(base * "/" * t)
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

"""
    _document_solver(prob) -> Union{Solver,Nothing}

The §2.2 `solver` block of the document an `EsmProblem` was built from.

Read from the problem's own run document rather than from a separate typed
field, so the §2.2.2 chain holds however the problem was built. Returns
`nothing` when the document declares no block, or when `prob` carries no
document at all (the direct-`f!` construction paths).
"""
function _document_solver(prob)
    doc = try
        getfield(prob, :run_doc)
    catch
        return nothing
    end
    doc isa AbstractDict || return nothing
    return coerce_solver(get(doc, "solver", nothing))
end
