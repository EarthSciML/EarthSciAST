"""
Shared raw-JSON traversal helpers for the load-time lowering passes.

Every pre-parse lowering pass (closed-function enum lowering, expression
templates §9.6, template-library imports §9.7, coupling imports §10.9–§10.11,
value-invention front door) walks the same shape of tree: the raw document as
`JSON3.Object`/`JSON3.Array` straight off the wire, or the
`OrderedDict{String,Any}`/`Dict{String,Any}`/`Vector{Any}` forms the passes
rebuild — i.e. objects keyed by `String` OR `Symbol`, arrays, and scalar
leaves. This file hosts the key-agnostic accessors and the three traversal
combinators so each pass expresses only its per-node logic, not the
object/array/leaf skeleton.

Included before the lowering passes in EarthSciAST.jl; depends only on JSON3
and OrderedCollections (never on the typed AST).
"""

using OrderedCollections: OrderedDict

# ---------------------------------------------------------------------------
# Node classification + Symbol-or-String key access
# ---------------------------------------------------------------------------

# JSON node-kind predicates. `JSON3.Object <: AbstractDict` and
# `JSON3.Array <: AbstractVector` on current JSON3, but the explicit union is
# kept as belt-and-braces (and as documentation of the two families handled).
_is_object(x) = (x isa AbstractDict || x isa JSON3.Object)
_is_array(x)  = (x isa AbstractVector || x isa JSON3.Array)

"""
    _raw_get(x, key::String)
    _raw_haskey(x, key::String) -> Bool

Key access over a raw JSON object regardless of key type: a `JSON3.Object`
keys by `Symbol`, the rebuilt `Dict`/`OrderedDict` forms by `String`. `get`
with the `String` key first, then the `Symbol` key (`nothing` if absent).
"""
_raw_get(x, key::String) = get(x, key, get(x, Symbol(key), nothing))
_raw_haskey(x, key::String) = haskey(x, key) || haskey(x, Symbol(key))

# ---------------------------------------------------------------------------
# Traversal combinators
# ---------------------------------------------------------------------------

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
