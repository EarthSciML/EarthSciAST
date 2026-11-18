"""
Shared raw-JSON traversal helpers for the load-time lowering passes.

Documents are normalized ONCE at the wire boundary (`_read_json_document`,
`coerce_esm_file`) into the ONE post-wire carrier — `OrderedDict{String,Any}`
objects, `Vector{Any}` arrays, scalar leaves — via [`_to_ordered`](@ref)
below. Every pre-parse lowering pass (enum lowering,
expression templates §9.6, template-library imports §9.7, coupling imports
§10.9–§10.11, value-invention front door) walks that shape, plus the raw
`JSON3.Object`/`JSON3.Array` a wire-boundary gate inspects BEFORE
normalization (JSON3's views accept string keys, so one string-keyed accessor
serves both). This file hosts the accessors, the normalizer, and the traversal
combinators, so each pass expresses only its per-node logic, not the
object/array/leaf skeleton. `_walk_json`, `_map_json` and `_collect_json!` are
for trees; `_rewrite_json` and `_visit_json` handle each shared subtree of a
DAG once.

Included before the lowering passes in EarthSciAST.jl; depends only on JSON3
and OrderedCollections (never on the typed AST).
"""

using OrderedCollections: OrderedDict

# ---------------------------------------------------------------------------
# Node classification + key access
# ---------------------------------------------------------------------------

# JSON node-kind predicates. `JSON3.Object <: AbstractDict` and
# `JSON3.Array <: AbstractVector` on current JSON3, but the explicit union is
# kept as belt-and-braces (and as documentation of the two families handled).
# The post-wire carriers are tested first: a concrete type is one type-tag
# compare, an abstract one a subtype query, and these run once per node of
# every whole-document walk.
@inline _is_object(x) = (
    x isa OrderedDict{String, Any} || x isa Dict{String, Any} ||
        x isa AbstractDict || x isa JSON3.Object
)
@inline _is_array(x) = (x isa Vector{Any} || x isa AbstractVector || x isa JSON3.Array)

# A JSON leaf: neither an object nor an array (the concrete leaf types first,
# as above).
@inline _is_json_leaf(x) =
    x isa Int64 || x isa Float64 || x isa String || x isa Bool || x isa Nothing ||
    !(_is_object(x) || _is_array(x))

# True when every element of `x` is a leaf (an inline number array, one ring
# vertex). Walkers that look for objects, or that only rebuild containers, can
# handle such an array in one tight loop instead of one call per element.
function _leaves_only(x::AbstractVector)
    for v in x
        _is_json_leaf(v) || return false
    end
    return true
end

"""
    _raw_get(x, key::String[, default])
    _raw_haskey(x, key::String) -> Bool

The access layer over raw JSON. Post-wire trees are string-keyed
(`_to_ordered`), and a `JSON3.Object` — the only pre-normalization carrier a
wire-boundary gate still sees — resolves string keys natively, so one plain
`get`/`haskey` covers every carrier. `_raw_get` reads an absent key, a JSON
`null` and a non-object `x` alike as `nothing` (or `default`); `_raw_haskey` is
the one way to tell a present `null` from an absent key, and is `false` for a
non-object.
"""
_raw_get(x, key::AbstractString) = _is_object(x) ? get(x, key, nothing) : nothing
function _raw_get(x, key::AbstractString, default)
    v = _raw_get(x, key)
    return v === nothing ? default : v
end
_raw_haskey(x, key::AbstractString) = _is_object(x) && haskey(x, key)

"""
    _components(root)

The components of a raw document, as `(kind, name::String, comp)` for each
object under `root["models"]` and then `root["reaction_systems"]`, in document
order. Entries that are not objects are skipped; a `root` that is not an
object has none.
"""
_components(root) = (
    (kind, string(name), comp)
        for kind in (_is_object(root) ? ("models", "reaction_systems") : ())
        for comps in (_raw_get(root, kind),) if comps !== nothing && _is_object(comps)
        for (name, comp) in pairs(comps) if _is_object(comp)
)

"""
    _to_ordered(x)

Deep-normalize any JSON carrier (a `JSON3.Object`/`JSON3.Array` straight off
the wire, or a native dict/vector tree with `String` or `Symbol` keys) into
the ONE post-wire carrier: `OrderedDict{String,Any}` objects, `Vector{Any}`
arrays, scalar leaves — PRESERVING document key order (declaration order is
normative for the §9.6.3 tie-break).

SHARING-PRESERVING: an identity memo maps each input container to its single
normalized counterpart, so a shared subtree — e.g. a template body composed
as a DAG by `_substitute` — normalizes to ONE shared output object instead of
being expanded into an exponential tree. Fresh-parsed JSON3 views are trees
(no aliasing is expressible in JSON text), so only the native nodes the
lowering passes themselves create can be shared. A JSON3 view is memoized
where the input reaches it (a native node may hold one view twice), and the
tree beneath it converts without the memo (`_json3_to_ordered`). A view is an
immutable value over the parsed text whose identity hash reads that whole
text, so the memo keys a view by its `inds` container instead (`_view_key`):
a mutable object each view instance gets for itself, so the key is O(1) and
names that instance exactly. Keying the view itself would cost the whole
document per root call, so a caller that normalizes a document one child at a
time would be O(children × text).

Always returns fresh containers (a deep, sharing-preserving copy), so callers
may mutate the result without touching the input.
"""
_to_ordered(x) = _to_ordered_memo(x, IdDict{Any, Any}())

# `_to_ordered` for a consumer that only reads the result: a leaf-only
# `Vector{Any}` (an inline number array) is shared with the input instead of
# copied, so normalizing an already-native document allocates nothing per row.
_to_ordered_shared(x) = _to_ordered_memo(x, IdDict{Any, Any}(), true)

function _to_ordered_memo(x, memo::IdDict{Any, Any}, share_leaves::Bool = false)
    if x isa JSON3.Object || x isa JSON3.Array
        key = _view_key(x)
        r = get(memo, key, nothing)
        r === nothing || return r
        out = _json3_to_ordered(x)
        memo[key] = out
        return out
    elseif _is_object(x)
        r = get(memo, x, nothing)
        r === nothing || return r
        out = OrderedDict{String, Any}()
        memo[x] = out
        for (k, v) in pairs(x)
            out[string(k)] = _to_ordered_memo(v, memo, share_leaves)
        end
        return out
    elseif _is_array(x)
        # A leaf-only array holds nothing to share or normalize: copy it as is,
        # without an identity-memo entry per (possibly millions of) row.
        x isa Vector{Any} && _leaves_only(x) && return share_leaves ? x : copy(x)
        r = get(memo, x, nothing)
        r === nothing || return r
        out = Vector{Any}()
        sizehint!(out, length(x))
        memo[x] = out
        for v in x
            push!(out, _to_ordered_memo(v, memo, share_leaves))
        end
        return out
    end
    return x
end

# A JSON3 view's memo key: its `inds` index container, which JSON3 allocates
# fresh for every view it makes (the root's in `JSON3.read`, a child's on each
# access), so two references share it exactly when they are the same view.
# Hashing the view instead would hash its `buf`, the whole parsed text.
_view_key(x::Union{JSON3.Object, JSON3.Array}) = getfield(x, :inds)

# The memo-free conversion of the tree under one JSON3 view: every child is a
# view of the same parsed text or a scalar leaf, so nothing below can alias.
function _json3_to_ordered(x::JSON3.Object)
    out = OrderedDict{String, Any}()
    for (k, v) in pairs(x)
        out[string(k)] = _json3_to_ordered(v)
    end
    return out
end
function _json3_to_ordered(x::JSON3.Array)
    out = Vector{Any}(undef, length(x))
    # JSON3 keeps every number of an array as a float once one element is a
    # float (`[0.5, 2]` reads `[0.5, 2.0]`), and its parser carries that mode
    # into the objects and arrays that follow the float, so in
    # `[0.5, {"ranges": {"k": [1, "n"]}}]` the bound reads `1.0`. A container
    # after a float element is therefore read back with the integer rule
    # JSON3 applies everywhere else (`_json3_reint`).
    floated = false
    for (i, v) in enumerate(x)
        out[i] = floated && (v isa JSON3.Object || v isa JSON3.Array) ?
            _json3_reint(v) : _json3_to_ordered(v)
        v isa Float64 && (floated = true)
    end
    return out
end
_json3_to_ordered(x) = x

# A subtree JSON3 parsed with every number as a float, normalized as if parsed
# with its integer rule: an integral number in Int64 range is an `Int64`,
# except an array's numbers after its first non-integral one, which stay
# floats as JSON3 keeps them. (An integer literal above 2^53 has already been
# rounded by then; JSON3 would have re-read its text.)
function _json3_reint(x::JSON3.Object)
    out = OrderedDict{String, Any}()
    for (k, v) in pairs(x)
        out[string(k)] = v isa Float64 ? something(_as_int64(v), v) :
            (v isa JSON3.Object || v isa JSON3.Array) ? _json3_reint(v) : v
    end
    return out
end
function _json3_reint(x::JSON3.Array)
    out = Vector{Any}(undef, length(x))
    floated = false
    for (i, v) in enumerate(x)
        if v isa Float64
            i64 = floated ? nothing : _as_int64(v)
            if i64 !== nothing
                out[i] = i64
            else
                out[i] = v
                floated = true
            end
        else
            out[i] = (v isa JSON3.Object || v isa JSON3.Array) ? _json3_reint(v) : v
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Traversal combinators
# ---------------------------------------------------------------------------

"""
    _find_json_path(hit, node, at="") -> Union{String,Nothing}

The path of the first OBJECT node, depth-first in document order, for which
`hit(n)` is true: `at` followed by one `/<key>` or `/<0-based index>` segment
per level, or `nothing` when no object matches. The path string is assembled
only for the hit, so a search through a document of large inline arrays costs
no string per visited element.
"""
function _find_json_path(hit, node, at::AbstractString = "")
    segs = _find_json_segs(hit, node)
    segs === nothing && return nothing
    return string(at, (string("/", s) for s in Iterators.reverse(segs))...)
end

# The path segments of the first hit, innermost first, or `nothing`.
function _find_json_segs(hit, node)
    if _is_object(node)
        hit(node) && return Any[]
        for (k, v) in pairs(node)
            h = _find_json_segs(hit, v)
            h === nothing || return push!(h, string(k))
        end
    elseif _is_array(node)
        _may_hold_object(node) || return nothing
        for (i, v) in enumerate(node)
            _is_json_leaf(v) && continue        # `hit` only ever sees objects
            # The common nested `Vector{Any}` row takes a static call.
            h = v isa Vector{Any} ? _find_json_segs(hit, v) : _find_json_segs(hit, v)
            h === nothing || return push!(h, i - 1)
        end
    end
    return nothing
end

# False when a JSON array can hold no object: its elements are scalars, or
# arrays of scalars (an inline number array, a ring of coordinate pairs). A
# validator walking for object nodes has nothing to do in such an array, so it
# can return before registering it in its identity memo. Looks two levels down
# only, so the check itself never recurses through a shared tree.
function _may_hold_object(x)
    for c in x
        _is_json_leaf(c) && continue
        if c isa Vector{Any}
            _leaves_only(c) || return true
        else
            _is_array(c) || return true
            _leaves_only(c) || return true
        end
    end
    return false
end

# Sentinel returned by a `_map_json` visitor to mean "no rewrite here — recurse
# structurally into my children". A singleton type (not `nothing`) so that
# `nothing` remains a legal replacement value.
struct _JsonDescend end
const _JSON_DESCEND = _JsonDescend()

"""
    _walk_json(f, node) -> Nothing

Depth-first, parent-before-children visit of every node of a raw JSON tree
(objects, arrays, AND scalar leaves). `f` is called as `f(key, n)` where `key`
is the `String` object key under which `n` hangs, or `nothing` for the root
and for array elements. Return `false` from `f` to PRUNE: the children of `n`
are not visited (any other return value — including `nothing` — descends).
Object entries are visited in document/iteration order.

A collector prunes structural namespaces by key, e.g. the §9.7.6 free-name
scan (`_collect_names!`, which skips the value under `"op"`):

    _walk_json(node) do key, n
        key == "op" && return false           # structural, not a name position
        n isa AbstractString && push!(out, string(n))
        return true
    end

For a plain predicate collector with no key logic, use
[`_collect_json!`](@ref).
"""
function _walk_json(f, node)
    _walk_json_impl(f, nothing, node)
    return nothing
end

function _walk_json_impl(f, key::Union{Nothing, String}, node)
    f(key, node) === false && return nothing
    if _is_object(node)
        for (k, v) in pairs(node)
            _walk_json_impl(f, string(k), v)
        end
    elseif _is_array(node)
        for v in node
            _walk_json_impl(f, nothing, v)
        end
    end
    return nothing
end

"""
    _map_json(f, node)

Structure-preserving rewrite of a raw JSON tree. `f` is called as `f(key, n)`
(same `key` convention as [`_walk_json`](@ref): the `String` object key, or
`nothing` at the root and for array elements) on every node, parent first:

- return [`_JSON_DESCEND`](@ref _JsonDescend) to keep `n`'s structure and
  recurse into its children (a scalar leaf is returned unchanged);
- return anything else to REPLACE the node with that value verbatim — the
  combinator does not descend into a replacement, so `f` deep-copies /
  recurses itself where needed (e.g. via `_to_ordered`, or by calling
  `_map_json` again on a sub-tree).

Rebuilt objects are `OrderedDict{String,Any}` in document key order and
rebuilt arrays are `Vector{Any}` — the same normalization as `_to_ordered`
(declaration order is normative for the §9.6.3 tie-break, so lowering-pass
rewrites must never lose it). Untouched sub-trees are still REBUILT into that
normalized form, matching how the existing rewrite walkers
(`_substitute_metaparams`, `_rename_walk`) reconstruct every object they
recurse through.

The metaparameter substitution pass (esm-spec §9.7.6), for instance, is

    _map_json(node) do key, n
        key !== nothing && key in _META_SUBST_SKIP_KEYS && return _to_ordered(n)
        n isa AbstractString && haskey(values, string(n)) &&
            return values[string(n)]
        return _JSON_DESCEND
    end

A rewrite whose decision needs SIBLING context (e.g. `_rename_walk` treating
`name` specially only inside an `apply_expression_template` node) intercepts
at the enclosing OBJECT node: match the object in `f`, rebuild it explicitly,
and call `_map_json` on the member values that need the generic recursion.
"""
function _map_json(f, node)
    return _map_json_impl(f, nothing, node)
end

function _map_json_impl(f, key::Union{Nothing, String}, node)
    r = f(key, node)
    r === _JSON_DESCEND || return r
    if _is_object(node)
        out = OrderedDict{String, Any}()
        for (k, v) in pairs(node)
            out[string(k)] = _map_json_impl(f, string(k), v)
        end
        return out
    elseif _is_array(node)
        return Any[_map_json_impl(f, nothing, v) for v in node]
    end
    return node
end

"""
    _collect_json!(pred, out, node) -> out

Push onto `out` every node `n` of the raw JSON tree (objects, arrays, and
scalar leaves alike, depth-first, parent before children) for which `pred(n)`
is true. No pruning — every node is tested; use [`_walk_json`](@ref) directly
when a structural namespace must be skipped by key.
"""
function _collect_json!(pred, out, node)
    _walk_json(node) do _, n
        pred(n) && push!(out, n)
        return true
    end
    return out
end

# ---------------------------------------------------------------------------
# Sharing-aware traversals
# ---------------------------------------------------------------------------
#
# Template substitution splices each binding by reference, so an expanded tree
# is a DAG in which one subtree can hang under exponentially many paths. The
# two traversals below handle each container once: `_rewrite_json` keeps an
# identity memo of results and rebuilds a container only when a child changed,
# and `_visit_json` keeps a set of the containers it has visited.

# Sentinel a `_visit_json` visitor returns to end the whole walk.
struct _JsonStop end
const _JSON_STOP = _JsonStop()

# The state of one `_rewrite_json` walk; passed to the callback so that it can
# rewrite parts of a node itself (`_rewrite_json_node`, `_rewrite_json_children`).
struct _JsonRewrite{F}
    f::F
    memo::IdDict{Any, Any}
    leaves::Bool
end

"""
    _rewrite_json(f, node; memo = IdDict{Any,Any}(), leaves = true) -> node′

Sharing-preserving rewrite of a raw JSON tree that may be a DAG. `f(rw, n)` is
called once per object (and, when `leaves = true`, on every scalar leaf),
parent first, and returns

- `_JSON_DESCEND` to keep `n` and rewrite its children (a leaf is kept as is);
- anything else to replace `n`; the replacement is not descended into. To
  rewrite part of `n` first, `f` calls `_rewrite_json_node(rw, x)` on a
  subtree or `_rewrite_json_children(rw, n; keep, drop)` on `n` itself, which
  share the walk's memo.

Arrays are always descended. Each container's result is recorded in `memo`
by identity, so a subtree shared under many parents is rewritten once and
its result shared; a container is rebuilt (`OrderedDict{String,Any}` /
`Vector{Any}`, key order kept) only when one of its children changed, and is
otherwise returned itself. A walk that changes nothing returns `node`.
`f`'s answer for a container must therefore depend on the container alone.

With `leaves = false`, `f` never sees a leaf, and an array that can hold no
object (`_may_hold_object`) is returned without being looked into, which keeps
a walk over large inline number arrays cheap.
"""
_rewrite_json(f, node; memo::IdDict{Any, Any} = IdDict{Any, Any}(), leaves::Bool = true) =
    _rewrite_json_node(_JsonRewrite(f, memo, leaves), node)

function _rewrite_json_node(rw::_JsonRewrite, n)
    if _is_object(n)
        r = get(rw.memo, n, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        r = rw.f(rw, n)
        res = r === _JSON_DESCEND ? _rewrite_json_children(rw, n) : r
        rw.memo[n] = res
        return res
    elseif _is_array(n)
        rw.leaves || _may_hold_object(n) || return n
        r = get(rw.memo, n, _JSON_DESCEND)
        r === _JSON_DESCEND || return r
        res = _rewrite_json_children(rw, n)
        rw.memo[n] = res
        return res
    end
    rw.leaves || return n
    r = rw.f(rw, n)
    return r === _JSON_DESCEND ? n : r
end

"""
    _rewrite_json_children(rw, n; keep = nothing, drop = nothing) -> n′

`n` with each child rewritten by the walk `rw`: a new container when some
child changed, else `n` itself. On an object, the value under the key `keep`
is copied as it is, and the entry under the key `drop` is left out (which
counts as a change).
"""
function _rewrite_json_children(
        rw::_JsonRewrite, n; keep::Union{Nothing, String} = nothing,
        drop::Union{Nothing, String} = nothing
    )
    changed = false
    if _is_object(n)
        buf = OrderedDict{String, Any}()
        for (k, v) in pairs(n)
            ks = string(k)
            if ks == drop
                changed = true
            elseif ks == keep
                buf[ks] = v
            else
                rv = _rewrite_json_node(rw, v)
                rv === v || (changed = true)
                buf[ks] = rv
            end
        end
        return changed ? buf : n
    end
    abuf = Vector{Any}(undef, length(n))
    for (i, v) in enumerate(n)
        rv = _rewrite_json_node(rw, v)
        rv === v || (changed = true)
        abuf[i] = rv
    end
    return changed ? abuf : n
end

# A JSON pointer built only when asked for: the base and the segments of the
# current position, which `_visit_json` pushes and pops as it moves.
struct _JsonPointer
    base::String
    segs::Vector{Any}
end
Base.string(p::_JsonPointer) = string(p.base, ("/" * string(s) for s in p.segs)...)

"""
    _visit_json(f, node; seen = IdDict{Any,Nothing}(), path = nothing) -> Bool

Visit each container of a raw JSON tree (which may be a DAG) once, parent
first, in document order. `f(key, n)` is called on every object and on every
array that may hold one (`_may_hold_object`; other arrays and scalar leaves
are skipped), with `key` the object key `n` hangs under or `nothing` for the
root and array elements. When `path` is a string, `f(key, n, ptr)` is called
instead: `string(ptr)` is the JSON pointer of `n` under `path`, built only when
asked for and valid only during the call.

`f` returns `false` to skip `n`'s children (`n` is then not counted as
visited, so `f` sees it again where it hangs elsewhere), `_JSON_STOP` to end
the walk, anything else to descend. A container already in `seen` is not
visited again. Returns `true` when `f` ended the walk.
"""
function _visit_json(
        f, node; seen::IdDict{Any, Nothing} = IdDict{Any, Nothing}(),
        path::Union{Nothing, AbstractString} = nothing
    )
    ptr = path === nothing ? nothing : _JsonPointer(String(path), Any[])
    return _visit_json_node(f, nothing, node, seen, ptr) === _JSON_STOP
end

function _visit_json_node(f, key, n, seen::IdDict{Any, Nothing}, ptr)
    obj = _is_object(n)
    obj || (_is_array(n) && _may_hold_object(n)) || return nothing
    haskey(seen, n) && return nothing
    r = ptr === nothing ? f(key, n) : f(key, n, ptr)
    r === false && return nothing
    r === _JSON_STOP && return _JSON_STOP
    seen[n] = nothing
    if obj
        for (k, v) in pairs(n)
            _is_json_leaf(v) && continue
            ks = string(k)
            ptr === nothing || push!(ptr.segs, ks)
            s = _visit_json_node(f, ks, v, seen, ptr)
            ptr === nothing || pop!(ptr.segs)
            s === _JSON_STOP && return s
        end
    else
        for (i, v) in enumerate(n)
            _is_json_leaf(v) && continue
            ptr === nothing || push!(ptr.segs, i - 1)
            s = _visit_json_node(f, nothing, v, seen, ptr)
            ptr === nothing || pop!(ptr.segs)
            s === _JSON_STOP && return s
        end
    end
    return nothing
end
