# ========================================================================
# tree_walk/const_tier.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4f: the CONST-CADENCE and TIME-CADENCE tiers of
# the CSE prelude (EarthSciSerialization-4qf + B3; audit finding #5).
# ========================================================================
#
# THE GAP THIS CLOSES
# -------------------
# `_make_rhs` refills EVERY prelude slot on EVERY RHS call. Many of those slots are
# pure PARAMETER ALGEBRA — an Arrhenius factor `A*exp(-Ea/(R*Tref))` whose every leaf
# is a parameter — and `p` does not change between the stages of a step, or between
# steps, or (usually) over an entire integration. The `Cadence` lattice (src/cadence.jl)
# names exactly this class (`const ⊏ discrete ⊏ continuous`) and `build_evaluator`
# never consulted it: the `exp` was recomputed on every stage of every step, forever.
#
# So the prelude is now THREE tiers. `f!` refills the DYNAMIC slots every call, the
# CONST slots only when `p` moved, and — the B3 tier this file grew — the TIME
# slots only when `(p, t, forcing epoch)` moved. This file decides which is which;
# the validity checks that decide "can have changed" live on `_CSECache` (compile.jl).
#
# THE TIME TIER'S TARGET is the finite-difference Jacobian: a stiff solver's FD fill
# makes N+1 RHS calls at the LITERALLY SAME `t` with a state perturbed one column at
# a time. Everything that depends only on `t` + `p` + the forcing buffers — the
# FastJX photolysis chain, a `w_time` interpolation-weight blend, a met-field gather
# — is state-blind, so N of those N+1 evaluations recompute an identical value. With
# the tier, the first call at a given `(p, t, epoch)` fills the time slots and the
# other N reuse them. Memoizing on `t` is inherently safe for these slots: their
# defs carry no history — a step REJECTION that revisits a `t` recomputes (or
# reuses) exactly the same pure function of that `t`. Kill switch:
# `ESS_TCADENCE_DISABLE=1` at build time demotes every time slot to DYNAMIC,
# restoring the refill-every-call behavior bit-for-bit.
#
# Since the lane-invariant sharing pass (invariant_share.jl) landed, lane-invariant
# kernel subtrees are prelude defs too — so the tier pays off on the ARRAY path as
# well, not just on scalar equations.
#
# `const` IN CADENCE IS NOT `const` IN VALUE — DO NOT FOLD AT BUILD TIME
# ---------------------------------------------------------------------
# This is the whole reason the tier is a runtime check and not a constant-folder.
# `p` is passed into `f!` on every call and legitimately changes: parameter sweeps,
# `remake`, and above all ForwardDiff-over-PARAMETERS, where the parameter VALUES are
# `Dual`s (which is exactly why `_rhs_value_type` promotes over `values(p)` and not
# just `eltype(u)`). Freezing a parameter-only slot at its Float64 build value would
# return a ZERO derivative for every parameter sensitivity — a wrong Jacobian that
# still looks entirely plausible. The slots are recomputed whenever `p` is not the
# same `p` they were computed for; see `_cse_const_stale`.

# ---- The classification rule --------------------------------------------------
#
# Each prelude slot gets a TIER in the little lattice `CONST(0) ⊏ TIME(1) ⊏
# DYNAMIC(2)`, as the max over its def's leaves and cache refs:
#
#     _NK_STATE                     → DYNAMIC   (`u` changes every stage)
#     _NK_TIME                      → TIME      (`t` + `p` determine it; memo on t)
#     _NK_PARAM_GATHER              → TIME      (see below — epoch-stamped)
#     _NK_LITERAL / _NK_PARAM       → CONST
#     _NK_CACHED on slot r          → tier[r]   (clause 2 — the trap)
#     _NK_OP / _NK_CONTRACTION      → max over children (pure functions; `fn`
#                                     included — the closed-function registry is
#                                     closed and deterministic, esm-spec §9.2; an
#                                     `interp.*` const table lives in `payload` as
#                                     frozen Float64 DATA and constrains nothing)
#
# Clause (2) is the trap, and a naive "does this subtree contain a state leaf?" scan
# walks straight into it. An `_NK_CACHED` node carries NO state/time/gather leaf of its
# own — it is a bare `cache[i]` load — so a def that reads a DYNAMIC slot through a
# cache ref looks leaf-clean and would be classified CONST, and would then be computed
# once and frozen while the slot it reads kept moving. And prelude defs absolutely do
# contain `_NK_CACHED` children: `_compile_cse` hoists a def's children BEFORE the def
# itself (that is what keeps the prelude topologically ordered), and `_share_lane_invariants!`
# rewrites its new defs against the slots below them.
#
# WHY `_NK_PARAM_GATHER` IS TIME, NOT CONST (and why it could not be, before B3):
# a live forcing buffer (ess-14f.3) or a discrete-cadence cache has its CONTENTS
# refreshed IN PLACE between calls (a data-refresh callback's `buffer .= …`, a
# `DiscreteMaterializer.materialize!`) while `p` itself never moves — a `p`-keyed
# validity stamp cannot see it change, so it must never enter the const tier. The
# TIME tier's stamp carries the FORCING EPOCH precisely so it can: `_write_forcing!`
# and `materialize!` bump `_FORCING_EPOCH` (compile.jl) on every in-place refresh,
# and `_cse_t_stale` refills on the bump even at an unchanged `t`. This is the
# discrete-cadence "refresh-keyed stamp" the original const-tier note deferred.
# (Contract note: DIRECT buffer mutation outside those two write paths must call
# `notify_forcing_refresh!` if the RHS may next run at an already-seen `t`.)
#
# ASCENDING SLOT ORDER makes clause (2) a single forward pass. Prelude slot order is
# topological (a def may only read slots strictly below its own — `_compile_cse`
# assigns child slots first, and `_share_lane_invariants!` sorts its new defs by node
# count for the same reason), so when slot `s` is classified, every slot it can
# possibly reference is already classified:
#
#     tier[s] = max(leaf tiers of def s, tier[r] for r in cached-slots-referenced)
#
# THE PAYOFF of getting clause (2) right is what makes the runtime split legal: a
# slot's def can only reference slots of its OWN TIER OR LOWER (max-monotonicity),
# so evaluating all const slots in ascending order, then all time slots in ascending
# order, then all dynamic slots in ascending order fills every slot from slots that
# are already filled or still valid — the three-loop `f!` is exactly the one-loop
# `f!` with the const/time loops skipped when they provably need not run.
#
# FAIL CLOSED. A cache ref into some OTHER `_CSECache`, or to a slot at or above its
# own (which would mean the prelude is not topologically ordered after all), is
# classified DYNAMIC. The cost of an unnecessary DYNAMIC slot is a recomputation; the
# cost of an unsound CONST/TIME slot is a stale number.
#
# NOT FOLDED AT BUILD TIME, EITHER TIER: a time slot is `const` over a Jacobian
# fill, not in VALUE TYPE. Its runtime evaluation in `T = _rhs_value_type(u, p, t)`
# is what keeps AD-over-parameters (`Dual` p) and AD-over-time (`Dual` t) exact —
# freezing at the Float64 build value would zero those sensitivities, the same
# eltype/parameter-freezing constraint the const-tier header pins above.

const _TIER_CONST = Int8(0)
const _TIER_TIME = Int8(1)
const _TIER_DYNAMIC = Int8(2)

# The tier of `n` — a subtree of `prelude[slot]` — in the CONST ⊏ TIME ⊏ DYNAMIC
# lattice. `tier` must be filled for every slot BELOW `slot`; entries at or above it
# are not read.
function _def_tier(n::_Node, tier::Vector{Int8}, slot::Int, cache::_CSECache)::Int8
    k = n.kind
    if k === _NK_STATE
        return _TIER_DYNAMIC
    elseif k === _NK_TIME || k === _NK_PARAM_GATHER
        return _TIER_TIME
    elseif k === _NK_CACHED
        # THE TRAP (clause 2): a cache ref has no leaves of its own, so its cadence is
        # the cadence of the SLOT it reads — not `const` by default.
        n.payload === cache || return _TIER_DYNAMIC    # a foreign cache: fail closed
        r = n.idx
        (1 <= r < slot) || return _TIER_DYNAMIC       # not below us: fail closed
        return @inbounds tier[r]
    end
    # `_NK_LITERAL` / `_NK_PARAM` are childless ⇒ const. `_NK_OP` (`fn` included) and
    # `_NK_CONTRACTION` are pure functions of their children: max over them.
    tr = _TIER_CONST
    for c in n.children
        tc = _def_tier(c, tier, slot, cache)
        tc === _TIER_DYNAMIC && return _TIER_DYNAMIC
        tc > tr && (tr = tc)
    end
    return tr
end

_tcadence_disabled() = get(ENV, "ESS_TCADENCE_DISABLE", "") == "1"

# Partition the FINAL prelude (post `_share_lane_invariants!`) into its three cadence
# tiers. Returns three ASCENDING slot-index vectors — the order `f!` must evaluate
# them in — which together are a permutation of `1:length(prelude)`.
#
# With `ESS_TCADENCE_DISABLE=1` (read at BUILD time, like `ESS_STENCIL_DISABLE`)
# every TIME slot is routed into the dynamic vector instead: refilled every call,
# which is bit-identical to the pre-B3 two-tier evaluator. The recorded `tier[]`
# entries keep their computed values so downstream classification is unchanged —
# a consumer of a demoted slot is itself TIME-or-worse and lands in the dynamic
# vector too, preserving ascending evaluation order among them.
function _classify_const_slots(prelude::AbstractVector{_Node}, cache::_CSECache)
    n = length(prelude)
    tdisabled = _tcadence_disabled()
    tier = Vector{Int8}(undef, n)
    const_slots = Int[]
    time_slots = Int[]
    dyn_slots = Int[]
    for s in 1:n
        tr = _def_tier(prelude[s], tier, s, cache)
        @inbounds tier[s] = tr
        if tr === _TIER_CONST
            push!(const_slots, s)
        elseif tr === _TIER_TIME && !tdisabled
            push!(time_slots, s)
        else
            push!(dyn_slots, s)
        end
    end
    return const_slots, time_slots, dyn_slots
end
