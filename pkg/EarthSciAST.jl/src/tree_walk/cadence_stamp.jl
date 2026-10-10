# ========================================================================
# tree_walk/cadence_stamp.jl — what a cadence tier remembers about `p` and
# about the live forcing data.
#
# A value that depends only on the parameters (the const tier) stays good
# while `p` is unchanged; one that also depends on `t` and on live forcing
# buffers (the time tier) stays good while `p`, `t` and the build's forcing
# epoch are unchanged. Every such tier — the scalar prelude's const and time
# slots, the discrete-cadence caches, the materialized array observeds —
# stamps what it was computed for with the helpers below.
# ========================================================================

# ---- Parameter stamps ---------------------------------------------------------
#
# `_pstamp(p)` is what a tier stores for the `p` it was computed with, and
# `_pstamp_same(s, p)` whether a stored stamp still describes `p`.
#
# For an `isbits` `p` (a NamedTuple of scalars, `nothing`) the stamp is `p`
# itself and the test is egal (`===`): a bit compare, strictly finer than `==`
# (it separates `0.0` from `-0.0` and matches identical `NaN` bit patterns), so
# two egal `p`s produce bit-identical values. `typeof(p)` is a compile-time
# constant at every call site, so that branch folds away.
#
# A `p` that is not `isbits` (a NamedTuple holding an array, a ComponentVector,
# a plain `Vector{Float64}`) can be mutated in place behind an unchanged object
# identity, so egal would miss a change. Its stamp is a deep copy, taken only
# when the tier refills, and the test compares contents element by element
# with the same egal rule. A `p` holding anything else (a Dict, a mutable
# struct, a function closure over mutable state), or holding more than
# `_PSTAMP_MAX_ELEMS` numbers, cannot be compared cheaply and safely; its
# stamp is `_CSE_INVALID`, which no `p` matches, so the tier refills on every
# call (never a stale value).

const _PSTAMP_MAX_ELEMS = 1 << 16

@inline _pstamp(p) = isbits(p) ? p : _pstamp_snapshot(p)

function _pstamp_snapshot(p)
    n = Ref(0)
    _pstamp_comparable(p, n) || return _CSE_INVALID
    return deepcopy(p)
end

_pstamp_comparable(x, n::Base.RefValue{Int}) = isbits(x)
_pstamp_comparable(x::Union{Tuple,NamedTuple}, n::Base.RefValue{Int}) =
    all(y -> _pstamp_comparable(y, n), values(x))
function _pstamp_comparable(x::AbstractArray, n::Base.RefValue{Int})
    n[] += length(x)
    n[] <= _PSTAMP_MAX_ELEMS || return false
    isbitstype(eltype(x)) && return true
    for i in eachindex(x)
        isassigned(x, i) || return false
        _pstamp_comparable(x[i], n) || return false
    end
    return true
end

@inline _pstamp_same(s, p) =
    isbits(p) ? s === p : (s isa typeof(p) && _pcontent_same(s, p))

_pcontent_same(a, b) = a === b
_pcontent_same(::Tuple{}, ::Tuple{}) = true
@inline _pcontent_same(a::Tuple, b::Tuple) =
    _pcontent_same(first(a), first(b)) && _pcontent_same(Base.tail(a), Base.tail(b))
@inline _pcontent_same(a::NamedTuple{N}, b::NamedTuple{N}) where {N} =
    _pcontent_same(Tuple(a), Tuple(b))
function _pcontent_same(a::AbstractArray, b::AbstractArray)
    (typeof(a) === typeof(b) && axes(a) == axes(b)) || return false
    @inbounds for i in eachindex(a)
        _pcontent_same(a[i], b[i]) || return false
    end
    return true
end

# ---- The forcing epoch --------------------------------------------------------
#
# A time-tier value may gather a LIVE forcing buffer (a `param_arrays` buffer or
# a discrete-cadence cache) whose CONTENTS are refreshed in place while `p` and
# `t` stand still (a refresh callback fires AT its tstop, so the first RHS call
# after it is at the same `t` as the calls before it). A `(p, t)` stamp cannot
# see that, so every in-place refresh bumps an epoch the time tiers compare.
#
# The epoch is per BUILD: each build owns a counter (`_ForcingEpoch`), and a
# refresh bumps the counters of exactly the builds that read the buffer it
# wrote. A build registers its `param_arrays` buffers at build time
# (`_register_forcing_buffers!`), keyed by their data pointer so that a write
# through the caller's N-d array and a read through its `vec` meet; the
# discrete-cadence materializer bumps its own build's counter directly. A
# refresh in one problem therefore leaves every other problem's memoized values
# alone.
#
# `_FORCING_EPOCH` is the process-wide part every build's epoch also includes:
# `notify_forcing_refresh!()` with no argument bumps it, for a caller who wrote a
# buffer directly and does not say which.

const _FORCING_EPOCH = Ref{UInt64}(0)

const _ForcingEpoch = Base.RefValue{UInt64}
_new_forcing_epoch() = _ForcingEpoch(UInt64(0))

# The epoch a time tier stamps and compares: the build's own count plus the
# process-wide one. Both only grow, so any bump of either moves the sum.
@inline _epoch_value(e::_ForcingEpoch) = e[] + _FORCING_EPOCH[]

@inline _bump_epoch!(e::_ForcingEpoch) = (e[] += UInt64(1); nothing)

# Data pointer => the builds reading that buffer: a weak reference to the
# registered array (so a recycled address is told apart from the buffer it
# once was) and a weak reference to each build's epoch.
const _BUFFER_EPOCHS = Dict{UInt,Vector{Tuple{WeakRef,WeakRef}}}()
const _BUFFER_EPOCHS_LOCK = ReentrantLock()

_buffer_key(buf::AbstractArray) = UInt(pointer(buf))

function _register_forcing_buffers!(epoch::_ForcingEpoch, buffers)
    isempty(buffers) && return nothing
    lock(_BUFFER_EPOCHS_LOCK) do
        for buf in buffers
            buf isa DenseArray || continue
            k = _buffer_key(buf)
            regs = get!(Vector{Tuple{WeakRef,WeakRef}}, _BUFFER_EPOCHS, k)
            filter!(r -> r[1].value !== nothing && r[2].value !== nothing, regs)
            push!(regs, (WeakRef(buf), WeakRef(epoch)))
        end
    end
    return nothing
end

# Bump the epoch of every build that reads `buf`. A buffer no build registered
# (a caller's own array) bumps nothing.
function _bump_buffer_epochs!(buf::AbstractArray)
    buf isa DenseArray || return _bump_global_epoch!()
    k = _buffer_key(buf)
    lock(_BUFFER_EPOCHS_LOCK) do
        regs = get(_BUFFER_EPOCHS, k, nothing)
        regs === nothing && return nothing
        for (wb, we) in regs
            b = wb.value
            e = we.value
            (b === nothing || e === nothing) && continue
            _buffer_key(b) == k && length(b) == length(buf) && _bump_epoch!(e::_ForcingEpoch)
        end
    end
    return nothing
end

@inline _bump_global_epoch!() = (_FORCING_EPOCH[] += UInt64(1); nothing)
