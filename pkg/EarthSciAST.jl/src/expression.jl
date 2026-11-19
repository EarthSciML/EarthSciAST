"""
Expression substitution and structural operations module.

This module provides functions for working with ESM format expressions:
- Variable substitution with scoped reference support
- Free variable analysis
- Expression simplification through constant folding

All operations are non-mutating and return new ASTExpr objects.

Numerical evaluation lives in `tree_walk.jl` (`evaluate_expr` / the build
under `esm_problem`) — the official EarthSciAST Julia evaluator — so this
module hosts no parallel dispatch table. `simplify`'s constant-folding step
delegates to `evaluate_expr` so adding an op to the tree-walk evaluator
transparently extends the folder.
"""

# ========================================
# 0. Shared sub-expression traversal (GENERATED from OPEXPR_FIELD_TABLE)
# ========================================
#
# Every walker below is `@eval`-generated from `OPEXPR_FIELD_TABLE` (types.jl),
# so the expression-bearing field set exists in EXACTLY ONE place. Traversal
# order is struct-field order: `args`, `lower`, `upper`, `expr_body`, dense
# `ranges` bounds, `values`, `filter`, `key`, `bindings` (sorted keys).

# Build one visit statement per expression-bearing table row: the one place
# that says how each field kind holds its children. `wrap(x, f, w, key)` maps a
# child (a `Symbol` naming a local bound to it), its field `f`, the field's
# wire key `w` and its position `key` in the field (an expression: `1` for a
# single-expression field, the 1-based index `i` in a vector, the key `mk` of a
# map, or `(mk, i)` for a dense `ranges` bound) to the statement that visits
# it. The statement is spliced INLINE, so the generated walkers stay
# closure-free (see `_foreach_subexpr_children` note below). Map keys are
# visited in sorted order.
function _opexpr_child_stmts(wrap::Function)::Vector{Expr}
    stmts = Expr[]
    for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        w = string(spec.wire)
        if spec.kind === :expr
            push!(
                stmts, :(
                    let x = e.$f
                        x === nothing || $(wrap(:x, f, w, 1))
                    end
                )
            )
        elseif spec.kind === :expr_vec
            # `args` is the one never-`nothing` instance; the guard folds away.
            push!(
                stmts, :(
                    let v = e.$f
                        if v !== nothing
                            for (i, x) in enumerate(v)
                                $(wrap(:x, f, w, :i))
                            end
                        end
                    end
                )
            )
        elseif spec.kind === :expr_map
            push!(
                stmts, :(
                    let m = e.$f
                        if m !== nothing
                            for mk in sort!(collect(keys(m)))
                                let x = m[mk]
                                    $(wrap(:x, f, w, :mk))
                                end
                            end
                        end
                    end
                )
            )
        elseif spec.kind === :ranges
            # A `ranges` entry is an `IndexSetRef` (no sub-expressions) or a
            # dense bound vector whose entries may be expression-valued.
            push!(
                stmts, :(
                    let m = e.$f
                        if m !== nothing
                            for mk in sort!(collect(keys(m)))
                                v = m[mk]
                                if v isa AbstractVector
                                    for (i, x) in enumerate(v)
                                        x isa ASTExpr && $(wrap(:x, f, w, :((mk, i))))
                                    end
                                end
                            end
                        end
                    end
                )
            )
        end
    end
    return stmts
end

"""
    child_exprs(e::ASTExpr) -> Vector{ASTExpr}

All immediate sub-expressions of `e`, drawn from EVERY expression-bearing
`OpExpr` field — not just `args`. This is the ONE shared traversal used by
[`free_variables`](@ref), [`Base.contains`](@ref contains), and (field-wise)
[`substitute`](@ref), so dependency analysis sees variables nested inside
faq bodies (`expr_body`), filter predicates (`filter`), integral
bounds (`lower`/`upper`), makearray `values`, expression-valued dense
`ranges` bounds, value-invention
`key` expressions, AND expression-template `bindings` values. The walk is
generated from `OPEXPR_FIELD_TABLE`, as validate's is.

Non-expression fields (kind `:scalar`/`:join`/`:internal` in the table: `wrt`,
`dim`, `int_var`, `output_idx`, `join`, `regions`, `shape`, `perm`, `axis`,
`fn`, `name`, `value`, `id`, `distinct`, …)
carry strings/ints/const data, not `ASTExpr` sub-trees, and are not traversed.
`wrt` names a variable and is handled separately by
`free_variables`/`contains`. Literal and variable leaves have no children.
"""
child_exprs(::NumExpr) = ASTExpr[]
child_exprs(::IntExpr) = ASTExpr[]
child_exprs(::VarExpr) = ASTExpr[]

@eval function child_exprs(e::OpExpr)::Vector{ASTExpr}
    out = ASTExpr[]
    $(_opexpr_child_stmts((x, _...) -> :(push!(out, $x)))...)
    return out
end

"""
    foreach_subexpr(f, expr::ASTExpr) -> Nothing

Apply `f` to `expr` and to every descendant expression node, depth-first,
parent before children, drawing children from [`child_exprs`](@ref) — so `f`
sees expressions nested in EVERY expression-bearing `OpExpr` field
(faq bodies, filters, integral bounds, makearray `values`,
dense `ranges` bounds, value-invention `key`s,
template `bindings` values), not just `args`.

Build predicate scans and collectors on this instead of hand-rolling a
recursive field walk: a hand-rolled walk over `args` (or a partial field list)
silently misses variables in the fields above, and a newly added
expression-bearing `OpExpr` field then has to be patched into every copy.
`OPEXPR_FIELD_TABLE` (types.jl) is the ONE place that enumerates the field
list; every walker here is generated from it. Internal — read-only traversal;
for structure-preserving rewrites use `map_children`.
"""
# Apply `f` to each immediate child WITHOUT materializing a `child_exprs`
# vector — same generated field set, same order. Used by the hot read-only
# walks (`foreach_subexpr`, `foreach_subexpr_once`) so a whole-tree scan allocates
# nothing on the common args-only node.
@eval function foreach_child(f, e::OpExpr)
    $(_opexpr_child_stmts((x, _...) -> :(f($x)))...)
    return nothing
end
foreach_child(::Any, ::NumExpr) = nothing
foreach_child(::Any, ::IntExpr) = nothing
foreach_child(::Any, ::VarExpr) = nothing

function foreach_subexpr(f, expr::ASTExpr)
    f(expr)
    _foreach_subexpr_children(f, expr)
    return nothing
end
# Recurse without an allocating per-node closure: `f` is threaded straight through
# each recursive `foreach_subexpr` call (the generator splices
# `foreach_subexpr(f, x)` directly into the field walk — a
# `c -> foreach_subexpr(f, c)` closure would allocate once per node, which is
# exactly the cost this removes).
_foreach_subexpr_children(f, ::NumExpr) = nothing
_foreach_subexpr_children(f, ::IntExpr) = nothing
_foreach_subexpr_children(f, ::VarExpr) = nothing
@eval function _foreach_subexpr_children(f, e::OpExpr)
    $(_opexpr_child_stmts((x, _...) -> :(foreach_subexpr(f, $x)))...)
    return nothing
end

"""
    _any_subexpr(pred, e::ASTExpr) -> Bool
    _any_subexpr_once(pred, e::ASTExpr) -> Bool

True iff `pred` holds for `e` or a descendant in any expression-bearing field,
stopping at the first hit (parent before children, the order of
[`foreach_subexpr`](@ref)). The `_once` form tests each distinct `OpExpr` once,
for expressions that share subtrees. Use these, not a hand-rolled walk over
`args`, for "does any node …" scans.
"""
_any_subexpr(pred::P, e::ASTExpr) where {P} = pred(e)::Bool
@eval function _any_subexpr(pred::P, e::OpExpr) where {P}
    pred(e)::Bool && return true
    $(_opexpr_child_stmts((x, _...) -> :(_any_subexpr(pred, $x) && return true))...)
    return false
end

_any_subexpr_once(pred::P, e::ASTExpr) where {P} =
    _any_subexpr_once(pred, e, IdDict{OpExpr, Nothing}())
_any_subexpr_once(pred::P, e::ASTExpr, ::IdDict{OpExpr, Nothing}) where {P} = pred(e)::Bool
@eval function _any_subexpr_once(pred::P, e::OpExpr, seen::IdDict{OpExpr, Nothing}) where {P}
    haskey(seen, e) && return false
    seen[e] = nothing
    pred(e)::Bool && return true
    $(_opexpr_child_stmts((x, _...) -> :(_any_subexpr_once(pred, $x, seen) && return true))...)
    return false
end

"""
    foreach_subexpr_once(f, expr::ASTExpr) -> Nothing

Identity-memoized [`foreach_subexpr`](@ref): each distinct `OpExpr` node
(by `===`) is ENTERED at most once, so walking a structurally-shared
expression DAG costs O(distinct nodes + edges) instead of once per PATH.
`foreach_subexpr` on a DAG where a shared node is reachable through `k`
parents re-walks its whole subtree `k` times — on the resolved observed
map (`_resolve_observed`, tree_walk/build_classify.jl), whose bodies are compact
DAGs by construction (`_sub_preserving`'s identity memo), a depth-`n`
chain that references its predecessor twice per level makes that 2^n.

Same traversal contract as `foreach_subexpr` otherwise: children come from
the ONE generated `OPEXPR_FIELD_TABLE` walk (every expression-bearing
field), parent before children, `f` return value ignored.

SEMANTICS CAVEAT — use for SET-COLLECTORS and predicate scans, not
counters: only `OpExpr` nodes are memoized (the `_SubMemo` convention —
`OpExpr` is mutable precisely so `===`/`objectid` are O(1) pointer
identity; leaves are immutable and have no children, so re-visiting one is
O(1) and bounded by the DAG's edge count). A leaf reachable through `k`
distinct parent nodes is therefore yielded up to `k` times, and a shared
`OpExpr` is yielded exactly once where `foreach_subexpr` would yield it
once per path. Results that are insensitive to duplicate/deduplicated
visits (e.g. accumulating names into a `Set`) are identical between the
two walkers.
"""
function foreach_subexpr_once(f, expr::ASTExpr)
    _foreach_subexpr_once(f, expr, IdDict{OpExpr, Nothing}())
    return nothing
end

_foreach_subexpr_once(f, e::NumExpr, ::IdDict{OpExpr, Nothing}) = (f(e); nothing)
_foreach_subexpr_once(f, e::IntExpr, ::IdDict{OpExpr, Nothing}) = (f(e); nothing)
_foreach_subexpr_once(f, e::VarExpr, ::IdDict{OpExpr, Nothing}) = (f(e); nothing)
# Generated from OPEXPR_FIELD_TABLE via the same `_opexpr_child_stmts`
# splice as `_foreach_subexpr_children` — the field list lives in exactly
# one place (do NOT hand-roll it here). The `seen` check is on ENTRY, so a
# shared node's children are enumerated once no matter its in-degree.
@eval function _foreach_subexpr_once(f, e::OpExpr, seen::IdDict{OpExpr, Nothing})
    haskey(seen, e) && return nothing
    seen[e] = nothing
    f(e)
    $(_opexpr_child_stmts((x, _...) -> :(_foreach_subexpr_once(f, $x, seen)))...)
    return nothing
end

# Every VarExpr name appearing anywhere in `expr` — the NON-BINDING twin of
# `free_variables`: it enumerates children through the ONE shared
# `child_exprs`/`foreach_subexpr` traversal (so it sees EVERY expression-bearing
# `OpExpr` field: args, faq `expr_body`, integral `lower`/`upper`,
# makearray `values`, aggregate `filter` predicates, value-invention `key`s,
# and expression-valued dense `ranges` bounds), plus
# the `wrt` differentiation target, exactly as `free_variables` does. Unlike
# `free_variables` it does NOT subtract a faq's bound loop
# symbols — we need the vars an expression READS, and every caller intersects
# the result with declared variable names (which drops the bound indices).
#
# Do NOT re-hand-roll the field list here. This walker feeds the setup-geometry
# dependency closure, the live-taint pass, `_resolve_observed`'s inlining
# trigger AND the cadence materialization split (`_discrete_materialize_split`),
# where a missed reference is a silent wrong answer (a def whose only state read
# sits in an aggregate `filter` would be frozen into a discrete-cadence cache at
# `u = 0`). Routing through `child_exprs` keeps this walker in step with the
# IR; `_build_discrete_materializer!` additionally CHECKS the
# result on the compiled fill nodes, so a future divergence fails loudly.
#
# IDENTITY-MEMOIZED (`foreach_subexpr_once`, expression.jl — the same generated
# field walk, deduplicated by `OpExpr` identity): the inputs here are routinely
# DAGs — `_resolve_observed` bodies keep sharing via `_sub_preserving`'s
# identity memo, and this walker runs INSIDE that resolver's fixed-point loop —
# so the plain path-walk (`foreach_subexpr`) was exponential on an observed
# chain whose levels each reference their predecessor ≥2×. A name set
# is dedup-insensitive, so the result is identical to the un-memoized walk.
function _referenced_var_names(expr, acc::Set{String} = Set{String}())
    expr isa ASTExpr || return acc
    foreach_subexpr_once(expr) do e
        if e isa VarExpr
            push!(acc, e.name)
        elseif e isa OpExpr && e.wrt !== nothing
            push!(acc, e.wrt::String)
        end
    end
    return acc
end

# Run `sweep` — a `() -> Bool` "did this pass change anything" closure — until a
# pass reports no change. The shared shape of the monotone set-propagation
# passes in `_geometry_setup_vars` (live taint, scalar-observed block,
# setup-forward, setup-backward) and the closure-materialization pass in
# `_derive_binning_coords`: each caller owns its seed set(s) and grows them
# inside `sweep`; saturation of a monotone pass over a finite universe always
# terminates.
function _saturate!(sweep::Function)
    while sweep()
    end
    return nothing
end

# The pointer segment of a child at `key` in the field with wire key `w`.
_child_pointer(path, w, ::Int) = string(path, "/", w)
_child_pointer(path, w, mk::AbstractString) = string(path, "/", w, "/", mk)
_child_pointer(path, w, (mk, i)::Tuple) = string(path, "/", w, "/", mk, "/", i - 1)

@eval function foreach_child_with_path(g, e::OpExpr, path::String)
    $(
        _opexpr_child_stmts(
            (x, f, w, key) -> key === :i ?
                :(g($x, string(path, $("/" * w * "/"), i - 1))) :
                :(g($x, _child_pointer(path, $w, $key)))
        )...
    )
    return nothing
end

# `foreach_child_with_path`'s walk (same children, same order) without the path
# strings: `g(child, field, i)` gets the child's field and its 1-based position
# in that field (1 for a single-expression field or a map value, the position
# in its bound vector for a dense `ranges` bound).
@eval function _foreach_child_field(g, e::OpExpr)
    $(
        _opexpr_child_stmts(
            (x, f, w, key) -> :(g($x, $(QuoteNode(f)), $(key === :mk ? 1 : key isa Expr ? :i : key)))
        )...
    )
    return nothing
end

@doc """
    foreach_child_with_path(g, e::OpExpr, path::String) -> Nothing

Apply `g(child, child_path)` to each immediate sub-expression of `e` — the
SAME generated field set and order as [`child_exprs`](@ref) — where
`child_path` extends `path` with the child's WIRE-key segment
(JSON-Pointer-style): `<path>/args/<i>`, `<path>/lower`, `<path>/expr`,
`<path>/ranges/<key>/<i>`, `<path>/values/<i>`, `<path>/axes/<key>`,
`<path>/filter`, `<path>/key`, `<path>/bindings/<key>` (indices 0-based).
Used by validate's reference walk so its descent can never drift from the
shared traversal.
""" foreach_child_with_path

# Index/loop symbols BOUND by this node itself (faq range keys,
# `output_idx` axis names, an integral's `int_var`). These are node-local
# binders, not references to enclosing-scope variables.
#
# NOT the same set as validation/references.jl's `_bound_index_symbols`, deliberately: that
# checker additionally credits subscript-position index names
# (`index(u, i+1)`) and `bindings` KEYS (template formal parameters — the table's `binds_scope`
# flag) into reference-check scope, because validation answers "could this
# name legally appear here?" while this helper answers the narrower
# "does THIS node bind this symbol for `free_variables` subtraction?".
# Widening this set would silently hide real free variables from dependency
# analysis.
function _bound_symbols(e::OpExpr)::Vector{String}
    out = String[]
    e.int_var === nothing || push!(out, e.int_var::String)
    if e.ranges !== nothing
        for k in keys(e.ranges)
            push!(out, String(k))
        end
    end
    if e.output_idx !== nothing
        for x in e.output_idx
            x isa AbstractString && push!(out, String(x))
        end
    end
    return out
end

# ========================================
# 0b. Field-preserving structural rewrite
# ========================================

"""
    map_children(f, e::ASTExpr) -> ASTExpr

Return a copy of `e` with `f` applied to each immediate sub-expression, preserving
`e`'s concrete type and every non-expression field. Leaf nodes (`NumExpr`,
`IntExpr`, `VarExpr`) are returned unchanged. For `OpExpr`, `f` is applied to every
expression-bearing field — the SAME set [`child_exprs`](@ref) traverses (`args`,
`lower`, `upper`, `expr_body`, dense `ranges` bounds, `values`, `filter`,
`key`, and `bindings` values) — and the node is rebuilt via
[`reconstruct`](@ref), so a newly added `OpExpr` field can never be silently
dropped by a rewrite.

This is the ONE field-preserving structural-rewrite primitive: `substitute`,
`simplify`, and the flatten/lowering rewrites are expressed in terms of it, and
its field walk is GENERATED from `OPEXPR_FIELD_TABLE` (types.jl) so the
expression-bearing field list lives in exactly one place.
"""
map_children(f, e::NumExpr)::ASTExpr = e
map_children(f, e::IntExpr)::ASTExpr = e
map_children(f, e::VarExpr)::ASTExpr = e

# Copy-on-write maps over one field's children: the field's own container is
# returned, unallocated, when `f` returns every child unchanged (`===`), and a
# copy holding the new children otherwise.
_map_child(f::F, ::Nothing) where {F} = nothing
_map_child(f::F, x::ASTExpr) where {F} = f(x)::ASTExpr

_map_child_vec(f::F, ::Nothing) where {F} = nothing
function _map_child_vec(f::F, v::AbstractVector) where {F}
    out = v
    @inbounds for i in eachindex(v)
        a = v[i]
        r = f(a)::ASTExpr
        if r !== a
            out === v && (out = copy(v))
            out[i] = r
        end
    end
    return out
end

_map_child_map(f::F, ::Nothing) where {F} = nothing
function _map_child_map(f::F, m::AbstractDict) where {F}
    out = m
    for (k, x) in m
        r = f(x)::ASTExpr
        if r !== x
            out === m && (out = copy(m))
            out[k] = r
        end
    end
    return out
end

_map_child_ranges(f::F, ::Nothing) where {F} = nothing
function _map_child_ranges(f::F, m::AbstractDict) where {F}
    out = m
    for (k, v) in m
        v isa AbstractVector || continue
        nv = v
        for i in eachindex(v)
            b = v[i]
            b isa ASTExpr || continue
            r = f(b)::ASTExpr
            if r !== b
                nv === v && (nv = copy(v))
                nv[i] = r
            end
        end
        if nv !== v
            out === m && (out = copy(m))
            out[k] = nv
        end
    end
    return out
end

const _MAP_CHILD_FN = (
    expr = :_map_child, expr_vec = :_map_child_vec, expr_map = :_map_child_map,
    ranges = :_map_child_ranges,
)
const _MAPPED_FIELDS = Tuple(
    f for (f, spec) in pairs(OPEXPR_FIELD_TABLE) if haskey(_MAP_CHILD_FN, spec.kind)
)

# IDENTITY-PRESERVING: when `f` returns every sub-expression unchanged (`===`),
# the node itself is returned and nothing is allocated. This is what lets a
# whole-tree rewrite pass (enum lowering, substitute with no hits, interning of
# an already-canonical subtree, …) leave a structurally-SHARED expression DAG
# shared — an unconditional rebuild would rematerialize the DAG as an
# exponential tree.
@eval function map_children(f::F, e::OpExpr)::ASTExpr where {F}
    $(
        (
            :(
                $(Symbol(:new_, fld)) = $(getfield(_MAP_CHILD_FN, OPEXPR_FIELD_TABLE[fld].kind))(
                    f, e.$fld
                )
            ) for fld in _MAPPED_FIELDS
        )...
    )
    $(foldl((acc, fld) -> :($acc && $(Symbol(:new_, fld)) === e.$fld), _MAPPED_FIELDS; init = true)) &&
        return e
    return reconstruct(e; $((Expr(:kw, fld, Symbol(:new_, fld)) for fld in _MAPPED_FIELDS)...))
end

"""
    _rewrite_expr(leaf, node, e::ASTExpr; scope = nothing, enter = (n, s) -> s) -> ASTExpr

Rewrite `e` bottom-up, the one whole-expression rewriter the flatten passes
share. A leaf (`NumExpr`, `IntExpr`, `VarExpr`) goes through `leaf(x, scope)`.
An `OpExpr`'s children are rewritten in the scope `enter(node, scope)` (a
node that binds loop symbols, say, changes what its children see), then the
node goes through `node(n, scope)`, where `n` is the node itself when no child
changed (`map_children` keeps identity) and a rebuilt copy otherwise.

Each distinct `OpExpr` is rewritten once per scope, by a memo keyed by node
identity and scope: template expansion makes subtrees shared by many parents,
and a walk without the memo visits a shared subtree once per path and
rematerializes the DAG as a tree. The result shares what the input shared.
"""
function _rewrite_expr(
        leaf::L, node::N, e::ASTExpr; scope = nothing, enter::F = _same_scope
    ) where {L, N, F}
    memo = Dict{Any, IdDict{OpExpr, ASTExpr}}()
    return _rewrite_expr_at(leaf, node, enter, e, scope, memo)
end

_same_scope(_, s) = s

function _rewrite_expr_at(leaf::L, node::N, enter::F, e::ASTExpr, scope, memo) where {L, N, F}
    e isa OpExpr || return leaf(e, scope)::ASTExpr
    tbl = get!(() -> IdDict{OpExpr, ASTExpr}(), memo, scope)
    hit = get(tbl, e, nothing)
    hit === nothing || return hit
    inner = enter(e, scope)
    out = node(
        map_children(c -> _rewrite_expr_at(leaf, node, enter, c, inner, memo), e), scope
    )::ASTExpr
    tbl[e] = out
    return out
end

# ========================================
# 1. Variable Substitution
# ========================================

"""
    substitute(expr::ASTExpr, bindings::Dict{String,ASTExpr})::ASTExpr

Replace every variable named in `bindings` with its replacement expression,
throughout `expr` (including faq bodies, filter predicates, integral bounds and
every other sub-expression a node carries). A variable not in `bindings` is
left unchanged. Substitution is single-pass: a replacement is inserted as is
and never substituted again. Returns a new expression; `expr` is not modified.

`bindings` must have value type `ASTExpr` exactly: a `Dict("x" => NumExpr(2.0))`
is a `Dict{String,NumExpr}` and has no method, so build it as
`Dict{String,ASTExpr}(...)`.

# Examples
```julia
names = ["k", "k0", "T_wall", "T_air"]
e = expression_from_json(parse_math("k (T_(upright(\"wall\")) - T_(upright(\"air\")))", names, :typst))
bindings = Dict{String,ASTExpr}("T_wall" => NumExpr(300.5),
                                "k" => expression_from_json(parse_math("2 italic(\"k0\")", names, :typst)))
substitute(e, bindings)  # shows as Typst math: (2 italic("k0")) (300.5 - T_(upright("air")))
```
"""
function substitute(expr::NumExpr, bindings::Dict{String, ASTExpr})::ASTExpr
    return expr  # Numeric literals are unchanged
end

function substitute(expr::IntExpr, bindings::Dict{String, ASTExpr})::ASTExpr
    return expr  # Integer literals are unchanged
end

function substitute(expr::VarExpr, bindings::Dict{String, ASTExpr})::ASTExpr
    return get(bindings, expr.name, expr)  # Replace if bound, otherwise keep original
end

# Field-preserving substitution: recurse into EVERY sub-expression the node
# carries (via the shared `map_children` rewrite) — not just `args` — so
# substitution is complete inside faq bodies, filter predicates,
# integral bounds, makearray values, value-invention `key` expressions, and
# expression-valued dense `ranges` bounds. `map_children` routes through
# `reconstruct`, preserving all non-expression fields (semiring, output_idx,
# id, join, …) that earlier hand-listed rebuilds
# silently dropped. Bound locals (index vars, `int_var`) are short local symbols
# never present in `bindings` (namespaced globals / parameter names), so
# recursing cannot capture them.
#
# THAT IS A PRECONDITION ON THE CALLER, not a property of the AST. The
# tree-walk's `_sub_preserving` (below) substitutes INDEX names —
# precisely the symbols binders bind — so it cannot assume this and does
# capture-avoiding descent instead. Do not carry this paragraph over to a
# binding map whose keys are loop variables.
substitute(expr::OpExpr, bindings::Dict{String, ASTExpr})::ASTExpr =
    map_children(x -> substitute(x, bindings), expr)

# ========================================
# 2. Free Variable Analysis
# ========================================

"""
    free_variables(expr::ASTExpr)::Set{String}

Extract all free (unbound) variable names from an expression.
Returns a set of variable names that appear in the expression.

# Examples
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
vars = free_variables(sum_expr)  # Set(["x", "y"])

nested = OpExpr("*", [OpExpr("+", [x, NumExpr(1.0)]), y])
vars = free_variables(nested)  # Set(["x", "y"])
```
"""
function free_variables(expr::NumExpr)::Set{String}
    return Set{String}()  # No variables in numeric literals
end

function free_variables(expr::IntExpr)::Set{String}
    return Set{String}()  # No variables in integer literals
end

function free_variables(expr::VarExpr)::Set{String}
    return Set([expr.name])  # Single variable
end

function free_variables(expr::OpExpr)::Set{String}
    # IDENTITY-MEMOIZED bottom-up computation: the free-variable set
    # of a subtree is INTRINSIC to it — a variable bound by an ENCLOSING binder
    # is still free in the subtree, because binder subtraction happens at the
    # binder node itself — so two paths reaching the same shared node always
    # yield the same set, and caching per `OpExpr` identity is sound. Inputs
    # here are routinely DAGs (`_sub_preserving` / template lowering keep
    # structurally-identical subtrees shared by reference), on which a per-path
    # recursion is exponential on a doubling chain. The memo is per top-level call, so the returned set (a
    # fresh `Set` per distinct node) is never aliased across calls.
    return _free_variables_dag(expr, IdDict{OpExpr, Set{String}}())
end

function _free_variables_dag(
        expr::OpExpr,
        memo::IdDict{OpExpr, Set{String}}
    )::Set{String}
    cached = get(memo, expr, nothing)
    cached === nothing || return cached
    # Union of free variables from EVERY expression-bearing field (via the
    # shared `child_exprs` traversal), so dependency analysis sees references
    # inside faq bodies, filter predicates, integral bounds and
    # makearray values.
    result = Set{String}()
    for c in child_exprs(expr)
        if c isa OpExpr
            union!(result, _free_variables_dag(c, memo))
        elseif c isa VarExpr
            push!(result, c.name)
        end
    end

    # Symbols bound by THIS node (faq loop indices, an
    # integral's `int_var`) are local binders, not free references.
    for b in _bound_symbols(expr)
        delete!(result, b)
    end

    # Add variables from wrt field if present
    if expr.wrt !== nothing
        push!(result, expr.wrt)
    end

    memo[expr] = result
    return result
end

# ========================================
# 3. Variable Containment Check
# ========================================

"""
    Base.contains(expr::ASTExpr, var::String)::Bool

Check if an expression contains a specific variable name.
Returns true if the variable appears anywhere in the expression — including
inside faq bodies, filter predicates, integral bounds and
makearray values (the shared `child_exprs` traversal). Unlike [`free_variables`](@ref), node-local binder symbols are
NOT subtracted: this is a pure containment check.

Defined as methods of `Base.contains` (haystack/needle semantics match);
there is no package-local `contains` function shadowing `Base`.

# Examples
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
contains(sum_expr, "x")  # true
contains(sum_expr, "z")  # false
```
"""
function Base.contains(expr::IntExpr, var::String)::Bool
    return false  # Integer literals don't contain variables
end

function Base.contains(expr::NumExpr, var::String)::Bool
    return false  # Numeric literals don't contain variables
end

function Base.contains(expr::VarExpr, var::String)::Bool
    return expr.name == var
end

function Base.contains(expr::OpExpr, var::String)::Bool
    # Check every expression-bearing field via the shared traversal.
    for c in child_exprs(expr)
        if contains(c, var)
            return true
        end
    end

    # Check wrt field
    if expr.wrt !== nothing && expr.wrt == var
        return true
    end

    return false
end

# ========================================
# 4. Evaluation error type
# ========================================

"""
    UnboundVariableError

Raised by [`evaluate_expr`](@ref) (the tree-walk evaluator entry point)
when an expression references a variable name that is not in the supplied
bindings. Defined here so it is in scope for callers that catch the
"binding not yet resolved" signal during iterated observed-variable
fixed-point passes.
Fields: `code` (always `E_TREEWALK_UNBOUND_VARIABLE`, the walker's code for
it), `variable_name` and `message`.

    UnboundVariableError(variable_name, message)
"""
struct UnboundVariableError <: EarthSciASTError
    code::String
    variable_name::String
    message::String
    UnboundVariableError(variable_name::AbstractString, message::AbstractString) =
        new("E_TREEWALK_UNBOUND_VARIABLE", String(variable_name), String(message))
end

# ========================================
# 5. Expression Simplification
# ========================================

"""
    simplify(expr::ASTExpr)::ASTExpr

Perform constant folding and algebraic simplification on an expression.
Returns a new simplified ASTExpr object (non-mutating).

# Simplification Rules
- Constant folding: `2 + 3` → `5`
- Additive identity: `x + 0` → `x`, `0 + x` → `x`
- Multiplicative identity: `x * 1` → `x`, `1 * x` → `x`
- Multiplicative zero: `x * 0` → `0`, `0 * x` → `0`
- Exponentiation: `x^0` → `1`, `x^1` → `x`

# Examples
```julia
# Constant folding
expr = OpExpr("+", [NumExpr(2.0), NumExpr(3.0)])
result = simplify(expr)  # NumExpr(5.0)

# Identity elimination
expr = OpExpr("*", [VarExpr("x"), NumExpr(1.0)])
result = simplify(expr)  # VarExpr("x")
```
"""
function simplify(expr::NumExpr)::ASTExpr
    return expr  # Already simplified
end

function simplify(expr::IntExpr)::ASTExpr
    return expr  # Already simplified
end

function simplify(expr::VarExpr)::ASTExpr
    return expr  # Already simplified
end

"""
    is_literal(expr::ASTExpr)::Bool

True iff `expr` is a numeric literal (either integer or float node).
"""
is_literal(expr::ASTExpr)::Bool = isa(expr, NumExpr) || isa(expr, IntExpr)

"""
    literal_value(expr::ASTExpr)

Return the numeric value of a literal node, as `Float64`. Throws on non-literals.
"""
literal_value(expr::NumExpr) = expr.value
literal_value(expr::IntExpr) = Float64(expr.value)

# A looser bound than the document rule `_as_int64`: `abs(f) <= 2^63`
# (`Float64(typemax(Int64))` rounds up to 2^63), so `f == 2^63` passes and the
# caller's `Int64(f)` throws `InexactError`, which `simplify`'s fold catches as
# "decline to fold" (algebraic fallthrough, not a `NumExpr` fold). Tightening
# the bound would change that path's result.
_int64_maybe_representable(f::Float64)::Bool = abs(f) <= Float64(typemax(Int64))

# Exception types `simplify`'s constant-folding step treats as "decline to
# fold" (fall through to the algebraic rules) rather than a bug:
#  - `UnboundVariableError` / `TreeWalkError` — a node `evaluate_expr` cannot
#    compile or evaluate without bindings (e.g. an aggregate whose empty `args`
#    are vacuously "all literal");
#  - `DomainError` (`sqrt`/`log` of a negative literal), `DivideError`,
#    `OverflowError` — literal math outside the reals / machine range;
#  - `InexactError` — the `Int64(result_value)` boundary case admitted by
#    `_int64_maybe_representable` (`f == 2^63`).
_foldable_failure(err) =
    err isa UnboundVariableError || err isa TreeWalkError ||
    err isa DomainError || err isa DivideError ||
    err isa OverflowError || err isa InexactError

function simplify(expr::OpExpr)::ASTExpr
    # Recurse into EVERY sub-expression via the shared field-preserving rewrite,
    # so folding and identity rules also reach faq bodies, filter
    # predicates, integral bounds, makearray values, table axes, and dense range
    # bounds — not just top-level `args`. `recursed` carries the simplified
    # children in all fields; the algebraic rules below only reshape `args`.
    recursed = map_children(simplify, expr)::OpExpr
    simplified_args = recursed.args

    op = recursed.op

    # Try constant folding first - if all arguments are numeric, evaluate.
    # Per RFC §5.4.1, promotion happens only in evaluate, not simplify;
    # so when mixed int/float inputs fold, the result is a float literal.
    # When all inputs are integer, preserve integer result (for ops whose
    # integer result is representable — fall back to float on non-integer).
    # Folding is delegated to the official tree-walk evaluator
    # (`evaluate_expr`) so the simplifier shares the runner's dispatch
    # table and there is no parallel operator switch in this module.
    if all(is_literal, simplified_args)
        try
            result_value = evaluate_expr(recursed, Dict{String, Float64}())
            all_int = all(arg -> isa(arg, IntExpr), simplified_args)
            if all_int && isfinite(result_value) && result_value == trunc(result_value) &&
                    _int64_maybe_representable(result_value)
                return IntExpr(Int64(result_value))
            end
            return NumExpr(result_value)
        catch err
            # An EXPECTED evaluation failure means "decline to fold" — continue
            # with algebraic simplification below. Anything else (including
            # InterruptException) is a real bug/signal and propagates.
            _foldable_failure(err) || rethrow()
        end
    end

    # Helper: true when arg is a numeric literal equal to v (compared by value).
    is_lit_val(arg, v) = (isa(arg, NumExpr) && arg.value == v) ||
        (isa(arg, IntExpr) && Float64(arg.value) == v)

    # Algebraic simplification rules
    if op == "+"
        # Remove zeros: x + 0 = x, 0 + x = x
        non_zero_args = filter(arg -> !is_lit_val(arg, 0.0), simplified_args)
        if length(non_zero_args) == 0
            return NumExpr(0.0)
        elseif length(non_zero_args) == 1
            return non_zero_args[1]
        else
            return reconstruct(recursed; args = ASTExpr[non_zero_args...])
        end

    elseif op == "*"
        # Check for zeros: x * 0 = 0, 0 * x = 0
        for arg in simplified_args
            if is_lit_val(arg, 0.0)
                return NumExpr(0.0)
            end
        end

        # Remove ones: x * 1 = x, 1 * x = x
        non_one_args = filter(arg -> !is_lit_val(arg, 1.0), simplified_args)
        if length(non_one_args) == 0
            return NumExpr(1.0)
        elseif length(non_one_args) == 1
            return non_one_args[1]
        else
            return reconstruct(recursed; args = ASTExpr[non_one_args...])
        end

    elseif op == "^" && length(simplified_args) == 2
        base = simplified_args[1]
        exponent = simplified_args[2]

        # x^0 = 1
        if is_lit_val(exponent, 0.0)
            return NumExpr(1.0)
        end

        # x^1 = x
        if is_lit_val(exponent, 1.0)
            return base
        end

        # 0^x = 0 (for x > 0)
        if is_lit_val(base, 0.0) && is_literal(exponent) && literal_value(exponent) > 0.0
            return NumExpr(0.0)
        end

        # 1^x = 1
        if is_lit_val(base, 1.0)
            return NumExpr(1.0)
        end

        return recursed

    elseif op == "-" && length(simplified_args) == 2
        # x - 0 = x
        if is_lit_val(simplified_args[2], 0.0)
            return simplified_args[1]
        end

        return recursed

    elseif op == "/" && length(simplified_args) == 2
        # x / 1 = x
        if is_lit_val(simplified_args[2], 1.0)
            return simplified_args[1]
        end

        # 0 / x = 0 (for x != 0)
        if is_lit_val(simplified_args[1], 0.0)
            return NumExpr(0.0)
        end

        return recursed
    end

    # If no simplification rules apply, return the fully-recursed expression.
    return recursed
end

# Variable substitution that preserves every OpExpr field — the
# package-level `substitute` only carries `wrt`/`dim` and drops
# `handler_id`, `fn`, etc., which would corrupt `call`/`broadcast`
# nodes on their way through. Scoped here because this module is the
# only caller that needs the full preservation.
#
# SHARING PRESERVATION. The lowered expression is a DAG: after
# `lower_expression_templates`, structurally-identical subtrees are stored ONCE
# and referenced by many parents (a deep reconstruction chain — e.g. a monotone
# PPM stencil — has interior nodes reached by ~100+ parent edges). An
# `IdDict{OpExpr,ASTExpr}` memo maps each unique input node to a SINGLE output
# node, so a shared sub-DAG is substituted once and remains shared. Without the
# memo a node of in-degree `d` is visited and `reconstruct`ed `d` times,
# re-inflating the DAG into an exponentially larger tree BEFORE it reaches
# `_compile` (whose own IdDict memo would otherwise have kept it small). The
# per-cell faq build (`_compile_faq_percell!`) calls this once per cell,
# so the re-inflation is paid per cell — the build-time OOM this memo removes.
# The memo is created fresh per top-level call: `bindings` is fixed within one
# call, so mapping input identity → output is sound.
const _SubMemo = IdDict{OpExpr, ASTExpr}

_sub_preserving(expr::NumExpr, ::Dict{String, ASTExpr}) = expr
_sub_preserving(expr::IntExpr, ::Dict{String, ASTExpr}) = expr
_sub_preserving(expr::VarExpr, bindings::Dict{String, ASTExpr}) =
    get(bindings, expr.name, expr)
_sub_preserving(expr::OpExpr, bindings::Dict{String, ASTExpr}) =
    _sub_preserving(expr, bindings, _SubMemo())

# 3-arg forms thread the memo. Leaves ignore it (returned verbatim, no allocation).
_sub_preserving(expr::NumExpr, ::Dict{String, ASTExpr}, ::_SubMemo) = expr
_sub_preserving(expr::IntExpr, ::Dict{String, ASTExpr}, ::_SubMemo) = expr
_sub_preserving(expr::VarExpr, bindings::Dict{String, ASTExpr}, ::_SubMemo) =
    get(bindings, expr.name, expr)

# Substitute each expression in `args`, returning `(substituted, changed)`. Like
# `_resolve_arg_vec`, the ORIGINAL vector is returned untouched (no allocation)
# when no element binds, and only the first differing element triggers a copy.
function _sub_arg_vec(
        args::Vector{ASTExpr}, bindings::Dict{String, ASTExpr},
        memo::_SubMemo
    )
    changed = false
    new_args = args
    @inbounds for i in eachindex(args)
        a = args[i]
        # Manual union-split over the four concrete `ASTExpr` subtypes. `args` has the
        # abstract element type `ASTExpr`, so a bare `_sub_preserving(a, …)` dispatches
        # dynamically (`ijl_apply_generic`) — the single largest flat cost in the
        # build profile. Narrowing with `isa` lets the `OpExpr`/`VarExpr` calls
        # resolve statically and short-circuits the `NumExpr`/`IntExpr` leaves
        # (which `_sub_preserving` returns verbatim) with no call at all.
        r = a isa OpExpr ? _sub_preserving(a, bindings, memo) :
            a isa VarExpr ? get(bindings, a.name, a) :
            a                                            # NumExpr / IntExpr: verbatim
        if r !== a
            if !changed
                new_args = copy(args)
                changed = true
            end
            new_args[i] = r
        end
    end
    return new_args, changed
end

# Does `expr` BIND any name `bindings` would replace? Same rule as
# `_bound_symbols` (expression.jl) but allocation-free on the hot path: a node
# carrying none of the three binder fields — every plain math op, which is the
# overwhelming majority of a per-cell substitution — answers `false` after three
# `=== nothing` checks and no name vector is built.
function _binds_any(expr::OpExpr, bindings::Dict{String, ASTExpr})
    isempty(bindings) && return false
    iv = expr.int_var
    if iv !== nothing && haskey(bindings, iv::String)
        return true
    end
    rg = expr.ranges
    if rg !== nothing
        for k in keys(rg)
            haskey(bindings, k) && return true
        end
    end
    # A `makearray`'s `output_idx` binds too: its region values read those
    # symbols at the cell being assembled, and `_resolve_index_of_makearray`
    # binds them to the subscripts the makearray is read at.
    oi = expr.output_idx
    if oi !== nothing
        for x in oi
            x isa AbstractString && haskey(bindings, String(x)) && return true
        end
    end
    return false
end

# `bindings` minus the names `expr` binds — the substitution map that may enter
# `expr`'s scope. Off the hot path (only reached when `_binds_any` fires), so it
# reuses `_bound_symbols` directly.
function _shadowed_bindings(expr::OpExpr, bindings::Dict{String, ASTExpr})
    bound = Set{String}(_bound_symbols(expr))
    out = Dict{String, ASTExpr}()
    for (n, v) in bindings
        n in bound || (out[n] = v)
    end
    return out
end

function _sub_preserving(expr::OpExpr, bindings::Dict{String, ASTExpr}, memo::_SubMemo)
    # Identity memo: a shared node substitutes to a single shared output node.
    cached = get(memo, expr, nothing)
    cached === nothing || return cached
    # CAPTURE AVOIDANCE. A node carrying `ranges` / `output_idx` / `int_var` is a
    # BINDER: those names are loop variables scoped to its own body, filter,
    # operands and bounds. A substitution for an OUTER variable of the same name
    # must not penetrate that scope. The shadow set is `_bound_symbols`
    # (expression.jl) verbatim, so substitution and `free_variables` share ONE
    # scoping rule rather than two that can drift.
    #
    # WHAT IT COSTS TO GET WRONG. The motivating case is an inlined column mean:
    #
    #     pbl_sum_O3[gi,gj]     = Σ_gk dp[gi,gj,gk]·pbl_f[gi,gj,gk]·O3[gi,gj,gk]
    #     pbl_mean_O3[gi,gj,gk] = pbl_sum_O3[gi,gj] / max(pbl_wt[gi,gj], 1)
    #
    # `gk` is CONTRACTED in the first and an OUTPUT index in the second. In an
    # INLINING build (`compiler=:interpreter`, or an observed excluded from
    # materialization) the sum is spliced into the mean's body. Substituting the
    # outer `gk` into the inner sum's own loop variable would leave `ranges`
    # declaring a `gk` the body no longer mentions, so the unroll would emit
    # `length(gk)` IDENTICAL terms: a wrong number with no diagnostic.
    if _binds_any(expr, bindings)
        inner = _shadowed_bindings(expr, bindings)
        # Every binding shadowed ⇒ nothing in this subtree can substitute.
        # Otherwise recurse under the reduced map with its OWN memo: `memo` maps
        # node identity under ONE binding map, and a shared node reachable from
        # both scopes must not resolve to the inner scope's answer outside it.
        result = isempty(inner) ? expr : _sub_preserving(expr, inner, _SubMemo())
        memo[expr] = result
        return result
    end
    new_args, changed = _sub_arg_vec(expr.args, bindings, memo)
    new_body = expr.expr_body
    if expr.expr_body !== nothing
        new_body = _sub_preserving(expr.expr_body, bindings, memo)
        changed |= new_body !== expr.expr_body
    end
    new_values = expr.values
    if expr.values !== nothing
        nv, vchanged = _sub_arg_vec(expr.values, bindings, memo)
        new_values = nv
        changed |= vchanged
    end
    # Substitute loop-var bindings into a `filter` predicate too, so a nested
    # aggregate's filter sees the outer index values (the join's `join_gates` are
    # position-keyed and need no substitution — they are carried through).
    new_filter = expr.filter
    if expr.filter !== nothing
        new_filter = _sub_preserving(expr.filter, bindings, memo)
        changed |= new_filter !== expr.filter
    end
    # A node with no bound descendant AND no range bounds to rewrite is returned
    # verbatim — no ~30-field OpExpr rebuilt. Nodes carrying `ranges` (only nested
    # aggregates do) always take the reconstruct path so their bound expressions
    # get substituted; those are rare relative to the plain stencil math ops that
    # dominate a per-cell substitution.
    # A template reference's bindings are expressions of this scope, implicit
    # ones (the names its body reads from the caller, tree_walk frames) among
    # them, so a substitution reaches them as it reaches any argument.
    new_bindings = expr.bindings
    if expr.bindings !== nothing
        for (bk, bv) in expr.bindings
            nb = _sub_preserving(bv, bindings, memo)
            nb === bv && continue
            new_bindings === expr.bindings && (new_bindings = copy(expr.bindings))
            new_bindings[bk] = nb
        end
        changed |= new_bindings !== expr.bindings
    end
    if expr.ranges === nothing && !changed
        memo[expr] = expr
        return expr
    end
    # Substitute loop-var bindings into range BOUNDS too, so a nested faq
    # whose reduction bound references an OUTER loop index — e.g. a per-cell
    # variable-valence reduction `k ∈ [1, index(n_edges_on_cell, i)]` inside an
    # outer `i`-loop — has `i` resolved when the inner faq is later expanded.
    # Bounds are Int (pass through) or ASTExpr (recursively substituted).
    new_ranges = _sub_ranges(expr.ranges, bindings, memo)
    # `reconstruct` (types.jl) copies every remaining OpExpr field, so the full
    # preservation this helper promises holds even as fields are added.
    result = reconstruct(
        expr; args = new_args, expr_body = new_body,
        values = new_values, filter = new_filter, ranges = new_ranges,
        bindings = new_bindings
    )
    memo[expr] = result
    return result
end

# Substitute loop-var bindings into a faq `ranges` dict's bound expressions.
# Each entry is a vector whose elements are Int (left as-is) or an ASTExpr bound
# (recursively `_sub_preserving`d). Returns `nothing` unchanged when ranges is
# nothing; otherwise a fresh Dict so the original is never mutated.
_sub_ranges(ranges::Nothing, ::Dict{String, ASTExpr}, ::_SubMemo) = nothing
function _sub_ranges(ranges, bindings::Dict{String, ASTExpr}, memo::_SubMemo)
    out = Dict{String, Any}()
    for (k, v) in ranges
        out[String(k)] = v isa AbstractVector ?
            Any[(e isa ASTExpr ? _sub_preserving(e, bindings, memo) : e) for e in v] : v
    end
    return out
end

"""
    expression_names(expr) -> Vector{String}

The variable names an expression or an equation uses, in order of first use:
its string leaves under `lhs`, `rhs` and `args`. These are the `names` to give
[`print_math`](@ref) to show an expression on its own, with its names declared.

`expr` is a decoded ESM expression or equation (the value `print_math` takes),
or a typed [`ASTExpr`](@ref) or [`Equation`](@ref).

```julia
julia> expression_names(Dict("lhs" => "y", "rhs" => Dict("op" => "*", "args" => ["k", "y"])))
2-element Vector{String}:
 "y"
 "k"
```
"""
function expression_names(expr)
    out = String[]
    _expression_names!(out, expr)
    return out
end

function _expression_names!(out::Vector{String}, v)
    if v isa AbstractString
        name = String(v)
        name in out || push!(out, name)
    elseif v isa AbstractVector
        foreach(x -> _expression_names!(out, x), v)
    elseif v isa AbstractDict
        for key in ("lhs", "rhs", "args")
            child = get(v, key, get(v, Symbol(key), nothing))
            child === nothing || _expression_names!(out, child)
        end
    elseif v isa VarExpr
        v.name in out || push!(out, v.name)
    elseif v isa OpExpr
        foreach(x -> _expression_names!(out, x), v.args)
    elseif v isa Equation
        _expression_names!(out, v.lhs)
        _expression_names!(out, v.rhs)
    end
    return out
end
