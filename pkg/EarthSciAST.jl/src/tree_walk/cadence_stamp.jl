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
# `_PSTAMP_MAX_ELEMS` numbers, cannot be compared cheaply and safely, and is
# refused with `E_TREEWALK_PARAM_UNSTAMPABLE`: the alternative, refilling
# every tier and re-walking `p` on every call, would silently cost an
# O(length(p)) walk and an allocation per call.

const _PSTAMP_MAX_ELEMS = 1 << 16

@inline _pstamp(p) = isbits(p) ? p : _pstamp_snapshot(p)

function _pstamp_snapshot(p)
    n = Ref(0)
    _pstamp_comparable(p, n) || _pstamp_refuse(p, n[])
    return deepcopy(p)
end

@noinline function _pstamp_refuse(p, nelems::Int)
    why = nelems > _PSTAMP_MAX_ELEMS ?
        "it holds more than $(_PSTAMP_MAX_ELEMS) numbers" :
        "it holds a value that is not a number, tuple, NamedTuple or array of these"
    throw(
        TreeWalkError(
            "E_TREEWALK_PARAM_UNSTAMPABLE",
            "parameter object of type $(typeof(p)) cannot be used with memoized " *
                "parameter-dependent values: $(why). Pass `p` as a NamedTuple, tuple " *
                "or array of numbers (at most $(_PSTAMP_MAX_ELEMS) in total)"
        )
    )
end

_pstamp_comparable(x, n::Base.RefValue{Int}) = isbits(x)
_pstamp_comparable(x::Union{Tuple, NamedTuple}, n::Base.RefValue{Int}) =
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

# A new stamp for `p`, written into the previous stamp `old` when both are
# vectors of the same bits type and length: `old` is a private snapshot no one
# else holds, so a tier that steps through parameter vectors (a solver's
# sensitivity sweep, a workspace alternating two `p`s) restamps without
# allocating.
@inline _pstamp_reuse(old, p) = _pstamp(p)
@inline function _pstamp_reuse(old, p::Vector{T}) where {T}
    if isbitstype(T) && old isa Vector{T} && length(old) == length(p)
        copyto!(old, p)
        return old
    end
    return _pstamp(p)
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

# ---- Primal parameter stamps --------------------------------------------------
#
# A value that depends on `p` only through its primal (a gate tested against
# zero, which a dual number answers from its value) is the same for a `Float64`
# `p` and for a dual-valued `p` with the same primal. Stamping it with
# `_pstamp(_pprimal(p))` and testing with `_pprimal_same` lets a solver that
# alternates between the two, or a Jacobian taken in several chunks of
# different partials, keep it. The test does not allocate: it compares `s`
# against the primal of each number in `p` where it stands.
_pprimal(x::Number) = _value(x)
_pprimal(x::Union{Tuple, NamedTuple}) = map(_pprimal, x)
_pprimal(x::AbstractArray) = map(_pprimal, x)
_pprimal(x) = x

@inline _pprimal_same(s, p) = isbits(p) ? s === _pprimal(p) : _pvalue_same(s, p)

_pvalue_same(a, b) = a === b
_pvalue_same(a, b::Number) = a === _value(b)
_pvalue_same(::Tuple{}, ::Tuple{}) = true
@inline _pvalue_same(a::Tuple, b::Tuple) = length(a) == length(b) &&
    _pvalue_same(first(a), first(b)) && _pvalue_same(Base.tail(a), Base.tail(b))
@inline _pvalue_same(a::NamedTuple{N}, b::NamedTuple{N}) where {N} =
    _pvalue_same(Tuple(a), Tuple(b))
function _pvalue_same(a::AbstractArray, b::AbstractArray)
    axes(a) == axes(b) || return false
    @inbounds for i in eachindex(a, b)
        _pvalue_same(a[i], b[i]) || return false
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

# A build's epoch: its own count, and whether the process-wide count is part of
# it. Every build's epoch is (`shared`). The private instance of a program that
# an `RhsWorkspace` evaluates (rhs_program.jl) has unshared epochs: its forcing
# arrives as a `ForcingSet` whose epoch it tracks itself, so a refresh elsewhere
# in the process is no reason to refill it, and that path never reads the global.
mutable struct _ForcingEpoch
    n::UInt64
    shared::Bool
end
_new_forcing_epoch() = _ForcingEpoch(UInt64(0), true)
Base.getindex(e::_ForcingEpoch) = e.n
Base.setindex!(e::_ForcingEpoch, v) = (e.n = UInt64(v); e)

# The epoch a time tier stamps and compares: the build's own count plus, when
# shared, the process-wide one. Both only grow, so any bump of either moves the
# sum.
@inline _epoch_value(e::_ForcingEpoch) = e.shared ? e.n + _FORCING_EPOCH[] : e.n

@inline _bump_epoch!(e::_ForcingEpoch) = (e.n += UInt64(1); nothing)

# Data pointer => the builds reading that buffer: a weak reference to the
# registered array (so a recycled address is told apart from the buffer it
# once was) and a weak reference to each build's epoch.
const _BUFFER_EPOCHS = Dict{UInt, Vector{Tuple{WeakRef, WeakRef}}}()
const _BUFFER_EPOCHS_LOCK = ReentrantLock()

# Registrations die with their build or buffer, but nothing removes them then (a
# finalizer may not take the lock). Registration instead sweeps the whole table
# once it has doubled since the last sweep, so the table stays within a constant
# factor of the live registrations at an amortized O(1) per registration.
const _BUFFER_EPOCHS_SWEEP_AT = Ref(64)

_buffer_key(buf::AbstractArray) = UInt(pointer(buf))

_live_registration(r::Tuple{WeakRef, WeakRef}) =
    r[1].value !== nothing && r[2].value !== nothing

function _sweep_buffer_epochs!()
    filter!(_BUFFER_EPOCHS) do (_, regs)
        filter!(_live_registration, regs)
        !isempty(regs)
    end
    _BUFFER_EPOCHS_SWEEP_AT[] = max(64, 2 * length(_BUFFER_EPOCHS))
    return nothing
end

function _register_forcing_buffers!(epoch::_ForcingEpoch, buffers)
    isempty(buffers) && return nothing
    lock(_BUFFER_EPOCHS_LOCK) do
        for buf in buffers
            buf isa DenseArray || continue
            k = _buffer_key(buf)
            regs = get!(Vector{Tuple{WeakRef, WeakRef}}, _BUFFER_EPOCHS, k)
            filter!(_live_registration, regs)
            push!(regs, (WeakRef(buf), WeakRef(epoch)))
        end
        length(_BUFFER_EPOCHS) >= _BUFFER_EPOCHS_SWEEP_AT[] && _sweep_buffer_epochs!()
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
