# tree_walk/obs_buffers.jl — run-time types of a build's right-hand side: the discrete refill
# and the two-buffer observed slot space (`_ObsSplitVec`, `_ObsExtVec`).

# The right-hand side's check that the discrete caches hold its own `p` and the
# forcing they were filled from, and the refill when they do not. The `p`
# compare is the const tier's (`_pstamp_same`, cadence_stamp.jl): a same-`p`
# call is a compare and never allocates. The forcing compare is the time
# tier's: the build's forcing epoch (cadence_stamp.jl) moves on every write to
# a buffer the build reads that is announced to the build's owner
# (`notify_forcing_refresh!`, which the refresh callback calls), and the caches
# are stale when it has moved since their last fill. (The refresh
# callback refills them itself, through its `post_refresh` hook, so the call
# after it finds them current.) A `p` of another type than the build's — dual
# numbers, for a derivative with respect to parameters — leaves the caches at
# their `p`: they hold Float64 values and cannot carry a derivative; a moved
# epoch still refills them, with that `p`. `DiscreteMaterializer.refresh!` is
# that second method, for a reader that has no `p` of its own.
#
# The refill writes the caches in place from inside `f!`. That makes it no less
# safe to share across threads than the rest of `f!`, which writes the build's
# prelude scratch and observed buffers on every call: one build's `f!` must not
# be called concurrently.
struct _DiscreteRefill{P, F}
    stamp::Base.RefValue{Any}
    materialize!::F
    epoch::_ForcingEpoch
    filled_epoch::Base.RefValue{UInt64}
end
@inline _discrete_forcing_current(g::_DiscreteRefill) =
    g.filled_epoch[] === _epoch_value(g.epoch)
@inline function (g::_DiscreteRefill{P})(p::P) where {P}
    (_pstamp_same(g.stamp[], p) && _discrete_forcing_current(g)) || g.materialize!(p)
    return nothing
end
@inline function (g::_DiscreteRefill)(p)
    _discrete_forcing_current(g) || g.materialize!()
    return nothing
end

# ============================================================
# 2b-f. Factored array-observed buffers (per-RHS-call materialization)
# ============================================================
#
# The runtime half of `_collect_materialized_array_obs`. Each materialized array
# observed owns a dense block of slots above the ODE state in ONE extended slot
# space; `f!` fills the observed blocks in dependency order and then runs the
# ordinary state RHS against that space. Since the reads compiled to plain state
# gathers, nothing downstream (the affine box processor, the kernel-class merge,
# the codegen tier, the cadence classifier) needed to learn a new leaf.
#
# The slot space is TWO buffers (`_ObsSplitVec`): slots `1:n_states` are the
# integrator's own `u` (and, for writes, its `du`), the slots above are the
# observed buffer. So nothing copies the state per call. The generated kernels
# pick the buffer per access at build time (`_cg_bufS` / `_cg_oview`, codegen
# tier); every other reader goes through the view's own indexing.

# One extended slot space over two buffers: slot `i <= n` is `u[i]`, slot
# `i > n` is `o[i - n]`, for reads and writes alike. The element type is the
# observed buffer's, the value type of the call.
struct _ObsSplitVec{T, U, O} <: AbstractVector{T}
    u::U
    o::O
    n::Int
end
_ObsSplitVec(u, o::AbstractVector{T}, n::Int) where {T} =
    _ObsSplitVec{T, typeof(u), typeof(o)}(u, o, n)
Base.size(s::_ObsSplitVec) = (s.n + length(s.o),)
Base.IndexStyle(::Type{<:_ObsSplitVec}) = IndexLinear()
@inline function Base.getindex(s::_ObsSplitVec, i::Int)
    @boundscheck checkbounds(s, i)
    n = s.n
    return @inbounds(i <= n ? s.u[i] : s.o[i - n])
end
@inline function Base.setindex!(s::_ObsSplitVec, v, i::Int)
    @boundscheck checkbounds(s, i)
    n = s.n
    @inbounds(i <= n ? (s.u[i] = v) : (s.o[i - n] = v))
    return s
end
# One half of the view, when slots `lo:hi` all fall in it (scan.jl).
function _scan_dense(du::_ObsSplitVec, lo::Int, hi::Int)
    lo > du.n && return (du.o, du.n)
    hi <= du.n && return (du.u, 0)
    return (du, 0)
end

# The observed buffers. Two of them — Float64 plus a lazily-allocated `alt`
# for the value type an AD-driven `f!` is called at — exactly like `_CSECache` /
# `_AccScratch`, so the RHS stays zero-alloc at Float64 AND differentiable.
# Allocated ONCE at build and reused across every RHS call. `ustash` holds a
# converted copy of a `u` that is not a `Vector` of the call's value type (a
# Float64 state under `Dual` parameters, a wrapped array); a `Vector{T}` state
# is read in place.
#
# Each buffer carries the cadence stamps of the prelude (`_CSECache`): `stamp64` /
# `stampalt` the `p` its const-cadence observeds were filled for, and
# `tp*`/`tt*`/`te*` the `(p, t, forcing epoch)` its time-cadence observeds were
# filled for (`_pstamp`, cadence_stamp.jl), and `fp*`/`fe*` the `(p, forcing
# epoch)` its forcing-cadence observeds were filled for. A freshly allocated
# `alt` holds no valid block, so allocating one invalidates all of its stamps.
mutable struct _ObsExtVec
    f64::Vector{Float64}
    alt::Any
    stamp64::Any
    stampalt::Any
    tp64::Any
    tt64::Float64
    te64::UInt64
    tpalt::Any
    ttalt::Any
    tealt::UInt64
    epoch::_ForcingEpoch
    ustash::Any
    fp64::Any
    fe64::UInt64
    fpalt::Any
    fealt::UInt64
end
_ObsExtVec(n::Int, epoch::_ForcingEpoch = _new_forcing_epoch()) =
    _ObsExtVec(
    _zeros_f64(n), nothing, _CSE_INVALID, _CSE_INVALID,
    _CSE_INVALID, NaN, UInt64(0), _CSE_INVALID, _CSE_INVALID, UInt64(0),
    epoch, nothing, _CSE_INVALID, UInt64(0), _CSE_INVALID, UInt64(0)
)
# The state part of the call's slot space: `u` itself when it is a `Vector{T}`,
# else `u` converted into the stash, as the copy into one extended vector did.
@inline _obsext_state(s::_ObsExtVec, u::Vector{T}, ::Type{T}) where {T} = u
@inline function _obsext_state(s::_ObsExtVec, u, ::Type{T}) where {T}
    b = s.ustash
    if !(b isa Vector{T} && length(b) == length(u))
        b = Vector{T}(undef, length(u))
        s.ustash = b
    end
    copyto!(b, u)
    return b::Vector{T}
end
@inline _obsext_buf(s::_ObsExtVec, ::Type{Float64}) = s.f64
@inline function _obsext_buf(s::_ObsExtVec, ::Type{T}) where {T}
    b = s.alt
    b isa Vector{T} && return b
    nb = zeros(T, length(s.f64))
    s.alt = nb
    s.stampalt = _CSE_INVALID
    s.tpalt = _CSE_INVALID
    s.fpalt = _CSE_INVALID
    return nb
end
@inline _obsext_const_stale(s::_ObsExtVec, ::Type{Float64}, p) =
    !_pstamp_same(s.stamp64, p)
@inline _obsext_const_stale(s::_ObsExtVec, ::Type{T}, p) where {T} =
    !_pstamp_same(s.stampalt, p)
@inline function _obsext_mark_const!(s::_ObsExtVec, ::Type{Float64}, p)
    s.stamp64 = _pstamp_reuse(s.stamp64, p)
    return nothing
end
@inline function _obsext_mark_const!(s::_ObsExtVec, ::Type{T}, p) where {T}
    s.stampalt = _pstamp_reuse(s.stampalt, p)
    return nothing
end
# The forcing tier's test and mark: the time tier's (below) without `t`.
@inline _obsext_forcing_stale(s::_ObsExtVec, ::Type{Float64}, p) =
    !(s.fe64 === _epoch_value(s.epoch) && _pstamp_same(s.fp64, p))
@inline _obsext_forcing_stale(s::_ObsExtVec, ::Type{T}, p) where {T} =
    !(s.fealt === _epoch_value(s.epoch) && _pstamp_same(s.fpalt, p))
@inline function _obsext_mark_forcing!(s::_ObsExtVec, ::Type{Float64}, p)
    _pstamp_same(s.fp64, p) || (s.fp64 = _pstamp_reuse(s.fp64, p))
    s.fe64 = _epoch_value(s.epoch)
    return nothing
end
@inline function _obsext_mark_forcing!(s::_ObsExtVec, ::Type{T}, p) where {T}
    _pstamp_same(s.fpalt, p) || (s.fpalt = _pstamp_reuse(s.fpalt, p))
    s.fealt = _epoch_value(s.epoch)
    return nothing
end

# The time tier's test and mark, with `_cse_t_stale` / `_cse_mark_t!`'s rules:
# `t` by egal (the Float64 buffer stamps only a Float64 `t`, the other only an
# isbits one), `p` by `_pstamp_same`, and the build's forcing epoch.
@inline _obsext_t_stale(s::_ObsExtVec, ::Type{Float64}, p, t) =
    !(t === s.tt64 && s.te64 === _epoch_value(s.epoch) && _pstamp_same(s.tp64, p))
@inline _obsext_t_stale(s::_ObsExtVec, ::Type{T}, p, t) where {T} =
    !(s.ttalt === t && s.tealt === _epoch_value(s.epoch) && _pstamp_same(s.tpalt, p))
@inline function _obsext_mark_t!(s::_ObsExtVec, ::Type{Float64}, p, t)
    if t isa Float64
        _pstamp_same(s.tp64, p) || (s.tp64 = _pstamp_reuse(s.tp64, p))
        s.tt64 = t
        s.te64 = _epoch_value(s.epoch)
    else
        s.tp64 === _CSE_INVALID || (s.tp64 = _CSE_INVALID)
    end
    return nothing
end
@inline function _obsext_mark_t!(s::_ObsExtVec, ::Type{T}, p, t) where {T}
    if isbits(t)
        _pstamp_same(s.tpalt, p) || (s.tpalt = _pstamp_reuse(s.tpalt, p))
        s.ttalt === t || (s.ttalt = t)
        s.tealt = _epoch_value(s.epoch)
    else
        s.tpalt === _CSE_INVALID || (s.tpalt = _CSE_INVALID)
    end
    return nothing
end
