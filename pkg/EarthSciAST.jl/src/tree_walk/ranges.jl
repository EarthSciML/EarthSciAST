# tree_walk/ranges.jl — integer range expansion for index ranges.

# True iff `c` holds consecutive ascending integers (`first(c):last(c)` element
# for element), without materializing either side.
_is_unit_run(c::AbstractUnitRange{<:Integer}) = true
function _is_unit_run(c)
    isempty(c) && return true
    nxt = first(c)
    for x in c
        x == nxt || return false
        nxt += 1
    end
    return true
end

# Expand a ranges entry to the concrete list of integer values.
# `r` is [lo, hi] or [lo, step, hi] (elements may be Int or Any, but must all
# be concrete integers — expression-valued bounds are not supported by the
# tree-walk evaluator).
function _expand_int_range(r::AbstractVector)
    _allof(x -> x isa Integer, r) || throw(
        TreeWalkError(
            "E_TREEWALK_DYNAMIC_RANGE",
            "expression-valued range bounds are not supported in the tree-walk " *
                "evaluator; use a structured-grid discretization, whose bounds are " *
                "concrete integers by construction"
        )
    )
    length(r) == 2 && return Int(r[1]):Int(r[2])
    length(r) == 3 && return Int(r[1]):Int(r[2]):Int(r[3])
    throw(
        TreeWalkError(
            "E_TREEWALK_RANGE_ARITY",
            "range entry must have 2 or 3 entries, got $(length(r))"
        )
    )
end

# A unit-step range as itself, any other range as its value list.
_dense_range_or_list(r::UnitRange{Int}) = r
_dense_range_or_list(r) = collect(r)

# The constant contracted ranges as value lists, for the per-cell loops that
# store them into `Vector{Int}` slots (converted once here, not once per cell).
_contract_lists(::Nothing) = nothing
_contract_lists(cc) = Union{Vector{Int}, Nothing}[
    c === nothing ? nothing : convert(Vector{Int}, c)
        for c in cc
]

# The output-index iterators of a `faq` equation, one per name: the ranges
# themselves when every one is unit-step (so a grid-sized axis is never
# materialized), the expanded value lists otherwise.
function _output_range_iters(ranges_dict, idx_names)
    rs = [_expand_int_range(ranges_dict[n]) for n in idx_names]
    all(r -> r isa UnitRange{Int}, rs) && return UnitRange{Int}[r for r in rs]
    return Vector{Int}[collect(r) for r in rs]
end

# True iff every element of a range spec is already a concrete Integer — i.e.
# the range can be expanded once, globally, with `_expand_int_range` (the
# constant-bound fast path used by structured grids and the Route-B padded
# unstructured form).
_is_const_int_range(r::AbstractVector) = _allof(x -> x isa Integer, r)

# Expand a ranges entry whose bounds may be *expression-valued* (e.g. a
# per-cell reduction bound `index(n_edges_on_cell, i) - 1`).  Each non-Integer
# element is evaluated to a concrete Int via `_eval_const_int` under the current
# output-cell binding `idx_env` and the model's `const_arrays` — exactly the
# primitive already used to resolve indirect neighbour gathers.  This realizes a
# variable-valence / ragged segment reduction with NO host-side padding: the
# upper bound is each cell's true valence, evaluated lazily per output cell.
# Integer elements pass through unchanged, so a fully-constant range gives the
# same result as `_expand_int_range` (backward compatible).
function _expand_int_range_dyn(
        r::AbstractVector, idx_env::Dict{String, Int},
        const_arrays::AbstractDict
    )
    bnd(x) = x isa Integer ? Int(x) : _eval_const_int(x, idx_env, const_arrays)
    length(r) == 2 && return bnd(r[1]):bnd(r[2])
    length(r) == 3 && return bnd(r[1]):bnd(r[2]):bnd(r[3])
    throw(
        TreeWalkError(
            "E_TREEWALK_RANGE_ARITY",
            "range entry must have 2 or 3 entries, got $(length(r))"
        )
    )
end
