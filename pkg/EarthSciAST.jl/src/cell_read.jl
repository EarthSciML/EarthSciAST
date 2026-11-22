# ============================================================================
# Reading an array expression at one cell of a grid (esm-spec §4.3.4)
# ============================================================================
#
# The pointwise lift, shape promotion and the elementwise template lift each
# rewrite a whole-array expression into the body of a `faq` that computes one
# cell. They share what this file holds: the per-cell gather of a variable by
# index-set name, the walk that reads an expression's operands at the cell, the
# `faq` that wraps the result, and the rule that names its loop symbols.

# Reads the template references the lifts meet through the flattened system's
# merged registry, each template analysed once (elementwise_refs.jl); cellwise
# variants the lift needs are added to that registry. Nothing is expanded.
struct _ElementwiseContext
    registry::Any
    bodies::Dict{String, Any}          # template => (params, typed body) or nothing
    roles::Dict{String, Any}           # template => _EwRoles (elementwise_refs.jl)
    names::Dict{String, Set{String}}   # template => the names its expansion reads, less params
    cellwise::Dict{Tuple{String, Vector{String}}, Any}   # (template, split) => (variant, map)
end

_ElementwiseContext(registry) = _ElementwiseContext(
    registry, Dict{String, Any}(), Dict{String, Any}(), Dict{String, Set{String}}(),
    Dict{Tuple{String, Vector{String}}, Any}()
)

# Op-class memberships for the array rewrites, derived from the registry flags
# (src/op_registry.jl); memberships are pinned literal-for-literal by
# test/op_registry_test.jl.
#
# Nodes that PRODUCE an array (subject to `output_idx` emptiness for the
# reductions — see `_is_array_producer`).
const _ARRAY_PRODUCER_OPS = _ops_with(:array_producer)
# Nodes that carry their own indexing (the array producers plus an `index`
# gather): the leaf-indexing rewrites never descend into them.
const _SELF_INDEXED_OPS = _ops_with(:self_indexed)

# True iff `expr` is an array-PRODUCING node: a `makearray`, or an `faq` with a
# non-empty `output_idx` (a scalar reduction has an empty `output_idx` and
# produces a scalar).
function _is_array_producer(expr::ASTExpr)::Bool
    expr isa OpExpr || return false
    expr.op == "makearray" && return true
    expr.op in _ARRAY_PRODUCER_OPS || return false
    expr.output_idx === nothing && return false
    return any(s -> s isa AbstractString, expr.output_idx)
end

# The rank of the array an array producer yields: a `makearray`'s region rank
# (0 with no region), a `faq`'s count of string output indices.
_producer_rank(v::OpExpr) = v.op == "makearray" ?
    ((v.regions === nothing || isempty(v.regions)) ? 0 : length(v.regions[1])) :
    count(s -> s isa AbstractString, something(v.output_idx, ()))

# The axes of an `n`-axis `makearray` region at which a region value of rank
# `rank` is indexed: every axis when the ranks agree, else the region's
# non-singleton axes (`singleton(d)`: axis `d` spans one cell), since a face or
# strip region pins the others to one line (esm-spec §9.6.8). The caller checks
# that the count matches `rank`.
_region_value_axes(rank::Int, n::Int, singleton) =
    rank == n ? collect(1:n) : Int[d for d in 1:n if !singleton(d)]

"""
    _AxisAlign(axes, var_shapes)

The index sets of a per-cell rewrite's result, positionally parallel to the
rewrite's loop symbols, and every variable's declared index sets. An operand
whose index sets are a subset of `axes` is gathered at the loop over each of
ITS OWN index sets, so a `[lat]` operand in a `[lon, lat, lev]` result
replicates along `lon` and `lev`, and a `[lat, lon]` operand in a `[lon, lat]`
result transposes rather than being read positionally (esm-spec §4.3.4).
"""
struct _AxisAlign
    axes::Vector{String}
    var_shapes::Dict{String, Vector{String}}
end

# An alignment is usable only when its index sets are positionally parallel to
# `loops` and distinct: a result that names one index set on two axes (`[x, x]`,
# a square operator field) has no single loop per name, so such a rewrite reads
# positionally.
function _usable_align(
        align::Union{Nothing, _AxisAlign}, loops::Vector{String}
    )::Union{Nothing, _AxisAlign}
    align === nothing && return nothing
    length(align.axes) == length(loops) || return nothing
    allunique(align.axes) || return nothing
    return align
end

# `index(node, loops…)`: `node`'s element at the current cell, positionally.
_index_wrap(node::ASTExpr, loops::Vector{String})::OpExpr =
    OpExpr("index", ASTExpr[node, (VarExpr(l) for l in loops)...])

"""
    _gather_by_name(v, shape, axes, loops) -> OpExpr or Tuple{Symbol, String}

The variable `v`, declared over the index sets `shape`, read at the current
cell of a grid whose loop `loops[d]` runs over the index set `axes[d]`: each
declared index set is read at the loop over it (esm-spec §4.3.4). A shape equal
to the grid's is the positional gather.

When there is no such read, returns why, with the index set at fault:
`(:foreign, s)` for the first index set of `shape` the grid does not run over;
otherwise `(:repeated, s)` for the first that `shape` names twice, or
`(:grid_repeated, s)` for the first the grid runs over on two axes. Each caller
decides what a refusal means in its position.
"""
function _gather_by_name(
        v::VarExpr, shape::Vector{String}, axes::Vector{String}, loops::Vector{String}
    )
    shape == axes && return _index_wrap(v, loops)
    for s in shape
        s in axes || return (:foreign, s)
    end
    subs = Vector{ASTExpr}(undef, length(shape) + 1)
    subs[1] = v
    for (d, s) in enumerate(shape)
        s in view(shape, 1:(d - 1)) && return (:repeated, s)
        count(isequal(s), axes) == 1 || return (:grid_repeated, s)
        subs[d + 1] = VarExpr(loops[findfirst(isequal(s), axes)])
    end
    return OpExpr("index", subs)
end

# Promotion's reading of an array variable leaf at the cell: by name under a
# usable alignment, positionally for a variable with no declared shape, a shape
# equal to the result's, or a shape that repeats an index set (there is then no
# single loop per name). An index set the result is not shaped over is
# `E_TREEWALK_ARRAY_SHAPE_MISMATCH`, the build-time twin of `validate()`'s
# `array_shape_mismatch`, unless `on_foreign` handles it.
function _index_wrap_var(
        v::VarExpr, loops::Vector{String}, align::Union{Nothing, _AxisAlign};
        on_foreign = _throw_array_shape_mismatch
    )::OpExpr
    align === nothing && return _index_wrap(v, loops)
    vs = get(align.var_shapes, v.name, nothing)
    (vs === nothing || isempty(vs) || !allunique(vs)) && return _index_wrap(v, loops)
    r = _gather_by_name(v, vs, align.axes, loops)
    r isa OpExpr && return r
    return on_foreign(v, vs, align.axes, last(r))
end

_array_shape_mismatch_text(v::VarExpr, shape, axes, s) =
    "Operand '$(v.name)' of an array-level expression is declared over " *
    "index set '$(s)' (shape $(shape)), which the result shape " *
    "$(axes) is not shaped over (esm-spec §4.3.4)"

_throw_array_shape_mismatch(v::VarExpr, shape, axes, s) = throw(
    TreeWalkError("E_TREEWALK_ARRAY_SHAPE_MISMATCH", _array_shape_mismatch_text(v, shape, axes, s))
)

"""
    _read_at_cell(leaf, node, expr; elementwise = true, inner = _is_elementwise_node) -> ASTExpr

The walk every per-cell rewrite of a whole-array expression shares. A variable
reference goes through `leaf(v, elementwise)`. An `OpExpr` goes through
`node(e)` first: a result other than `nothing` replaces it (an array producer
wrapped whole, a self-indexed node kept, a refusal thrown). Otherwise its
`args`, and only its `args`, are rewritten, each in element-wise position when
`inner(e)` says the node is element-wise over them, and the node is rebuilt
around them.

Each distinct `OpExpr` is rewritten once per position, by node identity: the
rewrite of a shared subtree depends on whether it sits in element-wise
position, and nothing else, so a structurally-shared input rewrites to a
shared output rather than an exponentially large tree.
"""
function _read_at_cell(
        leaf::L, node::N, expr::ASTExpr;
        elementwise::Bool = true, inner::I = _is_elementwise_node
    ) where {L, N, I}
    memo = (IdDict{OpExpr, ASTExpr}(), IdDict{OpExpr, ASTExpr}())
    return _read_at_cell(leaf, node, inner, expr, elementwise, memo)
end

function _read_at_cell(leaf::L, node::N, inner::I, expr::ASTExpr, elementwise::Bool, memo) where {L, N, I}
    expr isa VarExpr && return leaf(expr, elementwise)::ASTExpr
    expr isa OpExpr || return expr
    tbl = elementwise ? memo[1] : memo[2]
    hit = get(tbl, expr, nothing)
    hit === nothing || return hit
    result = node(expr)
    if result === nothing
        child = inner(expr)
        result = reconstruct(
            expr; args = ASTExpr[
                _read_at_cell(leaf, node, inner, a, child, memo) for a in expr.args
            ]
        )
    end
    tbl[expr] = result
    return result
end

"""
    _wrap_bare_array_refs(expr, arrayvars, loops; wrap_node, stop_node, align = nothing) -> ASTExpr

`expr` read at the cell `loops` names: a reference to a variable in
`arrayvars` becomes its gather ([`_index_wrap_var`](@ref)), by index-set name
in element-wise position under a usable `align` and positionally elsewhere; an
`OpExpr` for which `wrap_node` holds is gathered whole, positionally (checked
before `stop_node`); one for which `stop_node` holds is kept as it is.
"""
function _wrap_bare_array_refs(
        expr::ASTExpr, arrayvars::Set{String}, loops::Vector{String};
        wrap_node, stop_node, align::Union{Nothing, _AxisAlign} = nothing
    )::ASTExpr
    align = _usable_align(align, loops)
    leaf(v, elementwise) = v.name in arrayvars ?
        _index_wrap_var(v, loops, elementwise ? align : nothing) : v
    node(e) = wrap_node(e) ? _index_wrap(e, loops) : stop_node(e) ? e : nothing
    # Without an alignment no position reads by name, so every node is read in
    # the one position.
    inner = align === nothing ? Returns(false) : _is_elementwise_node
    return _read_at_cell(leaf, node, expr; elementwise = align !== nothing, inner = inner)
end

# Replace each reference to an ARRAY variable in `arrayvars` with its gather at
# the cell, wrap each array-producing node (`makearray`, a `faq` with output
# indices) whole, and keep each node that carries its own indexing: the
# whole-array broadcast of esm-spec §9.6.8, where `rhs = -c * D(u, x)`
# multiplies the `makearray` a discretization lowered `D(u, x)` to elementwise.
# `align` makes the variable gathers name-based (esm-spec §4.3.4).
_index_array_leaves(
    expr::ASTExpr, arrayvars::Set{String}, loops::Vector{String};
    align::Union{Nothing, _AxisAlign} = nothing
)::ASTExpr = _wrap_bare_array_refs(
    expr, arrayvars, loops;
    wrap_node = _is_array_producer, stop_node = e -> e.op in _SELF_INDEXED_OPS,
    align = align
)

# The per-cell `faq` over `loops` whose body is `body`: the wrapper of every
# lift.
_cell_faq(body::ASTExpr, loops::Vector{String}, ranges::Dict{String, Any})::OpExpr =
    OpExpr("faq", ASTExpr[]; output_idx = Any[l for l in loops], ranges = ranges, expr_body = body)

# Ranges `{"from": axes[d]}` for each loop.
_cell_ranges(loops::Vector{String}, axes::Vector{String}) =
    Dict{String, Any}(loops[d] => IndexSetRef(axes[d]) for d in eachindex(axes))

"""
    _fresh_loops(exprs, n; ctx = nothing) -> Vector{String}

The loop symbols of a lift: `_p0 … _p<n-1>`, the prefix lengthened by one `_`
until none is a name `exprs` (one expression or several) reads or binds
([`_used_names!`](@ref), template applications expanded through `ctx`). The
Rust binding makes the same choice, so the two write the same lifted equation
(esm-spec §9.6.11).
"""
function _fresh_loops(exprs, n::Integer; ctx = nothing)::Vector{String}
    used = Set{String}()
    seen = IdDict{OpExpr, Nothing}()
    for e in (exprs isa ASTExpr ? (exprs,) : exprs)
        _used_names!(used, e, ctx, seen)
    end
    prefix = "_p"
    while true
        loops = String["$(prefix)$(d)" for d in 0:(n - 1)]
        any(in(used), loops) || return loops
        prefix = "_" * prefix
    end
    return
end

"""
    _used_names!(out, e, ctx = nothing) -> out

Every name `e` reads or binds: variable references and, on every node, the
symbols it binds (`_bound_symbols`: `int_var`, range keys, `output_idx`), a
range's `of` parents, `wrt` and `dim`, through every expression-bearing field.
With a template context (`_ElementwiseContext`), an application contributes its
expansion's names. Each node is visited once. The Rust binding's `names_in`.
"""
function _used_names!(out::Set{String}, e, ctx = nothing, seen::IdDict{OpExpr, Nothing} = IdDict{OpExpr, Nothing}())
    if e isa VarExpr
        push!(out, e.name)
        return out
    end
    e isa OpExpr || return out
    haskey(seen, e) && return out
    seen[e] = nothing
    if e.op == "apply_operator" && ctx !== nothing && _ew_template(ctx, e.name) !== nothing
        # The names of the expansion, without expanding: the body's (less its
        # parameters, memoized per template) and the bindings' (esm-spec §9.6.11).
        union!(out, _ew_template_names(ctx, e.name))
        e.bindings === nothing || foreach(v -> _used_names!(out, v, ctx, seen), values(e.bindings))
        return out
    end
    union!(out, _bound_symbols(e))
    if e.ranges !== nothing
        for r in values(e.ranges)
            r isa IndexSetRef && union!(out, r.of)
        end
    end
    for f in (e.wrt, e.dim)
        f === nothing || push!(out, f)
    end
    foreach_child(c -> _used_names!(out, c, ctx, seen), e)
    return out
end

"""
    _register_synthetic_index_set!(registry, name, extent, who) -> registry

Add the interval index set `name` of size `extent` to `registry`, the flattened
`index_sets`, for an axis a lift or a promotion made that no declared index
set names. An entry already there of that size is reused; one of another size
is one the document declared, and is refused with `DimensionPromotionError`
rather than shadowed. `who` and `what` name the lift and the axis for the
message.
"""
function _register_synthetic_index_set!(
        registry::AbstractDict{String, IndexSet}, name::String, extent::Int,
        who::String, what::String
    )
    if haskey(registry, name)
        registry[name].size == extent && return registry
        throw(
            DimensionPromotionError(
                "$(who) needs the index set '$(name)' of size $(extent) for " *
                    "$(what), but the document declares '$(name)' with a different size"
            )
        )
    end
    registry[name] = IndexSet("interval"; size = extent)
    return registry
end
