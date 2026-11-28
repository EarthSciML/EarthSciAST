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
    _allof(y -> _pstamp_comparable(y, n), values(x))
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

# A new stamp for `p`, written into the previous stamp `old` when it can be:
# `old` is a private snapshot no one else holds, so a tier that steps through
# parameter vectors (a solver's sensitivity sweep, a workspace alternating two
# `p`s) restamps without allocating. `_pprimal_restamp` below is the same for
# the primal stamp.
@inline _pstamp_reuse(old, p) = _restamp(old, p, identity)

# The one restamp both stamps share. `f` is what the stamp holds of `p`
# (`identity`, or `_pprimal`). `old` is reused when `p` is a vector whose
# stamp is a vector of one bits type `S` (`_stamp_eltype`), `old` is that
# vector at `p`'s length, and `p` is within the `_PSTAMP_MAX_ELEMS` a stamp may
# hold; every other case takes a fresh `_pstamp`, which refuses what cannot be
# stamped.
@inline _restamp(old, p, f::F) where {F} = _pstamp(f(p))
@inline function _restamp(old, p::Vector{T}, f::F) where {T, F}
    S = _stamp_eltype(f, T)
    if S !== nothing && isbitstype(S) && old isa Vector{S} &&
            length(old) == length(p) && length(p) <= _PSTAMP_MAX_ELEMS
        @inbounds for i in eachindex(p)
            old[i] = f(p[i])
        end
        return old
    end
    return _pstamp(f(p))
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

# A new primal stamp for `p`, reusing `old` on the terms `_restamp` states.
@inline _pprimal_restamp(old, p) = _restamp(old, p, _pprimal)

# The element type of the stamp `f` makes of a vector with elements of type
# `T`, or `nothing` when it is not one fixed type.
_stamp_eltype(::typeof(identity), ::Type{T}) where {T} = T
_stamp_eltype(::typeof(_pprimal), ::Type{T}) where {T <: Number} = typeof(_value(zero(T)))
_stamp_eltype(::typeof(_pprimal), ::Type) = nothing

# ---- The forcing epoch --------------------------------------------------------
#
# A time-tier value may gather a LIVE forcing buffer (a `param_arrays` buffer or
# a discrete-cadence cache) whose CONTENTS are refreshed in place while `p` and
# `t` stand still (a refresh callback fires AT its tstop, so the first RHS call
# after it is at the same `t` as the calls before it). A `(p, t)` stamp cannot
# see that, so every in-place refresh bumps an epoch the time tiers compare.
#
# The epoch belongs to one build, and the build's owner carries it: a Problem's
# build products and its `DiscreteMaterializer`, or an `Internal.Build`'s
# report. A writer announces a refresh to that owner
# ([`notify_forcing_refresh!`](@ref), data_refresh.jl); the discrete-cadence
# materializer bumps it after every fill. A refresh announced to one owner
# leaves every other build's memoized values alone. A program workspace
# (rhs_program.jl) gets epochs of its own and bumps them when its forcing set
# changes.
#
# `announced` says whether every writer of the build's live buffers announces
# its writes. Only then may a value that reads forcing but not `t` (the
# forcing-cadence observeds, rhs_assembly.jl) be kept across a new `t`;
# otherwise it is refilled whenever `t` moves too, so a write nobody announced
# (a `build_refresh_callback` with `owner = nothing`) is seen at the next new
# `t`. It is set for a program workspace (its buffers are loaded from forcing
# sets, which bump its epochs), for a Problem whose live buffers are all its
# own providers' (written by its own announcing callback), and for the owner a
# caller gives `build_refresh_callback` (`_declare_announced!`).
mutable struct _ForcingEpoch
    n::UInt64
    announced::Bool
end
_ForcingEpoch(n::UInt64) = _ForcingEpoch(n, false)
_new_forcing_epoch() = _ForcingEpoch(UInt64(0))
Base.getindex(e::_ForcingEpoch) = e.n
Base.setindex!(e::_ForcingEpoch, v) = (e.n = UInt64(v); e)

# The value a time tier stamps and compares. It only grows.
@inline _epoch_value(e::_ForcingEpoch) = e.n

@inline _bump_epoch!(e::_ForcingEpoch) = (e.n += UInt64(1); nothing)
