# tree_walk/build_helpers.jl — small build-time utilities: lockstep site
# translation, the claimed-slot set `_Covered`, the shared read-only `_EMPTY_*`
# sentinels, two operator accessors and `_dependency_order`.

# ─────────────────────────────────────────────────────────────────────────────
# Build-work counts (RFC out-of-line-expression-templates §12), through the
# engagement sink (`_count!`, compiler.jl): `:compile_calls` for each object
# `_compile` lowers, `:branch_templates` for each `_build_branch_template`
# call, and `:body_variants` for each compile-once template-body variant (one
# per use site and region class). A benchmark or a test that asserts build work
# does not grow with the grid reads them from `Internal.build`'s report.

# ─────────────────────────────────────────────────────────────────────────────
# THE SLOTS AN EQUATION BUILD HAS CLAIMED (`_compile_derivative_equations`'s
# duplicate-derivative check). Single slots go in a bit set over the slot space,
# made on the first such claim; a box whose slots are one contiguous run is
# claimed as that range, so claiming it costs the same at any size and a build
# that claims only such boxes (a materialized observed's fill) never makes the
# bit set at all.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct _Covered
    n::Int
    bits::BitVector                  # empty until the first single-slot claim
    runs::Vector{UnitRange{Int}}     # disjoint claimed runs, sorted
end
_Covered(n::Int) = _Covered(n, BitVector(), UnitRange{Int}[])

_cover_bits!(c::_Covered) =
    (length(c.bits) == c.n || (c.bits = falses(c.n)); c.bits)

# Whether a claimed run meets `lo:hi`: the runs are disjoint and sorted, so the
# last one starting at or before `hi` is the only candidate.
function _runs_meet(c::_Covered, lo::Int, hi::Int)
    k = searchsortedlast(c.runs, hi; by = r -> r isa Int ? r : first(r))
    return k >= 1 && last(c.runs[k]) >= lo
end

function Base.getindex(c::_Covered, i::Int)
    1 <= i <= c.n || throw(BoundsError(c, i))
    length(c.bits) == c.n && @inbounds(c.bits[i]) && return true
    return _runs_meet(c, i, i)
end

function Base.setindex!(c::_Covered, v::Bool, i::Int)
    1 <= i <= c.n || throw(BoundsError(c, i))
    (v || length(c.bits) == c.n) && (_cover_bits!(c)[i] = v)
    return c
end

# Release single-slot claims (a tier that claimed `outs` and then declined).
function _uncover!(c::_Covered, outs)
    length(c.bits) == c.n || return c
    for i in outs
        c.bits[i] = false
    end
    return c
end

# Whether any slot of `lo:hi` is claimed.
function _cover_any(c::_Covered, lo::Int, hi::Int)
    lo > hi && return false
    (1 <= lo && hi <= c.n) || throw(BoundsError(c, lo:hi))
    length(c.bits) == c.n && _bits_any(c.bits, lo, hi) && return true
    return _runs_meet(c, lo, hi)
end

# Claim `lo:hi`, as bits (`run = false`) or as one range.
function _cover_fill!(c::_Covered, lo::Int, hi::Int; run::Bool = false)
    lo > hi && return c
    (1 <= lo && hi <= c.n) || throw(BoundsError(c, lo:hi))
    if run
        insert!(
            c.runs, searchsortedlast(c.runs, lo; by = r -> r isa Int ? r : first(r)) + 1,
            lo:hi
        )
    else
        fill!(view(_cover_bits!(c), lo:hi), true)
    end
    return c
end

# ─────────────────────────────────────────────────────────────────────────────
# SHARED READ-ONLY `_EMPTY_*` SENTINELS — invariant: NEVER MUTATED.
#
# The `_EMPTY_*` constants scattered through this evaluator
# (`_EMPTY_DERIVED_EXTENTS`, `_EMPTY_IDX_ENV`, `_EMPTY_VI_MAPS`,
# `_EMPTY_FACTOR_SCOPE`, `_EMPTY_CONST_ARRAYS`, `_EMPTY_PARAMS`,
# `_EMPTY_PGATHER`) are single shared MUTABLE Dicts used as "no entries"
# default arguments so hot build paths don't allocate a fresh empty Dict per
# call. They are read-only BY CONVENTION ONLY (Julia has no frozen Dict, and
# switching to a distinct immutable type would perturb the type-stable
# hot-path signatures): every consumer may only `haskey`/`get`/iterate them,
# never `setindex!`/`push!`/`merge!` into one. Writing to a sentinel would
# silently leak state into every later build in the process. Code paths that
# need a mutable dict must branch to a fresh instance (see e.g. the
# `derived_extents` selection in `_build_evaluator_impl`). The invariant is
# pinned by a test that asserts each sentinel is still empty after a full
# build+evaluate cycle (tree_walk_op_table_test.jl).
# ─────────────────────────────────────────────────────────────────────────────
const _EMPTY_DERIVED_EXTENTS = Dict{String, Int}()

# Shared read-only empty loop-variable environment (see the `_EMPTY_*` sentinel
# block above). `_eval_const_int` only ever
# reads its `idx_env` (haskey / getindex, never assigns), so index args that
# carry no unresolved loop variable — the common per-cell gather case, where the
# outer loop vars are already substituted to literals — can pass this single
# instance instead of allocating a fresh `Dict{String,Int}()` per index arg. In
# a stencil RHS that is a handful of freshly-GC'd dicts per neighbour gather per
# cell removed from the build-time allocation load.
const _EMPTY_IDX_ENV = Dict{String, Int}()

# An explicit empty shape (`[]`, a rank-0 declaration) is scalar, not an array;
# only a non-empty declared shape marks an array variable. `nothing` (no shape) is
# also scalar.
_is_array_shape(shape) = shape !== nothing && !isempty(shape)

# ---- Aggregate-node field accessors -------------------------------------------
# The `output_idx` / `ranges` fields of a faq/makearray node are
# optional on the wire (`nothing` when absent), and `output_idx` may carry
# non-string entries that every consumer skips. These accessors are the single
# spelling of "the string output indices" and "a ranges table" (formerly
# duplicated across the build/resolve expansion and cell-discovery sites).
_output_idx_strings(op::OpExpr) = op.output_idx === nothing ? String[] :
    String[String(s) for s in op.output_idx if s isa AbstractString]
_ranges_dict(op::OpExpr) = op.ranges === nothing ? Dict{String, Any}() : op.ranges

# ---- Kahn-style dependency ordering (shared ready-set loop) ---------------------
# Order `names` so every name comes after the names it depends on. `deps(name)`
# returns the subset of `names` that must precede it (recomputed per pass — cheap
# at build time and keeps the callers' original shape); `on_cycle(done)` MUST
# throw (each call site owns its error code/message) and is called when a full
# pass over the remaining names makes no progress, i.e. the residue is cyclic.
# Within a pass the scan follows the iteration order of `names`, so the result
# is deterministic for a given input collection.
function _dependency_order(names, deps::F; on_cycle::G) where {F, G}
    order = String[]
    done = Set{String}()
    total = length(names)
    while length(order) < total
        progressed = false
        for n in names
            n in done && continue
            if all(d -> d in done, deps(n))
                push!(order, n)
                push!(done, n)
                progressed = true
            end
        end
        progressed || on_cycle(done)
    end
    return order
end

# True iff `e` is a `const`-op node (build-time literal data — a vertex ring
# array, a source field). Its value lives in `e.value`, not `e.args`.
_is_const_op(e) = e isa OpExpr && (e::OpExpr).op == "const"

# Probe the extents of a rectangular nested-vector const without allocating its cells.
function _const_op_dims(val)::Vector{Int}
    dims = Int[]
    node = val
    while !(node isa Number)
        n = length(node)
        push!(dims, n)
        n == 0 && break
        node = first(node)
    end
    return dims
end

# Convert a const literal to Julia's column-major layout with one axis per
# level of its nested value.
function _const_op_to_array(val)::Array{Float64}
    dims = _const_op_dims(val)
    A = Array{Float64}(undef, dims...)
    _fill_const_dense!(A, val, dims) || _fill_const_array!(A, val, ())
    return A
end

# The fill for a value whose every level is a list of exactly the probed
# extent with numbers at the bottom (every well-formed inline array): each
# element goes straight to its column-major offset. Returns `false` on any
# other shape, and the caller redoes the fill with `_fill_const_array!`.
function _fill_const_dense!(A::Array{Float64}, val, dims::Vector{Int})
    (isempty(dims) || any(==(0), dims)) && return false
    strides = Vector{Int}(undef, length(dims))
    s = 1
    for d in eachindex(dims)
        strides[d] = s
        s *= dims[d]
    end
    return _fill_const_level!(vec(A), val, 1, 1, dims, strides)
end

_fill_const_level!(
    A::Vector{Float64}, node, depth::Int, off::Int, dims::Vector{Int},
    strides::Vector{Int}
)::Bool =
    node isa Vector{Any} ? _fill_const_level_vec!(A, node, depth, off, dims, strides) :
    node isa AbstractVector ? _fill_const_level_vec!(A, node, depth, off, dims, strides) : false

function _fill_const_level_vec!(
        A::Vector{Float64}, node::AbstractVector, depth::Int, off::Int,
        dims::Vector{Int}, strides::Vector{Int}
    )::Bool
    n = length(node)
    n == dims[depth] || return false
    s = strides[depth]
    if depth == length(dims)
        for k in 1:n
            x = node[k]
            v = x isa Int64 ? Float64(x) : x isa Float64 ? x :
                x isa Number ? Float64(x)::Float64 : return false
            @inbounds A[off + (k - 1) * s] = v
        end
    else
        for k in 1:n
            sub = node[k]
            o = off + (k - 1) * s
            # The common nested `Vector{Any}` row takes a static call.
            (
                sub isa Vector{Any} ? _fill_const_level_vec!(A, sub, depth + 1, o, dims, strides) :
                    _fill_const_level!(A, sub, depth + 1, o, dims, strides)
            ) ||
                return false
        end
    end
    return true
end

function _fill_const_array!(A, node, idx::Tuple)
    if node isa Number
        A[idx...] = Float64(node)
        return
    end
    for (k, sub) in enumerate(node)
        _fill_const_array!(A, sub, (idx..., k))
    end
    return
end
