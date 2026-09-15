# ========================================================================
# ext/reactant_direct/values.jl — the value model of the direct StableHLO
# emitter: emitted values, the emission context, constants, shape plumbing,
# slot maps and the slice/concatenate/gather read forms.
# Included by ext/EarthSciASTReactantExt.jl through reactant_direct/mod.jl.
# ========================================================================

# ---- the emitted value -------------------------------------------------------
#
# Every emitted value is a rank-1 `tensor<Lxf64>`; a scalar is `L == 1`.
# Combining a scalar with a lane vector emits exactly one `broadcast_in_dim`
# (size-1 dim expansion), which is the only shape op the ladder ever needs.
struct _DEVal
    v::_MLIR.IR.Value
    len::Int
end

# Slot map entry: which emitted value holds this slot, and at which lane
# position. `nothing` ⇒ nothing has written the slot YET.
const _DESlot = Union{Nothing,Tuple{_DEVal,Int}}

# A slot map, plus the STATIC write plan the read forms need to interpret a
# `nothing` entry. `writer[s]` is the SECTION of the emission that first writes
# slot `s` (0 ⇒ no section writes it at all); sections are numbered in emission
# order — one per materialization level, then one for the state equations — and
# `_DE_SECTIONS` names them.
#
# The plan exists because a `nothing` entry means two different things, and only
# one of them is a bug. Both readings start from the same fact: the interpreter
# runs THESE units in THIS order over an extended vector that starts at zero
# (`_oop_du_zeros` allocates it fresh per call), so at any point in the walk an
# unwritten slot holds 0.0 on host.
#
#   A ZERO THIS SECTION IS ENTITLED TO — nothing writes the slot, or the only
#   writer is this same section, which has not reached the write yet. The
#   interpreter reads 0.0 there too, so the emitter must supply one. An
#   in-place prefix scan is the standing example: at each step it READS its own
#   slot and then overwrites it with the running accumulation, and the last step
#   of a lane reads a position no term kernel ever fills.
#
#   AN ORDERING VIOLATION — a LATER section writes the slot, i.e. a fill level
#   reads a level above it. The level plan is then wrong: the out-of-place
#   evaluator silently folds in a zero, the in-place one folds in the PREVIOUS
#   CALL's value out of its reused buffer, and the two stop agreeing. Refusing
#   is the right answer, and the message names the section that writes it.
#
# Built once by `_de_plan_writes!` before the walk, from the same plan data the
# walk consumes, so the two cannot disagree.
struct _DEMap
    m::Vector{_DESlot}
    writer::Vector{Int32}
end
_DEMap(n::Int) = _DEMap(Vector{_DESlot}(nothing, n), zeros(Int32, n))

function _de_mark!(M::_DEMap, slots, section::Int32)
    w = M.writer
    for s in slots
        (1 <= s <= length(w)) || continue
        @inbounds w[s] == 0 && (w[s] = section)
    end
    return nothing
end

# ---- where we are, for the error messages -----------------------------------
#
# The IR carries no provenance (`_Node` and `_AccKernel` have no name field), so
# the emitter keeps its own breadcrumb: the driver sets this to the state
# equation / fill level / access kernel it is about to emit, and every refusal
# reads it. Module-level because the refusal sites are leaves of a deep walk
# that would otherwise all have to thread a context they do not use; one
# emission runs to completion inside one `Reactant.@compile` trace on one task,
# and `_de_rule!` restores the previous value, so nesting is safe.
const _DE_RULE = Ref{String}("the right-hand side")

function _de_rule!(f::F, s::AbstractString) where {F}
    prev = _DE_RULE[]
    _DE_RULE[] = String(s)
    try
        return f()
    finally
        _DE_RULE[] = prev
    end
end

"""
    _de_refuse(construct, detail)

The emitter's ONE refusal. Hard by design: no interpreter fallback.
`construct` names the node kind / descriptor kind / kernel shape in the IR's own
vocabulary; the rule comes from `_DE_RULE`.
"""
_de_refuse(construct::AbstractString, detail::AbstractString) =
    throw(_E.DirectEmitError(construct, _DE_RULE[], detail))

# ---- the emission context ----------------------------------------------------

mutable struct _DECtx
    n_states::Int
    p::Any
    t::_DEVal
    ue::_DEMap                              # extended-state slot map (1..n_total)
    consts::Dict{UInt64,_DEVal}             # scalar literal bit pattern -> value
    arrconsts::Dict{Vector{Float64},_DEVal} # array constant content -> value
    # Live forcing buffers, threaded exactly as the interpreter's `_Forcing`
    # threads them: `hostkeys` are the build's aliased host arrays in the
    # container's order, `bufs` is THIS call's container (traced program inputs),
    # `bufvals` memoizes the emitted rank-1 view of each.
    bufs::Any
    hostkeys::Vector{Vector{Float64}}
    bufvals::Vector{Union{Nothing,_DEVal}}
    static::IdDict{_E._Node,Bool}           # memoized "this subtree is host-computable"
    bstatic::IdDict{Any,Bool}               # the same, for a lane-batched subtree
    reduce_min::Int                         # fold length at which a chain becomes a reduce
    names::Dict{Int,String}                 # flat slot -> element name (for the rule text)
    # Producer-set -> the one concatenation a cross-producer gather reads from,
    # so a read set that recurs (and on a stencil they all do) pays for it once.
    gather_bases::Dict{Tuple{Vector{_MLIR.IR.Value},Bool},Tuple{_DEVal,Vector{Int},Int}}
    # EMITTER-SIDE CSE OF READS. Two reads of the same span of the same value
    # are the same SSA value, and on a stencil that happens constantly: measured
    # on ReSEACT's transport half at 288 cells, the reverse-mode program was
    # emitted with 58,620 `stablehlo.slice` of which only 14,476 were DISTINCT —
    # one span appearing a hundred times. The pipeline does find them
    # (`cse_slice`), by comparing operations pairwise, which is quadratic in a
    # population three quarters of which the emitter knows to be redundant
    # before it writes it. Emission is one straight-line block, so an earlier
    # value always dominates a later use and the reuse needs no scope check.
    slices::Dict{Tuple{_MLIR.IR.Value,Int,Int,Int},_DEVal}
    concats::Dict{Vector{_MLIR.IR.Value},_DEVal}
    stats::Dict{Symbol,Int}
    # Which SECTION of the emission is running: materialization level `li` while
    # the fills are emitted, `nlev + 1` from the CSE prelude onwards. The read
    # forms compare it against the write plan (`_DEMap`) to tell a zero this
    # section is entitled to from a level read out of order.
    section::Int32
    # WHICH EMITTER SITE is running — the scalar spine, a fill level, an access
    # kernel, a scan, the output assembly. Purely a tally key for the read
    # attribution below; nothing reads it back and nothing branches on it.
    site::Symbol
end

function _DECtx(n_states::Int, n_total::Int, p, t::_DEVal, uval::_DEVal,
                bufs, hostkeys::Vector{Vector{Float64}}, names::Dict{Int,String})
    ue = _DEMap(n_total)
    for s in 1:n_states
        ue.m[s] = (uval, s)
    end
    return _DECtx(n_states, p, t, ue, Dict{UInt64,_DEVal}(),
                  Dict{Vector{Float64},_DEVal}(), bufs, hostkeys,
                  Union{Nothing,_DEVal}[nothing for _ in hostkeys],
                  IdDict{_E._Node,Bool}(), IdDict{Any,Bool}(),
                  _de_reduce_min(), names,
                  Dict{Tuple{Vector{_MLIR.IR.Value},Bool},
                       Tuple{_DEVal,Vector{Int},Int}}(),
                  Dict{Tuple{_MLIR.IR.Value,Int,Int,Int},_DEVal}(),
                  Dict{Vector{_MLIR.IR.Value},_DEVal}(),
                  Dict{Symbol,Int}(), Int32(0), :none)
end

# A ⊕-fold this long stops being a chain of binary ops and becomes ONE
# `stablehlo.reduce` (see `_de_fold_terms`). The chain is kept below the cut
# because it is bit-identical to the interpreter's left fold; the reduce is not
# (XLA may reassociate), which is why the cut exists at all and why it is
# tunable rather than hard-wired.
_de_reduce_min() =
    something(tryparse(Int, get(ENV, "ESM_DIRECT_EMIT_REDUCE_MIN", "32")), 32)

# Section names for the refusal text. Sections are numbered in emission order:
# `1 … nlev` are the materialization levels, `nlev + 1` is everything after them
# (the CSE prelude, the state equations, their kernels and their prefix scans),
# which writes only `du`. The vector is per-emission, set by `_de_plan_writes!`.
const _DE_SECTIONS = Ref{Vector{String}}(String[])
_de_sectionname(k::Integer) =
    (v = _DE_SECTIONS[]; 1 <= k <= length(v) ? v[k] : "emission section $k")

# Name a flat slot for an error message: the caller's `var_map` spelling when it
# passed one, the bare slot otherwise.
_de_slotname(ctx::_DECtx, s::Int) = get(ctx.names, s, "flat slot $s")

function _de_slotsname(ctx::_DECtx, slots::Vector{Int})
    isempty(slots) && return "no output slot"
    length(slots) == 1 && return _de_slotname(ctx, slots[1])
    return string(_de_slotname(ctx, slots[1]), " … ",
                  _de_slotname(ctx, slots[end]), " (", length(slots), " lanes)")
end

# ---- MLIR plumbing -----------------------------------------------------------

_de_loc() = _MLIR.IR.Location()
_de_ty(L::Int) = _MLIR.IR.TensorType(Int64[L], _MLIR.IR.Type(Float64))
_de_ty_i1(L::Int) = _MLIR.IR.TensorType(Int64[L], _MLIR.IR.Type(Bool))
_de_ty_i64(dims::Vector{Int}) = _MLIR.IR.TensorType(Int64.(dims), _MLIR.IR.Type(Int64))
_de_tally!(ctx::_DECtx, k::Symbol) = (ctx.stats[k] = get(ctx.stats, k, 0) + 1; nothing)

# READ ATTRIBUTION. Every emitted `slice` / `gather` / `concatenate` is tallied
# a second time under `<op>@<site>.<why>` — which EMITTER SITE was running and
# which read form asked for it. A flat total says a module carries N slices; it
# does not say whether they are a stencil's reads, a kernel's invariant scalars
# or the output assembly, and those need different fixes.
#
# THIS IS NOT DECORATION. The single-position slice was the op the
# post-differentiation `enzyme-hlo-opt` run is quadratic in, four levers had
# been spent against it, and the fifth was aimed at the scalar spine on the
# reasoning that a per-cell walk must be where one-element reads come from.
# Measured on ReSEACT's transport half at 288 cells, the scalar spine emitted
# NONE: 1,728 of the 2,869 slices in one right-hand side were `_de_assemble`'s,
# a surface that had its own run-walk and never reached the read cost model.
# Naming the site is what turned a plausible answer into the right one.
#
# `_de_at!` names the site; `_de_site!` charges an emitted op to it.
_de_at!(ctx::_DECtx, s::Symbol) = (ctx.site = s; nothing)
_de_site!(ctx::_DECtx, pre::Symbol, why::Symbol) =
    _de_tally!(ctx, Symbol(pre, "@", ctx.site, ".", why))
_de_res(op) = _MLIR.IR.result(op)

# `_DEVal` ↔ Reactant's traced array, for the two places that reuse Reactant's
# own op builders rather than building the op here: the `interp.*` knot seams
# (interp.jl) and the long-fold `stablehlo.reduce` (`_de_fold_terms`). Both are
# O(1) in the grid, so the program stays IR-shaped either way.
_de_traced(a::_DEVal) = TracedRArray{Float64,1}((), a.v, (a.len,))
_de_untraced(x::TracedRArray{Float64,1}) = _DEVal(x.mlir_data, length(x))
_de_untraced(x::TracedRNumber{Float64}) =
    _DEVal(_de_res(_hlo.reshape(x.mlir_data; result_0=_de_ty(1), location=_de_loc())), 1)

# ---- constants ---------------------------------------------------------------
#
# ONE constant per distinct literal (by bit pattern, so `-0.0` and `0.0` stay
# apart and two NaNs with different payloads stay apart), one per distinct array
# content.

function _de_const(ctx::_DECtx, x::Float64)::_DEVal
    key = reinterpret(UInt64, x)
    hit = get(ctx.consts, key, nothing)
    hit === nothing || return hit
    _de_tally!(ctx, :constant_scalar)
    op = _hlo.constant(; output=_de_ty(1),
                       value=_MLIR.IR.DenseElementsAttribute([x]), location=_de_loc())
    v = _DEVal(_de_res(op), 1)
    ctx.consts[key] = v
    return v
end

function _de_arrconst(ctx::_DECtx, xs::Vector{Float64})::_DEVal
    length(xs) == 1 && return _de_const(ctx, xs[1])
    hit = get(ctx.arrconsts, xs, nothing)
    hit === nothing || return hit
    _de_tally!(ctx, :constant_array)
    op = _hlo.constant(; output=_de_ty(length(xs)),
                       value=_MLIR.IR.DenseElementsAttribute(xs), location=_de_loc())
    v = _DEVal(_de_res(op), length(xs))
    ctx.arrconsts[copy(xs)] = v
    return v
end

function _de_boolconst(ctx::_DECtx, m::Vector{Bool})::_MLIR.IR.Value
    _de_tally!(ctx, :constant_mask)
    op = _hlo.constant(; output=_de_ty_i1(length(m)),
                       value=_MLIR.IR.DenseElementsAttribute(m), location=_de_loc())
    return _de_res(op)
end

# ---- shape plumbing ----------------------------------------------------------

function _de_bcast(ctx::_DECtx, a::_DEVal, L::Int)::_DEVal
    a.len == L && return a
    a.len == 1 || _de_refuse("a lane-width mismatch",
        "a value of length $(a.len) met lane width $L. The two came from the " *
        "same expression, so one of them was planned at a different lane " *
        "enumeration than the other — a kernel-plan invariant break, not a " *
        "coverage gap.")
    _de_tally!(ctx, :broadcast_in_dim)
    op = _hlo.broadcast_in_dim(a.v; result_0=_de_ty(L),
                               broadcast_dimensions=_MLIR.IR.DenseArrayAttribute(Int64[0]),
                               location=_de_loc())
    return _DEVal(_de_res(op), L)
end

function _de_slice(ctx::_DECtx, src::_DEVal, lo::Int, hi::Int, stride::Int=1;
                   why::Symbol=:other)::_DEVal
    L = length(lo:stride:hi)
    (L == src.len && lo == 1 && stride == 1) && return src
    key = (src.v, lo, hi, stride)
    hit = get(ctx.slices, key, nothing)
    hit === nothing || return hit
    _de_tally!(ctx, :slice)
    _de_site!(ctx, L == 1 ? :slice1 : :sliceN, why)
    op = _hlo.slice(src.v; result_0=_de_ty(L),
                    start_indices=_MLIR.IR.DenseArrayAttribute(Int64[lo - 1]),
                    limit_indices=_MLIR.IR.DenseArrayAttribute(Int64[hi]),
                    strides=_MLIR.IR.DenseArrayAttribute(Int64[stride]),
                    location=_de_loc())
    out = _DEVal(_de_res(op), L)
    ctx.slices[key] = out
    return out
end

function _de_concat(ctx::_DECtx, pieces::Vector{_DEVal})::_DEVal
    length(pieces) == 1 && return pieces[1]
    key = _MLIR.IR.Value[pc.v for pc in pieces]
    hit = get(ctx.concats, key, nothing)
    hit === nothing || return hit
    _de_tally!(ctx, :concatenate)
    _de_site!(ctx, :concat, :x)
    L = sum(pc.len for pc in pieces)
    op = _hlo.concatenate(key; result_0=_de_ty(L),
                          dimension=0, location=_de_loc())
    out = _DEVal(_de_res(op), L)
    ctx.concats[key] = out
    return out
end

# A true `stablehlo.gather` of `src` at 1-based `positions` — the form a read
# takes when its index vector shatters into more runs than slices are worth.
function _de_gather_op(ctx::_DECtx, src::_DEVal, positions::Vector{Int})::_DEVal
    _de_tally!(ctx, :gather)
    _de_site!(ctx, :gather, :x)
    L = length(positions)
    idx = reshape(Int64.(positions) .- 1, L, 1)
    idxop = _hlo.constant(; output=_de_ty_i64([L, 1]),
                          value=_MLIR.IR.DenseElementsAttribute(idx), location=_de_loc())
    dn = _MLIR.API.stablehloGatherDimensionNumbersGet(
        _MLIR.IR.current_context(),
        0, Int64[],          # offset_dims
        1, Int64[0],         # collapsed_slice_dims
        0, Int64[],          # operand_batching_dims
        0, Int64[],          # start_indices_batching_dims
        1, Int64[0],         # start_index_map
        1)                   # index_vector_dim
    op = _hlo.gather(src.v, _de_res(idxop); result=_de_ty(L), dimension_numbers=dn,
                     slice_sizes=_MLIR.IR.DenseArrayAttribute(Int64[1]),
                     indices_are_sorted=false, location=_de_loc())
    return _DEVal(_de_res(op), L)
end

# ---- reads: slices plus one concatenate, or one gather -----------------------
#
# The ONE read form, shared by every surface that reads a vector of positions:
# the extended-state slot map (materialized observeds and the raw state), a live
# forcing buffer, and a CSR reduce's body buffer. `srcs` is the read's positions
# already resolved to (producer value, position inside it).
#
# Decompose into (same producer, arithmetic-position) runs: one slice per run,
# one concatenate if there is more than one. That is the reference-preserving
# form — an affine run of slots costs one slice and no index data at all, where
# a dense gather costs an O(L) i64 constant. When the vector genuinely shatters
# (more runs than half its length, and not tiny) AND lies in one producer, a
# single gather is the cheaper program and is emitted instead.
#
# A `nothing` entry is a STRUCTURAL ZERO (see `_DEMap`): a run of them becomes
# one zero constant of that width, the same piece `_de_assemble` emits for an
# unwritten output run. A read that mixes them with real producers therefore
# still costs one piece per run and nothing per zero lane.
const _DESlotSrc = Union{Nothing,_DEVal}

# ---- the read cost model -----------------------------------------------------
#
# WHEN ONE GATHER BEATS A SLICE PER RUN. The slice path costs one op per run
# plus one concatenate, and no index data; a gather costs one op plus an O(n)
# i64 index constant (and, across producers, one concatenate of the producer
# values, which is cached). So the decision is the AVERAGE RUN LENGTH, and
# `_DE_RUN_WORTH` is the length at which they break even.
#
# THE RULE THIS REPLACES DECIDED SOMETHING ELSE. It asked whether the read had
# more runs than HALF its positions — an average run shorter than two — and it
# additionally required every run to lie in ONE producer and the read to contain
# no structural zero. Measured on ReSEACT's transport half at 288 cells, all
# three clauses missed: the PPM stencil's reads average two to four positions
# per run (so `> n ÷ 2` is false), and of the 506 reads that reach a
# concatenate, 241 are single-producer and 255 span TWO. The step therefore
# arrived at XLA as 55,117 slices, and the reverse-mode program as 1.82 MILLION.
# See reseact.esm's COMPILE_COST.md for the measurement.
#
# BOTH SIDES OF THE TRADE WERE MEASURED, on ReSEACT's two halves at 288 cells,
# and the gather wins both, which is why it is the default. The transport half's
# optimized module goes from 18,060 ops to 6,510, its per-call median from
# 3.3 ms to 1.9 ms, and the reverse-mode program the adjoint compiles becomes
# tractable at all. The chemistry half, whose reads are not shattered, emits ONE
# gather and is unchanged in every figure. `ESM_DIRECT_EMIT_READ=runs` restores
# the previous shape exactly, as the negative control and as the escape if a
# model is ever found where the concatenated base is the wrong trade.
#
# Neither setting changes a NUMBER: a gather of the same positions from the same
# values is bit-identical to slices-plus-concatenate of them.
#
# `ESM_DIRECT_EMIT_READ=always` is the third setting and it is a MEASUREMENT
# LEVER, not a recommendation: it gathers every read that decomposes into more
# than one run and lifts the base budget, which bounds from above what the read
# form can buy and tells a measurement whether a threshold or the base budget is
# the clause doing the declining.
const _DE_GATHER_MIN_PIECES = 8
const _DE_RUN_WORTH = 4

_de_read_mode() = get(ENV, "ESM_DIRECT_EMIT_READ", "gather")

function _de_gather_is_cheaper(npieces::Int, n::Int)
    mode = _de_read_mode()
    mode == "runs" && return false
    mode == "always" && return npieces > 1
    return npieces >= _DE_GATHER_MIN_PIECES && npieces * _DE_RUN_WORTH > n
end

# The base a cross-producer gather reads from: the DISTINCT producer values
# concatenated once, plus one zero element when the read carries structural
# zeros (a gather may read one position many times, so every zero lane points
# at that single element). Returns the base, the offset of each producer inside
# it, and the position of the zero — or `nothing` when the concatenate the base
# needs would copy more than `_DE_GATHER_BASE_MAX` elements.
#
# WHAT THE BASE COSTS IS THE COPY, AND ONLY ONCE. The base is cached on the
# emission context keyed by the producer set, so its concatenate is emitted once
# however many reads use it, and a base over ONE producer with no structural
# zero is not a concatenate at all — `_de_concat` of a single piece is that
# piece. The budget is therefore an absolute bound on the copy, charged only
# when a copy happens.
#
# CHARGING IT TO ONE READ IS WHAT THE FIRST VERSION DID, and on ReSEACT's
# transport half at 288 cells that declined the stencil's own base. 640 reads
# there share 37 distinct producer sets, and 240 of them read 432 positions in
# 168 to 312 runs out of TWO producers — the 3744-slot extended state beside a
# 2304-slot buffer, 6048 elements — which `max(8n, 4096)` refused at 4096.
# Three quarters of the slices the emitter still handed to Enzyme, 43,368 of
# 58,620, came from those 240 reads; see reseact.esm's COMPILE_COST.md for what
# they cost the reverse-mode compile.
# `ESM_DIRECT_GATHER_BASE_MAX` overrides the budget, and is the other half of
# the measurement lever: 4096 reproduces the shape the per-read rule produced on
# this model, which is the negative control the numbers above were measured
# against.
const _DE_GATHER_BASE_MAX = 1 << 16

function _de_gather_base_max()
    _de_read_mode() == "always" && return typemax(Int)
    v = get(ENV, "ESM_DIRECT_GATHER_BASE_MAX", "")
    return isempty(v) ? _DE_GATHER_BASE_MAX :
           something(tryparse(Int, v), _DE_GATHER_BASE_MAX)
end

# Pure, so the decision can be pinned by a test at sizes no fixture reaches.
_de_gather_base_fits(nprods::Int, needzero::Bool, tot::Int) =
    ((nprods == 1 && !needzero) ? 0 : tot) <= _de_gather_base_max()

function _de_gather_base(ctx::_DECtx, prods::Vector{_DEVal}, needzero::Bool)
    key = (_MLIR.IR.Value[q.v for q in prods], needzero)
    hit = get(ctx.gather_bases, key, nothing)
    hit === nothing || return hit
    tot = sum(q.len for q in prods) + (needzero ? 1 : 0)
    _de_gather_base_fits(length(prods), needzero, tot) || return nothing
    offs = Int[]
    acc = 0
    for q in prods
        push!(offs, acc)
        acc += q.len
    end
    pieces = copy(prods)
    zpos = 0
    if needzero
        push!(pieces, _de_const(ctx, 0.0))
        zpos = acc + 1
    end
    base = _de_concat(ctx, pieces)
    out = (base, offs, zpos)
    ctx.gather_bases[key] = out
    return out
end

function _de_runs_as_gather(ctx::_DECtx, srcs::Vector{_DESlot},
                            runs::Vector{Tuple{_DESlotSrc,Int,Int,Int}},
                            needzero::Bool)
    prods = _DEVal[]
    for r in runs
        sv = r[1]
        sv === nothing && continue
        any(q -> q.v == (sv::_DEVal).v, prods) || push!(prods, sv::_DEVal)
    end
    # All zeros: the slice path already emits exactly one constant for that.
    isempty(prods) && return nothing
    got = _de_gather_base(ctx, prods, needzero)
    got === nothing && return nothing
    base, offs, zpos = got
    pos = Vector{Int}(undef, length(srcs))
    for (i, e) in enumerate(srcs)
        if e === nothing
            pos[i] = zpos
        else
            sv, q = e::Tuple{_DEVal,Int}
            k = findfirst(x -> x.v == sv.v, prods)::Int
            pos[i] = offs[k] + q
        end
    end
    return _de_gather_op(ctx, base, pos)
end

function _de_emit_runs(ctx::_DECtx, srcs::Vector{_DESlot})::_DEVal
    n = length(srcs)
    n == 0 && _de_refuse("an empty read", "a read of zero positions reached the emitter.")
    # (src, lo, hi, stride); `src === nothing` ⇒ a zero run, `hi` its width.
    runs = Tuple{_DESlotSrc,Int,Int,Int}[]
    nzero = 0
    i = 1
    while i <= n
        e = srcs[i]
        if e === nothing
            j = i
            while j + 1 <= n && srcs[j + 1] === nothing
                j += 1
            end
            push!(runs, (nothing, 1, j - i + 1, 1))
            nzero += 1
            i = j + 1
            continue
        end
        sv, p0 = e::Tuple{_DEVal,Int}
        j = i
        stride = 1
        while j + 1 <= n
            nx = srcs[j + 1]
            nx === nothing && break
            nx[1].v == sv.v || break
            d = nx[2] - (srcs[j]::Tuple{_DEVal,Int})[2]
            if j == i
                d >= 1 || break
                stride = d
            elseif d != stride
                break
            end
            j += 1
        end
        push!(runs, (sv, p0, (srcs[j]::Tuple{_DEVal,Int})[2], stride))
        i = j + 1
    end
    if _de_gather_is_cheaper(length(runs), n)
        g = _de_runs_as_gather(ctx, srcs, runs, nzero > 0)
        g === nothing || return g
    end
    pieces = _DEVal[r[1] === nothing ? _de_arrconst(ctx, zeros(Float64, r[3])) :
                    _de_slice(ctx, r[1]::_DEVal, r[2], r[3], r[4]; why=:runs) for r in runs]
    return _de_concat(ctx, pieces)
end

# One value, many positions (a forcing buffer read, a CSR body read).
_de_take(ctx::_DECtx, src::_DEVal, positions::Vector{Int})::_DEVal =
    _de_emit_runs(ctx, _DESlot[(src, q) for q in positions])

# ---- slot-map reads and writes -----------------------------------------------
#
# `nothing` back from `_de_src` is a structural zero, NOT "no answer": the
# caller emits a zero of the right width. The refusal is kept for the one case
# that is genuinely an ordering bug — a slot a later unit writes.

# The `nothing` decision, factored out of `_de_src` so it is exercisable on its
# own. `nothing` back means "emit a zero here": either no section writes the
# slot at all, or the only writer is `section` itself, which is still running.
# A write by a LATER section is the ordering violation, and it refuses.
@inline function _de_unwritten(M::_DEMap, s::Int, section::Int32,
                               name::AbstractString)
    w = @inbounds M.writer[s]
    (w == 0 || w <= section) && return nothing
    _de_refuse("a read-before-write",
        "$name is read while emitting $(_de_sectionname(section)), and " *
        "$(_de_sectionname(w)) writes it LATER. The ordering must come from " *
        "the fill levels, which are supposed to guarantee that a level reads " *
        "only levels below it. On host the read takes whatever the extended " *
        "buffer holds at that point — a zero from the out-of-place runner's " *
        "fresh vector, the PREVIOUS CALL's value from the in-place runner's " *
        "reused one — so the two interpreters no longer agree either, and it " *
        "is the level plan that has to change.")
end

@inline function _de_src(ctx::_DECtx, M::_DEMap, s::Int)::_DESlot
    (1 <= s <= length(M.m)) || _de_refuse("a read outside the slot map",
        "slot $s is outside the extended state (length $(length(M.m))).")
    e = @inbounds M.m[s]
    e === nothing || return e
    return _de_unwritten(M, s, ctx.section, _de_slotname(ctx, s))
end

_de_read(ctx::_DECtx, M::_DEMap, s::Int, why::Symbol=:read1)::_DEVal =
    (e = _de_src(ctx, M, s); e === nothing ? _de_const(ctx, 0.0) :
                             _de_slice(ctx, e[1], e[2], e[2]; why=why))

_de_gather(ctx::_DECtx, M::_DEMap, slots::Vector{Int})::_DEVal =
    _de_emit_runs(ctx, _DESlot[_de_src(ctx, M, s) for s in slots])

function _de_write!(ctx::_DECtx, M::_DEMap, slots::Vector{Int}, val::_DEVal)
    m = M.m
    if val.len == 1
        for s in slots
            m[s] = (val, 1)
        end
    else
        val.len == length(slots) ||
            _de_refuse("a scatter of the wrong width",
                "a kernel result of length $(val.len) is scattered into " *
                "$(length(slots)) slots ($(_de_slotsname(ctx, slots))).")
        for (l, s) in enumerate(slots)
            m[s] = (val, l)
        end
    end
    return nothing
end

# Assemble a slot map into one rank-1 value: a READ of the whole map, at
# positions `1:n`, through the one read form every other surface uses.
#
# THIS USED TO BE ITS OWN RUN-WALK, and that is where most of the emitter's
# single-position slices came from. The output slot map of a stencil model is
# INTERLEAVED — a kernel's result value holds its own cells, and the next slot
# in ascending order usually belongs to a different value or to a different
# position inside the same one — so the "runs of consecutive positions in the
# same producer" a local walk can find are mostly runs of ONE, and each of those
# costs a `stablehlo.slice` of a single element. Measured on ReSEACT's transport
# half at 288 cells: 2,160 pieces over 3,744 slots, of which 1,728 were single
# positions — 60% of every slice the emitter wrote, and the largest block of the
# population the post-differentiation `cse_slice` pattern is quadratic in.
#
# There was never a reason for the output to decide this differently from every
# other read: `_de_emit_runs` decomposes the same positions into the same runs
# and then applies the COST MODEL to them — one gather when the map shatters,
# slices plus a concatenate when it does not, structural zeros folded into
# either. An unwritten slot is a `nothing` entry, which is exactly the
# structural zero the read form already knows how to carry.
_de_assemble(ctx::_DECtx, M::_DEMap, n::Int)::_DEVal =
    _de_emit_runs(ctx, _DESlot[@inbounds M.m[i] for i in 1:n])

# ---- live forcing buffers as program INPUTS ----------------------------------
#
# The compiled IR reaches a live forcing buffer by ALIAS: an `_NK_PARAM_GATHER`
# payload and a forcing descriptor's `arr` field are the same host
# `Vector{Float64}` the build bound. Emitting that host array as a CONSTANT is
# the silent-staleness bug: XLA would bake in whatever the buffer held at compile
# time and ignore every in-place refresh for ever after, with no exception and no
# NaN.
#
# So the emitter reads buffers through the ARGUMENT LIST: an identity (`===`)
# scan over the
# build's host arrays, in the container's own order, swapping in this call's
# argument entry. O(#forcing VARIABLES) per read, never O(#cells).
function _de_buffer(ctx::_DECtx, arr::Vector{Float64})::_DEVal
    ks = ctx.hostkeys
    for j in eachindex(ks)
        if ks[j] === arr
            hit = ctx.bufvals[j]
            hit === nothing || return hit
            x = ctx.bufs[j]
            x isa TracedRArray{Float64,1} ||
                _de_refuse("a forcing buffer argument of type $(typeof(x))",
                    "buffer $j of the `buffers` argument is not a traced " *
                    "rank-1 Float64 array. Pass `map(ConcreteRArray, " *
                    "forcing_buffers(f))`, the container the explicit-buffers form " *
                    "expects.")
            v = _DEVal(x.mlir_data, length(x))
            ctx.bufvals[j] = v
            _de_tally!(ctx, :forcing_input)
            return v
        end
    end
    _de_refuse("a live forcing buffer of length $(length(arr))",
        "the read's aliased host buffer is not in the `buffers` argument. " *
        "Compile `direct_rhs_with_buffers(f)` and pass the container " *
        "`forcing_buffers(f)` names, positionally; a buffer the emitter cannot " *
        "find in it would otherwise be baked in as a compile-time constant and " *
        "never see a refresh.")
end
