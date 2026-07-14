# ========================================================================
# tree_walk/const_tier.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4f: the CONST-CADENCE tier of the CSE prelude
# (EarthSciSerialization-4qf; audit finding #5).
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
# So the prelude is now TWO tiers. `f!` refills the DYNAMIC slots every call and the
# CONST slots only when they can have changed. This file decides which is which; the
# validity check that decides "can have changed" lives on `_CSECache` (compile.jl).
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
# A prelude slot `s` is CONST iff
#
#     (1) `prelude[s]` contains no `_NK_STATE`, no `_NK_TIME`, no `_NK_PARAM_GATHER`,
#     AND (2) every `_NK_CACHED` child of it refers to a slot that is itself CONST.
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
# The three DYNAMIC leaf kinds, and why each is dynamic:
#   * `_NK_STATE` — `u` changes every stage. Obviously continuous cadence.
#   * `_NK_TIME`  — `t` changes every stage. Likewise.
#   * `_NK_PARAM_GATHER` — a live forcing buffer (ess-14f.3) or a discrete-cadence
#     cache. Its CONTENTS are refreshed IN PLACE between calls (a data-refresh
#     callback's `buffer .= …`, a `DiscreteMaterializer.materialize!`) while `p`
#     itself never moves. It is DISCRETE cadence, not const, and a `p`-keyed validity
#     stamp cannot see it change — so it must never enter the const tier. (Giving the
#     discrete tier its own refresh-keyed stamp is the natural follow-on; it is not
#     this change.)
# Everything else — literals, `_NK_PARAM`, and every pure op over them, `fn` included
# (the closed-function registry is closed and deterministic, esm-spec §9.2) — is a
# deterministic function of `p` alone.
#
# ASCENDING SLOT ORDER makes clause (2) a single forward pass. Prelude slot order is
# topological (a def may only read slots strictly below its own — `_compile_cse`
# assigns child slots first, and `_share_lane_invariants!` sorts its new defs by node
# count for the same reason), so when slot `s` is classified, every slot it can
# possibly reference is already classified:
#
#     is_const[s] = (no state/time/pgather leaf in def s)
#                   && all(is_const[r] for r in cached-slots-referenced-by def s)
#
# THE PAYOFF of getting clause (2) right is what makes the runtime split legal:
# a const def can then only reference const slots. So evaluating all const slots in
# ascending order, and then all dynamic slots in ascending order, fills every slot
# from slots that are already filled — the two-loop `f!` is exactly the one-loop `f!`
# with the const loop skipped when it provably need not run.
#
# FAIL CLOSED. A cache ref into some OTHER `_CSECache`, or to a slot at or above its
# own (which would mean the prelude is not topologically ordered after all), is
# classified DYNAMIC. The cost of an unnecessary DYNAMIC slot is a recomputation; the
# cost of an unsound CONST slot is a stale number.

# Does `n` — a subtree of `prelude[slot]` — depend only on `p`? `is_const` must be
# filled for every slot BELOW `slot`; entries at or above it are not read.
function _def_is_const(n::_Node, is_const::Vector{Bool}, slot::Int, cache::_CSECache)::Bool
    k = n.kind
    if k === _NK_STATE || k === _NK_TIME || k === _NK_PARAM_GATHER
        return false
    elseif k === _NK_CACHED
        # THE TRAP (clause 2): a cache ref has no leaves of its own, so its cadence is
        # the cadence of the SLOT it reads — not `const` by default.
        n.payload === cache || return false            # a foreign cache: fail closed
        r = n.idx
        (1 <= r < slot) || return false               # not below us: fail closed
        return @inbounds is_const[r]
    end
    # `_NK_LITERAL` / `_NK_PARAM` are childless ⇒ const. `_NK_OP` (`fn` included) and
    # `_NK_CONTRACTION` are pure functions of their children: const iff all of them are.
    # An `interp.*` const table lives in `payload` and is frozen `Float64` DATA, so it
    # constrains nothing.
    for c in n.children
        _def_is_const(c, is_const, slot, cache) || return false
    end
    return true
end

# Partition the FINAL prelude (post `_share_lane_invariants!`) into its two cadence
# tiers. Returns two ASCENDING slot-index vectors — the order `f!` must evaluate them
# in — which together are a permutation of `1:length(prelude)`.
function _classify_const_slots(prelude::AbstractVector{_Node}, cache::_CSECache)
    n = length(prelude)
    is_const = Vector{Bool}(undef, n)
    const_slots = Int[]
    dyn_slots = Int[]
    for s in 1:n
        c = _def_is_const(prelude[s], is_const, s, cache)
        @inbounds is_const[s] = c
        push!(c ? const_slots : dyn_slots, s)
    end
    return const_slots, dyn_slots
end
