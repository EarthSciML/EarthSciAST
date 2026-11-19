# tree_walk/scalar_walk.jl — the compiled scalar walker (`_eval_node` / `_eval_node_op`).

# ============================================================
# 4. Compiled walker
# ============================================================

# The value type `T` is threaded through the whole walk (rather than re-derived at
# each node) so that every `Type{T}`-dispatched scratch lookup (`_cse_read`,
# `_cse_buf`) is resolved statically.
#
# NOTHING in this walker CONVERTS to `T`. A leaf returns whatever it natively holds
# and Julia's promotion does the rest: a `Float64` literal beside a `Dual` state
# promotes at the operator, which is both correct (a constant's derivative is zero)
# and, for `^`, ESSENTIAL — see the note on the `^` arm in `_eval_node_op`. So under
# AD the return type is the small union `Union{Float64,T}`, which Julia union-splits;
# at `T === Float64` it collapses to `Float64` and this is the pre-existing walker,
# instruction for instruction.
#
# The 4-arg form is the build-time / test entry point (constant folding, initial
# conditions, loop bounds): it derives `T` from the arguments, which are `Float64`
# there, so it lands on the same specialization.
@inline _eval_node(n::_Node, u, p, t) = _eval_node(n, u, p, t, _rhs_value_type(u, p, t))

@inline function _eval_node(n::_Node, u, p, t, ::Type{T}) where {T}
    k = n.kind
    if k === _NK_LITERAL
        return n.literal
    elseif k === _NK_STATE
        @inbounds return u[n.idx]
    elseif k === _NK_PARAM
        return _read_param(p, n.sym, n.idx)
    elseif k === _NK_PARAM_GATHER
        # Live read of a captured forcing buffer. `payload` is the
        # aliased flat `Vector{Float64}` (a `_PGatherArray.flat`) and `idx` the
        # pre-linearized column-major offset, both fixed at build time; the buffer
        # CONTENTS are refreshed in place by the J1 discrete callback. The concrete
        # `::Vector{Float64}` assert keeps this monomorphic + zero-alloc (no
        # runtime-symbol `getfield`, so the scalar `p` NamedTuple stays homogeneous).
        @inbounds return (n.payload::Vector{Float64})[n.idx]
    elseif k === _NK_CONST_GATHER || k === _NK_LIVE_GATHER
        # Runtime-indexed read of a captured const/provider array,
        # or of a live forcing buffer (`_NK_LIVE_GATHER`, the same read).
        # `payload` is a `_ConstGatherArray` (flat column-major values + strides);
        # the subscript `children` are evaluated HERE and linearized HERE, so a
        # child that resolves to a runtime-varying value (a bound output
        # index) reaches a different element with no rebuild. Subscripts are
        # exact-integer-valued, so `round(Int, …)` recovers them without drift. Each
        # subscript is resolved on its own axis (`_const_gather_sub`). The concrete
        # `::_ConstGatherArray` assert keeps this arm monomorphic; the happy-path
        # read allocates nothing (the guard only throws on failure).
        cg = n.payload::_ConstGatherArray
        children = n.children
        strides = cg.strides
        off = 1
        @inbounds for d in eachindex(children)
            sub = _const_gather_sub(cg, d, round(Int, _eval_node(children[d], u, p, t, T)))
            off += (sub - 1) * strides[d]
        end
        @inbounds return cg.flat[off]
    elseif k === _NK_TIME
        return t
    elseif k === _NK_CACHED
        # Common-subexpression reference. The value was computed once
        # into the per-call scratch cache by the CSE prelude (see `_make_rhs`);
        # every occurrence reads it here instead of re-walking the subtree. The
        # `_CSECache` is captured in `payload` at build time; `T` selects which of
        # its two buffers holds this call's values (Float64 slots vs. the Dual
        # buffer ForwardDiff drove `f!` with).
        return _cse_read(n.payload::_CSECache, n.idx, T)
    elseif k === _NK_CONTRACTION
        return _eval_contraction(n, u, p, t, T)
    elseif k === _NK_LOOPVAR
        # Current value of the enclosing runtime contraction loop counter
        #. Always an INTEGER (a contracted index),
        # read as a `Float64` like the literal the unroll puts in its place, so
        # arithmetic on it differentiates as the unroll's does.
        return Float64((n.payload::Base.RefValue{Int})[])
    elseif k === _NK_CONTRACTION_LOOP
        return _eval_contraction_loop(n, u, p, t, T)
    elseif k === _NK_RAGGED_LOOP
        return _eval_ragged_loop(n, u, p, t, T)
    elseif k === _NK_STATE_GATHER
        return _eval_state_gather(n, u, p, t, T)
    elseif k === _NK_RECUR_GATHER
        return _eval_recur_gather(n, u, p, t, T)
    elseif k === _NK_OP
        return _eval_node_op(n, u, p, t, T)
    elseif k === _NK_ARG
        return _eval_arg(n, T)
    elseif k === _NK_CALL
        return _run_call(c -> _eval_node(c, u, p, t, T), n, u, p, t, T)
    end
    return _unknown_kind(n, "the scalar walker")
end

"""
    _unknown_kind(n::_Node, pass::AbstractString)

Raise for a node whose kind `pass` has no arm for: the last arm of every ladder
over `_Node.kind`, so an untaught pass fails by name instead of reinterpreting
the node.
"""
@noinline _unknown_kind(n::_Node, pass::AbstractString) = throw(
    TreeWalkError(
        "E_TREEWALK_UNKNOWN_NODE_KIND",
        "$pass has no arm for a node of kind $(_node_kind_name(n.kind))" *
            (n.op === Symbol("") ? "" : " (op $(n.op))")
    )
)

# Runtime state read at a loop-var-dependent slot.
# Evaluates the subscript children to integers, bounds-checks each against the
# state array's `[lo,hi]` (an out-of-range subscript is a ghost cell → 0̄, matching
# the unroll), computes the column-major offset into the frozen slot table, and
# reads `u` at that flat slot. Returns `eltype(u)` on both arms exactly as the
# `_NK_STATE` leaf does (so the state axis stays derivative-carrying under
# ForwardDiff and the arm is type-stable); zero per-call allocation.
function _eval_state_gather(n::_Node, u, p, t, ::Type{T}) where {T}
    sg = n.payload::_StateGather
    children = n.children
    off = 0
    @inbounds for d in eachindex(children)
        sub = round(Int, _eval_node(children[d], u, p, t, T))
        (sg.lo[d] <= sub <= sg.hi[d]) || return zero(eltype(u))   # ghost cell
        off += (sub - sg.lo[d]) * sg.strides[d]
    end
    slot = _sg_slot(sg, off)
    @inbounds return u[slot]
end

# A recurrence's causal self-read (`_RecurGather`). The subscripts are evaluated
# and range-checked in dimension order, as `_eval_state_gather` does (a later one
# is not evaluated once one is out of the frame), and the read is served only
# from a cell the sweep has already published.
function _eval_recur_gather(n::_Node, u, p, t, ::Type{T}) where {T}
    rg = n.payload::_RecurGather
    children = n.children
    ord = 0
    slot = rg.base
    @inbounds for d in eachindex(children)
        sub = round(Int, _eval_node(children[d], u, p, t, T))
        lo = rg.lo[d]
        (lo <= sub < lo + rg.dims[d]) || _recur_unavailable(rg, children, d, u, p, t, T)
        ord += (sub - lo) * rg.sweep_w[d]
        slot += (sub - lo) * rg.strides[d]
    end
    ord < rg.cur[] || _recur_unavailable(rg, children, length(children), u, p, t, T)
    @inbounds return u[slot]
end

# The fault, off the hot path: the first `nd` subscripts (the ones the read
# evaluated) are evaluated again for the message.
@noinline function _recur_unavailable(
        rg::_RecurGather, children, nd::Int, u, p, t,
        ::Type{T}
    ) where {T}
    subs = Int[round(Int, _eval_node(children[d], u, p, t, T)) for d in 1:nd]
    return _recur_unavailable_at(rg, rg.cur[], subs)
end

# `E_TREEWALK_RECUR_UNAVAILABLE` for a self-read of `rg`'s variable at `subs` (the
# subscripts evaluated before the read stopped) while the sweep is at position
# `cur`. The emitted sweep (recurrence_sweep.jl) raises it through here too, so
# both forms say the same thing.
@noinline function _recur_unavailable_at(rg::_RecurGather, cur::Int, subs::Vector{Int})
    r = cur
    cell = zeros(Int, length(rg.dims))
    for d in sortperm(rg.sweep_w; rev = true)
        q, r = divrem(r, rg.sweep_w[d])
        cell[d] = rg.lo[d] + q
    end
    inframe = length(subs) == length(rg.dims) &&
        all(d -> rg.lo[d] <= subs[d] < rg.lo[d] + rg.dims[d], eachindex(subs))
    throw(
        TreeWalkError(
            "E_TREEWALK_RECUR_UNAVAILABLE",
            "causal self-read of '$(rg.name)' at [$(join(subs, ", "))" *
                (length(subs) < length(rg.dims) ? ", …" : "") *
                "] while evaluating cell [$(join(cell, ", "))]: " *
                (
                inframe ? "that cell has not been published yet" :
                    "that position is outside the recurrence's frame " *
                    "[$(join(("$(rg.lo[d]):$(rg.lo[d] + rg.dims[d] - 1)" for d in eachindex(rg.dims)), ", "))]"
            ) *
                " (esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.4). A self-read is never " *
                "resolved to a value it cannot have; write the base case as an `ifelse` " *
                "guard in the body"
        )
    )
end

# Compile-once runtime ⊕-reduction. Iterates the static
# integer range `lo:step:hi`, writing the counter into the shared `Ref` every
# iteration so the ONE compiled `body` (whose `_NK_LOOPVAR` leaves read that ref)
# yields term(k); folds with ⊕ seeded from 0̄ (`n.literal`). The iteration order is
# `_expand_int_range`'s order — the SAME order the unroll path (`_foreach_aggregate_term`
# → `_combine_with_reducer`) accumulates in, from the same 0̄ seed (esm-spec §4.3.1) —
# so a single-index loop is bit-identical to the unrolled fold. Nested loops
# (multi-index) group the sum by the outer index, a
# reassociation within ~length·eps of the flat unroll. Zero per-call allocation: the
# ref is built once at compile time; the fold is stack-only and type-stable in `T`.
#
# The seed enters the first step as the node's `Float64`, not converted to `T`,
# as the emitted loop has it (`_cg_contraction_loop`): `seed ⊕ term₁` leaves a
# `Dual` term's partials as they are, where `T(seed) ⊕ term₁` adds the seed's
# zero partials to them and turns a `-0.0` partial into `0.0`. The first step is
# taken before the loop so the accumulator is a `T` throughout.
function _eval_contraction_loop(n::_Node, u, p, t, ::Type{T}) where {T}
    spec = n.payload::_ContractLoop
    ref = spec.ref
    body = @inbounds n.children[1]
    op = n.op
    rng = spec.lo:spec.step:spec.hi
    isempty(rng) && return T(n.literal)
    ref[] = first(rng)
    b1 = _eval_node(body, u, p, t, T)
    s = T(_oplus_numeric(op, n.literal, b1))
    rng = (first(rng) + spec.step):spec.step:spec.hi
    if op === :+
        @inbounds for k in rng
            ref[] = k
            s += _eval_node(body, u, p, t, T)
        end
    elseif op === :*
        @inbounds for k in rng
            ref[] = k
            s *= _eval_node(body, u, p, t, T)
        end
    elseif op === :max
        @inbounds for k in rng
            ref[] = k
            s = max(s, _eval_node(body, u, p, t, T))
        end
    elseif op === :min
        @inbounds for k in rng
            ref[] = k
            s = min(s, _eval_node(body, u, p, t, T))
        end
    else
        _throw_unknown_reducer(op)
    end
    return s
end

# `_RaggedLoop`'s fold (see there): the bounds are evaluated first, lower then
# upper, then the terms in range order, folded into the `Float64` 0̄ (a row with
# no terms is that 0̄, as the per-cell build's literal for it is).
function _eval_ragged_loop(n::_Node, u, p, t, ::Type{T}) where {T}
    spec = n.payload::_RaggedLoop
    ref = spec.ref
    ch = n.children
    body = @inbounds ch[1]
    lo = round(Int, _eval_node(@inbounds(ch[2]), u, p, t, T))
    hi = round(Int, _eval_node(@inbounds(ch[3]), u, p, t, T))
    rng = lo:spec.step:hi
    isempty(rng) && return n.literal
    op = n.op
    z = n.literal
    # The first step is `0̄ ⊕ term` with the `Float64` 0̄, which also fixes the
    # accumulator's type for the loop.
    ref[] = first(rng)
    v = _eval_node(body, u, p, t, T)
    s = _oplus_numeric(op, z, v)
    for k in Iterators.drop(rng, 1)
        ref[] = k
        v = _eval_node(body, u, p, t, T)
        s = _oplus_numeric(op, s, v)
    end
    return s
end

# Runtime ⊕-reduction over a node's children, parameterized by semiring (§5.1).
# The accumulator is seeded from `n.literal`, the 0̄ identity baked onto the node
# at build time from the registry table — so every arm (incl. empty-or-folded
# max/min/×) returns the normative identity without any hardcoded constant here.
# Every arm has ONE shape: an `@inbounds` sequential fold over the children
# seeded from `n.literal`. The `:+` arm sums from 0.0 (sum_product's 0̄, the only
# ⊕=+ semiring) in child order — allocation-free and bit-identical to the prior
# `@tullio s = …` sum (which `zero`-seeds the same sequential accumulation). The
# Tullio form built per-call codegen machinery (~80 B per reduced cell); keeping
# the arms structurally identical is what makes the RHS `f!` non-allocating
#. This node is only built with ≥1 child (the empty case folds to a
# literal upstream).
# bool_and_or's ⊕ (§5.1) on the evaluator's 1.0/0.0 encoding of a truth value:
# a fold step, so both operands are evaluated, as the other bindings' reductions
# combine them. The emitted folds (codegen_kernel.jl, array_contraction.jl) call
# this same function.
@inline _or_combine(acc, term) = ((acc != 0) | (term != 0)) ? 1.0 : 0.0

function _eval_contraction(n::_Node, u, p, t, ::Type{T}) where {T}
    op = n.op
    children = n.children
    if op === :+
        s = n.literal  # 0̄ = 0.0 for sum_product
        @inbounds for k in eachindex(children)
            s += _eval_node(children[k], u, p, t, T)
        end
        return s
    elseif op === :*
        s = n.literal  # 1̄ for the ×-reduce
        @inbounds for k in eachindex(children)
            s *= _eval_node(children[k], u, p, t, T)
        end
        return s
    elseif op === :max
        s = n.literal  # -∞
        @inbounds for k in eachindex(children)
            s = max(s, _eval_node(children[k], u, p, t, T))
        end
        return s
    elseif op === :or
        s = n.literal  # false
        @inbounds for k in eachindex(children)
            s = _or_combine(s, _eval_node(children[k], u, p, t, T))
        end
        return s
    elseif op === :min
        s = n.literal  # +∞
        @inbounds for k in eachindex(children)
            s = min(s, _eval_node(children[k], u, p, t, T))
        end
        return s
    end
    return _throw_unknown_reducer(op)
end

# ---- The scalar walker's operator ladder ----
#
# Generated from the operator registry (`_op_ladder`, tree_walk/op_ladder.jl):
# one compare-and-branch arm per shaped registry row, each checking the registry
# arity. The setup-time GEOMETRY nodes (tree_walk/geometry_compile.jl) sit at the
# tail: they exist only in build-time compiled geometry bodies, where `u` is a
# small loop-index frame, never the ODE state, so the right-hand side's operators
# never reach that arm.
@eval function _eval_node_op(n::_Node, u, p, t, ::Type{T}) where {T}
    op = n.op
    c = n.children
    $(
        _op_ladder(
            i -> :(_eval_node(c[$i], u, p, t, T)), :(length(c)),
            quote
                if op === :geo_gather || op === :geo_agg || op === :geo_count ||
                        op === :cellmemo || op === :geomemo
                    return _eval_geo_op(n, u, p, t, T)
                end
                throw(_unevaluable_operator(op, "the scalar ladder has no arm for it"))
            end
        )
    )
end
