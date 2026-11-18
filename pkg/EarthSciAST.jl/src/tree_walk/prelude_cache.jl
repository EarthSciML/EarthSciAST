# tree_walk/prelude_cache.jl — the scalar prelude's cache (`_CSECache`), its buffers and the
# const-tier and time-tier validity stamps.

# The CSE prelude's per-call scratch, captured on every `_NK_CACHED` node at
# build time and refilled at the top of each `f!` call. TWO buffers, because the
# RHS has two value types (see `_rhs_value_type`):
#
#   * `f64`  — the production `Float64` slots. Sized once at build; `f!` writes it
#              and `_NK_CACHED` reads it, exactly as before this struct existed.
#   * `alt`  — the buffer for whatever NON-`Float64` value type last called `f!`
#              (a `Vector{Dual}` under ForwardDiff). `nothing` until the first such
#              call, so a model that is only ever integrated pays ZERO extra memory
#              and takes ZERO extra branches: `_cse_buf`/`_cse_read` dispatch on
#              `Type{Float64}` and compile to a bare field load.
#
# Kept as ONE cache object per evaluator (not per Dual type) because ForwardDiff
# uses a single `Dual{Tag,V,N}` for the whole Jacobian: the buffer is allocated on
# the first Dual call and reused by every later one. Alternating between two
# distinct Dual types would re-allocate `alt` each call — correct, just not free —
# which is the same non-reentrancy bargain the access-kernel scratch tiers already make.
#
# Each buffer carries its OWN const-tier validity stamp (`stamp64` / `stampalt`): the
# `p` whose const slots that buffer currently holds, or `_CSE_INVALID`. The stamp is
# PER BUFFER and not merely per `p`, and that is load-bearing — a freshly allocated
# `alt` is `undef`, so "`p` has not changed, skip the const slots" would read GARBAGE
# on the first `Dual` call if the two buffers shared one stamp. `_cse_buf` therefore
# invalidates the stamp of any buffer it allocates. See const_tier.jl for the tier.
#
# Each buffer ALSO carries a T-TIER stamp triple (B3, const_tier.jl): the `(p, t,
# forcing-epoch)` its TIME-cadence slots currently hold. A t-only slot depends on `p`,
# `t`, and the CONTENTS of any live forcing buffer it gathers — never on the state —
# so its value stays good exactly while all three stand still. The `t` half of the
# f64 stamp is a TYPED `Float64` field (`tt64`), not an `Any`: `t` moves on virtually
# every accepted step, and re-boxing it into an `Any` field per step would cost the
# hot path its zero-allocation property. The `p` halves (`tp64`/`tpalt`) are `Any`
# like the const stamps and are only re-stored when `p` actually moves; `ttalt` is
# `Any` because a non-Float64 value type may (rarely) carry a non-Float64 `t` — a
# `Dual` t under AD-over-time — and a `Dual` t must never satisfy a Float64-keyed
# stamp, which `===` (egal, type-discriminating) guarantees structurally.
mutable struct _CSECache
    f64::Vector{Float64}
    alt::Any
    stamp64::Any
    stampalt::Any
    # ---- t-tier stamps (B3): the (p, t, forcing epoch) the t-slots hold ----
    tp64::Any
    tt64::Float64
    te64::UInt64
    tpalt::Any
    ttalt::Any
    tealt::UInt64
    # The build's forcing epoch (cadence_stamp.jl), shared with its other tiers.
    epoch::_ForcingEpoch
end

# "This buffer's const slots hold nothing valid." A private singleton, so it is `!==`
# every possible `p` — including `nothing`, the parameter-free model's `p` sentinel.
struct _CSEInvalid end
const _CSE_INVALID = _CSEInvalid()

_CSECache() = _CSECache(
    Float64[], nothing, _CSE_INVALID, _CSE_INVALID,
    _CSE_INVALID, NaN, UInt64(0), _CSE_INVALID, _CSE_INVALID,
    UInt64(0), _new_forcing_epoch()
)

# Fetch the prelude scratch for value type `T`. `T` is a compile-time constant at
# every call site (it is derived from the argument TYPES — see `_rhs_value_type`),
# so exactly one of these two methods is compiled into any given `f!`
# specialization, and the `Float64` one is a field load.
#
# `f64` is allocated ONCE, at build time (`_cse_compile_scalar` sizes it, and
# `_share_kernel_invariants!` (xcse.jl) may grow it), and never replaced — so its stamp can only
# be invalidated by a `p` change. `alt` is (re)allocated lazily here, and every fresh
# `alt` is `undef` memory whose const slots have never been filled: allocating one
# MUST invalidate its stamp.
@inline _cse_buf(c::_CSECache, ::Type{Float64}) = c.f64
@inline function _cse_buf(c::_CSECache, ::Type{T}) where {T}
    b = c.alt
    b isa Vector{T} && return b
    nb = Vector{T}(undef, length(c.f64))
    c.alt = nb
    c.stampalt = _CSE_INVALID
    c.tpalt = _CSE_INVALID     # fresh `undef` buffer: its t-slots were never filled
    return nb
end

# ---- The const tier's validity check (EarthSciSerialization-4qf) --------------
#
# A CONST prelude slot (const_tier.jl) depends only on `p`, so the value in the buffer
# stays good until `p` changes — or until the buffer itself is replaced. `f!` refills
# the const slots iff `_cse_const_stale` says so, and stamps the buffer afterwards.
#
# The comparison is `_pstamp_same` (cadence_stamp.jl): egal for an `isbits` `p`, so
# two `p`s that match have bit-identical parameter values and therefore produce
# bit-identical const slots, and an element-by-element egal compare against a deep
# copy for a `p` holding arrays, so an in-place mutation of one moves the stamp.
@inline _cse_const_stale(c::_CSECache, ::Type{Float64}, p) =
    !_pstamp_same(c.stamp64, p)
@inline _cse_const_stale(c::_CSECache, ::Type{T}, p) where {T} =
    !_pstamp_same(c.stampalt, p)

# Record which `p` this buffer's const slots now hold. Storing into an `Any` field
# BOXES `p` — that is fine and deliberate: it happens only when `p` CHANGES, never on
# the repeated same-`p` calls whose zero-allocation property `f!` must keep (pinned by
# tree_walk_allocation_test.jl). A `p` holding arrays is stored as a deep copy.
@inline function _cse_mark_const!(c::_CSECache, ::Type{Float64}, p)
    c.stamp64 = _pstamp_reuse(c.stamp64, p)
    return nothing
end
@inline function _cse_mark_const!(c::_CSECache, ::Type{T}, p) where {T}
    c.stampalt = _pstamp_reuse(c.stampalt, p)
    return nothing
end

# ---- The t-tier's validity check (B3) -----------------------------------------
#
# A TIME-cadence prelude slot (const_tier.jl) is a deterministic function of
# `(p, t, forcing-buffer contents)`, so the value in the buffer stays good until any
# of the three moves — or until the buffer itself is replaced (`_cse_buf` invalidates
# `tpalt` on allocation; `f64` is never replaced). `f!` refills the t-slots iff
# `_cse_t_stale` says so, and stamps the buffer afterwards.
#
# The `t` compare is `===` (EGAL) — a BIT compare, deliberately NOT `==` and NOT
# `isapprox`. Bit-equality is exactly the FD-Jacobian shape (N+1 calls at the
# LITERALLY same `t`, perturbed `u`), and it is the only predicate under which the
# skip is bit-exact: two `t`s that are egal produce bit-identical slot values, while
# `==` would merge `0.0`/`-0.0` (different slots for e.g. `sign(t)`) and any
# tolerance would return one `t`'s forcing for a nearby other. Egal is also
# TYPE-discriminating, which closes the AD trap for free: a `Dual` `t` (AD-over-time
# rides the `alt` buffer, since `T` promotes over `typeof(t)`) is never egal to a
# stamped `Float64` `t`, and two `Dual`s with equal values but different partials are
# not egal either — the memo can never hand AD a value whose partials belong to a
# different seed. On the `f64` buffer `t isa Float64` is guaranteed dynamically
# (any other `t` fails `t === c.tt64` by type and `_cse_mark_t!` refuses to stamp
# it), so the typed `tt64` field is sound.
#
# The epoch compare is what makes a live-forcing gather admissible in this tier at
# all (the const tier must exclude it): an in-place refresh bumps the build's forcing epoch,
# the stamp stops matching, and the slots refill — at the same `t`, which is exactly
# when a refresh callback fires. `p` is compared exactly as in the const tier.
@inline _cse_t_stale(c::_CSECache, ::Type{Float64}, p, t) =
    !(t === c.tt64 && c.te64 === _epoch_value(c.epoch) && _pstamp_same(c.tp64, p))
@inline _cse_t_stale(c::_CSECache, ::Type{T}, p, t) where {T} =
    !(c.ttalt === t && c.tealt === _epoch_value(c.epoch) && _pstamp_same(c.tpalt, p))

# Record the `(p, t, epoch)` this buffer's t-slots now hold. Zero-allocation on the
# paths that repeat: `t` lands in a TYPED field (`tt64`) on the Float64 buffer, and
# the `Any` fields (`tp64`/`tpalt`/`ttalt`) are only re-stored (boxed) when their
# value actually moved — `p` on a `p` change, `ttalt` on a `t` change of the alt
# path. A non-Float64 `t` on the Float64 buffer, or a non-isbits `t`, is never
# stamped (fail closed: the tier refills every call, which is the pre-B3 behavior).
@inline function _cse_mark_t!(c::_CSECache, ::Type{Float64}, p, t)
    if t isa Float64
        _pstamp_same(c.tp64, p) || (c.tp64 = _pstamp_reuse(c.tp64, p))
        c.tt64 = t
        c.te64 = _epoch_value(c.epoch)
    else
        c.tp64 === _CSE_INVALID || (c.tp64 = _CSE_INVALID)
    end
    return nothing
end
@inline function _cse_mark_t!(c::_CSECache, ::Type{T}, p, t) where {T}
    if isbits(t)
        _pstamp_same(c.tpalt, p) || (c.tpalt = _pstamp_reuse(c.tpalt, p))
        c.ttalt === t || (c.ttalt = t)
        c.tealt = _epoch_value(c.epoch)
    else
        c.tpalt === _CSE_INVALID || (c.tpalt = _CSE_INVALID)
    end
    return nothing
end

# Read slot `i`. The `::Vector{T}` assert is what keeps the read monomorphic out
# of the `Any` field; `f!` calls `_cse_buf` before the prelude runs, so `alt` is
# always a live `Vector{T}` by the time an `_NK_CACHED` node is evaluated.
@inline _cse_read(c::_CSECache, i::Int, ::Type{Float64}) = @inbounds c.f64[i]
@inline _cse_read(c::_CSECache, i::Int, ::Type{T}) where {T} =
    @inbounds (c.alt::Vector{T})[i]
