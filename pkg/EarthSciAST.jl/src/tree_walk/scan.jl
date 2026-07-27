# ========================================================================
# tree_walk/scan.jl — cumulative (prefix) reductions in O(N)  (ess-scan)
#
# A cumulative sum is an ordinary `aggregate` whose `filter` admits the
# monotone window `j <= i` (esm-spec §4.3.1, "Cumulative (prefix)
# reductions"). Nothing about that shape is special to the build until you
# look at what it costs: `_unrolled_contraction_body` (build.jl) expands a
# constant-bound contraction into ONE symbolic ⊕-fold shared by every output
# cell, and with an inequality filter each of the N terms carries a runtime
# guard, so cell `i` evaluates
#
#     ((0̄ ⊕ g_1) ⊕ g_2) ⊕ … ⊕ g_N,     g_j = ifelse(j ⋚ i, term_j, 0̄)
#
# — N terms at every one of N cells. Measured on this build: an elementwise
# equation over 2048 cells costs ~1.5 µs per RHS call, the same-sized prefix
# sum ~18 ms. The affine + codegen tiers both FIRE; they are simply being
# asked to do O(N²) arithmetic.
#
# THE REWRITE. Consecutive output cells of a FORWARD scan share a prefix:
# acc_i = acc_{i-1} ⊕ term_i. So the whole equation is two O(N) passes:
#
#   1. TERMS. Substitute the contracted symbol with the output symbol in the
#      body (`u[j]` → `u[i]`, `u[j]*dx[j]` → `u[i]*dx[i]`) and hand THAT to
#      the ordinary affine build. It is an elementwise body with no
#      contraction left in it, so it inherits the affine lowering, the
#      codegen tier, threading, the class merge and AD unchanged — this file
#      adds no kernel type and no node kind.
#   2. FOLD. After the kernel section has written every term into `du`, walk
#      this equation's own output slots in ascending scan order and
#      accumulate in place (`_apply_scan_fold!` below).
#
# Splitting it this way — rather than carrying an accumulator through the
# cell loop — is deliberate. `_AccKernel`s are per-cell INDEPENDENT by
# construction, and four runners rely on that (the scalar walk, the lane
# tape, the Polyester-threaded plan, and the codegen'd loop nest), plus the
# `:oop` emitter. A stateful kernel would have to be taught to all of them;
# a post-pass over `du` is invisible to every one.
#
# BIT-EXACTNESS IS THE CONTRACT, as everywhere else in this runtime. Pass 2
# seeds with 0̄ and left-associates ascending, which is exactly the shape
# `_unrolled_contraction_body` emits (`OpExpr(oplus, [zerobar; terms…])`,
# left-nested per the codegen tier's stated fold order). The only formal
# difference is that the unrolled body also applies `⊕ 0̄` for every
# NON-admitted `j`, which the accumulator skips — and that padding is an
# exact no-op for all four reducers:
#   * `x * 1.0`, `max(x, -Inf)`, `min(x, +Inf)` are identities bit-for-bit;
#   * `x + 0.0` is the identity for every `x` EXCEPT `-0.0`, and a fold
#     seeded at `+0.0` can never hold `-0.0` (`0.0 + (-0.0)` is `+0.0`, and
#     IEEE `x + (-x)` is `+0.0` under round-to-nearest).
# Checked, not just argued: a `[-0.0, -0.0, -0.0]` prefix sum returns `+0.0`
# from all three tiers (codegen, affine-interpreted, per-cell reference) and
# from a bare accumulator.
#
# FORWARD ONLY. `j >= i` / `j > i` keep the triangular path. The accumulation
# order the spec fixes is ascending `j` for EVERY variant, so a reverse scan
# folds its suffix from the low end upward and consecutive reverse cells
# share no partial result; accumulating one right-to-left would re-associate
# the fold, which is not a no-op in floating point. The mirrored spellings
# `i >= j` / `i > j` ARE forward scans and are recognized as such. This
# matches the Rust and Python ports exactly.
# ========================================================================

# One equation's prefix fold, resolved to output slots at build time.
#
# `slots` holds `nlanes × len` state indices in LANE-MAJOR order: lane `l`
# owns `slots[(l-1)*len+1 : l*len]`, ascending along the scanned axis. A lane
# is one combination of the equation's non-scanned output indices, so a rank-1
# scan has a single lane and a rank-2 scan along `i` has one lane per `j`.
# Slots are resolved through the same `lhs_body` → `_cell_key` → `var_map`
# path the per-cell build uses, so this makes no independent assumption about
# the state layout.
#
# `inclusive` distinguishes `j <= i` (cell `i` includes its own term) from
# `j < i` (cell `i` is the accumulation BEFORE its own term; cell 1 is the
# empty reduction, which takes 0̄ — esm-spec §4.3.1).
struct _ScanFold
    slots::Vector{Int}
    len::Int
    oplus::Symbol         # :+ :* :max :min
    zerobar::Float64
    inclusive::Bool
end

# Apply every prefix fold of this build, in place over `du`. Runs AFTER the
# kernel section, so each fold reads back the per-cell terms its own term
# kernels just wrote. Value-type-generic in exactly the walker's sense: `du`
# carries the value type and the `Float64` 0̄ seed promotes at the first ⊕,
# which is how the unrolled fold's `NumExpr(zerobar)` leaf behaves too.
@inline function _apply_scan_folds!(du, folds::AbstractVector{_ScanFold})
    @inbounds for i in eachindex(folds)
        _apply_scan_fold!(du, folds[i])
    end
    return nothing
end

function _apply_scan_fold!(du, S::_ScanFold)
    op = S.oplus
    # Resolve the semiring ⊕ ONCE per fold, then run a type-stable lane loop
    # specialized on the concrete function (the `where {F}` on `_scan_lanes!`).
    if op === :+
        _scan_lanes!(du, S, +)
    elseif op === :*
        _scan_lanes!(du, S, *)
    elseif op === :max
        _scan_lanes!(du, S, max)
    elseif op === :min
        _scan_lanes!(du, S, min)
    else
        throw(TreeWalkError("E_TREEWALK_SCAN_UNKNOWN_OPLUS",
            "prefix scan carries unsupported ⊕ '$(op)'; expected +, *, max or min"))
    end
    return nothing
end

function _scan_lanes!(du, S::_ScanFold, combine::F) where {F}
    slots = S.slots
    len = S.len
    z = S.zerobar
    len >= 1 || return nothing
    nlanes = div(length(slots), len)
    @inbounds for l in 1:nlanes
        base = (l - 1) * len
        if S.inclusive
            # acc_i = acc_{i-1} ⊕ term_i, seeded 0̄ ⊕ term_1.
            s = slots[base + 1]
            acc = combine(z, du[s])
            du[s] = acc
            for k in 2:len
                s = slots[base + k]
                acc = combine(acc, du[s])
                du[s] = acc
            end
        else
            # Strict window: cell i emits the accumulation BEFORE its own term,
            # so cell 1 is the empty reduction and takes 0̄ verbatim.
            s = slots[base + 1]
            acc = combine(z, du[s])
            du[s] = z
            for k in 2:len
                s = slots[base + k]
                term = du[s]
                du[s] = acc
                acc = combine(acc, term)
            end
        end
    end
    return nothing
end

# ---- The `:oop` emitter's form of the same fold ----
# Identical values in an identical order — which is what keeps a Float64 `:oop`
# run bit-identical to `:inplace`, the property the in-place tests lean on by
# using `:oop` as their oracle. The only difference is mechanical: every write
# goes through the `_oop_store` seam (oop.jl) and `du` is rebound, so a backend
# whose output container is functional or traced sees the discipline the rest
# of the oop runners already follow.
function _apply_scan_folds_oop(du, folds::AbstractVector{_ScanFold})
    for i in eachindex(folds)
        du = _apply_scan_fold_oop(du, folds[i])
    end
    return du
end

function _apply_scan_fold_oop(du, S::_ScanFold)
    op = S.oplus
    op === :+   && return _scan_lanes_oop(du, S, +)
    op === :*   && return _scan_lanes_oop(du, S, *)
    op === :max && return _scan_lanes_oop(du, S, max)
    op === :min && return _scan_lanes_oop(du, S, min)
    throw(TreeWalkError("E_TREEWALK_SCAN_UNKNOWN_OPLUS",
        "prefix scan carries unsupported ⊕ '$(op)'; expected +, *, max or min"))
end

function _scan_lanes_oop(du, S::_ScanFold, combine::F) where {F}
    slots = S.slots
    len = S.len
    z = S.zerobar
    len >= 1 || return du
    nlanes = div(length(slots), len)
    for l in 1:nlanes
        base = (l - 1) * len
        if S.inclusive
            s = slots[base + 1]
            acc = combine(z, @inbounds du[s])
            du = _oop_store(du, s, acc)
            for k in 2:len
                s = slots[base + k]
                acc = combine(acc, @inbounds du[s])
                du = _oop_store(du, s, acc)
            end
        else
            s = slots[base + 1]
            acc = combine(z, @inbounds du[s])
            du = _oop_store(du, s, z)
            for k in 2:len
                s = slots[base + k]
                term = @inbounds du[s]
                du = _oop_store(du, s, acc)
                acc = combine(acc, term)
            end
        end
    end
    return du
end
