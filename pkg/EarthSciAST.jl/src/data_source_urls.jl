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
        throw(ExpressionTemplateError(
            ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
            "url template $(repr(t)) carries an unexpanded '\${...}' variable. " *
            "esm-spec §8.2.1 does not expand environment variables into a data " *
            "source's location: a document that reads one does not say what it " *
            "reads, and the value is spliced into a URL that is then fetched. " *
            "Write a path relative to this document instead (it resolves against " *
            "the document's own directory), or symlink the data to that path."))
    end
    # Substitution-led: the author's own substitution supplies the location, so
    # there is no literal prefix to classify. §8.2 requires unrecognized
    # substitutions to be passed through, so this is left alone.
    startswith(t, "{") && return t
    match(_URL_TEMPLATE_SCHEME_RE, t) === nothing || return t

    joined = startswith(t, "/") ? t : _absolute_url_base(base_dir) * "/" * t
    resolved = _remove_url_dot_segments(joined)
    if occursin('?', resolved) || occursin('#', resolved)
        throw(ExpressionTemplateError(
            ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
            "url template $(repr(t)) resolves to $(repr(resolved)), whose '?' or " *
            "'#' would be read as a URL query or fragment rather than as part of " *
            "the path (esm-spec §8.2.1). Rename or relocate the file."))
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
function _resolved_source_url(template::AbstractString, base_dir::AbstractString,
                              where::AbstractString)
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
                t, base_path, "data_sources.$(string(name)).source.url_template") != String(t)
        end
        ms = _raw_get(src, "mirrors")
        if ms !== nothing && _is_array(ms)
            for (i, m) in enumerate(ms)
                m isa AbstractString || continue
                changed |= _resolved_source_url(
                    m, base_path,
                    "data_sources.$(string(name)).source.mirrors[$(i - 1)]") != String(m)
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
                t, base_path, "data_sources.$(string(name)).source.url_template")
        end
        ms = get(src, "mirrors", nothing)
        if ms !== nothing && _is_array(ms)
            src["mirrors"] = Any[m isa AbstractString ?
                                 _resolved_source_url(
                                     m, base_path,
                                     "data_sources.$(string(name)).source.mirrors[$(i - 1)]") : m
                                 for (i, m) in enumerate(ms)]
        end
    end
    return doc
end
