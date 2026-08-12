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
    _oop_knot_count, _oop_knot_pair, _oop_knot_pair2, _oop_bilinear_corners,
    _scan_lanes_oop, _ScanFold, _oop_new_memo, _oop_intern_tally!,
    _read_param_data

# ---- Parameter reads (the vector `p` ABI) ------------------------------------
#
# The parameter half of the same story as the state read below, and the same
# answer. A vector `p` (`ComponentVector`, `Vector`) is unwrapped to its dense
# data by `_param_data` — for a traced `ComponentVector` that is a `TracedRArray`,
# and a bare `q[idx]` on one raises "Scalar indexing is disallowed" (measured;
# indexing the ComponentVector itself is worse, an ambiguous `getindex`). Under
# `@allowscalar` it traces to a slice + reshape and yields the `TracedRNumber` the
# walker's `convert(T, …)` wants.
#
# The bound that makes `@allowscalar` a narrow assertion rather than a blanket
# opt-out is even tighter here than for the state: this fires O(#PARAMETERS) times
# per RHS — a fact of the DOCUMENT, not of the grid — so the emitted program size
# is untouched by N. Reading a whole parameter vector as one operand would be the
# alternative, and it is the wrong shape: parameters enter the RHS one scalar at a
# time, at nodes scattered through the expression tree.
@inline _read_param_data(d::TracedRArray{T,1}, idx::Int) where {T} =
    @allowscalar d[idx]

# ---- State reads -------------------------------------------------------------
#
# The scalar read. `u[i]` on a `TracedRArray` throws; under `@allowscalar` it traces
# to a slice + reshape and yields a `TracedRNumber`, which is what the walker's
# `convert(T, …)` wants. Returning a size-1 SLICE (`u[i:i]`) instead would broadcast
# correctly but is a `TracedRArray`, and `convert(TracedRNumber, ::TracedRArray)` is not
# a thing — so the scalar spine, not the lane axis, is where this method belongs.
@inline _oop_read_state(u::TracedRArray{T,1}, i::Int) where {T} = @allowscalar u[i]

# ---- Read interning: one op per (SSA value, window), per RHS call ------------
#
# The TWO-argument `_oop_gather` still needs no method: `u[slots]` on a
# `TracedRArray` with a host `Vector{Int}` already traces to the right op —
# Reactant's `getindex_linear` emits a `stablehlo.slice` when `slots` is a
# constant-stride run and a `stablehlo.gather` otherwise. The same applies to a
# forcing LANE read (`_AK_FORCING_BOX` / `_AK_ARR_TBL_BOX`): the walker routes it
# through `_oop_gather` over the traced buffers ARGUMENT. What DOES need a method
# is the three-argument form, because emitting the right op is not the same thing
# as emitting it once.
#
# THE MEASUREMENT. ReSEACT at 7x7x16, raw (`optimize=false`) HLO: 8,093
# `stablehlo.slice` ops over 3,165 distinct `(operand, window)` pairs — 4,928
# (60.9%) exact duplicates. 7,648 of the 8,093 are 784-element window reads of the
# emitter's flat extended state tensor `ue = [u ; zeros]`, i.e. one materialized
# array observed's whole cell block, re-read once per acc-kernel descriptor that
# mentions it: one chemistry RHS emits 478 slices over 123 distinct windows, and
# one window is sliced 1,392 times across the module. XLA is left to rediscover
# the duplication with `CSE<mlir::stablehlo::SliceOp>`, which is PAIRWISE over
# slice ops and therefore quadratic in their count; a `perf` profile of a stuck
# CONUS compile put ~50% of all CPU in that pattern and its
# `OperationEquivalence::isEquivalentTo` callees. Interning at emission means the
# duplicate is never created, so the quadratic pattern never sees it.
#
# WHY THE KEY IS SOUND — this is the safety-critical part, because a key
# collision returns the WRONG DATA silently.
#
#   * The container half of the key is the operand's CURRENT MLIR SSA VALUE, not
#     the Julia object. A `TracedRArray` is MUTABLE and `setindex!` rebinds its
#     `mlir_data` in place (Reactant `Indexing.jl`), so one Julia object holds
#     different values over its life — `objectid` would alias a pre-write read
#     onto a post-write one, which is exactly the catastrophic case. An SSA value,
#     by contrast, is immutable by construction: `%42` denotes one tensor of one
#     shape with one set of contents for the whole program. Two reads of the same
#     `(value, window)` are therefore the same tensor by definition, and
#     `_oop_scatter` moving the container on changes the key automatically.
#   * The window half is the slot vector ITSELF, compared by CONTENT. The memo is
#     a `Dict`, so a hash collision is resolved by `isequal` on the full vector —
#     the key is verified on every hit, and equal keys are equal windows because
#     `slots` is the complete description of what a gather reads. `length(u)` is
#     in the key too, so an entry can never be served to a differently-shaped
#     operand even in the presence of a stale pointer.
#   * Pointer reuse (ABA) is the one residual hazard: an SSA value's address is
#     the address of the defining op's result storage, so a FREED op could in
#     principle be replaced at the same address. Within one RHS invocation MLIR
#     ops are only ever appended — erasure and RAUW happen in the pass pipeline,
#     long after the trace has finished — so no op observed by this memo can be
#     freed while the memo is alive. Confining the memo to one invocation is what
#     makes that argument airtight, and `ESS_OOP_INTERN=2` re-checks the recorded
#     value against the live one on every hit (see `_rx_intern_check`).
#
# WHY ONE RHS INVOCATION IS ALSO THE LARGEST SOUND SCOPE. A driver may trace the
# RHS inside a `@trace for` body, which puts those ops in a nested MLIR REGION.
# A value defined in one region does not dominate a use outside it (or in a later
# one), so a memo that outlived the invocation could hand back a value the
# verifier rejects — or, across separate `@compile`s, a value from a dead module.
# The emitter itself opens no region inside one invocation, so every value the
# memo holds is defined in the same block as every use of it. The prior
# attribution's deeper variant ("hoist `ue` windows to program scope", 568 slices
# instead of 937) is therefore DECLINED here: it is exactly the cross-region case
# this bound excludes.
#
# NUMERICS. Reusing an SSA value for an identical read is a pure emission-time
# CSE. The reused value is the result of the op the duplicate would have emitted,
# with the same operand and the same window, so the consuming ops receive
# bit-identical inputs; the emitted program differs from the non-interned one
# only by the removal of ops with no other effect. This is the transformation
# `cse_slice` performs on the same module, moved from the compiler to the emitter.

# `Dict` rather than `IdDict`: content-keyed on the slot vector is the point (the
# duplicate descriptors hold DIFFERENT `Vector{Int}` objects with equal
# contents), and `Dict` verifies the key with `isequal` on every hit. `Base`'s
# array hash is sub-linear, so a lookup is cheap even for an 8,232-slot window.
struct _RxGatherMemo
    d::Dict{Tuple{UInt,Int,Vector{Int}},Any}
    check::Bool
end
_RxGatherMemo(check::Bool) = _RxGatherMemo(Dict{Tuple{UInt,Int,Vector{Int}},Any}(), check)

# The operand's current SSA value, as a raw address. `get_mlir_data` returns the
# `MLIR.IR.Value`; `.ref.ptr` is the `MlirValue` handle MLIR itself uses for
# identity (`mlirValueEqual` compares exactly this).
@inline _rx_value_id(u::TracedRArray) =
    UInt(Reactant.TracedUtils.get_mlir_data(u).ref.ptr)

# `ESS_OOP_INTERN`: `0` declines the memo entirely (the feature's kill switch,
# matching how `ESS_OOP_BATCH=0` declines lane batching); `2` additionally
# re-verifies each hit. Read once per RHS call, at trace time only.
function _oop_new_memo(u::TracedRArray{<:Any,1})
    mode = get(ENV, "ESS_OOP_INTERN", "1")
    mode == "0" && return nothing
    return _RxGatherMemo(mode == "2")
end

# The assertion mode. On a hit, re-derive the key from the LIVE operand and
# compare it to the one recorded when the entry was made, and check that the
# memoized result still has the window's length. It cannot catch a wrong ANSWER
# that a sound key already excludes; what it catches is the one thing the key
# argument above rests on — an SSA value having moved out from under an entry.
function _rx_intern_check(u::TracedRArray, slots::Vector{Int}, key, hit)
    k2 = (_rx_value_id(u), length(u), slots)
    (k2[1] == key[1] && k2[2] == key[2]) ||
        error("ESS_OOP_INTERN=2: memo key drifted for a live operand " *
              "($(key[1]) -> $(k2[1]), len $(key[2]) -> $(k2[2]))")
    (hit isa AbstractArray && length(hit) != length(slots)) &&
        error("ESS_OOP_INTERN=2: memoized read has length $(length(hit)) " *
              "for a $(length(slots))-slot window")
    return nothing
end

# A hit returns a FRESH handle onto the memoized SSA value rather than the same
# Julia object. No op is emitted (a `TracedRArray` is a name for a value, and
# this is the same value), and it keeps the one property the non-interned build
# had for free: two consumers of the same read never share a mutable wrapper, so
# a consumer that rebound its operand's `mlir_data` could not reach the other's.
# Nothing in this emitter does that today; the guard costs one small host
# allocation per hit and removes the whole class.
@inline _rx_rewrap(v::TracedRArray{T,N}) where {T,N} =
    TracedRArray{T,N}(v.paths, v.mlir_data, v.shape)
@inline _rx_rewrap(v) = v

function _oop_gather(u::TracedRArray{<:Any,1}, slots::Vector{Int},
                     memo::_RxGatherMemo)
    key = (_rx_value_id(u), length(u), slots)
    d = memo.d
    hit = get(d, key, nothing)
    if hit !== nothing
        memo.check && _rx_intern_check(u, slots, key, hit)
        _oop_intern_tally!(true)
        return _rx_rewrap(hit)
    end
    v = _oop_gather(u, slots)
    d[key] = v
    _oop_intern_tally!(false)
    return v
end

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

# ---- Prefix (cumulative) scans, one whole LEVEL at a time --------------------
#
# `_scan_lanes_oop` (src/tree_walk/scan.jl) walks lane × level and touches ONE
# element per step: a scalar read of `du`, a ⊕, a scalar write back. On host
# that is the right program — the accumulator stays in a register and nothing
# allocates. Under a trace it was the LAST O(grid) surface in this emitter, and
# by a wide margin. Each element costs a `dynamic_slice` + a
# `dynamic_update_slice` (each rewriting the WHOLE extended state tensor) + 4
# index constants + 2 reshapes + a broadcast, so the emitted program grows by
# `2·len` slice ops and `~4·len` constants PER LANE. Measured on ReSEACT at
# NLEV=16 — one exclusive scan of `len = 17` half levels, one lane per column,
# two traced RHS sites per SSPRK43 step — that is 34 `stablehlo.dynamic_slice`,
# 34 `stablehlo.dynamic_update_slice` and 140 `stablehlo.constant` per GRID
# COLUMN, i.e. 100% of what still scaled with the grid once the per-cell scalar
# surface was lane-batched (ess-oop-batch).
#
# The recurrence is sequential along the LEVEL axis only; lanes never read each
# other. So run it level-major: one whole-array gather of level `k` across every
# lane, one broadcast ⊕ into the running lane vector, one whole-array scatter
# back. `len` gathers + `len` scatters, INDEPENDENT of the number of lanes —
# the same "one whole-array op per structural step, never one per cell"
# discipline `_oop_scatter` above is written to.
#
# BIT-IDENTITY, which is the acceptance bar. Lane `l`'s accumulator visits
# exactly the same terms in the same ascending order, seeded from the same 0̄,
# and broadcasting is elementwise — so each lane's fold is the scalar loop's
# fold operation for operation, for all four ⊕ and both window kinds. Every
# term is read from the ORIGINAL `du`: in the scalar loop the read of level `k`
# precedes the write of level `k`, and a fold's slots are pairwise distinct
# state indices, so no read there ever observed a write either. Pinned over
# `+`/`*`/`max`/`min` × inclusive/exclusive against the scalar form.
#
# The seed is materialised as a length-`nlanes` CONSTANT rather than left as a
# host `Float64`: `combine(z::Float64, ::TracedRNumber)` resolves to a method
# that returns the host operand for `max`/`min` (a `max(-Inf, x) === -Inf` the
# scalar path silently emitted), which broadcasting against a real traced array
# does not do.
function _scan_lanes_oop(du::TracedRArray{T,1}, S::_ScanFold, combine::F) where {T,F}
    slots = S.slots
    len = S.len
    len >= 1 || return du
    nlanes = div(length(slots), len)
    nlanes >= 1 || return du
    # Level `k`'s slot across every lane — the scalar loop's `slots[(l-1)*len+k]`
    # read column-wise instead of row-wise. Host `Int`s, trace time only.
    lev = Vector{Vector{Int}}(undef, len)
    @inbounds for k in 1:len
        v = Vector{Int}(undef, nlanes)
        for l in 1:nlanes
            v[l] = slots[(l - 1) * len + k]
        end
        lev[k] = v
    end
    term = Vector{Any}(undef, len)
    @inbounds for k in 1:len
        term[k] = _oop_gather(du, lev[k])
    end
    zbar = Reactant.Ops.constant(fill(convert(T, S.zerobar), nlanes))
    out = Vector{Any}(undef, len)
    acc = combine.(zbar, term[1])
    if S.inclusive
        out[1] = acc
        @inbounds for k in 2:len
            acc = combine.(acc, term[k])
            out[k] = acc
        end
    else
        # Strict window: cell 1 is the empty reduction and takes 0̄ verbatim;
        # cell k emits the accumulation BEFORE its own term.
        out[1] = zbar
        @inbounds for k in 2:len
            out[k] = acc
            acc = combine.(acc, term[k])
        end
    end
    @inbounds for k in 1:len
        du = _oop_scatter(du, lev[k], out[k])
    end
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
