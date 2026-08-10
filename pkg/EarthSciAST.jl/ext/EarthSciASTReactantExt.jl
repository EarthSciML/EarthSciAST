"""
    EarthSciASTReactantExt

XLA tracing for the OUT-OF-PLACE RHS (`build_evaluator(model; form = :oop)`,
src/tree_walk/oop.jl), loaded automatically when `Reactant` is in the session.

WHAT THIS EXTENSION IS. Six methods on the five container SEAMS the out-of-place
walker already routes every state read and every `du` write through. Not a sixth
evaluator: `@compile`ing `f` runs the SAME tree walk, on the SAME compiled IR, with
`TracedRNumber`/`TracedRArray` in place of `Float64`/`Vector{Float64}` — the walk
executes once, at TRACE time, and what XLA gets is the flat op graph it left behind.
That is the whole reason the emitter is eltype-generic and buffer-free; `f!` cannot
be traced at all, because it captures a concrete `Vector{Float64}` scratch buffer per
`_VecNode` and XLA has nothing to do with a host buffer.

WHY THESE FIVE AND NOTHING ELSE. Everything in between — `_oop_op`'s broadcast ladder,
CSE, the semiring folds, the invariant hoist — is already legal StableHLO: broadcasting
`TracedRArray`s traces to elementwise ops, and `_oop_value_type` resolves to
`TracedRNumber{Float64}` on its own (`promote_type` over Reactant's number type does the
right thing), so `convert(T, literal)`, `zero(T)`, `one(T)` all trace. What is NOT legal
is exactly the container boundary:

  * SCALAR INDEXING of a traced array is REJECTED, not slow — Reactant errors with
    "Scalar indexing is disallowed" rather than silently emitting a per-element read.
    `_oop_read_state` / `_oop_store` are the only two places the walker does it, and
    both do it O(#scalar states) times (never O(#cells) — a lane axis goes through
    `_oop_gather`/`_oop_scatter`, which are whole-array ops and trace as-is). So
    `@allowscalar` here is a narrow, bounded assertion, not a blanket opt-out: it says
    "this index is on the scalar spine of the model", and the program size stays
    independent of the grid, which is the property the compiled IR exists to have.

  * The OUTPUT CONTAINER cannot come from `similar`. Under tracing
    `T === TracedRNumber{Float64}`, and `similar(u, T, n)` is a host `Vector` OF traced
    scalars — a Julia array holding trace handles, not a traced array. It has no MLIR
    value, so the trace has no output and the compile fails (or, worse, silently returns
    a constant). `_oop_du_zeros` takes the container from `Reactant.Ops.fill` instead.

LIVE FORCING BUFFERS ARE TRACED ARGUMENTS, NOT CAPTURES (B2). A live forcing
buffer (`param_arrays`, ess-14f.3; a `DiscreteMaterializer` cache is a `pgather`
entry by construction) is bound BY REFERENCE into `_NK_PARAM_GATHER` node payloads
and forcing acc descriptors. Under tracing a CAPTURED host array is a TRACE-TIME
CONSTANT: XLA bakes in whatever the buffer held at `@compile`, the discrete-cadence
refresh callback (src/data_refresh.jl) then writes the buffer in place, and the
compiled program does not see it — silently STALE forcing, no error, plausible
numbers. That defect was demonstrated, then fixed by moving the BINDING, not the
refresh model: the out-of-place RHS now carries an explicit-buffers form,
`rhs_with_buffers(f)(u, p, t, buffers)`, whose `buffers` container (see
`forcing_buffers` / `forcing_buffer_index`) arrives through the ARGUMENT LIST. An
array passed as an argument is a real XLA input, and `copyto!`-ing new values into
that same `ConcreteRArray` between calls IS seen by the already-compiled program
(measured, and pinned by test/reactant_oop_test.jl) — so the discrete-cadence model
survives compilation verbatim: one aliased buffer per forcing, refreshed in place at
each cadence boundary (`sync_forcing!` mirrors host → device inside the refresh
callback's `post_refresh` hook), no reallocation, no recompile. (Recompiling at each
boundary "works" and is the trap: silent, O(#boundaries) compiles, and a different
program at each one.)

The usage contract, then:

    fo   = build_evaluator(model; form = :oop, param_arrays = forcing)[1]
    dev  = map(ConcreteRArray, forcing_buffers(fo))
    xla  = @compile rhs_with_buffers(fo)(u_r, p_r, t_r, dev)
    # at each cadence boundary, after the host refresh:
    sync_forcing!(dev, forcing_buffers(fo))

`@compile`-ing the 3-ARG wrapper `fo(u, p, t)` over a live-forcing model still
REFUSES (audit J5): the wrapper forwards its captured HOST buffers, which is
exactly the silent-staleness configuration, so the walk throws
`E_TREEWALK_XLA_LIVE_FORCING` during the trace rather than bake them in. A model
with no `param_arrays` compiles through the 3-arg wrapper as before.
"""
module EarthSciASTReactantExt

using Reactant: Reactant, TracedRArray, TracedRNumber, @allowscalar

import EarthSciAST: _oop_read_state, _oop_gather, _oop_du_zeros, _oop_store,
    _oop_scatter, _oop_read_forcing, _oop_prefix_copy,
    _oop_knot_count, _oop_knot_pair, _oop_knot_pair2, _oop_bilinear_corners

# ---- State reads -------------------------------------------------------------
#
# The scalar read. `u[i]` on a `TracedRArray` throws; under `@allowscalar` it traces
# to a slice + reshape and yields a `TracedRNumber`, which is what the walker's
# `convert(T, …)` wants. Returning a size-1 SLICE (`u[i:i]`) instead would broadcast
# correctly but is a `TracedRArray`, and `convert(TracedRNumber, ::TracedRArray)` is not
# a thing — so the scalar spine, not the lane axis, is where this method belongs.
@inline _oop_read_state(u::TracedRArray{T,1}, i::Int) where {T} = @allowscalar u[i]

# `_oop_gather` needs no method: `u[slots]` on a `TracedRArray` with a host
# `Vector{Int}` already traces to a whole-array gather (XLA then canonicalizes a
# contiguous run to a slice on its own). It is here as an explicit note so that the
# absence of a method reads as a decision rather than an oversight. The same
# applies to a forcing LANE read (`_AK_FORCING_BOX` / `_AK_ARR_TBL_BOX`): the
# walker routes it through `_oop_gather` over the traced buffers ARGUMENT.

# The scalar read of a live forcing buffer passed as a traced argument
# (`_NK_PARAM_GATHER` / `_AK_ARR_FIXED`). Same bounded-scalar-indexing argument
# as `_oop_read_state`: O(#scalar forcing reads), never O(#cells) — a forcing
# lane axis goes through `_oop_gather`, a whole-array op.
@inline _oop_read_forcing(buf::TracedRArray{T,1}, i::Int) where {T} =
    @allowscalar buf[i]

# ---- Output container --------------------------------------------------------
#
# `Ops.fill` builds a genuine `TracedRArray` of the state length. `T0` (the UNWRAPPED
# element type) is recovered from `u`, so a Float32 trace produces a Float32 `du`
# rather than silently widening.
@inline _oop_du_zeros(u::TracedRArray{T0,1}, ::Type{TracedRNumber{T0}},
                      n::Int) where {T0} = Reactant.Ops.fill(zero(T0), (n,))

# The materialized-observed prelude's state prefix. ONE traced concatenation, not
# `n` stores: the host default's `copyto!` walks elements, which both trips the
# scalar-indexing rejection and — if it were allowed — would put the STATE LENGTH
# into the XLA program, exactly the grid-dependence the compiled IR exists to
# avoid. `ue` is zero-filled by `_oop_du_zeros`, so the tail beyond `n` is the
# zeros the observed fills then overwrite, and concatenating reproduces it
# without reading `ue` at all.
@inline function _oop_prefix_copy(ue::TracedRArray{T0,1}, u::TracedRArray{T0,1},
                                  n::Int) where {T0}
    length(ue) == n && return u
    return vcat(u, @inbounds ue[(n + 1):length(ue)])
end

# One scalar equation's `du` slot. Same bounded-scalar-indexing argument as
# `_oop_read_state`; mutation of a `TracedRArray` is tracked by the trace, so the
# returned `du` is the same object and the seam's rebinding contract is trivially met.
@inline function _oop_store(du::TracedRArray{T,1}, i::Int, v) where {T}
    @allowscalar du[i] = v
    return du
end

# One array kernel's whole result, in ONE traced scatter. The default seam loops
# cell-by-cell; doing that here would emit `length(out)` scatter ops and make the
# XLA program's SIZE grow with the grid — the exact property the vectorized IR is
# built to avoid.
#
# The scalar `res` arm is NOT a corner case: a single-cell kernel group — which is
# what every ghost-boundary cell of a stencil becomes — has all of its lanes merge
# equal, so its whole template hoists to `_VK_INVARIANT` and the kernel evaluates to
# ONE `TracedRNumber`. A 1-D stencil therefore hits this arm on both ends of the grid.
#
# `fill(res, n)` (a host `Vector` of `n` copies of the one trace handle, which
# Reactant materializes as a traced array) rather than the obvious `du[out] .= res`:
# broadcasting a traced SCALAR into a `view` of a traced array routes through
# `_setindex_scalar_cartesian!` and throws the scalar-indexing error, and it does so
# only when `length(out) == 1` — i.e. exactly on the boundary kernels, and never on
# the interior one that a quick test would look at. Placing the value carries no
# arithmetic, so it cannot perturb the result the way a `res .+ zeros(n)` would.
@inline function _oop_scatter(du::TracedRArray{T,1}, out::Vector{Int}, res) where {T}
    du[out] = res isa AbstractArray ? res : fill(res, length(out))
    return du
end

# ---- interp knot addressing: a GATHER, not an O(table) select ladder ---------
#
# The sixth seam, and the one with the largest measured effect. The default
# lowering of `interp.*`'s locate → gather → blend (src/tree_walk/oop.jl) is a
# branch-free SELECT LADDER: one `ifelse` per table knot, chained. On host that
# is the right program — a few fused broadcasts over a 2–3 knot table. Under a
# trace it is O(table) traced OPS PER CALL SITE, and the constant is brutal:
# one `interp.bilinear` on a 61×23 table over 392 lanes emits 76,593 stablehlo
# ops (5,524 `select`, 2,806 `compare`, 1,319 `and`, plus scaffolding) and takes
# 74 s to trace. The ReSEACT Fast-JX component has 18 of them; across the
# operator-split window's traced RHS call sites that reached 21.4M ops and the
# XLA compile was OOM-killed at 30.4 GB, with >90% of the program being ladder
# scaffolding and <1% real arithmetic.
#
# XLA has the constant-time primitive the ladder is emulating. "Index a constant
# table by a computed integer index" is `stablehlo.gather`; "count how many knots
# are ≤ the query" is a `compare` against a constant knot ROW plus one `reduce`.
# Both are O(1) ops in the TABLE — the emitted program stops depending on the
# table size at all, and the 61×23 bilinear drops to ~400 ops (190×).
#
# BIT-IDENTITY, which is the acceptance bar (test/tree_walk_oop_test.jl pins the
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
# precisely the property a compiled program must not have: at 13×7×72 the
# 61×23 flux table reached 165,464,208 doubles = 1.32 GB and Reactant refused
# to emit it (its threshold is 100 MB). Keying lanes by VALUE makes the
# constant scale with the number of distinct tables — a property of the
# document, not of the domain: the same table falls to 25,254 doubles (193 KB)
# and stays there at every grid.
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
# `_oop_lane_bound` (oop.jl) before the broadcast, so they never arrive at all.
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

# count-locate: one compare against a constant knot row + one reduce.
function _oop_knot_count(knots::_RxKnots, q::_RxIdx, cmp::F) where {F}
    Lq = max(_rx_len(q), 1)
    K = Reactant.Ops.constant(_rx_knot_matrix(knots, Lq))     # (L|1) × n
    Q = reshape(_rx_vec(q, 1), (Lq, 1))                       # (L|1) × 1
    c = sum(ifelse.(cmp.(K, Q), 1.0, 0.0); dims = 2)          # (L|1) × 1
    s = Reactant.Ops.reshape(c, size(c, 1))
    return _rx_unwrap(s, max(_rx_cols(knots), _rx_len(q)))
end

# knot pair: two gathers, independent of the table size.
function _oop_knot_pair(v::_RxKnots, i::_RxIdx)
    L = max(_rx_cols(v), _rx_len(i))
    ik = _rx_int(_rx_vec(i, max(L, 1)))
    # One dedup pass serves both knots: the next knot is one stride on.
    flat, lin, dk = _rx_knot_lin(v, ik)
    return (_rx_unwrap(_rx_take(flat, lin), L),
            _rx_unwrap(_rx_take(flat, lin .+ Int64(dk)), L))
end

# Two tables at one index. The default fuses them to share the ladder's
# compares; with a gather there are no compares to share, so it is two pairs.
function _oop_knot_pair2(a::_RxKnots, b::_RxKnots, i::_RxIdx)
    alo, ahi = _oop_knot_pair(a, i)
    blo, bhi = _oop_knot_pair(b, i)
    return alo, ahi, blo, bhi
end

# bilinear corners: four gathers of one flat table constant at
# `lin`, `lin+Δk`, `lin+Δl`, `lin+Δk+Δl` — no `Nx·Ny` cell ladder.
function _oop_bilinear_corners(tbl::_RxTbl, i::_RxIdx, j::_RxIdx,
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

end # module
