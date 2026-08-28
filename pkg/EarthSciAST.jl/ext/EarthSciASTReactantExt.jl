"""
    EarthSciASTReactantExt

XLA tracing for the OUT-OF-PLACE RHS (`build_evaluator(model; form = :oop)`,
src/tree_walk/oop.jl), loaded automatically when `Reactant` is in the session.

UPSTREAM DEFECTS THIS EXTENSION WORKS AROUND are catalogued in UPSTREAM_ISSUES.md,
together with what each one unblocks here and what it does NOT. Read it before
adding a workaround, and before concluding that a cost centre is upstream's fault —
most of the compile cost seen so far has been emitter shape in THIS repository.

WHAT THIS EXTENSION IS. Methods on the SEAMS the out-of-place walker already routes
every state read, `du` write, interp knot read and emitted op through (the `import`
list below is the full set). Not a second evaluator: `@compile`ing `f` runs the SAME tree walk, on the SAME compiled IR, with
`TracedRNumber`/`TracedRArray` in place of `Float64`/`Vector{Float64}` — the walk
executes once, at TRACE time, and what XLA gets is the flat op graph it left behind.
That is the whole reason the emitter is eltype-generic and buffer-free; `f!` cannot
be traced at all, because it captures concrete `Vector{Float64}` scratch buffers (the
CSE prelude and the access kernels' `_AccCSE` tiers) and XLA has nothing to do with a
host buffer.

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
(pinned by test/reactant_oop_test.jl) — so the discrete-cadence model
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
    _oop_op, _oop_const, _oop_powlit, _oop_gvn_tally!,
    _read_param_data

# ---- Parameter reads (the vector `p` ABI) ------------------------------------
#
# The parameter half of the same story as the state read below, and the same
# answer. A vector `p` (`ComponentVector`, `Vector`) is unwrapped to its dense
# data by `_param_data` — for a traced `ComponentVector` that is a `TracedRArray`,
# and a bare `q[idx]` on one raises "Scalar indexing is disallowed" (indexing the
# ComponentVector itself is worse, an ambiguous `getindex`). Under
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
# WHY. Most `stablehlo.slice` ops in a raw (`optimize=false`) module are window
# reads of the emitter's flat extended state tensor `ue = [u ; zeros]` — one
# materialized array observed's whole cell block, re-read once per acc-kernel
# descriptor that mentions it — and most of those are exact `(operand, window)`
# duplicates. XLA is left to rediscover the duplication with
# `CSE<mlir::stablehlo::SliceOp>`, which is PAIRWISE over slice ops and therefore
# quadratic in their count, and that pattern dominates compile time on a large
# grid. Interning at emission means the duplicate is never created.
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
# memo holds is defined in the same block as every use of it. The deeper variant
# — hoisting `ue` windows to PROGRAM scope — is therefore declined here: it is
# exactly the cross-region case this bound excludes.
#
# NUMERICS. Reusing an SSA value for an identical read is a pure emission-time
# CSE. The reused value is the result of the op the duplicate would have emitted,
# with the same operand and the same window, so the consuming ops receive
# bit-identical inputs; the emitted program differs from the non-interned one
# only by the removal of ops with no other effect.

# `Dict` rather than `IdDict`: content-keyed on the slot vector is the point (the
# duplicate descriptors hold DIFFERENT `Vector{Int}` objects with equal
# contents), and `Dict` verifies the key with `isequal` on every hit. `Base`'s
# array hash is sub-linear, so a lookup is cheap even for a large window.
#
# The same object also carries the EMISSION value-numbering tables (ess-oop-gvn;
# see the seam block in tree_walk/oop.jl for why the key is emitted SSA values).
# `gvn == false` leaves them permanently empty.
struct _RxGatherMemo
    d::Dict{Tuple{UInt,Int,Vector{Int}},Any}
    check::Bool
    gvn::Bool                                    # emission value numbering on
    interning::Bool                              # (operand, window) read memo on
    native::Bool                                 # native-op emission on
    ops::Dict{Any,Any}                           # (opcode, T, operand value ids) -> value
    consts::Dict{Any,Any}                        # (T, source type, bit pattern) -> value
    reads::Dict{Tuple{UInt,Int,Int},Any}         # (operand value, len, index) -> value
end
_RxGatherMemo(check::Bool, gvn::Bool, interning::Bool, native::Bool) =
    _RxGatherMemo(Dict{Tuple{UInt,Int,Vector{Int}},Any}(), check, gvn, interning, native,
                  Dict{Any,Any}(), Dict{Any,Any}(),
                  Dict{Tuple{UInt,Int,Int},Any}())

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
    # VALUE NUMBERING AND NATIVE EMISSION DEFAULT OFF — opt in with
    # `ESS_OOP_GVN=1` / `ESS_OOP_NATIVE=1`. Both are bit-exact and both cut the
    # emitted op count, but fewer ops is the mechanism, not the goal: whether they
    # cut `@compile` wall time has not been established, and on-off comparisons so
    # far have not been consistent across programs. Until they are, the default
    # emitter stays what it was.
    gvn = get(ENV, "ESS_OOP_GVN", "0") != "0"
    nat = get(ENV, "ESS_OOP_NATIVE", "0") != "0"
    # THREE INDEPENDENT switches on one object: each of read interning, value
    # numbering and native emission can be declined on its own, so the object
    # itself is declined only when all three are off (which is the pre-feature
    # emitter, exactly).
    mode == "0" && !gvn && !nat && return nothing
    return _RxGatherMemo(mode == "2", gvn, mode != "0", nat)
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
    memo.interning || return _oop_gather(u, slots)
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

# ---- Emission value numbering (ess-oop-gvn) ---------------------------------
#
# The read memo above removes duplicate READS; this removes duplicate ops. The
# argument for why it is sound, why the key is emitted SSA values rather than
# AST nodes, and why scalar constants are the load-bearing case, is at the
# `_oop_op`/`_oop_const` seams in tree_walk/oop.jl. What lives here is the part
# that needs Reactant: what "the same value" means.
#
# VALUE IDENTITY. An operand's identity is its current MLIR SSA value plus its
# SHAPE — the same `.ref.ptr` handle `mlirValueEqual` compares, the same one the
# read memo keys on, and for the same reason (a `TracedRArray` is a mutable
# NAME for a value, so the Julia object is not it). The shape rides along
# because two results of different shape are never the same tensor, and it
# costs nothing to be explicit.
#
# AN OPERAND WITHOUT AN SSA VALUE DECLINES THE WHOLE OP. A host `Float64`, a
# frozen lane `Vector{Float64}` from an `_OopAccPlan`, a ghost `BitVector`: none
# has a value identity, and the tempting substitute — `objectid` — is exactly the
# unsound one, because those are MUTABLE host containers whose contents can
# differ between two calls with the same address. Rather than reason about which
# host arrays the build promises to freeze, an op with any such operand is
# emitted unmemoized. (Reactant already interns ARRAY constants by value in its
# own entry-block table, so the frozen lane vectors do not duplicate anyway; the
# ops CONSUMING them are the small residue this declines.)
@inline _rx_value_id(x::TracedRNumber) =
    UInt(Reactant.TracedUtils.get_mlir_data(x).ref.ptr)

@inline _rx_vid(x::TracedRArray) = (_rx_value_id(x), size(x))
@inline _rx_vid(x::TracedRNumber) = (_rx_value_id(x), ())
@inline _rx_vid(::Any) = nothing

# A `TracedRNumber` handle is rewrapped for the same reason a `TracedRArray` one
# is: a hit hands back a fresh name for the value, never the memo's own object.
@inline _rx_rewrap(v::TracedRNumber{T}) where {T} = TracedRNumber{T}(v.paths, v.mlir_data)

# ---- Native op emission (ess-oop-native) ------------------------------------
#
# WHY. A large share of the raw (`optimize=false`) op count is no-ops:
# `broadcast_in_dim`s whose input and output types are IDENTICAL, `transpose`s
# with identity permutation and identical types, and `constant`s nothing ever
# reads. They are not duplicates for CSE to find; they are scaffolding for XLA's
# canonicalizer to delete, and every pass in the pipeline walks them first.
#
# WHERE THEY COME FROM — Reactant's broadcast lowering, not this emitter's
# arithmetic:
#   * `Reactant.broadcast_to_size(::TracedRArray, rsize)` emits a
#     `broadcast_in_dim` UNCONDITIONALLY, including when `size(arg) == rsize`;
#   * `_copyto!` runs it over every argument, and `Broadcast.Extruded` runs it
#     TWICE (hence the `%b = broadcast_in_dim %a` pairs at identical type);
#   * `Base.materialize` is `copyto!(similar(bc), bc)`, and `similar` on a
#     traced array is `Ops.fill(0, shape)` — a `stablehlo.constant` that
#     `set_mlir_data!` then rebinds away from, leaving it dead;
#   * `promote_to`/`materialize_traced_array` contribute the identity
#     `transpose`.
# So one `a .+ b` over lanes costs ~6 ops where one is wanted.
#
# WHAT THIS DOES. For the four IEEE arithmetic primitives and negation — and
# ONLY those — emit the `stablehlo` op directly through `Reactant.Ops` when the
# operands are already traced values of the same element type and lane shape.
# `Ops.add(a, b)` builds exactly one operation over exactly those two operand
# values.
#
# WHY THE SET IS EXACTLY THESE FIVE, and stops there. `stablehlo.add`,
# `subtract`, `multiply`, `divide` and `negate` on `f64` ARE the IEEE-754
# operations Julia's `+ - * / -` are, on every input including subnormals,
# infinities and NaNs — so substituting them is bit-exact by definition. That is
# NOT true of the tempting next candidates: Julia's
# `max`/`min` propagate NaN and `stablehlo.maximum`/`minimum` are not specified
# to, and `^` has an integer-exponent fast path in Julia that `stablehlo.power`
# does not share. Those keep the broadcast path; the scaffolding they carry is
# the price of a guarantee, and they are a small share of the total anyway.
#
# THE FOLD ORDER IS THE LADDER'S. `_oop_op(:+)` folds LEFT — `((c1+c2)+c3)…` —
# and so does this, term for term, because association order is a numerical
# decision this tier is not allowed to make. Likewise the SCALAR/ARRAY SHAPE of
# every intermediate is preserved: a scalar pair stays a scalar op and a scalar
# is lifted to lane width only where broadcast would have lifted it, so neither
# the emitted widths nor the runtime work change.
#
# OUTCOME. Native emission cuts the RAW op count materially and leaves the
# OPTIMIZED count essentially unchanged — XLA is left holding the same program,
# which is the correctness signal this tier is supposed to produce. It composes
# with value numbering rather than subsuming it: GVN removes whole duplicate ops,
# this removes the scaffolding around the ops that remain. Whether the smaller raw
# program shortens `@compile` is the open question that keeps both OFF by default
# (see `_oop_new_memo`); `ESS_OOP_NATIVE=1` opts in, independently of the others.

@inline _rx_native_elt(::Type{Reactant.TracedRNumber{T0}}) where {T0} = T0
@inline _rx_native_elt(::Type) = nothing

# Every operand traced, of element type `T0`, and every ARRAY operand of the same
# length? Returns that lane length (0 = all scalars), or -1 for "not eligible".
function _rx_native_len(c::AbstractVector, ::Type{T0}) where {T0}
    L = 0
    @inbounds for i in eachindex(c)
        a = c[i]
        if a isa TracedRArray{T0,1}
            n = length(a)
            if L == 0
                L = n
            elseif L != n
                return -1
            end
        elseif !(a isa TracedRNumber{T0})
            return -1
        end
    end
    return L
end

# Lift a scalar to lane width — the one broadcast that is REAL work, so it is
# value-numbered like any other emitted op rather than repeated per use site.
function _rx_lift(a::TracedRNumber, L::Int, memo::_RxGatherMemo)
    L == 0 && return a
    memo.gvn || return Reactant.broadcast_to_size(a, (L,))
    key = (:_lift, L, _rx_value_id(a))
    hit = get(memo.ops, key, nothing)
    if hit !== nothing
        _oop_gvn_tally!(true)
        return _rx_rewrap(hit)
    end
    v = Reactant.broadcast_to_size(a, (L,))
    memo.ops[key] = v
    _oop_gvn_tally!(false)
    return v
end
@inline _rx_lift(a::TracedRArray, ::Int, ::_RxGatherMemo) = a

# One binary application, with exactly broadcast's shape behaviour: array-array
# and scalar-scalar stay at their own width, a mixed pair lifts the scalar.
@inline function _rx_bin(f::F, a, b, memo::_RxGatherMemo) where {F}
    if a isa TracedRArray && b isa TracedRNumber
        return f(a, _rx_lift(b, length(a), memo))
    elseif a isa TracedRNumber && b isa TracedRArray
        return f(_rx_lift(a, length(b), memo), b)
    else
        return f(a, b)
    end
end

# `nothing` means "not natively emittable" — the caller falls back to the shared
# broadcast ladder, which is the reference for every op this does not cover.
function _rx_native_op(op::Symbol, c::AbstractVector, ::Type{T},
                       memo::_RxGatherMemo) where {T}
    T0 = _rx_native_elt(T)
    T0 === nothing && return nothing
    n = length(c)
    n == 0 && return nothing
    L = _rx_native_len(c, T0)
    L < 0 && return nothing
    if op === :+ || op === :*
        n < 2 && return nothing
        f = op === :+ ? Reactant.Ops.add : Reactant.Ops.multiply
        r = _rx_bin(f, c[1], c[2], memo)
        @inbounds for i in 3:n
            r = _rx_bin(f, r, c[i], memo)
        end
        return r
    elseif op === :-
        n == 1 && return Reactant.Ops.negate(c[1])
        n == 2 && return _rx_bin(Reactant.Ops.subtract, c[1], c[2], memo)
        return nothing
    elseif op === :neg
        return n == 1 ? Reactant.Ops.negate(c[1]) : nothing
    elseif op === :/
        return n == 2 ? _rx_bin(Reactant.Ops.divide, c[1], c[2], memo) : nothing
    end
    return nothing
end

function _rx_op_ids(c::AbstractVector)
    n = length(c)
    ids = Vector{Any}(undef, n)
    @inbounds for i in 1:n
        v = _rx_vid(c[i])
        v === nothing && return nothing
        ids[i] = v
    end
    return ids
end

# One hash lookup per op, in place of XLA rediscovering the duplicate pairwise.
function _oop_op(op::Symbol, c::AbstractVector, ::Type{T}, memo::_RxGatherMemo) where {T}
    memo.gvn || return _rx_emit_op(op, c, T, memo)
    ids = _rx_op_ids(c)
    ids === nothing && return _rx_emit_op(op, c, T, memo)
    key = (op, T, ids)
    hit = get(memo.ops, key, nothing)
    if hit !== nothing
        _oop_gvn_tally!(true)
        return _rx_rewrap(hit)
    end
    v = _rx_emit_op(op, c, T, memo)
    memo.ops[key] = v
    _oop_gvn_tally!(false)
    return v
end

# The emission itself: native where it is provably the same IEEE operation,
# the shared broadcast ladder everywhere else.
@inline function _rx_emit_op(op::Symbol, c::AbstractVector, ::Type{T},
                             memo::_RxGatherMemo) where {T}
    if memo.native
        nat = _rx_native_op(op, c, T, memo)
        nat === nothing || return nat
    end
    return _oop_op(op, c, T)
end

# `x ^ <host literal>` (`_oop_pow`: a literal exponent deliberately stays a host
# `Float64`, which is a numerics decision, not an emission one). The exponent is
# therefore part of the KEY rather than an operand; its bit pattern, so that
# `-0.0` and `0.0` are the distinct constants they are.
function _oop_powlit(base, ex::Float64, memo::_RxGatherMemo)
    memo.gvn || return base .^ ex
    id = _rx_vid(base)
    id === nothing && return base .^ ex
    key = (:_powlit, reinterpret(UInt64, ex), Any[id])
    hit = get(memo.ops, key, nothing)
    if hit !== nothing
        _oop_gvn_tally!(true)
        return _rx_rewrap(hit)
    end
    v = base .^ ex
    memo.ops[key] = v
    _oop_gvn_tally!(false)
    return v
end

# ---- Scalar constants: the load-bearing case --------------------------------
#
# Reactant memoizes an ARRAY constant by value — `Ops.constant(::DenseArray)`
# keys a task-local table on the `DenseElementsAttribute` and hoists the op into
# the entry block — but a SCALAR constant takes `Ops.constant(::Number)` ->
# `Ops.fill` -> `stablehlo.constant`, unconditionally, with no table. So one
# numeric coefficient used at N sites arrives as N distinct SSA values, and that
# does not merely cost N-1 constant ops: it DEFEATS the cascade above, because
# `k .* x` at two sites then has different operand ids and neither the products
# nor anything above them can share.
#
# Keyed on the exact BIT PATTERN, so `0.0` and `-0.0` stay the different
# constants they are and no two distinct NaN payloads merge. The concrete source
# type is in the key too, so an `Int` 1 is never served for a `Float64` 1.0.
@inline _rx_cbits(x::Float64) = reinterpret(UInt64, x)
@inline _rx_cbits(x::Float32) = UInt64(reinterpret(UInt32, x))
@inline _rx_cbits(x::Int64)   = reinterpret(UInt64, x)
@inline _rx_cbits(x::Int32)   = UInt64(reinterpret(UInt32, x))
@inline _rx_cbits(x::Bool)    = UInt64(x)

const _RxConstable = Union{Float64,Float32,Int64,Int32,Bool}

# Anything else (a `TracedRNumber` parameter read, an irrational, a Dual) is
# passed straight through: `convert` is either free or not a constant emission.
@inline _oop_const(::Type{T}, x, memo::_RxGatherMemo) where {T} = convert(T, x)

function _oop_const(::Type{T}, x::_RxConstable, memo::_RxGatherMemo) where {T}
    memo.gvn || return convert(T, x)
    key = (:_const, T, typeof(x), _rx_cbits(x))
    hit = get(memo.consts, key, nothing)
    if hit !== nothing
        _oop_gvn_tally!(true)
        return _rx_rewrap(hit)
    end
    v = convert(T, x)
    memo.consts[key] = v
    _oop_gvn_tally!(false)
    return v
end

# ---- Scalar reads ------------------------------------------------------------
#
# `@allowscalar u[i]` traces to a slice + a reshape, so a repeated scalar read
# of one slot is TWO redundant ops. Keyed exactly as the window read is, with the
# window replaced by the single index.
function _oop_read_state(u::TracedRArray{T,1}, i::Int, memo::_RxGatherMemo) where {T}
    memo.gvn || return _oop_read_state(u, i)
    return _rx_read_memo(memo, u, i, () -> _oop_read_state(u, i))
end

function _oop_read_forcing(buf::TracedRArray{T,1}, i::Int, memo::_RxGatherMemo) where {T}
    memo.gvn || return _oop_read_forcing(buf, i)
    return _rx_read_memo(memo, buf, i, () -> _oop_read_forcing(buf, i))
end

function _rx_read_memo(memo::_RxGatherMemo, v::TracedRArray, i::Int, emit::F) where {F}
    key = (_rx_value_id(v), length(v), i)
    hit = get(memo.reads, key, nothing)
    if hit !== nothing
        _oop_gvn_tally!(true)
        return _rx_rewrap(hit)
    end
    r = emit()
    memo.reads[key] = r
    _oop_gvn_tally!(false)
    return r
end

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
# equal, so its whole template hoists into the kernel's invariant tier and the
# kernel evaluates to ONE `TracedRNumber`. A 1-D stencil hits this arm at both ends.
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
# `2·len` slice ops and `~4·len` constants PER LANE — dozens of ops per grid
# column, and once the per-cell scalar surface was lane-batched (ess-oop-batch),
# the only thing left in this emitter that still scaled with the grid.
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
# The default lowering of `interp.*`'s locate → gather → blend
# (src/tree_walk/oop.jl) is a branch-free SELECT LADDER: one `ifelse` per table
# knot, chained. On host that is the right program — a few fused broadcasts over a
# 2–3 knot table. Under a trace it is O(table) traced OPS PER CALL SITE, so a
# component that interpolates over tables of a few thousand entries emits a
# program dominated by `select`/`compare` scaffolding rather than arithmetic, and
# XLA compile can exhaust host memory.
#
# XLA has the constant-time primitive the ladder is emulating. "Index a constant
# table by a computed integer index" is `stablehlo.gather`; "count how many knots
# are ≤ the query" is a `compare` against a constant knot ROW plus one `reduce`.
# Both are O(1) ops in the TABLE, so the emitted program stops depending on the
# table size at all.
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
# return the SAME Float64 lane value as the ladder in `tree_walk/oop.jl` — the
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
# when every lane agrees BITWISE (`isequal`, the same key `_oop_lane_bound` and
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

function _oop_knot_count(knots::_RxKnots, q::_RxIdx, cmp::F) where {F}
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
