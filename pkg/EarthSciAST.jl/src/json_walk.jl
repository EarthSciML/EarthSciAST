"""
Shared raw-JSON traversal helpers for the load-time lowering passes.

Documents are normalized ONCE at the wire boundary (`_read_json_document`,
`coerce_esm_file`) into the ONE post-wire carrier — `OrderedDict{String,Any}`
objects, `Vector{Any}` arrays, scalar leaves — via [`_to_ordered`](@ref)
below. Every pre-parse lowering pass (closed-function enum lowering,
expression templates §9.6, template-library imports §9.7, coupling imports
§10.9–§10.11, value-invention front door) walks that shape, plus the raw
`JSON3.Object`/`JSON3.Array` a wire-boundary gate inspects BEFORE
normalization (JSON3's views accept string keys, so one string-keyed accessor
serves both). This file hosts the accessors, the normalizer, and the three
traversal combinators so each pass expresses only its per-node logic, not the
object/array/leaf skeleton.

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
_is_object(x) = (x isa AbstractDict || x isa JSON3.Object)
_is_array(x)  = (x isa AbstractVector || x isa JSON3.Array)

"""
    _raw_get(x, key::String)
    _raw_haskey(x, key::String) -> Bool

String-keyed access over a raw JSON object. Post-wire trees are string-keyed
(`_to_ordered`), and a `JSON3.Object` — the only pre-normalization carrier a
wire-boundary gate still sees — resolves string keys natively, so one plain
`get`/`haskey` covers every carrier. `_raw_get` reports an absent key as
`nothing`.
"""
_raw_get(x, key::String) = get(x, key, nothing)
_raw_haskey(x, key::String) = haskey(x, key)

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
tree beneath it converts without the memo (`_json3_to_ordered`): each view is
an immutable value over the parsed text, and its identity hash reads that
whole text, so memoizing every view makes a load quadratic in document size.

Always returns fresh containers (a deep, sharing-preserving copy), so callers
may mutate the result without touching the input.
"""
_to_ordered(x) = _to_ordered_memo(x, IdDict{Any,Any}())

function _to_ordered_memo(x, memo::IdDict{Any,Any})
    if x isa JSON3.Object || x isa JSON3.Array
        r = get(memo, x, nothing)
        r === nothing || return r
        out = _json3_to_ordered(x)
        memo[x] = out
        return out
    elseif _is_object(x)
        r = get(memo, x, nothing)
        r === nothing || return r
        out = OrderedDict{String,Any}()
        memo[x] = out
        for (k, v) in pairs(x)
            out[string(k)] = _to_ordered_memo(v, memo)
        end
        return out
    elseif _is_array(x)
        r = get(memo, x, nothing)
        r === nothing || return r
        out = Vector{Any}()
        memo[x] = out
        for v in x
            push!(out, _to_ordered_memo(v, memo))
        end
        return out
    end
    return x
end

# The memo-free conversion of the tree under one JSON3 view: every child is a
# view of the same parsed text or a scalar leaf, so nothing below can alias.
function _json3_to_ordered(x::JSON3.Object)
    out = OrderedDict{String,Any}()
    for (k, v) in pairs(x)
        out[string(k)] = _json3_to_ordered(v)
    end
    return out
end
function _json3_to_ordered(x::JSON3.Array)
    out = Vector{Any}(undef, length(x))
    for (i, v) in enumerate(x)
        out[i] = _json3_to_ordered(v)
    end
    return out
end
_json3_to_ordered(x) = x

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
function _find_json_path(hit, node, at::AbstractString="")
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
        for (i, v) in enumerate(node)
            h = _find_json_segs(hit, v)
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
_may_hold_object(x) =
    any(c -> _is_object(c) || (_is_array(c) && any(g -> _is_array(g) || _is_object(g), c)), x)

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

function _walk_json_impl(f, key::Union{Nothing,String}, node)
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

function _map_json_impl(f, key::Union{Nothing,String}, node)
    r = f(key, node)
    r === _JSON_DESCEND || return r
    if _is_object(node)
        out = OrderedDict{String,Any}()
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
