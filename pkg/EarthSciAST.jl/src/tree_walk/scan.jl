# ========================================================================
# tree_walk/scan.jl — cumulative (prefix) reductions in O(N)  (ess-scan)
#
# A cumulative sum is an ordinary `faq` whose `filter` admits the
# monotone window `j <= i` (esm-spec §4.3.1, "Cumulative (prefix)
# reductions"). Nothing about that shape is special to the build until you
# look at what it costs: `_unrolled_contraction_body` (build.jl) expands a
# constant-bound contraction into ONE symbolic ⊕-fold shared by every output
# cell, and with an inequality filter each of the N terms carries a runtime
# guard, so cell `i` evaluates
#
#     ((0̄ ⊕ g_1) ⊕ g_2) ⊕ … ⊕ g_N,     g_j = ifelse(j ⋚ i, term_j, 0̄)
#
# — N terms at every one of N cells, i.e. O(N²) arithmetic per RHS call against
# O(N) for an elementwise equation of the same size. The affine and codegen tiers
# both FIRE; they are simply being asked to do quadratic work.
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
# construction, and the runners rely on that (the scalar walk and the
# codegen'd loop nest, serial or chunked), plus the
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
#
# STAGGERED OUTPUT. The output axis may also be the term axis plus one trailing
# cell — the shape a cumulative flux takes on a staggered grid, where the
# quantity lands on the NODES and the terms live at the CENTRES (ReSEACT's
# `Mz[ke] = -Σ_{k < ke}(…)` over `lev_nodes` contracting `lev`). It is the same
# recurrence run one step further, so NOTHING IN THIS FILE CHANGES for it: the
# term pass runs over the centres, the last node is left unwritten by the term
# kernels, and the strict fold below writes every cell before reading it — the
# slot's entry value reaches only an `acc` the loop discards.
# `_scan_term_iters` (build.jl) states the admission condition and why the
# inclusive window is excluded. Pinned by the staggered testsets in
# test/scan_prefix_test.jl, bitwise against the per-cell reference exactly as
# the same-range cases are.
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
#
# `terms` holds the term kernels the build made for this fold (`_AccKernel`s,
# untyped here because they are defined later). The in-place build uses them
# to compile the term into the fold's own pass (scan_fused.jl); the fold itself
# never reads them.
#
# `kstride` / `lstride`: when the slots are one affine box, slot `k` of lane `l`
# is `slots[1] + (l-1)·lstride + (k-1)·kstride`; `kstride == 0` when they are
# not. A scan along a slow axis (a column scan over levels with the columns
# fastest) has `kstride > 1`, and walking it lane by lane strides through
# memory; `_scan_lanes_strided!` walks it level by level instead when the
# lanes are contiguous.
struct _ScanFold
    slots::Vector{Int}
    len::Int
    oplus::Symbol         # :+ :* :max :min
    zerobar::Float64
    inclusive::Bool
    terms::Vector{Any}
    lstride::Int
    kstride::Int
end
function _ScanFold(slots::Vector{Int}, len::Int, oplus::Symbol, zerobar::Float64,
                   inclusive::Bool, terms::Vector{Any})
    ls, ks = _scan_strides(slots, len)
    return _ScanFold(slots, len, oplus, zerobar, inclusive, terms, ls, ks)
end
_ScanFold(slots::Vector{Int}, len::Int, oplus::Symbol, zerobar::Float64,
          inclusive::Bool) = _ScanFold(slots, len, oplus, zerobar, inclusive, Any[])

function _scan_strides(slots::Vector{Int}, len::Int)
    (len >= 2 && !isempty(slots)) || return (0, 0)
    nl = div(length(slots), len)
    ks = slots[2] - slots[1]
    ls = nl >= 2 ? slots[len + 1] - slots[1] : 0
    @inbounds for l in 1:nl, k in 1:len
        slots[(l - 1) * len + k] == slots[1] + (l - 1) * ls + (k - 1) * ks ||
            return (0, 0)
    end
    return (ls, ks)
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

# A level's folds as a plain list (the output-time observed program's levels),
# which carry no fused scans: the folds alone.
_apply_scan_folds!(du, u, p, t, folds::AbstractVector{_ScanFold}) =
    _apply_scan_folds!(du, folds)

# Fold lanes `l1:l2` of `S` (all of them by default); lanes are independent.
function _apply_scan_fold!(du, S::_ScanFold, l1::Int = 1,
                           l2::Int = S.len >= 1 ? div(length(S.slots), S.len) : 0)
    op = S.oplus
    # Resolve the semiring ⊕ ONCE per fold, then run a type-stable lane loop
    # specialized on the concrete function (the `where {F}` on `_scan_lanes!`).
    if op === :+
        _scan_lanes!(du, S, +, l1, l2)
    elseif op === :*
        _scan_lanes!(du, S, *, l1, l2)
    elseif op === :max
        _scan_lanes!(du, S, max, l1, l2)
    elseif op === :min
        _scan_lanes!(du, S, min, l1, l2)
    else
        throw(TreeWalkError("E_TREEWALK_SCAN_UNKNOWN_OPLUS",
            "prefix scan carries unsupported ⊕ '$(op)'; expected +, *, max or min"))
    end
    return nothing
end

function _scan_lanes!(du, S::_ScanFold, combine::F, l1::Int, l2::Int) where {F}
    slots = S.slots
    len = S.len
    z = S.zerobar
    len >= 1 || return nothing
    # A strided scan whose running value is stored exactly by `du` (the value
    # type ⊕ yields is `du`'s own) runs level by level.
    if S.lstride == 1 && S.kstride >= l2 - l1 + 1 && l2 > l1 &&
       typeof(combine(z, zero(eltype(du)))) === eltype(du)
        return _scan_lanes_strided!(du, S, combine, l1, l2)
    end
    @inbounds for l in l1:l2
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

# `_scan_lanes!` over lanes `l1:l2` of a fold whose lanes are the fast axis
# (`lstride == 1`) and whose levels lie `kstride` apart, level by level: one
# level's lanes are contiguous independent cells, and the level below is past
# their span, so the loop over them carries no dependence and may vectorize
# across cells. Each lane's running value is kept in its own slot instead of a
# local, which `du` stores exactly (the caller checks the value type), so
# every lane folds the same values in the same order:
#   1. inclusive in place, `du[s_k] = du[s_{k-1}] ⊕ du[s_k]` from `0̄ ⊕ du[s_1]`,
#      which is `_scan_lanes!`'s inclusive `acc` at every cell;
#   2. a strict fold then shifts it one level up and puts 0̄ at the first, since
#      its cell `k` holds the inclusive value of cell `k-1`. The last cell's
#      term, which a strict fold reads and discards, is overwritten here too.
function _scan_lanes_strided!(du, S::_ScanFold, combine::F, l1::Int, l2::Int) where {F}
    s1 = S.slots[1]
    ls = S.lstride
    ks = S.kstride
    len = S.len
    first = s1 + (l1 - 1) * ls
    last = s1 + (l2 - 1) * ls + (len - 1) * ks
    v, off = _scan_dense(du, min(first, last), max(first, last))
    _scan_strided_run!(v, s1 - off, ks, len, S.zerobar, S.inclusive, combine, l1, l2)
    return nothing
end

function _scan_strided_run!(du, s1::Int, ks::Int, len::Int, z::Float64,
                            inclusive::Bool, combine::F, l1::Int, l2::Int) where {F}
    a = s1 + l1 - 1
    b = s1 + l2 - 1
    @inbounds begin
        for s in a:b
            du[s] = combine(z, du[s])
        end
        for k in 2:len
            o = (k - 1) * ks
            @simd ivdep for s in (a + o):(b + o)
                du[s] = combine(du[s - ks], du[s])
            end
        end
        if !inclusive
            for k in len:-1:2
                o = (k - 1) * ks
                @simd ivdep for s in (a + o):(b + o)
                    du[s] = du[s - ks]
                end
            end
            for s in a:b
                du[s] = z
            end
        end
    end
    return nothing
end

# The plain vector `du`'s slots `lo:hi` live in, and the offset to subtract
# (the two-buffer view's method is with it, in build.jl).
_scan_dense(du, lo::Int, hi::Int) = (du, 0)
