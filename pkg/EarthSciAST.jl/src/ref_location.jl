# Reference spelling and location (esm-spec §4.7): `${VAR}` expansion, the
# bundled standard library, and http(s) URL resolution and fetching.

# esm-spec §4.7: a `${VAR}` token in a ref (subsystem or template import) is
# expanded from the process environment before resolution — an OPTIONAL loader
# capability (like URL refs). An UNSET variable is left literal, so the ref
# simply fails to resolve (`template_import_unresolved` / the subsystem error)
# rather than silently misresolving.
# `${VAR}` with the variable name as capture group 1.
const _ENV_REF_RE = r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"

function _expand_env_tokens(ref::AbstractString)
    # `replace` hands the callback the whole matched token (`"${VAR}"`);
    # re-match to pull the variable name out of the capture group.
    return replace(
        String(ref), _ENV_REF_RE =>
            token -> get(ENV, match(_ENV_REF_RE, token)[1], token)
    )
end

# esm-spec §4.7 standard-library refs: `esm:std/<file>.esm` names a file of the
# package's bundled copy of the repo-root `lib/` (written by
# `scripts/sync-lib.sh`). The directory is a `Ref` so tests can substitute a
# bundle, and `__init__` sets it from where the package is loaded at run time
# (`_init_stdlib_dir!`): a path computed at precompile time would go stale when
# the depot or a system image is relocated. The whole `esm:` scheme is
# reserved: a ref beginning with it is never a path or a URL.
_bundled_stdlib_dir() = joinpath(pkgdir(@__MODULE__), "data", "lib")
const _STDLIB_DIR = Ref(_bundled_stdlib_dir())
_init_stdlib_dir!() = (_STDLIB_DIR[] = _bundled_stdlib_dir())
const _STD_NAME_RE = r"^[A-Za-z0-9_][A-Za-z0-9_.\-]*\.esm$"

_is_std_ref(ref::AbstractString) = startswith(ref, "esm:")

# Whether `path` is (or would be) a file of the bundle — what `_expand_ref_env`
# maps a standard-library ref to. Such a path is never URL-joined.
_is_bundled_path(path::AbstractString) =
    startswith(path, joinpath(_STDLIB_DIR[], ""))

# The bundled path a standard-library candidate names, or a path under the
# bundle that cannot exist (its `unresolved` subdirectory is never written), so
# each mechanism raises its ordinary unresolved diagnostic.
function _std_ref_path(candidate::AbstractString)
    m = match(r"^esm:std/(.*)$", candidate)
    if m !== nothing
        segs = filter(!=("."), split(m[1], '/'))
        if length(segs) == 1 && occursin(_STD_NAME_RE, segs[1])
            path = joinpath(_STDLIB_DIR[], segs[1])
            isfile(path) && return path
        end
    end
    return joinpath(_STDLIB_DIR[], "unresolved", replace(candidate, r"[/\\]" => "%2F"))
end

"""
    _expand_ref_env(ref, base_dir = nothing) -> String

The §4.7 spelling step before a ref resolves. A ref beginning with `esm:` is
taken as written (no `\${VAR}` expansion) and mapped to the bundled standard
library; any other ref has its `\${VAR}` tokens expanded, and an expansion that
begins with `esm:` is a standard-library ref too. When `base_dir` is the
bundle itself (a ref inside a bundled file), a relative ref must name another
bundled file, so the library's own imports stay inside it.
"""
function _expand_ref_env(ref::AbstractString, base_dir = nothing)
    r = _is_std_ref(ref) ? String(ref) : _expand_env_tokens(ref)
    _is_std_ref(r) && return _std_ref_path(r)
    if base_dir isa AbstractString && !isempty(base_dir) &&
            normpath(base_dir) == normpath(_STDLIB_DIR[]) &&
            !isabspath(r) && !_is_url(r)
        return _std_ref_path("esm:std/" * r)
    end
    return r
end

"""
    _is_url(s) -> Bool

True iff `s` is an http(s) URL (the two remote-reference schemes of
esm-spec §4.7).
"""
_is_url(s::AbstractString) = startswith(s, "http://") || startswith(s, "https://")

"""
    _url_split(url) -> (scheme_authority, path, suffix)

Split an http(s) URL into its scheme + authority (`"https://host[:port]"`),
its path (always at least `"/"`), and the trailing query/fragment suffix
(possibly empty).
"""
function _url_split(url::AbstractString)
    m = match(r"^(https?://[^/?#]*)([^?#]*)([\s\S]*)$", url)
    m === nothing && throw(ArgumentError("not an http(s) URL: '$url'"))
    scheme_authority, path, suffix = m.captures
    return String(scheme_authority), (isempty(path) ? "/" : String(path)), String(suffix)
end

"""
    _remove_dot_segments(path) -> String

RFC 3986 §5.2.4 dot-segment removal for a URL path beginning with `/`:
`"/a/b/../c/./d.esm"` → `"/a/c/d.esm"`. `..` never climbs above the root.
"""
function _remove_dot_segments(path::AbstractString)::String
    segs = split(path, '/')
    out = String[]
    for seg in segs
        if seg == "."
            continue
        elseif seg == ".."
            length(out) > 1 && pop!(out)
        else
            push!(out, String(seg))
        end
    end
    # A trailing "." / ".." leaves the result a directory: keep the slash.
    !isempty(segs) && (segs[end] == "." || segs[end] == "..") && push!(out, "")
    joined = join(out, "/")
    return isempty(joined) || joined == "/" ? "/" : joined
end

"""
    _url_normalize(url) -> String

Canonical form of an http(s) URL for cycle detection: dot segments removed
from the path, scheme/authority and any query/fragment preserved verbatim.
"""
function _url_normalize(url::AbstractString)::String
    sa, path, suffix = _url_split(url)
    return sa * _remove_dot_segments(path) * suffix
end

"""
    _url_join(base_url::AbstractString, ref::AbstractString) -> String

Resolve `ref` against `base_url`, where `base_url` names the DIRECTORY a
URL-loaded document was fetched from (`_url_dirname`). Absolute http(s)
refs pass through (normalized); `/`-rooted refs replace the base path;
anything else joins onto the base directory. Dot segments are removed
(RFC 3986 §5.2 relative resolution for the cases §4.7 admits)."""
function _url_join(base_url::AbstractString, ref::AbstractString)::String
    _is_url(ref) && return _url_normalize(ref)
    sa, bpath, _ = _url_split(base_url) # base query/fragment never inherited
    path = startswith(ref, "/") ? String(ref) :
        (endswith(bpath, "/") ? bpath * ref : bpath * "/" * ref)
    return sa * _remove_dot_segments(path)
end

"""
    _url_dirname(url) -> String

The URL of the directory containing `url`'s document — the base against
which the document's own relative refs resolve (drops the last path
segment and any query/fragment): `"https://h/lib/a.esm"` → `"https://h/lib"`.
"""
function _url_dirname(url::AbstractString)::String
    sa, path, _ = _url_split(url)
    i = findlast('/', path)
    return (i === nothing || i <= 1) ? sa : sa * path[1:prevind(path, i)]
end

# ---------------------------------------------------------------------------
# Where a reference points, and the one reader of referenced documents
# ---------------------------------------------------------------------------

"""
    _RefBase

Where a document's own relative refs resolve: the directory it was read from
(`_DirBase`) or, for a document fetched over http(s), its URL directory
(`_UrlBase`, RFC 3986 joining). Strings become a base only at the public entry
points ([`_ref_base`](@ref)).
"""
abstract type _RefBase end

struct _DirBase <: _RefBase
    dir::String
end

struct _UrlBase <: _RefBase
    url::String
end

"""
    _ref_base(s) -> _RefBase

The base a caller's `base_path` string names: an http(s) URL directory, or a
filesystem directory.
"""
_ref_base(s::AbstractString) = _is_url(s) ? _UrlBase(String(s)) : _DirBase(String(s))
_ref_base(b::_RefBase) = b

# The base as the string the public helpers and messages take.
_base_string(b::_DirBase) = b.dir
_base_string(b::_UrlBase) = b.url

"""
    _RefTarget

One resolved reference. `key` is its canonical identity (an absolute path, a
normalised URL, or a path into the bundled standard library), used for cycle
detection and as the reader's cache key; it is also where the document is
read from. `base` is the target's own base, against which ITS relative refs
resolve. `ref` is the spelling after `\${VAR}` and `esm:std/` expansion, and
`authored` the spelling as written; diagnostics quote one of the two.
"""
struct _RefTarget
    key::String
    base::_RefBase
    ref::String
    authored::String
end

_is_remote(t::_RefTarget) = t.base isa _UrlBase

"""
    _resolve_ref(base, ref) -> _RefTarget

Resolve `ref` against `base` (esm-spec §4.7): expand `\${VAR}` tokens and the
`esm:std/` scheme, then a bundled standard-library path is taken as is, an
http(s) URL is normalised, a relative ref inside a URL-loaded document is
URL-joined onto its base, and anything else is an absolute local path.
"""
function _resolve_ref(base::_RefBase, authored::AbstractString)::_RefTarget
    r = _expand_ref_env(authored, base isa _DirBase ? base.dir : nothing)
    if _is_bundled_path(r)
        return _RefTarget(r, _DirBase(dirname(r)), r, String(authored))
    elseif _is_url(r) || base isa _UrlBase
        key = _is_url(r) ? _url_normalize(r) : _url_join(base.url, r)
        return _RefTarget(key, _UrlBase(_url_dirname(key)), r, String(authored))
    end
    key = abspath(joinpath(base.dir, r))
    return _RefTarget(key, _DirBase(dirname(key)), r, String(authored))
end

"""
    _download_url_contents(url) -> String

Default URL fetcher: download `url` via `Base.download` and return its contents.
"""
function _download_url_contents(url::AbstractString)::String
    tmp = Base.download(url)
    content = read(tmp, String)
    rm(tmp, force = true)
    return content
end

"""
    _DocumentSource(; fetch = _download_url_contents, read_library = nothing)

The reader of every document a load references: mounted documents (§4.7),
template libraries (§9.7.2) and coupling libraries (§10.10). One is created
per load by the public entry points and travels with the load, so a load
reads and parses each file once however many edges or walks reach it, and
nothing global decides what a load reads.

* `fetch(url) -> String` reads an http(s) document. Tests pass an offline
  fetcher here, through the internal entry [`_load_document`](@ref).
* `read_library(ref, base_dir, origin) -> (raw_doc, target_base_dir)`, when
  given, replaces the reader for template-library imports only: the `load_ref`
  keyword of [`resolve_template_machinery`](@ref).
* `cache` holds each document by `_RefTarget.key` in its post-wire form
  (`_wire_document`: the carrier, op spellings settled once, so the
  `deprecated_op` warning fires once per file per load).
* `pinned` holds the local paths a mounting document's injected import refs
  were resolved to ([`_pin_injected_refs!`](@ref)): such a ref is the
  assembler's and names that file wherever it is spliced, a remote leaf
  included, where a relative or rooted spelling would join onto the leaf's URL.
"""
struct _DocumentSource
    fetch::Function
    read_library::Union{Nothing, Function}
    cache::Dict{String, Any}
    pinned::Set{String}
end

_DocumentSource(; fetch = _download_url_contents, read_library = nothing) =
    _DocumentSource(fetch, read_library, Dict{String, Any}(), Set{String}())

"""
    _resolve_ref(src, base, ref) -> _RefTarget

[`_resolve_ref`](@ref) for a ref read during a load: a local path the load
pinned (`src.pinned`) names itself, whatever `base` is.
"""
function _resolve_ref(src::_DocumentSource, base::_RefBase, ref::AbstractString)::_RefTarget
    ref in src.pinned && return _RefTarget(String(ref), _DirBase(dirname(ref)), String(ref), String(ref))
    return _resolve_ref(base, ref)
end

"""
    _RefUnreadable(target, reason, cause)

A referenced document could not be read: `reason` is `:not_found` (no such
local file), `:unreachable` (the read or the fetch failed; `cause` is the
error) or `:invalid_json` (the JSON, or the Markdown or Typst source document,
does not parse; `cause` is the `ParseError`). Internal: each
reference mechanism converts it at its edge into its own diagnostic
(`unresolved_subsystem_ref`, `template_import_unresolved`,
`coupling_import_unresolved`).
"""
struct _RefUnreadable <: EarthSciASTError
    target::_RefTarget
    reason::Symbol
    cause::Any
end

# The text of the document `t` names. A resource error or an interrupt is
# never reported as an unreadable document.
function _read_text(src::_DocumentSource, t::_RefTarget)::String
    if !_is_remote(t)
        isfile(t.key) || throw(_RefUnreadable(t, :not_found, nothing))
    end
    try
        return _is_remote(t) ? String(src.fetch(t.key)) : read(t.key, String)
    catch e
        _is_resource_error(e) && rethrow()
        throw(_RefUnreadable(t, :unreachable, e))
    end
end

"""
    _read_document(src, t; copy = true) -> post-wire document

The document `t` names, read and parsed through `src` once per load
(`_parse_document_text`: JSON, Markdown or Typst by the extension, esm-spec
§1.2.1; then `_wire_document`: carrier, op spellings). A caller that mutates
gets a fresh `deepcopy`; `copy = false` hands out the cached tree for a
read-only look. Raises `_RefUnreadable`; an op-spelling refusal (`removed_op`,
the `faq` gate) propagates as the `ParseError` it is.
"""
function _read_document(src::_DocumentSource, t::_RefTarget; copy::Bool = true)
    if !haskey(src.cache, t.key)
        text = _read_text(src, t)
        parsed = try
            _parse_document_text(text, t.key)
        catch e
            # A removed operator keeps its own code (esm-spec §1.2.1).
            (e isa ParseError && e.code != ERROR_CODES.REMOVED_OP) || rethrow()
            throw(_RefUnreadable(t, :invalid_json, e))
        end
        src.cache[t.key] = _wire_document(parsed)
    end
    doc = src.cache[t.key]
    return copy ? deepcopy(doc) : doc
end

# The cause of an unreadable reference, as message text.
_unreadable_cause(u::_RefUnreadable) =
    u.cause === nothing ? "" : sprint(showerror, u.cause)

Base.showerror(io::IO, u::_RefUnreadable) = print(
    io, "referenced document '", u.target.ref, "' (", u.target.key, ") could not be read: ",
    u.reason, isnothing(u.cause) ? "" : ": " * _unreadable_cause(u)
)
