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
const _DESlot = Union{Nothing, Tuple{_DEVal, Int}}

# A slot map, plus the STATIC write plan the read forms need to interpret a
# `nothing` entry. `writer[s]` is the SECTION of the emission that first writes
# slot `s` (0 ⇒ no section writes it at all); sections are numbered in emission
# order — one per materialization level, then one for the state equations — and
# the context's `sections` names them.
#
# The plan exists because a `nothing` entry means two different things, and only
# one of them is a bug. The emitted program runs THESE units in THIS order over
# an extended vector that starts at zero, so at any point in the walk an
# unwritten slot holds 0.0.
#
#   A ZERO THIS SECTION IS ENTITLED TO — nothing writes the slot, or the only
#   writer is this same section, which has not reached the write yet. The host
#   evaluator reads 0.0 there too, so the emitter must supply one. An in-place
#   prefix scan is the standing example: at each step it READS its own slot and
#   then overwrites it with the running accumulation, and the last step of a
#   lane reads a position no term kernel ever fills.
#
#   AN ORDERING VIOLATION — a LATER section writes the slot, i.e. a fill level
#   reads a level above it. The level plan is then wrong: the emitted program
#   would fold in a zero while the host evaluator `f!` folds in the PREVIOUS
#   CALL's value out of its reused buffer, and the two stop agreeing. Refusing
#   is the right answer, and the message names the section that writes it.
#
# Built once by `_de_plan_writes!` before the walk, from the same plan data the
# walk consumes, so the two cannot disagree.
struct _DEMap
    m::Vector{_DESlot}
    writer::Vector{Int32}
    # THE CANONICAL BASE (`_de_canon_base`): this whole map as ONE value in SLOT
    # ORDER, so slot `s` is element `s` of it. Emitted lazily by the first read
    # that wants it and dropped by the next write, because a base taken before a
    # write describes the map as it was.
    base::Base.RefValue{Union{Nothing, _DEVal}}
end
_DEMap(n::Int) = _DEMap(
    Vector{_DESlot}(nothing, n), zeros(Int32, n),
    Base.RefValue{Union{Nothing, _DEVal}}(nothing)
)

function _de_mark!(M::_DEMap, slots, section::Int32)
    w = M.writer
    for s in slots
        (1 <= s <= length(w)) || continue
        @inbounds w[s] == 0 && (w[s] = section)
    end
    return nothing
end

# ---- the emission context ----------------------------------------------------

mutable struct _DECtx
    n_states::Int
    precision::DataType
    tree_fold::Bool
    counters::IdDict{Base.RefValue{Int}, Int}
    p::Any
    t::_DEVal
    ue::_DEMap                              # extended-state slot map (1..n_total)
    consts::Dict{UInt64, _DEVal}             # scalar literal bit pattern -> value
    arrconsts::Dict{Vector{Float64}, _DEVal} # array constant content -> value
    # Live forcing buffers. `hostkeys` are the build's aliased host arrays in the
    # container's (name-sorted) order, `bufs` is THIS call's container of traced
    # program inputs aligned with it, and `bufvals` memoizes the emitted rank-1
    # view of each. A descriptor names its buffer by host array IDENTITY, so a
    # read resolves by scanning `hostkeys` for it and taking the same position
    # out of `bufs`.
    bufs::Any
    hostkeys::Vector{Vector{Float64}}
    bufvals::Vector{Union{Nothing, _DEVal}}
    windows::Union{Nothing, Vector{Union{Nothing, _E._TileForcingWindow}}}
    static::_E._NodeMap{Bool}                # memoized "this subtree is host-computable"
    bstatic::IdDict{Any, Bool}               # the same, for a lane-batched subtree
    opts::DirectEmitOptions
    names::Dict{Int, String}                 # flat slot -> element name (for the rule text)
    # WHERE WE ARE, for the error messages. The IR carries no provenance
    # (`_Node` and `_AccKernel` have no name field), so the driver sets `rule`
    # to the state equation / fill level / access kernel it is about to emit
    # (`_de_rule!`), and every refusal reads it. `sections` names the emission
    # sections the write plan numbers (`_de_plan_writes!`).
    rule::String
    sections::Vector{String}
    # Producer-set -> the one concatenation a cross-producer gather reads from,
    # so a read set that recurs (and on a stencil they all do) pays for it once.
    gather_bases::Dict{Tuple{Vector{_MLIR.IR.Value}, Bool}, Tuple{_DEVal, Vector{Int}, Int}}
    # EMITTER-SIDE CSE OF READS. Two reads of the same span of the same value
    # are the same SSA value, and on a stencil that happens constantly: a
    # neighbour span is read once per consumer, and a reverse-mode program
    # multiplies every one of those by the tape. The pipeline does find them
    # (`cse_slice`), by comparing operations pairwise, which is quadratic in a
    # population the emitter knows to be redundant before it writes it.
    # Emission is one straight-line block, so an earlier value always dominates
    # a later use and the reuse needs no scope check.
    slices::Dict{Tuple{_MLIR.IR.Value, Int, Int, Int}, _DEVal}
    concats::Dict{Vector{_MLIR.IR.Value}, _DEVal}
    # The two gather tables: (value read, positions into it) -> the gather, and
    # (index width, positions) -> the index constant on its own. They are not
    # the same interning; `_de_gather_op` says why.
    gathers::Dict{Tuple{_MLIR.IR.Value, Vector{Int}}, _DEVal}
    idxconsts::Dict{Tuple{Int, Vector{Int}}, _MLIR.IR.Value}
    stats::Dict{Symbol, Int}
    # Which SECTION of the emission is running: materialization level `li` while
    # the fills are emitted, `nlev + 1` from the CSE prelude onwards. The read
    # forms compare it against the write plan (`_DEMap`) to tell a zero this
    # section is entitled to from a level read out of order.
    section::Int32
    # WHICH EMITTER SITE is running — the scalar spine, a fill level, an access
    # kernel, a scan, the output assembly. Purely a tally key for the read
    # attribution below; nothing reads it back and nothing branches on it.
    site::Symbol
    # A binary32 fragment's declared-binary64 comparison keys
    # (`_DEExactKeys`, fragment.jl), or `nothing`.
    keys64::Any
    # The template call whose body this context emits as a function
    # (`_DECallFrame`, calls.jl), or `nothing` outside a function body.
    frame::Any
    # The function callables of this emission, by key (calls.jl): one object
    # per key, so Reactant's call cache emits each function once.
    callfns::Dict{Any, Any}
end

function _DECtx(
        n_states::Int, n_total::Int, p, t::_DEVal, uval::Union{Nothing, _DEVal},
        bufs, hostkeys::Vector{Vector{Float64}}, names::Dict{Int, String},
        opts::DirectEmitOptions; precision = Float64, tree_fold = false, windows = nothing,
        keys64 = nothing, frame = nothing, callfns = Dict{Any, Any}()
    )
    ue = _DEMap(n_total)
    if uval !== nothing
        for s in 1:n_states
            ue.m[s] = (uval, s)
        end
    end
    return _DECtx(
        n_states, precision, tree_fold, IdDict{Base.RefValue{Int}, Int}(), p, t, ue, Dict{UInt64, _DEVal}(),
        Dict{Vector{Float64}, _DEVal}(), bufs, hostkeys,
        Union{Nothing, _DEVal}[nothing for _ in hostkeys], windows,
        _E._NodeMap{Bool}(), IdDict{Any, Bool}(),
        opts, names, "the right-hand side", String[],
        Dict{
            Tuple{Vector{_MLIR.IR.Value}, Bool},
            Tuple{_DEVal, Vector{Int}, Int},
        }(),
        Dict{Tuple{_MLIR.IR.Value, Int, Int, Int}, _DEVal}(),
        Dict{Vector{_MLIR.IR.Value}, _DEVal}(),
        Dict{Tuple{_MLIR.IR.Value, Vector{Int}}, _DEVal}(),
        Dict{Tuple{Int, Vector{Int}}, _MLIR.IR.Value}(),
        Dict{Symbol, Int}(), Int32(0), :none, keys64, frame, callfns
    )
end

# ---- refusals ----------------------------------------------------------------

"""
    _de_refuse(ctx, construct, detail)
    _de_refuse_at(rule, construct, detail)

The emitter's ONE refusal. Hard by design: no interpreter fallback.
`construct` names the node kind / descriptor kind / kernel shape in the IR's own
vocabulary; the rule is the context's breadcrumb (`_de_rule!`), or, at the few
sites that run before or outside an emission, the rule the caller names.
"""
_de_refuse_at(rule::AbstractString, construct::AbstractString, detail::AbstractString) =
    throw(_E.DirectEmitError(construct, rule, detail))
_de_refuse(ctx::_DECtx, construct::AbstractString, detail::AbstractString) =
    _de_refuse_at(ctx.rule, construct, detail)
_de_refuse(::Nothing, construct, detail) = _de_refuse_at("lane subscript", construct, detail)

# Run `f` with the breadcrumb set to `s`, restoring the previous one after.
function _de_rule!(f::F, ctx::_DECtx, s::AbstractString) where {F}
    prev = ctx.rule
    ctx.rule = String(s)
    try
        return f()
    finally
        ctx.rule = prev
    end
end

# Section names for the refusal text. Sections are numbered in emission order:
# `1 … nlev` are the materialization levels, `nlev + 1` is everything after them
# (the CSE prelude, the state equations, their kernels and their prefix scans),
# which writes only `du`.
_de_sectionname(sections::Vector{String}, k::Integer) =
    1 <= k <= length(sections) ? sections[k] : "emission section $k"

# Name a flat slot for an error message: the caller's `var_map` spelling when it
# passed one, the bare slot otherwise.
_de_slotname(ctx::_DECtx, s::Int) = get(ctx.names, s, "flat slot $s")

function _de_slotsname(ctx::_DECtx, slots::Vector{Int})
    isempty(slots) && return "no output slot"
    length(slots) == 1 && return _de_slotname(ctx, slots[1])
    return string(
        _de_slotname(ctx, slots[1]), " … ",
        _de_slotname(ctx, slots[end]), " (", length(slots), " lanes)"
    )
end

# ---- MLIR plumbing -----------------------------------------------------------

_de_loc() = _MLIR.IR.Location()
_de_ty(L::Int, T::Type = Float64) = _MLIR.IR.TensorType(Int64[L], _MLIR.IR.Type(T))
_de_ty(ctx::_DECtx, L::Int) = _de_ty(L, ctx.precision)
_de_ty_i1(L::Int) = _MLIR.IR.TensorType(Int64[L], _MLIR.IR.Type(Bool))
_de_ty_i64(dims::Vector{Int}) = _MLIR.IR.TensorType(Int64.(dims), _MLIR.IR.Type(Int64))
_de_ty_i32(dims::Vector{Int}) = _MLIR.IR.TensorType(Int64.(dims), _MLIR.IR.Type(Int32))
_de_tally!(ctx::_DECtx, k::Symbol) = (ctx.stats[k] = get(ctx.stats, k, 0) + 1; nothing)

# READ ATTRIBUTION. Every emitted `slice` / `gather` / `concatenate` is tallied
# a second time under `<op>@<site>.<why>` — which EMITTER SITE was running and
# which read form asked for it. A flat total says a module carries N slices; it
# does not say whether they are a stencil's reads, a kernel's invariant scalars
# or the output assembly, and those need different fixes.
#
# THIS IS NOT DECORATION. The single-position slice is the op the
# post-differentiation `enzyme-hlo-opt` run is quadratic in, and the surface
# that emits most of them on a stencil model is not the one a reader expects
# (the per-cell scalar spine) but the output assembly. An attribution that
# names the site is what separates a plausible answer from the right one.
#
# `_de_at!` names the site; `_de_site!` charges an emitted op to it.
_de_at!(ctx::_DECtx, s::Symbol) = (ctx.site = s; nothing)
_de_site!(ctx::_DECtx, pre::Symbol, why::Symbol) =
    _de_tally!(ctx, Symbol(pre, "@", ctx.site, ".", why))
_de_res(op) = _MLIR.IR.result(op)

# `_DEVal` ↔ Reactant's traced array, for the two places that reuse Reactant's
# own op builders rather than building the op here: the comparison count
# (closed.jl) and the long-fold `stablehlo.reduce` (`_de_fold_terms`). Both are
# O(1) in the grid, so the program stays IR-shaped either way.
_de_traced(a::_DEVal, ::Type{T} = Float64) where {T} = TracedRArray{T, 1}((), a.v, (a.len,))
_de_eltype(::TracedRArray{T}) where {T} = T
_de_untraced(x::TracedRArray{T, 1}) where {T} = _DEVal(x.mlir_data, length(x))
_de_untraced(x::TracedRNumber{T}) where {T} =
    _DEVal(_de_res(_hlo.reshape(x.mlir_data; result_0 = _de_ty(1, T), location = _de_loc())), 1)

function _de_cast(a::_DEVal, from::Type, to::Type)
    from === to && return a
    op = _hlo.convert(a.v; result = _de_ty(a.len, to), location = _de_loc())
    return _DEVal(_de_res(op), a.len)
end

_de_counter(ctx::_DECtx, r::Base.RefValue{Int}) = get(() -> r[], ctx.counters, r)
_de_set_counter!(ctx::_DECtx, r::Base.RefValue{Int}, value::Int) = (ctx.counters[r] = value)


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
    op = _hlo.constant(;
        output = _de_ty(ctx, 1),
        value = _MLIR.IR.DenseElementsAttribute([ctx.precision(x)]), location = _de_loc()
    )
    v = _DEVal(_de_res(op), 1)
    ctx.consts[key] = v
    return v
end

function _de_arrconst(ctx::_DECtx, xs::Vector{Float64})::_DEVal
    length(xs) == 1 && return _de_const(ctx, xs[1])
    hit = get(ctx.arrconsts, xs, nothing)
    hit === nothing || return hit
    _de_tally!(ctx, :constant_array)
    op = _hlo.constant(;
        output = _de_ty(ctx, length(xs)),
        value = _MLIR.IR.DenseElementsAttribute(ctx.precision === Float64 ? xs : Float32.(xs)), location = _de_loc()
    )
    v = _DEVal(_de_res(op), length(xs))
    ctx.arrconsts[copy(xs)] = v
    return v
end

function _de_boolconst(ctx::_DECtx, m::Vector{Bool})::_MLIR.IR.Value
    _de_tally!(ctx, :constant_mask)
    op = _hlo.constant(;
        output = _de_ty_i1(length(m)),
        value = _MLIR.IR.DenseElementsAttribute(m), location = _de_loc()
    )
    return _de_res(op)
end

# ---- shape plumbing ----------------------------------------------------------

function _de_bcast(ctx::_DECtx, a::_DEVal, L::Int)::_DEVal
    a.len == L && return a
    a.len == 1 || _de_refuse(
        ctx,
        "a lane-width mismatch",
        "a value of length $(a.len) met lane width $L. The two came from the " *
            "same expression, so one of them was planned at a different lane " *
            "enumeration than the other — a kernel-plan invariant break, not a " *
            "coverage gap."
    )
    _de_tally!(ctx, :broadcast_in_dim)
    op = _hlo.broadcast_in_dim(
        a.v; result_0 = _de_ty(ctx, L),
        broadcast_dimensions = _MLIR.IR.DenseArrayAttribute(Int64[0]),
        location = _de_loc()
    )
    return _DEVal(_de_res(op), L)
end

function _de_slice(
        ctx::_DECtx, src::_DEVal, lo::Int, hi::Int, stride::Int = 1;
        why::Symbol = :other
    )::_DEVal
    L = length(lo:stride:hi)
    (L == src.len && lo == 1 && stride == 1) && return src
    key = (src.v, lo, hi, stride)
    hit = get(ctx.slices, key, nothing)
    hit === nothing || return hit
    _de_tally!(ctx, :slice)
    _de_site!(ctx, L == 1 ? :slice1 : :sliceN, why)
    op = _hlo.slice(
        src.v; result_0 = _de_ty(ctx, L),
        start_indices = _MLIR.IR.DenseArrayAttribute(Int64[lo - 1]),
        limit_indices = _MLIR.IR.DenseArrayAttribute(Int64[hi]),
        strides = _MLIR.IR.DenseArrayAttribute(Int64[stride]),
        location = _de_loc()
    )
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
    op = _hlo.concatenate(
        key; result_0 = _de_ty(ctx, L),
        dimension = 0, location = _de_loc()
    )
    out = _DEVal(_de_res(op), L)
    ctx.concats[key] = out
    return out
end

# THE INDEX VECTOR IS WHAT THE GATHER FORM COSTS, and it is paid in the data
# the module ships rather than in its operation count. Two things bound it.
#
# INTERNING, and by CONTENTS rather than by use. The gather itself is interned
# the way the slice and concatenate forms already are — same value, same
# positions, same SSA result — but that alone leaves the index vector emitted
# again for every gather that is not itself a repeat, and on a slot map most of
# them are not: a write retires the map's canonical base, so the next read of
# the SAME slots is a different gather over a different value at exactly the
# same indices, and the map is written between almost every pair of reads. The
# index vector is a property of the READ and of nothing else, so it is interned
# on its own, and a module carries one copy of each distinct one.
#
# THE ELEMENT TYPE. `stablehlo.gather` takes start indices of any integer type,
# and a 32-bit index addresses a base far longer than a slot map that fits in
# memory, so the vector is emitted as `i32` whenever every position into the
# base is representable in one and as `i64` otherwise. The width changes no
# number the program computes. `DirectEmitOptions.gather_index_bits` pins it,
# as the negative control and as the escape if a backend is found that wants the
# wide form.

# Pure, so the width can be pinned by a test at base lengths no fixture reaches.
_de_index_bits(baselen::Int, want::Int) =
    (want == 32 && baselen <= typemax(Int32)) ? 32 : 64

function _de_idxconst(ctx::_DECtx, positions::Vector{Int}, bits::Int)
    key = (bits, positions)
    hit = get(ctx.idxconsts, key, nothing)
    hit === nothing || return hit
    L = length(positions)
    attr = bits == 32 ?
        _MLIR.IR.DenseElementsAttribute(reshape(Int32.(positions) .- Int32(1), L, 1)) :
        _MLIR.IR.DenseElementsAttribute(reshape(Int64.(positions) .- Int64(1), L, 1))
    _de_tally!(ctx, :gather_index)
    op = _hlo.constant(;
        output = (bits == 32 ? _de_ty_i32([L, 1]) : _de_ty_i64([L, 1])),
        value = attr, location = _de_loc()
    )
    v = _de_res(op)
    ctx.idxconsts[(bits, copy(positions))] = v
    return v
end

# A true `stablehlo.gather` of `src` at 1-based `positions` — the form a read
# takes when its index vector shatters into more runs than slices are worth.
function _de_gather_op(ctx::_DECtx, src::_DEVal, positions::Vector{Int})::_DEVal
    key = (src.v, positions)
    hit = get(ctx.gathers, key, nothing)
    hit === nothing || return hit
    _de_tally!(ctx, :gather)
    _de_site!(ctx, :gather, :x)
    L = length(positions)
    idx = _de_idxconst(
        ctx, positions,
        _de_index_bits(src.len, ctx.opts.gather_index_bits)
    )
    dn = _MLIR.API.stablehloGatherDimensionNumbersGet(
        _MLIR.IR.current_context(),
        0, Int64[],          # offset_dims
        1, Int64[0],         # collapsed_slice_dims
        0, Int64[],          # operand_batching_dims
        0, Int64[],          # start_indices_batching_dims
        1, Int64[0],         # start_index_map
        1
    )                   # index_vector_dim
    op = _hlo.gather(
        src.v, idx; result = _de_ty(ctx, L), dimension_numbers = dn,
        slice_sizes = _MLIR.IR.DenseArrayAttribute(Int64[1]),
        indices_are_sorted = false, location = _de_loc()
    )
    out = _DEVal(_de_res(op), L)
    ctx.gathers[(src.v, copy(positions))] = out
    return out
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
const _DESlotSrc = Union{Nothing, _DEVal}

# ---- the read cost model -----------------------------------------------------
#
# A read that decomposes into runs of consecutive positions is emitted either as
# one slice per run plus a concatenate, or as one gather with an i64 index
# constant. The rule: gather when the read has more than `_DE_GATHER_MIN_PIECES`
# runs, or exactly that many and they average fewer than `_DE_RUN_WORTH`
# positions; otherwise slice.
#
# Two costs set the numbers. The reverse of a slice is a pad-and-add that the
# downstream optimizer turns back into more slices, and the slice deduplication
# passes downstream are quadratic in the slice population (UPSTREAM_ISSUES.md),
# so a read whose run count grows with the grid must gather; that is the cap. A
# gather is an indexed copy where a slice is a contiguous one, so a read of a few
# long runs keeps its slices; that is the floor, and the cap equals it.
#
# Neither form changes a NUMBER: a gather of the same positions from the same
# values is bit-identical to slices-plus-concatenate of them.
#
# Switches (`DirectEmitOptions`): `read = :runs` restores the slice-per-run
# shape (the negative control); `:always` gathers every multi-run read and lifts
# the base budget (a measurement lever, not a recommendation);
# `gather_max_pieces` overrides the cap. Pinned by
# test/reactant/reactant_direct_emit_test.jl.
const _DE_GATHER_MIN_PIECES = 8
const _DE_RUN_WORTH = 4

function _de_gather_is_cheaper(opts::DirectEmitOptions, npieces::Int, n::Int)
    opts.read === :runs && return false
    opts.read === :always && return npieces > 1
    npieces > opts.gather_max_pieces && return true
    return npieces >= _DE_GATHER_MIN_PIECES && npieces * _DE_RUN_WORTH > n
end

# The base a cross-producer gather reads from: the DISTINCT producer values
# concatenated once, plus one zero element when the read carries structural
# zeros (a gather may read one position many times, so every zero lane points
# at that single element). Returns the base, the offset of each producer inside
# it, and the position of the zero — or `nothing` when the concatenate the base
# needs would copy more elements than the emission's base budget allows.
#
# The base is cached on the emission context keyed by the producer set, so its
# concatenate is emitted once however many reads use it, and a base over one
# producer with no structural zero is that producer (no copy). The budget bounds
# that copy, charged only when a copy happens, not per read: the read that most
# needs a base is often short and drawn from two large producers. It is a
# multiple of the extended state with an absolute floor, since a fixed element
# count would refuse every cross-producer read past some grid size (the output
# assembly, which spans every producer, first).
# `DirectEmitOptions.gather_base_max` overrides it.
const _DE_GATHER_BASE_FLOOR = 1 << 16
const _DE_GATHER_BASE_FACTOR = 4

# Pure, so the budget can be pinned by a test at sizes no fixture reaches.
_de_gather_base_max(n_ue::Int) =
    max(_DE_GATHER_BASE_FLOOR, _DE_GATHER_BASE_FACTOR * n_ue)

function _de_gather_base_budget(ctx::_DECtx)
    ctx.opts.read === :always && return typemax(Int)
    return something(ctx.opts.gather_base_max, _de_gather_base_max(length(ctx.ue.m)))
end

# Pure, so the decision can be pinned by a test at sizes no fixture reaches.
_de_gather_base_fits(nprods::Int, needzero::Bool, tot::Int, budget::Int) =
    ((nprods == 1 && !needzero) ? 0 : tot) <= budget

function _de_gather_base(ctx::_DECtx, prods::Vector{_DEVal}, needzero::Bool)
    key = (_MLIR.IR.Value[q.v for q in prods], needzero)
    hit = get(ctx.gather_bases, key, nothing)
    hit === nothing || return hit
    tot = sum(q.len for q in prods) + (needzero ? 1 : 0)
    _de_gather_base_fits(
        length(prods), needzero, tot,
        _de_gather_base_budget(ctx)
    ) || return nothing
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

function _de_runs_as_gather(
        ctx::_DECtx, srcs::Vector{_DESlot},
        runs::Vector{Tuple{_DESlotSrc, Int, Int, Int}},
        needzero::Bool
    )
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
            sv, q = e::Tuple{_DEVal, Int}
            k = findfirst(x -> x.v == sv.v, prods)::Int
            pos[i] = offs[k] + q
        end
    end
    return _de_gather_op(ctx, base, pos)
end

# The decomposition on its own — pure, and shared by every caller that has to
# know how many pieces a read costs BEFORE deciding what to emit for it.
function _de_run_decompose(srcs::Vector{_DESlot})
    n = length(srcs)
    # (src, lo, hi, stride); `src === nothing` ⇒ a zero run, `hi` its width.
    runs = Tuple{_DESlotSrc, Int, Int, Int}[]
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
        sv, p0 = e::Tuple{_DEVal, Int}
        j = i
        stride = 1
        while j + 1 <= n
            nx = srcs[j + 1]
            nx === nothing && break
            nx[1].v == sv.v || break
            d = nx[2] - (srcs[j]::Tuple{_DEVal, Int})[2]
            if j == i
                d >= 1 || break
                stride = d
            elseif d != stride
                break
            end
            j += 1
        end
        push!(runs, (sv, p0, (srcs[j]::Tuple{_DEVal, Int})[2], stride))
        i = j + 1
    end
    return runs, nzero
end

function _de_emit_decomposed(
        ctx::_DECtx, srcs::Vector{_DESlot},
        runs::Vector{Tuple{_DESlotSrc, Int, Int, Int}},
        nzero::Int
    )::_DEVal
    if _de_gather_is_cheaper(ctx.opts, length(runs), length(srcs))
        g = _de_runs_as_gather(ctx, srcs, runs, nzero > 0)
        g === nothing || return g
    end
    pieces = _DEVal[
        r[1] === nothing ? _de_arrconst(ctx, zeros(Float64, r[3])) :
            _de_slice(ctx, r[1]::_DEVal, r[2], r[3], r[4]; why = :runs) for r in runs
    ]
    return _de_concat(ctx, pieces)
end

function _de_emit_runs(ctx::_DECtx, srcs::Vector{_DESlot})::_DEVal
    isempty(srcs) &&
        _de_refuse(ctx, "an empty read", "a read of zero positions reached the emitter.")
    runs, nzero = _de_run_decompose(srcs)
    return _de_emit_decomposed(ctx, srcs, runs, nzero)
end

# One value, many positions (a forcing buffer read, a CSR body read).
_de_take(ctx::_DECtx, src::_DEVal, positions::Vector{Int})::_DEVal =
    _de_emit_runs(ctx, _DESlot[(src, q) for q in positions])

# ---- the canonical base: one value per slot map, in slot order ---------------
#
# `_de_gather_base` builds a base per PRODUCER SET. That is the right unit for a
# forcing buffer, whose reads all come out of one value, and the wrong one for
# the slot map: a stencil's reads draw from dozens of overlapping producer sets,
# so the map's contents are concatenated again for each of them, and no two of
# those copies address a slot the same way.
#
# The canonical base is the MAP ITSELF: its distinct producers concatenated in
# first-slot order, then put into slot order — element `s` is slot `s`. Reading
# the map is then reading ONE value at PLAIN SLOT INDICES, and that buys three
# things at once. The concatenate is emitted once per map per write epoch rather
# than once per producer set. A read whose slots are affine in slot space is an
# ordinary `stablehlo.slice` of it, carrying no index constant at all — which is
# what keeps the index-data volume of the gather form bounded. And
# `_de_assemble`, which reads slots `1..n`, IS the base: no op, no index data.
#
# WHEN IT IS WORTH BUILDING. The base is one concatenate, plus one gather when
# the producers do not already lie in slot order — cheap against a read that
# shatters into hundreds of pieces, not cheap against one that decomposes into
# eight. So it is built only for a read that would otherwise cost more than the
# piece cap in ops, which is the same line `_de_gather_is_cheaper` draws.
#
# BUILDING IT NEVER CALLS `_de_src`. An unwritten slot is the structural zero
# every read form already carries; whether reading one is an ORDERING VIOLATION
# is a property of the READ, and the read has already asked that question by the
# time it asks for a base.
function _de_canon_worth(opts::DirectEmitOptions, npieces::Int)
    opts.read === :runs && return false
    opts.read === :always && return npieces > 1
    return npieces > opts.gather_max_pieces
end

function _de_canon_base(ctx::_DECtx, M::_DEMap)::Union{Nothing, _DEVal}
    hit = M.base[]
    hit === nothing || return hit
    n = length(M.m)
    n == 0 && return nothing
    prods = _DEVal[]
    at = Dict{_MLIR.IR.Value, Int}()
    needzero = false
    for e in M.m
        if e === nothing
            needzero = true
        else
            sv = (e::Tuple{_DEVal, Int})[1]
            haskey(at, sv.v) || (push!(prods, sv); at[sv.v] = length(prods))
        end
    end
    isempty(prods) && return nothing
    tot = sum(q.len for q in prods) + (needzero ? 1 : 0)
    _de_gather_base_fits(
        length(prods), needzero, tot,
        _de_gather_base_budget(ctx)
    ) || return nothing
    offs = Vector{Int}(undef, length(prods))
    acc = 0
    for k in eachindex(prods)
        offs[k] = acc
        acc += prods[k].len
    end
    zpos = needzero ? acc + 1 : 0
    pos = Vector{Int}(undef, n)
    inorder = true
    @inbounds for i in 1:n
        e = M.m[i]
        if e === nothing
            pos[i] = zpos
        else
            sv, q = e::Tuple{_DEVal, Int}
            pos[i] = offs[at[sv.v]] + q
        end
        pos[i] == i || (inorder = false)
    end
    pieces = copy(prods)
    needzero && push!(pieces, _de_const(ctx, 0.0))
    prev = ctx.site
    _de_at!(ctx, :canon)
    out = try
        base = _de_concat(ctx, pieces)
        if inorder
            # The concatenation IS in slot order; the only op left is the trim
            # when the producers run past the map's last slot.
            base.len == n ? base : _de_slice(ctx, base, 1, n; why = :canon)
        else
            # MEMOIZED ON THE LAYOUT, not just cached on the map. A write
            # drops the map's base, and a section that interleaves writes with
            # reads therefore asks for a new one after each; when the write did
            # not move any slot the base covers, the layout is the one already
            # emitted. That pair — the concatenation and the layout — is the
            # key `_de_gather_op` interns on, so asking it again is free.
            _de_gather_op(ctx, base, pos)
        end
    finally
        _de_at!(ctx, prev)
    end
    _de_tally!(ctx, :canon_base)
    M.base[] = out
    return out
end

# ---- slot-map reads and writes -----------------------------------------------
#
# `nothing` back from `_de_src` is a structural zero, NOT "no answer": the
# caller emits a zero of the right width. The refusal is kept for the one case
# that is genuinely an ordering bug — a slot a later unit writes.

# The `nothing` decision, factored out of `_de_src` so it is exercisable on its
# own. `nothing` back means "emit a zero here": either no section writes the
# slot at all, or the only writer is `section` itself, which is still running.
# A write by a LATER section is the ordering violation, and it refuses.
@inline function _de_unwritten(
        M::_DEMap, s::Int, section::Int32,
        name::AbstractString, sections::Vector{String}, rule::AbstractString
    )
    w = @inbounds M.writer[s]
    (w == 0 || w <= section) && return nothing
    return _de_refuse_at(
        rule, "a read-before-write",
        "$name is read while emitting $(_de_sectionname(sections, section)), and " *
            "$(_de_sectionname(sections, w)) writes it LATER. The ordering must come from " *
            "the fill levels, which are supposed to guarantee that a level reads " *
            "only levels below it. The emitted program would read a zero there " *
            "while the host evaluator reads the PREVIOUS CALL's value out of its " *
            "reused buffer, so the two would not agree; it is the level plan that " *
            "has to change."
    )
end

@inline function _de_src(ctx::_DECtx, M::_DEMap, s::Int)::_DESlot
    (1 <= s <= length(M.m)) || _de_refuse(
        ctx,
        "a read outside the slot map",
        "slot $s is outside the extended state (length $(length(M.m)))."
    )
    e = @inbounds M.m[s]
    e === nothing || return e
    return _de_unwritten(
        M, s, ctx.section, _de_slotname(ctx, s), ctx.sections, ctx.rule
    )
end

_de_read(ctx::_DECtx, M::_DEMap, s::Int, why::Symbol = :read1)::_DEVal =
    (
    e = _de_src(ctx, M, s); e === nothing ? _de_const(ctx, 0.0) :
        _de_slice(ctx, e[1], e[2], e[2]; why = why)
)

function _de_gather(ctx::_DECtx, M::_DEMap, slots::Vector{Int})::_DEVal
    isempty(slots) &&
        _de_refuse(ctx, "an empty read", "a read of zero positions reached the emitter.")
    srcs = _DESlot[_de_src(ctx, M, s) for s in slots]
    runs, nzero = _de_run_decompose(srcs)
    if _de_canon_worth(ctx.opts, length(runs))
        cb = _de_canon_base(ctx, M)
        # On a base in slot order the SAME read decomposes over plain slot
        # indices, so it re-enters the cost model one level down: affine slots
        # become one slice with no index constant, shattered ones one gather.
        cb === nothing || return _de_emit_runs(ctx, _DESlot[(cb, s) for s in slots])
    end
    return _de_emit_decomposed(ctx, srcs, runs, nzero)
end

function _de_write!(ctx::_DECtx, M::_DEMap, slots::Vector{Int}, val::_DEVal)
    m = M.m
    M.base[] = nothing
    if val.len == 1
        for s in slots
            m[s] = (val, 1)
        end
    else
        val.len == length(slots) ||
            _de_refuse(
            ctx,
            "a scatter of the wrong width",
            "a kernel result of length $(val.len) is scattered into " *
                "$(length(slots)) slots ($(_de_slotsname(ctx, slots)))."
        )
        for (l, s) in enumerate(slots)
            m[s] = (val, l)
        end
    end
    return nothing
end

# Assemble a slot map into one rank-1 value: a READ of the whole map, at
# positions `1:n`, through the one read form every other surface uses.
#
# THE OUTPUT IS A READ LIKE ANY OTHER, and it has to go through the same cost
# model. The output slot map of a stencil model is INTERLEAVED — a kernel's
# result value holds its own cells, and the next slot in ascending order
# usually belongs to a different value or to a different position inside the
# same one — so the "runs of consecutive positions in the same producer" a
# local walk finds here are mostly runs of ONE, and each of those would cost a
# `stablehlo.slice` of a single element. On a stencil model that is the largest
# block of the slice population the post-differentiation `cse_slice` pattern is
# quadratic in.
#
# `_de_emit_runs` decomposes the same positions into the same runs and then
# applies the COST MODEL to them — one gather when the map shatters, slices
# plus a concatenate when it does not, structural zeros folded into either. An
# unwritten slot is a `nothing` entry, which is exactly the structural zero the
# read form already knows how to carry.
function _de_assemble(ctx::_DECtx, M::_DEMap, n::Int)::_DEVal
    srcs = _DESlot[@inbounds M.m[i] for i in 1:n]
    runs, nzero = _de_run_decompose(srcs)
    if _de_canon_worth(ctx.opts, length(runs))
        cb = _de_canon_base(ctx, M)
        if cb !== nothing
            # Slots `1..n` of a base in slot order: the base, or a prefix of it.
            cb.len == n && return cb
            cb.len > n && return _de_slice(ctx, cb, 1, n; why = :assemble)
        end
    end
    return _de_emit_decomposed(ctx, srcs, runs, nzero)
end

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
# scan over the build's host arrays, in the container's own order, swapping in
# this call's argument entry. O(#forcing VARIABLES) per read, never O(#cells).
function _de_buffer_index(ctx::_DECtx, arr)
    j = findfirst(x -> x === arr, ctx.hostkeys)
    j !== nothing && return j
    return _de_refuse(
        ctx,
        "a live forcing buffer of length $(length(arr))",
        "the read's aliased host buffer is not in the `buffers` argument. " *
            "Compile `direct_rhs_with_buffers(f)` and pass the container " *
            "`forcing_buffers(f)` names, positionally; a buffer the emitter cannot " *
            "find in it would otherwise be baked in as a compile-time constant and " *
            "never see a refresh."
    )
end


function _de_buffer_read(ctx::_DECtx, arr, positions; why = :pgather)
    j = _de_buffer_index(ctx, arr)
    val = ctx.bufvals[j]
    if val === nothing
        x = ctx.bufs[j]
        x isa Union{TracedRArray{Float32, 1}, TracedRArray{Float64, 1}} ||
            _de_refuse(ctx, "forcing buffer $j of type $(typeof(x))", "expected a traced flat floating-point tensor.")
        val = _de_cast(_de_untraced(x), _de_eltype(x), ctx.precision)
        ctx.bufvals[j] = val
        _de_tally!(ctx, :forcing_input)
    end
    if val.len != length(arr)
        window = ctx.windows === nothing ? nothing : ctx.windows[j]
        window !== nothing && val.len == _E._tile_window_length(window) ||
            throw(DimensionMismatch("forcing buffer $j has the wrong length"))
        positions = positions isa Int ? _E._tile_window_position(window, positions) :
            Int[_E._tile_window_position(window, p) for p in positions]
    end
    return positions isa Int ? _de_slice(ctx, val, positions, positions; why) :
        _de_take(ctx, val, positions)
end
