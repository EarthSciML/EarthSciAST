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
# position. `nothing` ⇒ nothing has written the slot in this emission.
const _DESlot = Union{Nothing,Tuple{_DEVal,Int}}

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

The emitter's ONE refusal. Hard by design: no interpreter fallback, no fallback
to the traced emitter. `construct` names the node kind / descriptor kind /
kernel shape in the IR's own vocabulary; the rule comes from `_DE_RULE`.
"""
_de_refuse(construct::AbstractString, detail::AbstractString) =
    throw(_E.DirectEmitError(construct, _DE_RULE[], detail))

# ---- the emission context ----------------------------------------------------

mutable struct _DECtx
    n_states::Int
    p::Any
    t::_DEVal
    ue::Vector{_DESlot}                     # extended-state slot map (1..n_total)
    consts::Dict{UInt64,_DEVal}             # scalar literal bit pattern -> value
    arrconsts::Dict{Vector{Float64},_DEVal} # array constant content -> value
    # Live forcing buffers, threaded exactly as the interpreter's `_OopForcing`
    # threads them: `hostkeys` are the build's aliased host arrays in the
    # container's order, `bufs` is THIS call's container (traced program inputs),
    # `bufvals` memoizes the emitted rank-1 view of each.
    bufs::Any
    hostkeys::Vector{Vector{Float64}}
    bufvals::Vector{Union{Nothing,_DEVal}}
    static::IdDict{_E._Node,Bool}           # memoized "this subtree is host-computable"
    reduce_min::Int                         # fold length at which a chain becomes a reduce
    names::Dict{Int,String}                 # flat slot -> element name (for the rule text)
    stats::Dict{Symbol,Int}
end

function _DECtx(n_states::Int, n_total::Int, p, t::_DEVal, uval::_DEVal,
                bufs, hostkeys::Vector{Vector{Float64}}, names::Dict{Int,String})
    ue = Vector{_DESlot}(nothing, n_total)
    for s in 1:n_states
        ue[s] = (uval, s)
    end
    return _DECtx(n_states, p, t, ue, Dict{UInt64,_DEVal}(),
                  Dict{Vector{Float64},_DEVal}(), bufs, hostkeys,
                  Union{Nothing,_DEVal}[nothing for _ in hostkeys],
                  IdDict{_E._Node,Bool}(), _de_reduce_min(), names,
                  Dict{Symbol,Int}())
end

# A ⊕-fold this long stops being a chain of binary ops and becomes ONE
# `stablehlo.reduce` (see `_de_fold_terms`). The chain is kept below the cut
# because it is bit-identical to the interpreter's left fold; the reduce is not
# (XLA may reassociate), which is why the cut exists at all and why it is
# tunable rather than hard-wired.
_de_reduce_min() =
    something(tryparse(Int, get(ENV, "ESM_DIRECT_EMIT_REDUCE_MIN", "32")), 32)

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

function _de_slice(ctx::_DECtx, src::_DEVal, lo::Int, hi::Int, stride::Int=1)::_DEVal
    L = length(lo:stride:hi)
    (L == src.len && lo == 1 && stride == 1) && return src
    _de_tally!(ctx, :slice)
    op = _hlo.slice(src.v; result_0=_de_ty(L),
                    start_indices=_MLIR.IR.DenseArrayAttribute(Int64[lo - 1]),
                    limit_indices=_MLIR.IR.DenseArrayAttribute(Int64[hi]),
                    strides=_MLIR.IR.DenseArrayAttribute(Int64[stride]),
                    location=_de_loc())
    return _DEVal(_de_res(op), L)
end

function _de_concat(ctx::_DECtx, pieces::Vector{_DEVal})::_DEVal
    length(pieces) == 1 && return pieces[1]
    _de_tally!(ctx, :concatenate)
    L = sum(pc.len for pc in pieces)
    op = _hlo.concatenate(_MLIR.IR.Value[pc.v for pc in pieces]; result_0=_de_ty(L),
                          dimension=0, location=_de_loc())
    return _DEVal(_de_res(op), L)
end

# A true `stablehlo.gather` of `src` at 1-based `positions` — the form a read
# takes when its index vector shatters into more runs than slices are worth.
function _de_gather_op(ctx::_DECtx, src::_DEVal, positions::Vector{Int})::_DEVal
    _de_tally!(ctx, :gather)
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
function _de_emit_runs(ctx::_DECtx, srcs::Vector{Tuple{_DEVal,Int}})::_DEVal
    n = length(srcs)
    n == 0 && _de_refuse("an empty read", "a read of zero positions reached the emitter.")
    runs = Tuple{_DEVal,Int,Int,Int}[]   # (src, lo, hi, stride)
    i = 1
    while i <= n
        sv, p0 = srcs[i]
        j = i
        stride = 1
        while j + 1 <= n && srcs[j + 1][1].v == sv.v
            d = srcs[j + 1][2] - srcs[j][2]
            if j == i
                d >= 1 || break
                stride = d
            elseif d != stride
                break
            end
            j += 1
        end
        push!(runs, (sv, p0, srcs[j][2], stride))
        i = j + 1
    end
    if length(runs) > 1 && n > 8 && length(runs) > n ÷ 2 &&
       all(r[1].v == runs[1][1].v for r in runs)
        return _de_gather_op(ctx, runs[1][1], [e[2] for e in srcs])
    end
    pieces = _DEVal[_de_slice(ctx, r[1], r[2], r[3], r[4]) for r in runs]
    return _de_concat(ctx, pieces)
end

# One value, many positions (a forcing buffer read, a CSR body read).
_de_take(ctx::_DECtx, src::_DEVal, positions::Vector{Int})::_DEVal =
    _de_emit_runs(ctx, Tuple{_DEVal,Int}[(src, q) for q in positions])

# ---- slot-map reads and writes -----------------------------------------------

@inline function _de_src(ctx::_DECtx, m::Vector{_DESlot}, s::Int)
    (1 <= s <= length(m)) || _de_refuse("a read outside the slot map",
        "slot $s is outside the extended state (length $(length(m))).")
    e = m[s]
    e === nothing && _de_refuse("a read-before-write",
        "$(_de_slotname(ctx, s)) is read before anything in this emission wrote " *
        "it. On host the flat buffer would supply a zero here; the emitter has " *
        "no such buffer, so the ordering must come from the fill levels.")
    return e
end

_de_read(ctx::_DECtx, m::Vector{_DESlot}, s::Int)::_DEVal =
    (e = _de_src(ctx, m, s); _de_slice(ctx, e[1], e[2], e[2]))

_de_gather(ctx::_DECtx, m::Vector{_DESlot}, slots::Vector{Int})::_DEVal =
    _de_emit_runs(ctx, Tuple{_DEVal,Int}[_de_src(ctx, m, s) for s in slots])

function _de_write!(ctx::_DECtx, m::Vector{_DESlot}, slots::Vector{Int}, val::_DEVal)
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

# Assemble a slot map into one rank-1 value: runs of consecutive positions in the
# same producer become slices, unwritten runs become a zero constant, and one
# concatenate joins them. This is the same reference-preserving read the
# descriptors take, applied to the output.
function _de_assemble(ctx::_DECtx, m::Vector{_DESlot}, n::Int)::_DEVal
    pieces = _DEVal[]
    i = 1
    while i <= n
        e = m[i]
        if e === nothing
            j = i
            while j + 1 <= n && m[j + 1] === nothing
                j += 1
            end
            push!(pieces, _de_arrconst(ctx, zeros(Float64, j - i + 1)))
            i = j + 1
        else
            sv, p0 = e
            j = i
            while j + 1 <= n && m[j + 1] !== nothing && m[j + 1][1].v == sv.v &&
                  m[j + 1][2] == m[j][2] + 1
                j += 1
            end
            push!(pieces, _de_slice(ctx, sv, p0, m[j][2]))
            i = j + 1
        end
    end
    return _de_concat(ctx, pieces)
end

# ---- live forcing buffers as program INPUTS ----------------------------------
#
# The compiled IR reaches a live forcing buffer by ALIAS: an `_NK_PARAM_GATHER`
# payload and a forcing descriptor's `arr` field are the same host
# `Vector{Float64}` the build bound. Emitting that host array as a CONSTANT is
# the silent-staleness bug the traced extension's B2 note documents — XLA would
# bake in whatever the buffer held at compile time and ignore every in-place
# refresh for ever after, with no exception and no NaN.
#
# So the emitter reads buffers through the ARGUMENT LIST exactly as the
# interpreter's `_oop_forcing_slab` does: an identity (`===`) scan over the
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
                    "forcing_buffers(f))`, the container `rhs_with_buffers` " *
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
