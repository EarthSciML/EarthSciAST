# ========================================================================
# ext/reactant_knot_count.jl — the comparison count `Σ_k [cmp(knots[k], q)]`
# under a trace: an elementwise locate, not an O(table) select ladder.
# Included by ext/EarthSciASTReactantExt.jl.
# ========================================================================
#
# The default lowering of `_knot_count` (src/tree_walk/knot_count.jl) is a
# branch-free SELECT LADDER: one compare and one add per knot, chained. On host
# that is the right program. Under a trace it is O(table) traced OPS PER CALL
# SITE, so the comparison count the closed-AST templates lower to
# (ext/reactant_direct/closed.jl) over a table of a few thousand knots emits a
# program dominated by `select`/`compare` scaffolding rather than arithmetic.
#
# BIT-IDENTITY. The ladder sums 0.0/1.0 terms left to right; every term is 0.0
# or 1.0 and n ≪ 2^53, so every partial sum is an exactly-representable integer
# and the result is INDEPENDENT of association order. NaN queries fail every
# compare in every form and contribute 0.0.

const _RxIdx = Union{TracedRArray{<:Any, 1}, TracedRNumber}

# --- shape plumbing (host-side, trace time only) ------------------------------
#
# The query is a lane vector or one invariant scalar; `0` means "no lane axis
# of its own", and then the count runs at length 1 and is unwrapped back to a
# traced scalar.
@inline _rx_len(x::TracedRArray{<:Any, 1}) = length(x)
@inline _rx_len(::TracedRNumber) = 0

@inline _rx_vec(x::TracedRArray{<:Any, 1}, ::Int) = x
@inline _rx_vec(x::TracedRNumber, n::Int) = Reactant.broadcast_to_size(x, (n,))
@inline _rx_unwrap(r::AbstractVector, L::Int) = L == 0 ? (@allowscalar r[1]) : r

# f64 knot index (exactly integral and in range by the caller's clamp) → i64.
@inline _rx_int(i::TracedRArray{T, 1}) where {T} =
    Reactant.Ops.convert(TracedRArray{Int64, 1}, i)

# ONE `stablehlo.gather` of a constant table at 1-based traced indices.
# `Ops.constant` memoizes by value, so N call sites sharing a table share one
# constant in the module.
@inline _rx_take(vals::Vector{Float64}, lin::TracedRArray{Int64, 1}) =
    Reactant.Ops.gather_getindex(
    Reactant.Ops.constant(vals),
    Reactant.Ops.reshape(lin, length(lin), 1)
)

# The knot axis as (flat host constant, knot index → linear index).
@inline _rx_knot_lin(v::Vector{Float64}, ik::TracedRArray{Int64, 1}) = (v, ik)

# The constant the reduce tier compares against: a 1×n knot ROW.
_rx_knot_matrix(v::Vector{Float64}) = reshape(copy(v), 1, length(v))

# count-locate: `Σ_k [cmp(knots[k], q)]` computed elementwise, in one of three
# tiers, each returning the same Float64 as the ladder in
# `tree_walk/knot_count.jl` (the terms are 0.0/1.0 and n ≪ 2^53, so every sum is
# exact):
#
#   LADDER (n ≤ `locate_ladder_max`, default 8): the host chain verbatim, `n`
#     compares against knot constants, `n` selects, `n-1` adds.
#
#   AFFINE (larger n, when a host-time fit succeeds): a uniform axis guesses the
#     count as `g = floor(q·a + b)`, clamped to [0, n], then corrects it with one
#     gather of the knot above. With `P(k) = cmp(knots[k], q)`, true exactly for
#     `k ≤ c` on a sorted axis, and `gm = clamp(g, 0, n-1)`,
#
#         c = gm + [P(gm + 1)]
#
#     is exact provided `0 ≤ c − g ≤ 1` (the guess never overshoots and
#     undershoots by at most one). Floating-point rounding alone does not give
#     that (a query exactly on a knot can land one cell low or high), so `b` is
#     biased down by a δ far above the rounding error and far below 1, which
#     makes the error one-sided, and `_rx_affine_ok` verifies the bound
#     exhaustively on the host at trace time. A NaN query takes `g = 0` and
#     counts 0, as the ladder does.
#
#   REDUCE (everything else, and `locate = :reduce`): broadcast the knot row
#     against the query column, select 1.0/0.0, `reduce` along the knot axis.
#
# `DirectEmitOptions.locate` (`:auto` | `:reduce` | `:ladder` | `:affine`) picks the
# lowering and `locate_ladder_max` moves the ladder/affine cut (environment
# `ESS_RX_LOCATE`, `ESS_RX_LOCATE_LADDER_MAX`). The tiers are observationally
# identical compiled locates, so neither setting selects an evaluator or is a
# refusal boundary.

# LADDER tier: the reference chain, op for op.
function _rx_count_ladder(knots::Vector{Float64}, qv, cmp::F) where {F}
    cnt = ifelse.(cmp.(@inbounds(knots[1]), qv), 1.0, 0.0)
    for k in 2:length(knots)
        cnt = cnt .+ ifelse.(cmp.(@inbounds(knots[k]), qv), 1.0, 0.0)
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
        for delta in (0.0, 1.0e-9, 1.0e-6, 1.0e-12, 1.0e-3)
            b = (1.0 - v[1] * a) - delta
            _rx_affine_ok(v, a, b, cmp) && return (a, b)
        end
    end
    return nothing
end

# AFFINE tier: guess, then correct against the one real knot above it.
function _rx_count_affine(knots::Vector{Float64}, qv, cmp::F, a::Float64, b::Float64) where {F}
    n = length(knots)
    # `gm = clamp(floor(q·a + b), 0, n-1)`, with NaN pinned to 0 so the gather
    # index is always in range (a NaN reaching `stablehlo.convert` would be
    # undefined) and the compare below fails, giving the ladder's count of 0.
    gm = min.(max.(floor.(qv .* a .+ b), 0.0), Float64(n - 1))
    gm = ifelse.(qv .== qv, gm, 0.0)
    flat, lin = _rx_knot_lin(knots, _rx_int(gm .+ 1.0))
    return gm .+ ifelse.(cmp.(_rx_take(flat, lin), qv), 1.0, 0.0)   # knots[gm+1]
end

# A traced count outside a direct emission takes the options from `ENV`.
function _knot_count(knots::Vector{Float64}, q::_RxIdx, cmp::F) where {F}
    o = DirectEmitOptions(ENV)
    return _rx_knot_count(knots, q, cmp, o.locate, o.locate_ladder_max)
end

function _rx_knot_count(
        knots::Vector{Float64}, q::_RxIdx, cmp::F,
        mode::Symbol, ladder_max::Int
    ) where {F}
    n = length(knots)
    L = _rx_len(q)
    if mode !== :reduce && n >= 1
        qv = _rx_vec(q, max(L, 1))
        if n <= ladder_max || mode === :ladder
            return _rx_unwrap(_rx_count_ladder(knots, qv, cmp), L)
        end
        ab = _rx_affine_fit(knots, cmp)
        if ab !== nothing
            return _rx_unwrap(_rx_count_affine(knots, qv, cmp, ab[1], ab[2]), L)
        end
        mode === :affine && return _rx_unwrap(_rx_count_ladder(knots, qv, cmp), L)
    end
    # Fallback: one compare against a constant knot row + one reduce.
    Lq = max(_rx_len(q), 1)
    K = Reactant.Ops.constant(_rx_knot_matrix(knots))         # 1 × n
    Q = reshape(_rx_vec(q, 1), (Lq, 1))                       # (L|1) × 1
    c = sum(ifelse.(cmp.(K, Q), 1.0, 0.0); dims = 2)          # (L|1) × 1
    s = Reactant.Ops.reshape(c, size(c, 1))
    return _rx_unwrap(s, L)
end
