# tree_walk/bounded_const_array.jl — a const array's per-axis boundary policy (`BoundedConstArray`).

# ---- Const-array boundary policy ----
# A const array (Fornberg weights, mesh connectivity, a per-cell metric factor)
# may carry a per-dimension boundary policy so that a stencil gather at an
# out-of-range index resolves declaratively instead of erroring. This mirrors the
# state-variable gather, which honors grid periodicity (periodic-wrap) and applies
# a finite boundary policy at non-periodic edges. The covariant-FV connection
# terms gather metric factors at lat±1 / lon±1 offsets; on a lon-periodic metric
# those must WRAP, and at a non-periodic lat pole they must edge-extend — the
# zero-ghost convention is physically wrong for a metric.
#
# Per-dimension policy symbols:
#   :periodic — wrap the index into 1..N via mod1; correct for a periodic axis.
#   :clamp    — edge-extend (clamp to 1..N); the correct finite policy for a
#               metric/geometry factor at a non-periodic boundary.
#   :error    — throw E_TREEWALK_CONSTARRAY_OOB (default for any array WITHOUT a
#               declared policy, so genuine out-of-bounds bugs in connectivity /
#               stencil-weight factors are never masked).
const _CONST_BOUNDARY_KINDS = (:periodic, :clamp, :error)

# A const array tagged with a per-dimension boundary policy. It IS an
# `AbstractArray{Float64,N}` (forwards size/getindex to `data`), so it flows
# through the existing `const_arrays` threading transparently; only the gather's
# out-of-range handling branches on the wrapper via `_const_dim_boundary`.
struct BoundedConstArray{N} <: AbstractArray{Float64, N}
    data::Array{Float64, N}
    boundary::NTuple{N, Symbol}   # per-dim: :periodic | :clamp | :error
end
Base.size(a::BoundedConstArray) = size(a.data)
Base.IndexStyle(::Type{<:BoundedConstArray}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(a::BoundedConstArray, i::Int) = a.data[i]

# Per-dimension boundary policy: declared dims for a BoundedConstArray, :error
# (throw on OOB) for any plain const array.
_const_dim_boundary(a::BoundedConstArray, d::Int) = a.boundary[d]
_const_dim_boundary(::AbstractArray, ::Int) = :error

# Resolve a possibly-out-of-range 1-based index `i` in dimension `d` (size `n`) of
# const array `name` per its boundary policy. In-range indices pass through.
function _resolve_const_index(
        arr::AbstractArray, name::AbstractString,
        d::Int, i::Int, n::Int
    )
    (1 <= i <= n) && return i
    return _resolve_const_index_oob(_const_dim_boundary(arr, d), name, d, i, n)
end

# The out-of-range half of `_resolve_const_index`, for a caller that holds the
# dimension's policy symbol rather than the array (the run-time `_NK_CONST_GATHER`
# arm, `_const_gather_sub`).
@noinline function _resolve_const_index_oob(
        pol::Symbol, name::AbstractString,
        d::Int, i::Int, n::Int
    )
    if n >= 1
        pol === :periodic && return mod1(i, n)
        pol === :clamp && return clamp(i, 1, n)
    end
    # A live forcing buffer read at a run-time subscript (`_live_gather_node`):
    # the error its build-time read raises at a constant subscript.
    pol === :live && throw(
        TreeWalkError(
            "E_TREEWALK_PGATHER_OOB",
            "forcing array '$(name)' index $(i) out of range [1, $(n)] on dim $(d)"
        )
    )
    # Positional gather checks reuse this IR without making the computed
    # expression result a const array or applying its boundary policy.
    pol === :computed && throw(
        TreeWalkError(
            "E_TREEWALK_SHAPE_OP",
            "$(name) subscript $(i) is out of range 1:$(n) on axis $(d)"
        )
    )
    throw(
        TreeWalkError(
            "E_TREEWALK_CONSTARRAY_OOB",
            "const array '$(name)' index $(i) out of range 1..$(n) in dim $(d)"
        )
    )
end

# Wrap a const array with a declared per-dimension boundary policy. `boundary` is
# an iterable of per-dim policy symbols (or strings); its length must equal the
# array rank and each entry must be one of `_CONST_BOUNDARY_KINDS`.
function _wrap_bounded_const(arr::Array{Float64, N}, boundary, name::AbstractString) where {N}
    syms = Symbol[Symbol(b) for b in boundary]
    length(syms) == N ||
        throw(
        TreeWalkError(
            "E_TREEWALK_CONSTARRAY_BOUNDARY_NDIM",
            "const array '$(name)' boundary has $(length(syms)) dims but array is $(N)D"
        )
    )
    for s in syms
        s in _CONST_BOUNDARY_KINDS ||
            throw(
            TreeWalkError(
                "E_TREEWALK_CONSTARRAY_BOUNDARY_KIND",
                "const array '$(name)' boundary '$(s)' must be one of $(_CONST_BOUNDARY_KINDS)"
            )
        )
    end
    return BoundedConstArray{N}(arr, NTuple{N, Symbol}(syms))
end
