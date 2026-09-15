# ========================================================================
# ext/reactant_interp.jl — interp knot addressing under a trace: a GATHER,
# not an O(table) select ladder. Included by ext/EarthSciASTReactantExt.jl.
# ========================================================================
#
# The default lowering of `interp.*`'s locate → gather → blend
# (src/tree_walk/interp_lanes.jl) is a branch-free SELECT LADDER: one `ifelse`
# per table knot, chained. On host that is the right program — a few fused
# broadcasts over a 2–3 knot table. Under a trace it is O(table) traced OPS PER
# CALL SITE, so a component that interpolates over tables of a few thousand
# entries emits a program dominated by `select`/`compare` scaffolding rather
# than arithmetic, and XLA compile can exhaust host memory.
#
# XLA has the constant-time primitive the ladder is emulating. "Index a constant
# table by a computed integer index" is `stablehlo.gather`; "count how many knots
# are ≤ the query" is a `compare` against a constant knot ROW plus one `reduce`.
# Both are O(1) ops in the TABLE, so the emitted program stops depending on the
# table size at all.
#
# BIT-IDENTITY, which is the acceptance bar (test/interp_lanes_test.jl pins the
# lane forms against the scalar `_interp_*_core` kernels over dense query sweeps
# including both clamps and NaN):
#
#   * COUNT. The ladder sums 0.0/1.0 terms left to right; `sum` over the same
#     terms reassociates. Every term is 0.0 or 1.0 and n ≪ 2^53, so every partial
#     sum is an exactly-representable integer and the result is INDEPENDENT of
#     association order. NaN queries fail every compare in both forms and
#     contribute 0.0 in both.
#   * GATHER. The ladder SELECTS `v[k]` when `i == k` — it never blends — so the
#     table entry arrives bit-exact; a gather returns the same stored double.
#     Identical for ±0.0, subnormals, Inf and NaN table entries alike. The index
#     is produced by the callers' `min(max(count,1), n-1)` clamp, so it is an
#     exactly-integral Float64 in `[1, n-1]` and `stablehlo.convert` to i64
#     (round-toward-zero) is exact; the gather is therefore always in bounds and
#     never takes XLA's out-of-bounds clamping path.
#   * The blend, the query clamps and the NaN handling are untouched — they live
#     in the shared lane evaluators, not in these seams.
#
# Both knot SHAPES are served: a `Vector{Float64}` (one table shared by every
# lane) becomes a flat constant indexed by `k` directly; a
# `Vector{Vector{Float64}}` / `Matrix{Vector{Float64}}` of lane COLUMNS (the
# kernel-class merge's `_Interp*LaneSpec`, one table per lane) becomes the same
# flat constant in knot-major order, indexed by `(k-1)*D + gid[lane]` against a
# constant lane→group map — so the merged path gets the identical O(1) lowering,
# with lane `l` still reading only its own table. `D` is the number of DISTINCT
# lane tables rather than the lane count; see the lane-dedup section for why
# that difference is what keeps the constant off the grid size.

const _RxIdx = Union{TracedRArray{<:Any,1},TracedRNumber}
const _RxKnots = Union{Vector{Float64},Vector{Vector{Float64}}}
const _RxTbl = Union{Vector{Vector{Float64}},Matrix{Vector{Float64}}}

# --- lane-shape plumbing (host-side, trace time only) -------------------------
#
# Two independent "does this have a lane axis" questions: the QUERY (a lane
# vector, or one invariant scalar) and the TABLE (shared by every lane, or one
# column per lane). `0` means "no lane axis of its own"; the result carries a
# lane axis iff either does, and when neither does the gather runs at length 1
# and is unwrapped back to a traced scalar.
@inline _rx_len(x::TracedRArray{<:Any,1}) = length(x)
@inline _rx_len(::TracedRNumber) = 0
@inline _rx_cols(::Vector{Float64}) = 0
@inline _rx_cols(v::Vector{Vector{Float64}}) = length(v[1])
@inline _rx_tbl_cols(::Vector{Vector{Float64}}) = 0
@inline _rx_tbl_cols(t::Matrix{Vector{Float64}}) = length(t[1, 1])

@inline _rx_vec(x::TracedRArray{<:Any,1}, ::Int) = x
@inline _rx_vec(x::TracedRNumber, n::Int) = Reactant.broadcast_to_size(x, (n,))
@inline _rx_unwrap(r::AbstractVector, L::Int) = L == 0 ? (@allowscalar r[1]) : r

# f64 lane index (exactly integral and in `[1, n-1]` by the callers' clamp) → i64.
@inline _rx_int(i::TracedRArray{T,1}) where {T} =
    Reactant.Ops.convert(TracedRArray{Int64,1}, i)

# ONE `stablehlo.gather` of a constant table at 1-based traced indices.
# `Ops.constant` memoizes by value, so N call sites sharing a table share one
# constant in the module.
@inline _rx_take(vals::Vector{Float64}, lin::TracedRArray{Int64,1}) =
    Reactant.Ops.gather_getindex(Reactant.Ops.constant(vals),
                                 Reactant.Ops.reshape(lin, length(lin), 1))

# --- lane dedup ---------------------------------------------------------------
#
# WHY THIS EXISTS. The kernel-class merge tables one spec PER LANE, and a lane
# is (cell × member): merging Fast-JX's 18 actinic-flux bands over a grid gives
# `L = 18 · ncells` lanes. But the bands' tables do not vary with the cell —
# there are 18 DISTINCT tables and `ncells` copies of each. Materialising one
# copy per lane makes the emitted XLA constant scale with the GRID, which is
# precisely the property a compiled program must not have — on a real grid it
# exceeds the size of constant Reactant is willing to emit at all. Keying lanes by
# VALUE makes the constant scale with the number of DISTINCT tables, a property of
# the document rather than of the domain, so it stays flat at every grid.
#
# Grouping is by `isequal` (what `Dict` uses), NOT `==`: it separates `-0.0`
# from `0.0` and unifies `NaN` with `NaN`, so two lanes share a slot only when
# their tables agree BITWISE. Merging is therefore value-preserving by
# construction, and when no two lanes agree the groups degenerate to
# `gid[l] = l` and the emitted constant is byte-for-byte the old one.
#
# RELATION TO BUILD-TIME INTERNING (tree_walk/acc_merge.jl `_lane_intern`).
# Since the lane-table intern pool landed, content-equal `_Interp*Spec`s are
# already the SAME object (`===`) in `h.specs` when these seams run — sharing
# now exists in the build product, not just in the trace. This grouping stays
# anyway, and deliberately so: it is PER COLUMN COLLECTION (the axis columns
# group independently of the table columns), which is strictly FINER than the
# spec-level identity the pool provides — Fast-JX's 18 bands hold 18 distinct
# SPECS but ONE shared axis, so the axis constant dedupes to D = 1 here where
# a spec-identity key would stop at D = 18. The seams also only ever see the
# knot COLUMNS, not `h`, so spec identity is not even observable here. What
# interning did retire is the last O(lanes) constant these seams could not
# reach: the clamp/edge boundary columns are collapsed to scalars host-side by
# `_lane_bound` (interp_lanes.jl) before the broadcast, so they never arrive at all.
#
# Returns (reps, gid): `reps[g]` is a lane index witnessing group `g`, and
# `gid[l]` is lane `l`'s group. Host-side, trace time only.
function _rx_lane_groups(cols::AbstractArray{Vector{Float64}})
    L = length(first(cols))
    n = length(cols)
    key = Vector{Float64}(undef, n)
    ids = Dict{Vector{Float64},Int}()
    gid = Vector{Int64}(undef, L)
    reps = Int[]
    @inbounds for l in 1:L
        q = 0
        for c in cols
            key[q += 1] = c[l]
        end
        g = get(ids, key, 0)
        if g == 0
            g = length(reps) + 1
            ids[copy(key)] = g
            push!(reps, l)
        end
        gid[l] = g
    end
    return reps, gid
end

# The two knot shapes, as (flat host constant, knot index → linear index, the
# stride from one knot to the next). Knot-major, deduplicated across lanes.
@inline _rx_knot_lin(v::Vector{Float64}, ik::TracedRArray{Int64,1}) = (v, ik, 1)
function _rx_knot_lin(v::Vector{Vector{Float64}}, ik::TracedRArray{Int64,1})
    reps, gid = _rx_lane_groups(v)
    D = length(reps); n = length(v)
    flat = Vector{Float64}(undef, n * D)
    @inbounds for k in 1:n, g in 1:D
        flat[(k - 1) * D + g] = v[k][reps[g]]
    end
    return flat, (ik .- Int64(1)) .* Int64(D) .+ Reactant.Ops.constant(gid), D
end

# The constant the count compares against: a 1×n knot ROW when one table is
# shared, an L×n knot MATRIX when each lane owns one.
#
# `Lq` is the QUERY's lane count. Collapsing per-lane knots that are all equal
# to a single row is only sound when the query itself carries the lane axis —
# the L×n compare matrix is otherwise the only thing giving the result its L
# rows, and a 1×n row against a 1×1 query would silently return one lane where
# the caller unwraps L.
_rx_knot_matrix(v::Vector{Float64}, ::Int) = reshape(copy(v), 1, length(v))
function _rx_knot_matrix(v::Vector{Vector{Float64}}, Lq::Int)
    L = length(v[1])
    if Lq == L
        reps, _ = _rx_lane_groups(v)
        if length(reps) == 1
            r = reps[1]
            return reshape(Float64[v[k][r] for k in eachindex(v)], 1, length(v))
        end
    end
    M = Matrix{Float64}(undef, L, length(v))
    @inbounds for k in eachindex(v), l in 1:L
        M[l, k] = v[k][l]
    end
    return M
end

# The bilinear table as one flat constant + the (i,j) → linear-index map, and
# the strides that step to the neighbouring corner along each axis.
function _rx_tbl_lin(t::Vector{Vector{Float64}}, ii, jj, Nx::Int, Ny::Int)
    flat = Vector{Float64}(undef, Nx * Ny)
    @inbounds for k in 1:Nx, l in 1:Ny
        flat[(k - 1) * Ny + l] = t[k][l]
    end
    return flat, (ii .- Int64(1)) .* Int64(Ny) .+ jj, Ny, 1
end
function _rx_tbl_lin(t::Matrix{Vector{Float64}}, ii, jj, Nx::Int, Ny::Int)
    reps, gid = _rx_lane_groups(t)
    D = length(reps)
    flat = Vector{Float64}(undef, Nx * Ny * D)
    @inbounds for k in 1:Nx, l in 1:Ny
        col = t[k, l]
        base = ((k - 1) * Ny + (l - 1)) * D
        for m in 1:D
            flat[base + m] = col[reps[m]]
        end
    end
    lane = Reactant.Ops.constant(gid)
    lin = ((ii .- Int64(1)) .* Int64(Ny) .+ (jj .- Int64(1))) .* Int64(D) .+ lane
    return flat, lin, Ny * D, D
end

# --- the three seams ----------------------------------------------------------

# count-locate: `Σ_k [cmp(knots[k], q)]`, WITHOUT a `stablehlo.reduce`.
#
# WHY NOT THE REDUCE. The obvious lowering — broadcast the knot row against the
# query column, select 1.0/0.0, `reduce` along the knot axis — is five ops and was
# the first thing here. Locating elementwise instead has measured faster on the one
# real chemistry mechanism it was compared on, bit-exact against the reduce form,
# for a small increase in emitted ops. That is the whole case for this seam.
#
# It is NOT a fusion-boundary argument. An earlier version of this comment claimed
# reductions were hard fusion boundaries whose removal would collapse the step's
# fusion count; removing every locate reduction moved it by ~2%. Do not cite that
# model here, and do not extend this seam on its strength.
#
# So the count is computed elementwise instead, in one of three tiers. All three
# return the SAME Float64 lane value as the ladder in `tree_walk/interp_lanes.jl` — the
# terms are 0.0/1.0 and `n ≪ 2^53`, so every association order is exact, and the
# tiers below only ever ADD exact small integers.
#
#   LADDER (n ≤ `ESS_RX_LOCATE_LADDER_MAX`, default 8). Emit the host chain
#     verbatim: `n` compares against knot CONSTANTS, `n` selects, `n-1` adds.
#     Bit-identical by construction — it IS the reference expression. This is
#     not the O(table) ladder the seam header forbids: it is CAPPED at a few
#     knots. It is also what most real call sites want — photolysis mechanisms
#     interpolate the great majority of their cross-sections and quantum yields
#     over a 2- or 3-point temperature axis, where a reduce reduces two elements.
#
#   AFFINE (larger `n`, when a host-time fit succeeds). A uniform axis locates
#     arithmetically: `g = floor(q·a + b)` is the index, in ~7 elementwise ops,
#     no gather and no reduce. But `g` is NOT exact — for the Fast-JX flux
#     table's `-0.2 : 0.02 : 1.0` axis, `a = 50, b = 11` gives
#     `fl(fl(-0.2·50) + 11) = 0.999999999999998`, so a query sitting exactly ON
#     a knot lands one cell low, and the linear blend then returns
#     `t_{k-1} + 1·(t_k − t_{k-1})` where the reference returns `t_k` — equal in
#     real arithmetic, not in Float64. No choice of `(a, b)` fixes this in
#     general: the map would have to send every knot to an integer EXACTLY, and
#     the neighbouring float to strictly below it, which asks a rounding error
#     of ~1e-16·k to fall the right way n times over.
#
#     So the affine step is used only as a GUESS, and corrected by comparing
#     against the one real knot above it — a single gather of a constant table,
#     which this file already uses for the other two seams. Writing `P(k)` for
#     `cmp(knots[k], q)`, which for a sorted axis is TRUE exactly on the prefix
#     `k ≤ c` (that is the definition of the count `c`, under either `cmp`
#     sense), and `gm = clamp(g, 0, n-1)`:
#
#         c = gm + [P(gm + 1)]
#
#     is EXACT — no guards, at either end — provided the guess `g` (clamped to
#     [0, n]) satisfies the ONE-SIDED bound `0 ≤ c − g ≤ 1`, i.e. it never
#     overshoots and undershoots by at most one:
#       * `0 ≤ g ≤ n-1`, so `gm = g` and `c ∈ {g, g+1}`. `P(g+1)` holds iff
#         `c ≥ g+1`, which is precisely the `c = g+1` case.
#       * `g = n`, so `gm = n-1` and the bound forces `c = n` (`c ≤ n` always).
#         `P(n)` holds, giving `n-1 + 1`.
#     A NaN query is the `g = 0` case by construction (the select below), `P(1)`
#     fails, and the count is 0 — exactly what the ladder gives.
#
#     One-sidedness is what a downward BIAS in `b` buys: on the cell
#     `[knots[c], knots[c+1])` the exact affine map lands `t` in `[c, c+1)`, so
#     rounding can push `floor(t)` to `c+1` at the top of the cell. Subtracting
#     a δ that is huge next to the ~1e-15 rounding error and tiny next to 1
#     removes that side without introducing a second, and `floor(t)` lands on
#     `c` or `c-1`. Real axes so far take δ = 1e-9 or 0.
#
#     None of this is assumed. The bound is VERIFIED on the host, exhaustively,
#     at trace time: see `_rx_affine_ok`.
#
#   REDUCE (everything else, and `ESS_RX_LOCATE=reduce`). The original lowering,
#     kept as the documented fallback for a non-uniform axis too big for the
#     ladder. Nothing about it changed.
#
# `ESS_RX_LOCATE` forces a tier (`auto` | `reduce` | `ladder` | `affine`) for
# A/B measurement and as an escape hatch; `ESS_RX_LOCATE_LADDER_MAX` moves the
# ladder/affine cut. The tiers are observationally identical, so the only thing
# the switch can change is the emitted program.
_rx_locate_mode() = get(ENV, "ESS_RX_LOCATE", "auto")
_rx_ladder_max() = something(tryparse(Int, get(ENV, "ESS_RX_LOCATE_LADDER_MAX", "8")), 8)

# One knot's CONSTANT for the ladder: the scalar itself when the axis is shared,
# and the lane COLUMN when each lane owns a table — collapsed to its one scalar
# when every lane agrees BITWISE (`isequal`, the same key `_lane_bound` and
# the trace-time lane dedup group by), so a shared axis does not re-enter the
# module as an O(lanes) constant.
@inline _rx_knot_const(v::Vector{Float64}, k::Int) = @inbounds v[k]
function _rx_knot_const(v::Vector{Vector{Float64}}, k::Int)
    col = @inbounds v[k]
    @inbounds v1 = col[1]
    @inbounds for l in 2:length(col)
        isequal(col[l], v1) || return col
    end
    return v1
end

# LADDER tier: the reference chain, op for op.
function _rx_count_ladder(knots::_RxKnots, qv, cmp::F) where {F}
    cnt = ifelse.(cmp.(_rx_knot_const(knots, 1), qv), 1.0, 0.0)
    for k in 2:length(knots)
        cnt = cnt .+ ifelse.(cmp.(_rx_knot_const(knots, k), qv), 1.0, 0.0)
    end
    return cnt
end

# --- AFFINE tier: host-side fit and verification ------------------------------

# The guess the trace computes, evaluated on the HOST in the SAME order and with
# the SAME roundings (`fl(fl(q·a) + b)`, floor, then the [0, n] clamp), so what
# is verified is what is emitted.
@inline _rx_affine_guess(a::Float64, b::Float64, n::Int, q::Float64) =
    min(max(floor(q * a + b), 0.0), Float64(n))

_rx_count_ref(v::Vector{Float64}, q::Float64, cmp::F) where {F} =
    Float64(count(x -> cmp(x, q), v))

# Is `0 ≤ count(q) − guess(q) ≤ 1` for EVERY Float64 `q`? A finite check decides
# it. Both functions are monotone non-decreasing in `q` — the count obviously,
# the guess because `a > 0` and Float64 multiply, add, floor, min and max are
# all weakly order-preserving. A monotone step function is pinned by its
# plateaus, and every plateau of `count` (under either `cmp`) has its two
# endpoints in `P = ⋃_k {prevfloat(knots[k]), knots[k], nextfloat(knots[k])}`.
# So if the bound holds on `P`, then for any `q` in a plateau `[lo, hi] ⊆ P²`,
# `guess(lo) ≤ guess(q) ≤ guess(hi)` and `count(lo) = count(q) = count(hi)`
# sandwich `count(q) − guess(q)` between the two verified differences. The two
# unbounded plateaus are the clamp's: below `knots[1]` the count is 0 and the
# guess is pinned to 0 from both sides (≥ 0 by the clamp, ≤ 0 by the bound at
# `prevfloat(knots[1])`); above `knots[n]` the count is n and the guess is ≤ n
# by the clamp and ≥ n−1 by the bound at `nextfloat(knots[n])`.
function _rx_affine_ok(v::Vector{Float64}, a::Float64, b::Float64, cmp::F) where {F}
    (isfinite(a) && a > 0 && isfinite(b)) || return false
    n = length(v)
    n >= 2 || return false
    all(isfinite, v) || return false          # a NaN/Inf knot is not a staircase
    # The correction identity below needs `cmp(knots[k], q)` to be TRUE for a
    # prefix of `k` and false after — i.e. a sorted axis, which is what the
    # evaluators' own locate assumes ("largest k with axis[k] ≤ x"). Ties are
    # fine (the predicate reads the VALUE), reversals are not, so check rather
    # than assume: an unvalidated axis simply falls through to the reduce.
    issorted(v) || return false
    @inbounds for k in 1:n
        x = v[k]
        for q in (prevfloat(x), x, nextfloat(x))
            d = _rx_count_ref(v, q, cmp) - _rx_affine_guess(a, b, n, q)
            (0.0 <= d <= 1.0) || return false
        end
    end
    return true
end

# Candidate `(a, b)`: the three natural readings of "uniform spacing", each with
# the offset that puts knot k at k−1, less the downward bias δ that buys
# one-sidedness (see the tier's header). Ordered cheapest-assumption first; the
# whole search is a formality for a genuinely uniform axis and fails fast for
# anything else, and either way what decides is `_rx_affine_ok`, not this list.
function _rx_affine_fit(v::Vector{Float64}, cmp::F) where {F}
    n = length(v)
    (n >= 2 && isfinite(v[1]) && isfinite(v[n]) && v[n] > v[1]) || return nothing
    for a in ((n - 1) / (v[n] - v[1]), 1 / ((v[n] - v[1]) / (n - 1)), 1 / (v[2] - v[1]))
        (isfinite(a) && a > 0) || continue
        for delta in (0.0, 1e-9, 1e-6, 1e-12, 1e-3)
            b = (1.0 - v[1] * a) - delta
            _rx_affine_ok(v, a, b, cmp) && return (a, b)
        end
    end
    return nothing
end

# Lane-tabled knots: `(a, b)` is one pair of scalars, so EVERY distinct lane
# axis has to accept it. Distinct is `_rx_lane_groups`' key, so this is D fits,
# not L.
function _rx_affine_fit(v::Vector{Vector{Float64}}, cmp::F) where {F}
    reps, _ = _rx_lane_groups(v)
    axes = [Float64[v[k][r] for k in eachindex(v)] for r in reps]
    ab = _rx_affine_fit(axes[1], cmp)
    ab === nothing && return nothing
    for ax in axes
        _rx_affine_ok(ax, ab[1], ab[2], cmp) || return nothing
    end
    return ab
end

# AFFINE tier: guess, then correct against the one real knot above it.
function _rx_count_affine(knots::_RxKnots, qv, cmp::F, a::Float64, b::Float64) where {F}
    n = length(knots)
    # `gm = clamp(floor(q·a + b), 0, n-1)`, with NaN pinned to 0 so the gather
    # index is always in range (a NaN reaching `stablehlo.convert` would be
    # undefined) and the compare below fails, giving the ladder's count of 0.
    gm = min.(max.(floor.(qv .* a .+ b), 0.0), Float64(n - 1))
    gm = ifelse.(qv .== qv, gm, 0.0)
    flat, lin, _ = _rx_knot_lin(knots, _rx_int(gm .+ 1.0))
    return gm .+ ifelse.(cmp.(_rx_take(flat, lin), qv), 1.0, 0.0)   # knots[gm+1]
end

function _knot_count(knots::_RxKnots, q::_RxIdx, cmp::F) where {F}
    n = length(knots)
    L = max(_rx_cols(knots), _rx_len(q))
    mode = _rx_locate_mode()
    if mode != "reduce" && n >= 1
        qv = _rx_vec(q, max(L, 1))
        if n <= _rx_ladder_max() || mode == "ladder"
            return _rx_unwrap(_rx_count_ladder(knots, qv, cmp), L)
        end
        ab = _rx_affine_fit(knots, cmp)
        if ab !== nothing
            return _rx_unwrap(_rx_count_affine(knots, qv, cmp, ab[1], ab[2]), L)
        end
        mode == "affine" && return _rx_unwrap(_rx_count_ladder(knots, qv, cmp), L)
    end
    # Fallback: one compare against a constant knot row + one reduce.
    Lq = max(_rx_len(q), 1)
    K = Reactant.Ops.constant(_rx_knot_matrix(knots, Lq))     # (L|1) × n
    Q = reshape(_rx_vec(q, 1), (Lq, 1))                       # (L|1) × 1
    c = sum(ifelse.(cmp.(K, Q), 1.0, 0.0); dims = 2)          # (L|1) × 1
    s = Reactant.Ops.reshape(c, size(c, 1))
    return _rx_unwrap(s, L)
end

# knot pair: two gathers, independent of the table size.
function _knot_pair(v::_RxKnots, i::_RxIdx)
    L = max(_rx_cols(v), _rx_len(i))
    ik = _rx_int(_rx_vec(i, max(L, 1)))
    # One dedup pass serves both knots: the next knot is one stride on.
    flat, lin, dk = _rx_knot_lin(v, ik)
    return (_rx_unwrap(_rx_take(flat, lin), L),
            _rx_unwrap(_rx_take(flat, lin .+ Int64(dk)), L))
end

# Two tables at one index. The default fuses them to share the ladder's
# compares; with a gather there are no compares to share, so it is two pairs.
function _knot_pair2(a::_RxKnots, b::_RxKnots, i::_RxIdx)
    alo, ahi = _knot_pair(a, i)
    blo, bhi = _knot_pair(b, i)
    return alo, ahi, blo, bhi
end

# bilinear corners: four gathers of one flat table constant at
# `lin`, `lin+Δk`, `lin+Δl`, `lin+Δk+Δl` — no `Nx·Ny` cell ladder.
function _bilinear_corners(tbl::_RxTbl, i::_RxIdx, j::_RxIdx,
                               Nx::Int, Ny::Int)
    L = max(_rx_tbl_cols(tbl), _rx_len(i), _rx_len(j))
    n = max(L, 1)
    ii = _rx_int(_rx_vec(i, n)); jj = _rx_int(_rx_vec(j, n))
    flat, lin, dk, dl = _rx_tbl_lin(tbl, ii, jj, Nx, Ny)
    return (_rx_unwrap(_rx_take(flat, lin), L),
            _rx_unwrap(_rx_take(flat, lin .+ Int64(dk)), L),
            _rx_unwrap(_rx_take(flat, lin .+ Int64(dl)), L),
            _rx_unwrap(_rx_take(flat, lin .+ Int64(dk + dl)), L))
end
