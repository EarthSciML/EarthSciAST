# Load-time resolution of `data_sources[*].source.url_template` (esm-spec §8.2.1).
#
# A `url_template` need not be an absolute URL. §8.2.1 resolves it to one at
# load time against the directory of the file the entry was read from -- the
# same base and the same timing rule §4.7 fixes for a `ref`. That is what lets
# a document name data living outside its own repository without carrying a
# machine-specific absolute path.
#
# Environment variables are deliberately NOT expanded here (§4.7 permits
# `${VAR}` in a `ref`; §8.2 does not permit it at all), and a template that
# needs one is REFUSED rather than passed through: a document reading `${...}`
# from the ambient environment does not say what it reads, the expanded value is
# spliced into a URL that is then fetched, and an optional expansion capability
# would make the same document resolve under one binding and not another. See
# `docs/content/rfcs/portable-data-source-urls.md`.
#
# The pass runs on the RAW document, so the typed `DataSourceLocation`, the
# EarthSciIO provider extension (which re-serializes the loaded file) and
# `emit` all see one resolved form and none of them needs a base directory. It
# is idempotent (its output is scheme-led), so parse -> emit -> parse is stable.

"""
    _URL_TEMPLATE_SCHEME_RE

esm-spec §8.2.1: a template is already a URL when it is scheme-led. The `://`
is required (rather than a bare `scheme:`) so that a Windows drive letter and a
`{date:%Y}` substitution are both read as path text, not as a scheme.
"""
const _URL_TEMPLATE_SCHEME_RE = r"^[A-Za-z][A-Za-z0-9+.\-]*://"

"""
    _remove_url_dot_segments(path::AbstractString) -> String

RFC 3986 §5.2.4 dot-segment removal, lexically, on an absolute path.

Never `realpath`: a template carrying a `{date:...}` substitution names a file
that need not exist at load time, and resolving symlinks would make the
resolved URL depend on the filesystem rather than on the document.
"""
function _remove_url_dot_segments(path::AbstractString)
    out = String[]
    for seg in split(String(path), '/')
        (isempty(seg) || seg == ".") && continue
        if seg == ".."
            isempty(out) || pop!(out)
            continue
        end
        push!(out, seg)
    end
    return "/" * join(out, "/")
end

"""
    _absolute_url_base(base_dir::AbstractString) -> String

`base_dir` as an absolute POSIX directory.

The loader's base may be relative (`load_path("fixtures/x.esm")` gives
`fixtures`; `load_string` defaults to `pwd()`) and splicing a relative path
after `file://` would silently make its first segment the URL HOST -- the exact
misresolution §8.2.1 exists to stop.
"""
function _absolute_url_base(base_dir::AbstractString)
    b = isempty(base_dir) ? "." : String(base_dir)
    return startswith(b, "/") ? b : rstrip(replace(abspath(b), '\\' => '/'), '/')
end

"""
    resolve_source_url(template::AbstractString, base_dir::AbstractString) -> String

Resolve one `url_template` / `mirrors` entry per esm-spec §8.2.1. Throws an
[`ExpressionTemplateError`](@ref) with code `data_source_url_unresolved` when
the template cannot be resolved.
"""
function resolve_source_url(template::AbstractString, base_dir::AbstractString)
    t = String(template)
    if occursin("\${", t)
        throw(
            ExpressionTemplateError(
                ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
                "url template $(repr(t)) carries an unexpanded '\${...}' variable. " *
                    "esm-spec §8.2.1 does not expand environment variables into a data " *
                    "source's location: a document that reads one does not say what it " *
                    "reads, and the value is spliced into a URL that is then fetched. " *
                    "Write a path relative to this document instead (it resolves against " *
                    "the document's own directory), or symlink the data to that path."
            )
        )
    end
    # Substitution-led: the author's own substitution supplies the location, so
    # there is no literal prefix to classify. §8.2 requires unrecognized
    # substitutions to be passed through, so this is left alone.
    startswith(t, "{") && return t
    match(_URL_TEMPLATE_SCHEME_RE, t) === nothing || return t

    joined = startswith(t, "/") ? t : _absolute_url_base(base_dir) * "/" * t
    resolved = _remove_url_dot_segments(joined)
    if occursin('?', resolved) || occursin('#', resolved)
        throw(
            ExpressionTemplateError(
                ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
                "url template $(repr(t)) resolves to $(repr(resolved)), whose '?' or " *
                    "'#' would be read as a URL query or fragment rather than as part of " *
                    "the path (esm-spec §8.2.1). Rename or relocate the file."
            )
        )
    end
    return "file://" * resolved
end

"""
    _resolved_source_url(template, base_dir, where) -> String

[`resolve_source_url`](@ref), with the failure naming its document site.

A resolution failure must name the entry AND the template: "io error at
/\${MOVES_SNAPSHOTS}/x.parquet" names neither, and a source whose location
silently fails to resolve is indistinguishable from one that read zeros.
"""
function _resolved_source_url(
        template::AbstractString, base_dir::AbstractString,
        where::AbstractString
    )
    try
        return resolve_source_url(template, base_dir)
    catch e
        e isa ExpressionTemplateError || rethrow()
        throw(ExpressionTemplateError(e.code, "$(where): $(e.message)"))
    end
end

"""
    _resolve_data_source_urls(raw_data, base_path) -> Union{Nothing,OrderedDict}

Resolve every `data_sources[*].source` location in `raw_data` per esm-spec
§8.2.1, returning `nothing` when nothing changed and a normalized copy of the
document otherwise.

NON-MUTATING, and copying only on demand, for the reason the top-level `{ref}`
inliners are: `raw_data` may still be a `JSON3.Object` straight off the wire,
which is immutable, and the overwhelmingly common document declares no
`data_sources` at all and must not pay for a deep copy.
"""
function _resolve_data_source_urls(raw_data, base_path::AbstractString)
    _is_object(raw_data) || return nothing
    sources = _raw_get(raw_data, "data_sources")
    (sources !== nothing && _is_object(sources)) || return nothing

    # Pass one: resolve everything WITHOUT touching the document, so a refusal
    # is raised before any copy is made, and so an all-absolute catalog (every
    # fixture that was already `file:///...`) costs one regex per entry.
    changed = false
    for (name, entry) in pairs(sources)
        _is_object(entry) || continue
        src = _raw_get(entry, "source")
        (src !== nothing && _is_object(src)) || continue
        t = _raw_get(src, "url_template")
        if t isa AbstractString
            changed |= _resolved_source_url(
                t, base_path, "data_sources.$(string(name)).source.url_template"
            ) != String(t)
        end
        ms = _raw_get(src, "mirrors")
        if ms !== nothing && _is_array(ms)
            for (i, m) in enumerate(ms)
                m isa AbstractString || continue
                changed |= _resolved_source_url(
                    m, base_path,
                    "data_sources.$(string(name)).source.mirrors[$(i - 1)]"
                ) != String(m)
            end
        end
    end
    changed || return nothing

    doc = _to_ordered(raw_data)
    for (name, entry) in pairs(doc["data_sources"])
        _is_object(entry) || continue
        src = get(entry, "source", nothing)
        (src !== nothing && _is_object(src)) || continue
        t = get(src, "url_template", nothing)
        if t isa AbstractString
            src["url_template"] = _resolved_source_url(
                t, base_path, "data_sources.$(string(name)).source.url_template"
            )
        end
        ms = get(src, "mirrors", nothing)
        if ms !== nothing && _is_array(ms)
            src["mirrors"] = Any[
                m isa AbstractString ?
                    _resolved_source_url(
                        m, base_path,
                        "data_sources.$(string(name)).source.mirrors[$(i - 1)]"
                    ) : m
                    for (i, m) in enumerate(ms)
            ]
        end
    end
    return doc
end

# ---------------------------------------------------------------------------
# Mount-edge `url_substitutions` (esm-spec §4.7 "Binding a data source's
# location at the mount").
# ---------------------------------------------------------------------------

_is_ident_start(c::UInt8) = (UInt8('A') <= c <= UInt8('Z')) ||
    (UInt8('a') <= c <= UInt8('z')) || c == UInt8('_')
_is_ident_char(c::UInt8) = _is_ident_start(c) || (UInt8('0') <= c <= UInt8('9'))

"""
    _url_placeholders(template) -> Vector{Tuple{Int,Int,String}}

The bare `{name}` placeholders of a template, in order of appearance, as
`(first, last, name)` with `first`/`last` the byte indices of the braces.

Only a brace pair enclosing a C identifier is a placeholder a mount edge can
bind (esm-spec §4.7); a formatted substitution such as `{date:%Y%m%d}` is not,
so an edge can never rewrite the runtime's own date expansion.
"""
function _url_placeholders(template::AbstractString)
    b = codeunits(String(template))
    out = Tuple{Int, Int, String}[]
    i = 1
    n = length(b)
    while i <= n
        if b[i] == UInt8('{') && i < n && _is_ident_start(b[i + 1])
            j = i + 2
            while j <= n && _is_ident_char(b[j])
                j += 1
            end
            if j <= n && b[j] == UInt8('}')
                push!(out, (i, j, String(b[(i + 1):(j - 1)])))
                i = j + 1
                continue
            end
        end
        i += 1
    end
    return out
end

"""
    _each_source_location(f, doc)

Call `f(site, get, set)` for every `url_template` and every string `mirrors`
entry of `doc`'s `data_sources`, where `get()` reads the location and
`set(v)` overwrites it. `doc` must be a mutable native tree.
"""
function _each_source_location(f, doc::AbstractDict)
    sources = get(doc, "data_sources", nothing)
    sources isa AbstractDict || return
    for (name, entry) in sources
        entry isa AbstractDict || continue
        src = get(entry, "source", nothing)
        src isa AbstractDict || continue
        t = get(src, "url_template", nothing)
        if t isa AbstractString
            f("data_sources.$(name).source.url_template", t, v -> (src["url_template"] = v))
        end
        ms = get(src, "mirrors", nothing)
        if ms isa AbstractVector
            for i in eachindex(ms)
                m = ms[i]
                m isa AbstractString || continue
                f("data_sources.$(name).source.mirrors[$(i - 1)]", m, v -> (ms[i] = v))
            end
        end
    end
    return
end

"""
    apply_mount_url_substitutions!(doc, subs_raw, binder_dir, where) -> doc

Apply a mount edge's `url_substitutions` (`subs_raw`; `nothing` when the edge
carries none) to the REFERENCED document `doc` as resolved at that edge — its
own `data_sources` and those its own mounts already hoisted into it (esm-spec
§4.7 "Binding a data source's location at the mount"). `doc` is a mutable
native tree and is rewritten in place. `binder_dir` is the directory of the
MOUNTING document, the one that wrote the edge; `where` names the edge in a
diagnostic.

* A key names a bare `{key}` placeholder of some location in `doc`; one that
  names none is `url_substitution_unknown_name`, so a misspelt key fails at the
  edge rather than leaving the placeholder for a read to trip over.
* A value is text: a string carrying no `{` or `}`, so a substitution never
  introduces another one, and no `?` or `#`, since a value names a directory or
  a path segment (`data_source_url_unresolved` otherwise; also for a map that
  is not an object).
* Who wrote the location decides what it anchors on (§8.2.1). A placeholder
  that LEADS a template supplies the whole location: a URL or absolute path is
  used as-is and a relative one joins onto `binder_dir`. A placeholder anywhere
  else is a segment of the referenced document's location, spliced as text; the
  result resolves against the referenced document's directory when its §8.2.1
  pass runs next. A result that already carries a scheme is re-normalized here,
  since §8.2.1 leaves a scheme-led location alone and a spliced `..` must not
  survive: a `file:///...` one as §8.2.1 normalizes it, any other
  `scheme://authority/...` (e.g. a catalogue loaded from an `https` URL) has the
  dot segments of its PATH removed (RFC 3986 §5.2.4), query and fragment
  untouched.

A placeholder the edge does not bind is left as written, so it travels up with
a hoisted entry and an enclosing edge may bind it.
"""
function apply_mount_url_substitutions!(
        doc::AbstractDict, subs_raw, binder_dir::AbstractString,
        where::AbstractString
    )
    subs_raw === nothing && return doc
    _is_object(subs_raw) || throw(
        ExpressionTemplateError(
            ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
            "$(where): `url_substitutions` must be an object mapping a placeholder " *
                "name to a string (esm-spec §4.7)"
        )
    )
    isempty(subs_raw) && return doc
    bound = OrderedDict{String, String}()
    for (k, v) in pairs(subs_raw)
        key = string(k)
        v isa AbstractString || throw(
            ExpressionTemplateError(
                ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
                "$(where): `url_substitutions.$(key)` must be a string, got " *
                    "$(repr(v)) (esm-spec §4.7)"
            )
        )
        (occursin('{', v) || occursin('}', v)) && throw(
            ExpressionTemplateError(
                ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
                "$(where): `url_substitutions.$(key)` = $(repr(String(v))) carries a " *
                    "brace; a bound value is text and may not introduce another " *
                    "substitution (esm-spec §4.7)"
            )
        )
        # A value names a directory or a path segment; a query or fragment never
        # names a file (and a `#` would be dropped when the location is read).
        (occursin('?', v) || occursin('#', v)) && throw(
            ExpressionTemplateError(
                ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
                "$(where): `url_substitutions.$(key)` = $(repr(String(v))) carries a " *
                    "'?' or '#'; a bound value names a directory or a path segment, " *
                    "never a query or fragment (esm-spec §4.7)"
            )
        )
        bound[key] = String(v)
    end

    present = Set{String}()
    _each_source_location(doc) do _, t, _
        for (_, _, n) in _url_placeholders(t)
            push!(present, n)
        end
    end
    for k in keys(bound)
        k in present && continue
        throw(
            ExpressionTemplateError(
                ERROR_CODES.URL_SUBSTITUTION_UNKNOWN_NAME,
                "$(where): `url_substitutions` binds '$(k)', which no `url_template` " *
                    "or `mirrors` entry of the referenced document's data_sources " *
                    "spells as a placeholder `{$(k)}` (available: " *
                    "[$(join(sort!(collect(present)), ", "))]); a mount edge never " *
                    "invents a placeholder (esm-spec §4.7)"
            )
        )
    end

    # The value a LEADING placeholder contributes: the mounting document's
    # location, per §8.2.1's own forms.
    lead(v) = if match(_URL_TEMPLATE_SCHEME_RE, v) !== nothing || startswith(v, "/")
        v
    elseif _is_url(binder_dir)
        # A mounting document loaded from a URL: its directory is that URL's,
        # and a relative value joins onto it by RFC 3986 §5.2, dot segments
        # removed, exactly as its own relative refs do. `_url_join` reads the
        # base as a directory with or without a trailing '/'.
        _url_join(binder_dir, v)
    elseif match(_URL_TEMPLATE_SCHEME_RE, String(binder_dir)) !== nothing
        rstrip(String(binder_dir), '/') * "/" * v
    else
        _absolute_url_base(binder_dir) * "/" * v
    end

    _each_source_location(doc) do site, t, set
        t = String(t)
        found = _url_placeholders(t)
        any(p -> haskey(bound, p[3]), found) || return
        io = IOBuffer()
        last = 1
        for (s, e, n) in found
            haskey(bound, n) || continue
            write(io, SubString(t, last, prevind(t, s)))
            write(io, s == 1 ? lead(bound[n]) : bound[n])
            last = e + 1
        end
        write(io, SubString(t, last))
        out = String(take!(io))
        if startswith(out, "file:///")
            p = _remove_url_dot_segments(out[8:end])
            (occursin('?', p) || occursin('#', p)) && throw(
                ExpressionTemplateError(
                    ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
                    "$(where): $(site): the substituted location $(repr(out)) carries " *
                        "a '?' or '#' (esm-spec §8.2.1)"
                )
            )
            out = "file://" * p
        else
            out = _renormalize_url_path(out)
        end
        set(out)
    end
    return doc
end

# `scheme://authority`, the path, and the `?query` / `#fragment` suffix.
const _SCHEME_URL_PARTS_RE = r"^([A-Za-z][A-Za-z0-9+.\-]*://[^/?#]*)([^?#]*)([\s\S]*)$"

"""
    _renormalize_url_path(location) -> String

A scheme-led (`scheme://authority/...`) location with RFC 3986 §5.2.4 dot
segments removed from its PATH only, its query and fragment untouched; any
other location unchanged. The post-splice step of
[`apply_mount_url_substitutions!`](@ref) for a location in a scheme other than
`file://` (esm-spec §4.7: a spliced `..` never survives into a location in one
scheme and is removed in another).
"""
function _renormalize_url_path(location::AbstractString)
    m = match(_SCHEME_URL_PARTS_RE, location)
    m === nothing && return String(location)
    sa, path, suffix = m.captures
    isempty(path) && return String(location)
    return String(sa) * _remove_dot_segments(path) * String(suffix)
end
