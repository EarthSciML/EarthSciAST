# tree_walk/resolve_ctx.jl — what an index resolution reads besides the expression:
# the `_ResolveCtx`, the live forcing buffer type `_PGatherArray`, and the
# read-only empty defaults.

# The `ifelse` / `and` / `or` guards the node being resolved sits under: each
# guard's resolved condition and the truth value its branch needs (see
# `_resolve_guarded_op`).
const _ResolveGuards = Vector{Tuple{ASTExpr, Bool}}

"""
    _ResolveCtx

What one index resolution reads besides the expression: each array's cell
bounds (`array_var_info`), the slot layout (`var_map`), the build-time arrays
(`const_arrays`), the live forcing buffers (`pgather`), the build memo (`memo`,
`nothing` for a resolve that must not share the concrete build's), the index
names kept symbolic (`bound`), whether a scalar reduction nested in the term
stays a loop (`nest_loops`, the whole-array nest's own resolve), and the guards
the node sits under (`guards`, shared by every context derived from one
resolve).
"""
struct _ResolveCtx{L <: AbstractDict{String, Int}, C <: AbstractDict, G <: AbstractDict}
    array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}}
    var_map::L
    const_arrays::C
    pgather::G
    memo::_MaybeMemo
    bound::Set{String}
    nest_loops::Bool
    guards::_ResolveGuards
end

# `rc` with some of its fields replaced; the guards stay shared.
_derive(
    rc::_ResolveCtx; memo::_MaybeMemo = rc.memo, bound::Set{String} = rc.bound,
    nest_loops::Bool = rc.nest_loops, const_arrays::AbstractDict = rc.const_arrays
) = _ResolveCtx(
    rc.array_var_info, rc.var_map, const_arrays, rc.pgather, memo, bound, nest_loops, rc.guards
)

# A context starting a resolve with no names bound and no guards in force.
_ResolveCtx(
    array_var_info::Dict{String, Tuple{Vector{Int}, Vector{Int}}},
    var_map::AbstractDict{String, Int},
    const_arrays::AbstractDict = _EMPTY_CONST_ARRAYS,
    pgather::AbstractDict = _EMPTY_PGATHER,
    memo::_MaybeMemo = nothing
) = _ResolveCtx(
    array_var_info, var_map, const_arrays, pgather, memo, _EMPTY_BOUND_SYMS, false, _ResolveGuards()
)

# Whether the resolve keeps some index symbolic: a compile-once or loop path.
_is_symbolic(rc::_ResolveCtx) = rc.nest_loops || !isempty(rc.bound)

# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_CONST_ARRAYS = Dict{String, AbstractArray{Float64}}()

# Empty scalar-parameter scope for a build-time cellwise evaluation with no
# parameters bound (the common case). Shared so `_eval_cellwise` /
# `evaluate_cellwise` avoid allocating a fresh dict per call on the no-param
# path. Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_PARAMS = Dict{String, Float64}()

# A live forcing buffer bound by reference into the evaluator.
# Unlike `const_arrays` (build-time-FROZEN: `index(arr,…)` const-folds to a
# `NumExpr` literal, tree_walk.jl const-array branch), a `_PGatherArray` reroutes
# the SAME `index(forcing,…)` gather to a LIVE read of a captured `flat`
# `Vector{Float64}`. `flat = vec(buffer)` aliases the caller's dense
# `Array{Float64}` buffer, so a discrete refresh callback's in-place `buffer .= …`
# shows through to the RHS with zero reallocation. `dims` carries
# the source shape for bounds-checking + column-major linearization at build time.
# Reading the captured `flat` (NOT `getfield(p, runtime_sym)`) is what keeps the
# read zero-alloc: a runtime-symbol `getfield` on a heterogeneous NamedTuple boxes
# the union and would also regress the scalar `_NK_PARAM` path.
struct _PGatherArray
    flat::Vector{Float64}   # aliased flat view of the caller's buffer (live, by-ref)
    dims::Vector{Int}       # original shape — bounds-check + linearize at build time
    # A cache the build owns (a discrete-cadence var's, `_build_discrete_materializer!`)
    # rather than a forcing buffer the caller or a provider supplied.
    cache::Bool
    _PGatherArray(flat, dims, cache) = _new_typed(_PGatherArray, flat, dims, cache)
end
_def_new_typed(_PGatherArray)
_PGatherArray(flat, dims) = _PGatherArray(flat, dims, false)
# Read-only sentinel — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_PGATHER = Dict{String, _PGatherArray}()

# The set of index symbol names kept SYMBOLIC through `_resolve_indices`: the
# compile-once cellwise path's output indices, and the loop indices of a
# contraction loop, a ragged loop, the whole-array nest and the scatter. A
# const-array read whose subscript names one becomes a runtime
# `_ConstGatherRef` rather than a folded `NumExpr`; so does one whose subscript
# reads a parameter, a state or `t` (`_subscript_is_runtime`), whatever the
# set holds. The default threaded through the resolve recursion is this shared
# read-only empty set — see the `_EMPTY_*` invariant block next to
# `_EMPTY_DERIVED_EXTENTS`.
const _EMPTY_BOUND_SYMS = Set{String}()
