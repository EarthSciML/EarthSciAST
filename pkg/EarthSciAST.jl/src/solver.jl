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
# This file carries the parts that are NOT advisory: the spec-version gates
# (§2.2.4), the §2.2.2 tolerance resolution order, the §2.2.6 `${` refusal
# and location of `solver.external`, and the §2.2.7 check and conversion of
# `solver.time_span`. The `Solver` type itself
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
    version = _declared_minor(raw_data)
    (version === nothing || version >= (1, 1)) && return
    throw(ExpressionTemplateError(
        ERROR_CODES.SOLVER_VERSION_TOO_OLD,
        "the top-level `solver` block requires esm >= 1.1.0; " *
        "file declares $(string(_raw_get(raw_data, "esm"))). Offending path: /solver"))
end

# `(major, minor)` of the document's `esm` string, or `nothing` when it declares
# none the version gates can read.
function _declared_minor(raw_data)
    esm_raw = _raw_get(raw_data, "esm")
    esm_raw === nothing && return nothing
    m = match(r"^(\d+)\.(\d+)\.(\d+)$", string(esm_raw))
    m === nothing && return nothing
    return (parse(Int, m.captures[1]), parse(Int, m.captures[2]))
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
    version = _declared_minor(raw_data)
    (version === nothing || version >= (1, 3)) && return
    throw(ExpressionTemplateError(
        ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
        "`solver.external` requires esm >= 1.3.0; " *
        "file declares $(string(_raw_get(raw_data, "esm"))). Offending path: /solver/external"))
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

# A drive-letter path, `C:/` or `C:\`: absolute on every host (esm-spec §2.2.6).
const _DRIVE_PATH_RE = r"^[A-Za-z]:[/\\]"

_is_absolute_location_path(p::AbstractString) =
    startswith(p, "/") || occursin(_DRIVE_PATH_RE, p)

# An absolute path with its dot segments removed (RFC 3986 §5.2.4). A
# drive-letter path comes back as `C:/…`, its `\` read as `/` and its drive a
# root that `..` does not climb above.
function _lexical_absolute(p::AbstractString)
    occursin(_DRIVE_PATH_RE, p) || return _remove_url_dot_segments(p)
    return p[1:2] * _remove_url_dot_segments(replace(p[3:end], '\\' => '/'))
end

# `dir` as the absolute, dot-segment-free directory *D* of §2.2.6; a relative
# `dir` is taken against the working directory. Purely lexical.
function _absolute_directory(dir::AbstractString)
    d = isempty(dir) ? "." : String(dir)
    Sys.iswindows() && (d = replace(d, '\\' => '/'))
    _is_absolute_location_path(d) && return _lexical_absolute(d)
    return _lexical_absolute(replace(pwd(), '\\' => '/') * "/" * d)
end

# The §2.2.6 *D* a load records: the absolute directory the document was read
# from (`load_path`), or the base a string / in-memory load was given or
# defaulted to (`pwd()`). A URL base (a remotely loaded mount leaf, whose
# `solver` block never crosses the mount) records nothing.
function _solver_external_base(base_path::AbstractString)
    match(_URL_TEMPLATE_SCHEME_RE, base_path) === nothing || return nothing
    return _absolute_directory(base_path)
end

# `file://` plus an absolute, dot-segment-free path, each byte of its UTF-8
# encoding outside `A-Za-z0-9-._~/:` written `%XX` (§2.2.6). A drive path gets
# the third slash: `file:///C:/…`.
function _file_location_url(p::AbstractString)
    io = IOBuffer()
    print(io, "file://")
    startswith(p, "/") || print(io, '/')
    for b in codeunits(String(p))
        if (UInt8('A') <= b <= UInt8('Z')) || (UInt8('a') <= b <= UInt8('z')) ||
           (UInt8('0') <= b <= UInt8('9')) || b in codeunits("-._~/:")
            write(io, b)
        else
            print(io, '%', uppercase(string(b; base=16, pad=2)))
        end
    end
    return String(take!(io))
end

"""
    solver_external_location(file::EsmFile; base_path=nothing) -> Union{String,Nothing}

Where the document's `solver.external` points (esm-spec §2.2.6), or `nothing`
when its `solver` block carries no `external`.

| Form | Test on the string | Location |
|---|---|---|
| URL | matches `^[A-Za-z][A-Za-z0-9+.-]*://` | unchanged |
| Absolute path | begins with `/`, or a drive letter `C:/` / `C:\\` | dot segments removed, percent-encoded, prefixed `file://` |
| Relative path | anything else | joined onto *D*, dot segments removed, percent-encoded, prefixed `file://` |

Percent-encoding writes each byte of the path's UTF-8 encoding outside
`A-Za-z0-9-._~/:` as `%XX`, `%` included: the input is a path, not a URL. A
drive-letter path resolves to `file:///C:/…`.

*D* is `base_path` when given (a relative `base_path` is taken against the
working directory), else the directory recorded at load on the document — the
directory of the file read, or the working directory for a string load — else,
for a document built in memory, the working directory now.

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
    _is_absolute_location_path(t) && return _file_location_url(_lexical_absolute(t))
    base = base_path !== nothing ? _absolute_directory(base_path) :
           something(file.document_base, _absolute_directory(pwd()))
    return _file_location_url(_lexical_absolute(base * "/" * t))
end

"""
    reject_solver_time_span_pre_v13(raw_data)

Reject `solver.time_span` in a file declaring `esm` < 1.3.0.

The field arrives at `esm: 1.3.0`; a document declaring an earlier version whose
`solver` block carries it is rejected with `solver_time_span_version_too_old`
at `/solver/time_span` (esm-spec §2.2.4 requirement 4). Runs before schema
validation, beside [`reject_solver_external_pre_v13`](@ref).
"""
function reject_solver_time_span_pre_v13(raw_data)
    raw_data === nothing && return
    _is_object(raw_data) || return
    solver = _raw_get(raw_data, "solver")
    (solver !== nothing && _is_object(solver)) || return
    _raw_haskey(solver, "time_span") || return
    version = _declared_minor(raw_data)
    (version === nothing || version >= (1, 3)) && return
    throw(ExpressionTemplateError(
        ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD,
        "`solver.time_span` requires esm >= 1.3.0; " *
        "file declares $(string(_raw_get(raw_data, "esm"))). Offending path: /solver/time_span"))
end

# A `time_span` bound written as a timestamp: the schema's pattern, UTC with `Z`.
const _TIME_SPAN_TIMESTAMP_RE =
    r"^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(\.[0-9]+)?Z$"
# The time origin (`domain.temporal.reference_time` / `start`): any RFC 3339
# date-time, offset included. Ranges are checked after the match.
const _RFC3339_DATETIME_RE =
    r"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?([Zz]|([+-])([0-9]{2}):([0-9]{2}))$"

_is_leap_year(y::Int) = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
_days_in_month(y::Int, m::Int) =
    m == 2 ? (_is_leap_year(y) ? 29 : 28) : (m in (4, 6, 9, 11) ? 30 : 31)

# Days from 1970-01-01 to y-m-d in the proleptic Gregorian calendar (Hinnant's
# `days_from_civil`), so no host date library decides the range or the rules.
function _days_from_civil(y::Int, m::Int, d::Int)
    y -= m <= 2
    era = fld(y, 400)
    yoe = y - era * 400
    doy = div(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

# `(W, f)` of a date-time (esm-spec §2.2.7): whole seconds from the POSIX epoch,
# offset subtracted, and the fraction in [0, 1). `nothing` when `s` is not of
# the form `re` describes or names no calendar instant.
function _datetime_parts(s::AbstractString, re::Regex)
    m = match(re, s)
    m === nothing && return nothing
    y, mo, d, h, mi, sec = (parse(Int, m.captures[i]) for i in 1:6)
    (1 <= mo <= 12 && 1 <= d <= _days_in_month(y, mo) && h <= 23 && mi <= 59 &&
     sec <= 59) || return nothing
    offset = 0
    if length(m.captures) >= 9 && m.captures[9] !== nothing
        oh, om = parse(Int, m.captures[10]), parse(Int, m.captures[11])
        (oh <= 23 && om <= 59) || return nothing
        offset = (m.captures[9] == "-" ? -1 : 1) * (oh * 3600 + om * 60)
    end
    whole = _days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - offset
    frac = m.captures[7] === nothing ? 0.0 : parse(Float64, "0" * m.captures[7])
    return (whole, frac)
end

struct _TimeSpanFault
    message::String
end

# The time origin of §2.2.7 as `(W0, f0)`: `domain.temporal.reference_time`,
# else `domain.temporal.start`, else the POSIX epoch. Reads raw JSON and the
# typed `Domain.temporal` dict alike.
function _time_origin(domain)
    temporal = domain === nothing ? nothing :
               domain isa Domain ? domain.temporal : _raw_get(domain, "temporal")
    (temporal === nothing || !_is_object(temporal)) && return (0, 0.0)
    for key in ("reference_time", "start")
        # A present key selects its field, `null` included (esm-spec §2.2.7).
        _raw_haskey(temporal, key) || continue
        v = _raw_get(temporal, key)
        parts = v isa AbstractString ? _datetime_parts(v, _RFC3339_DATETIME_RE) : nothing
        parts === nothing && return _TimeSpanFault(
            "/domain/temporal/$(key) is \"$(v)\", which is not an RFC 3339 date-time, " *
            "so it cannot serve as the time origin a timestamp bound is counted from")
        return parts
    end
    return (0, 0.0)
end

# One bound in seconds, or a fault naming why it has none.
function _time_span_seconds(bound, which::String, origin)
    bound isa Real && return Float64(bound)
    parts = _datetime_parts(bound, _TIME_SPAN_TIMESTAMP_RE)
    parts === nothing &&
        return _TimeSpanFault("$(which) \"$(bound)\" names no calendar day")
    origin isa _TimeSpanFault && return origin
    (w, f), (w0, f0) = parts, origin
    return Float64(w - w0) + (f - f0)
end

# `(start, end)` in seconds, or the fault that makes it no interval.
function _time_span_interval(start, stop, domain)
    origin = any(b -> b isa AbstractString, (start, stop)) ? _time_origin(domain) : (0, 0.0)
    s = _time_span_seconds(start, "start", origin)
    s isa _TimeSpanFault && return s
    e = _time_span_seconds(stop, "end", origin)
    e isa _TimeSpanFault && return e
    e > s || return _TimeSpanFault(
        "end ($(e) s) is not after start ($(s) s), so it describes no interval")
    return (s, e)
end

_solver_time_span_invalid_error(fault::_TimeSpanFault) = ExpressionTemplateError(
    ERROR_CODES.SOLVER_TIME_SPAN_INVALID, "/solver/time_span: " * fault.message *
    " (esm-spec §2.2.7).")

# A bound the schema admits: a number, or a string matching its pattern. The
# load check leaves anything else for the schema to report.
_schema_valid_bound(v) = (v isa Real && !(v isa Bool)) ||
    (v isa AbstractString && occursin(_TIME_SPAN_TIMESTAMP_RE, v))

# The §2.2.7 load-time check, before schema validation and on the root alone.
function _reject_solver_time_span_invalid(raw_data)
    _is_object(raw_data) || return
    solver = _raw_get(raw_data, "solver")
    (solver !== nothing && _is_object(solver)) || return
    span = _raw_get(solver, "time_span")
    (span !== nothing && _is_object(span)) || return
    start, stop = _raw_get(span, "start"), _raw_get(span, "end")
    (_schema_valid_bound(start) && _schema_valid_bound(stop)) || return
    r = _time_span_interval(start, stop, _raw_get(raw_data, "domain"))
    r isa _TimeSpanFault && throw(_solver_time_span_invalid_error(r))
    return
end

"""
    resolve_time_span(file::EsmFile; tspan=nothing) -> Union{Tuple{Float64,Float64},Nothing}

The interval to simulate `file` over, most specific first (esm-spec §2.2.7):

1. `tspan`, an explicit interval at the call site, returned unchanged — it
   always wins, both bounds.
2. Otherwise the document's `solver.time_span`, as `(start, end)` in seconds.
3. Otherwise `nothing`.

A number bound is already seconds. A timestamp bound is the seconds from the
document's time origin — `domain.temporal.reference_time`, else
`domain.temporal.start`, else the POSIX epoch — to that instant, computed from
the fields as `(W − W₀) + (f − f₀)` with no host date library. Throws
`solver_time_span_invalid` for an interval a load would have refused (a
document built in memory is not checked at load).
"""
function resolve_time_span(file::EsmFile; tspan=nothing)
    tspan === nothing || return tspan
    s = file.solver
    (s === nothing || s.time_span === nothing) && return nothing
    r = _time_span_interval(s.time_span.start, s.time_span.stop, file.domain)
    r isa _TimeSpanFault && throw(_solver_time_span_invalid_error(r))
    return r
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
