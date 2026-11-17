# Reference spelling and location (esm-spec §4.7): `${VAR}` expansion, the
# bundled standard library, and http(s) URL resolution and fetching.

# esm-spec §4.7: a `${VAR}` token in a ref (subsystem or template import) is
# expanded from the process environment before resolution — an OPTIONAL loader
# capability (like URL refs). An UNSET variable is left literal, so the ref
# simply fails to resolve (`template_import_unresolved` / the subsystem error)
# rather than silently misresolving. Bindings without this capability treat
# `${VAR}` as a literal path segment, i.e. the same unresolved failure.
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

# The URL-resolution test every ref site applies: a URL ref, or a relative ref
# inside a URL-loaded document — but never a bundled standard-library file.
_is_remote_ref(ref::AbstractString, base::AbstractString) =
    !_is_bundled_path(ref) && (_is_url(ref) || _is_url(base))

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

const _URL_FETCHER = Ref{Function}(_download_url_contents)

"""
    _fetch_url(url) -> String

Fetch the contents of an http(s) URL. Indirected through `_URL_FETCHER`
so tests can substitute an offline fetcher (see `template_imports_test.jl`);
the default is [`_download_url_contents`](@ref) (`Base.download`).
"""
_fetch_url(url::AbstractString)::String = _URL_FETCHER[](url)

"""
    _canonical_ref(ref::String, base_path::String) -> String

Produce a canonical key for a reference, used for cycle detection.
URL identity is canonical: an absolute http(s) ref is normalized
(dot segments removed), and a relative ref whose referencing document
was itself loaded from a URL (`base_path` is a URL base) is joined
against that base. Local paths are resolved to absolute paths.
"""
function _canonical_ref(ref::String, base_path::String)::String
    if _is_bundled_path(ref)
        return ref
    elseif _is_url(ref)
        return _url_normalize(ref)
    elseif _is_url(base_path)
        return _url_join(base_path, ref)
    else
        return abspath(joinpath(base_path, ref))
    end
end
