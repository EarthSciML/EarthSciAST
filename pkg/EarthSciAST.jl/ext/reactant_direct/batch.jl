# ========================================================================
# ext/reactant_direct/batch.jl — the LANE-BATCHED scalar surface.
# ========================================================================
#
# A scalar surface (the `rhs_list` entries of an equation that declines the kernel
# path, and a materialized observed level's per-column `scalars`) is a list of
# (slot, tree) entries that are per-cell instances of one expression, differing
# only in baked-in cell data. `_oop_batch_scalars` (src/tree_walk/oop.jl) groups
# them by a structural signature that wildcards exactly the lane-varying leaves,
# lowers each group once to a lane-batched tree (`_OopBatchNode`) and leaves the
# ungroupable entries in `rest`. This file emits each group as whole-lane
# operations landing through one scatter, so a varying state leaf is one gather
# of L slots rather than L one-element slices (the read population the
# post-differentiation `enzyme-hlo-opt` pass is quadratic in).
#
# BIT-IDENTITY. Every arm performs, per lane, the operations the scalar walk
# performs for that lane's entry, in the same order: `_de_fold_terms` keeps the
# seeded ⊕-fold and the ascending-k accumulate, a ghost state-gather reads the
# same structural zero, a literal exponent stays a literal (the signature pins
# it), and a subtree that is host data in every lane is folded per lane by the
# same `_de_hostval` the scalar walk uses. With scalar batching off every entry
# is in `rest` and this file emits nothing.
#
# ORDER. `rest` first, then the groups, as the grouping orders them. Entries of
# one surface write disjoint slots and never read each other (see
# `_oop_batch_scalars`), so the reorder moves only writes.

# ---- the per-lane host fold --------------------------------------------------
#
# The batched twin of `_de_try_fold`. A batch subtree all of whose leaves are
# host data IN EVERY LANE (literals, enclosing loop counters, host parameters,
# frozen const-gathers) is evaluated here, lane by lane, and emitted as ONE
# array constant rather than as a subgraph — which is what keeps a contraction
# loop over frozen index arithmetic from emitting its whole range. Per lane it
# is `_de_hostval`'s own arithmetic, so a folded group agrees with the scalar
# walk's folded entry bit for bit.

function _de_bstatic(ctx::_DECtx, b::_E._OopBatchNode)::Bool
    hit = get(ctx.bstatic, b, nothing)
    hit === nothing || return hit
    r = _de_bstatic_uncached(ctx, b)
    ctx.bstatic[b] = r
    return r
end

function _de_bstatic_uncached(ctx::_DECtx, b::_E._OopBatchNode)::Bool
    k = b.kind
    if k === _E._NK_LITERAL || k === _E._NK_LOOPVAR
        return true
    elseif k === _E._NK_PARAM
        p = ctx.p
        p isa NamedTuple || return false
        hasproperty(p, b.sym) || return false
        return getfield(p, b.sym) isa Real
    elseif k === _E._NK_CONST_GATHER
        # Every lane's subscripts are loop-counter / literal integer arithmetic
        # (`_de_index_int`), which is the property `_NK_CONST_GATHER` carries by
        # construction — the scalar walk's `_de_static` asks the same of the
        # per-entry node's children.
        return all(nd -> all(ch -> _de_static(ctx, ch), nd.children), b.nodes)
    elseif k === _E._NK_CONTRACTION
        return all(c -> _de_bstatic(ctx, c), b.children)
    elseif k === _E._NK_CONTRACTION_LOOP
        return _de_bstatic(ctx, b.children[1])
    elseif k === _E._NK_OP
        _de_foldable_op(b.op) || return false
        return all(c -> _de_bstatic(ctx, c), b.children)
    end
    return false
end

# Lane `l` of a host-static batch subtree, in Float64, by the interpreter's own
# ladder — `_de_hostval` restricted to one lane.
function _de_bhostval(ctx::_DECtx, b::_E._OopBatchNode, l::Int)::Float64
    k = b.kind
    if k === _E._NK_LITERAL
        return isempty(b.lanes_f) ? b.literal : b.lanes_f[l]
    elseif k === _E._NK_LOOPVAR
        return Float64(_de_counter(ctx, b.refs[l]))
    elseif k === _E._NK_PARAM
        return Float64(getfield(ctx.p, b.sym)::Real)
    elseif k === _E._NK_CONST_GATHER
        return _de_hostval(ctx, b.nodes[l])
    elseif k === _E._NK_CONTRACTION
        terms = Float64[_de_bhostval(ctx, c, l) for c in b.children]
        return _de_host_fold(ctx, b.op, b.literal, terms)
    elseif k === _E._NK_CONTRACTION_LOOP
        body = b.children[1]
        r = b.refs[l]
        terms = Float64[]
        for kk in b.lo:b.step:b.hi
            _de_set_counter!(ctx, r, kk)
            push!(terms, _de_bhostval(ctx, body, l))
        end
        return _de_host_fold(ctx, b.op, b.literal, terms)
    end
    c = Any[_de_bhostval(ctx, ch, l) for ch in b.children]
    return _de_host_op(ctx, b.op, c)
end

function _de_btry_fold(ctx::_DECtx, b::_E._OopBatchNode, L::Int)::Union{Nothing, _DEVal}
    b.kind === _E._NK_LITERAL && return nothing     # already one constant
    (ctx.precision !== Float64 && b.kind in _DE_FOLD_KINDS) && return nothing
    _de_bstatic(ctx, b) || return nothing
    _de_tally!(ctx, :const_folded)
    vals = Float64[_de_bhostval(ctx, b, l) for l in 1:L]
    allsame = true
    @inbounds for l in 2:L
        allsame &= isequal(vals[l], vals[1])
    end
    return allsame ? _de_const(ctx, vals[1]) : _de_arrconst(ctx, vals)
end

# ---- the walk ----------------------------------------------------------------
#
# Returns a length-`L` lane vector, or a length-1 value where the subtree is
# lane-invariant — `_de_bin` / `_de_fold_terms` broadcast the two together, so
# they are interchangeable exactly as they are in the batch lowering.

function _de_batch(
        ctx::_DECtx, b::_E._OopBatchNode, L::Int,
        cache::Vector{_DEVal}
    )::_DEVal
    folded = _de_btry_fold(ctx, b, L)
    folded === nothing || return folded
    k = b.kind
    if k === _E._NK_LITERAL
        return isempty(b.lanes_f) ? _de_const(ctx, b.literal) :
            _de_arrconst(ctx, b.lanes_f)
    elseif k === _E._NK_STATE
        # THE READ THIS FILE EXISTS FOR: L one-element slices become one gather.
        return isempty(b.slots) ? _de_read(ctx, ctx.ue, b.idx, :state) :
            _de_gather(ctx, ctx.ue, b.slots)
    elseif k === _E._NK_PARAM
        return _de_param(ctx, b.sym)
    elseif k === _E._NK_TIME
        return ctx.t
    elseif k === _E._NK_CACHED
        (1 <= b.idx <= length(cache)) ||
            _de_refuse(
            ctx,
            "a lane-batched `_NK_CACHED` read",
            "the group references CSE slot $(b.idx) on a surface emitted " *
                "without a CSE cache."
        )
        return cache[b.idx]
    elseif k === _E._NK_PARAM_GATHER
        return _de_buffer_read(ctx, b.payload::Vector{Float64}, isempty(b.slots) ? b.idx : b.slots)
    elseif k === _E._NK_LOOPVAR
        # Per lane: congruent trees may bind DIFFERENT enclosing loops at this
        # position, so read each lane's own counter.
        refs = b.refs
        v1 = _de_counter(ctx, refs[1])
        all(r -> _de_counter(ctx, r) == v1, refs) && return _de_const(ctx, Float64(v1))
        return _de_arrconst(ctx, Float64[Float64(_de_counter(ctx, r)) for r in refs])
    elseif k === _E._NK_CONST_GATHER
        # `_de_btry_fold` above already took every case where the subscripts are
        # host data, which is every case `_NK_CONST_GATHER` can be in.
        _de_refuse(
            ctx,
            "a lane-batched const gather with non-host subscripts",
            "a `_NK_CONST_GATHER` subscript is loop-counter and literal " *
                "arithmetic by construction; this one did not resolve on host."
        )
    elseif k === _E._NK_STATE_GATHER
        # Per-lane slot resolution on host, then ONE read of the slot map.
        # A ghost lane is a STRUCTURAL ZERO in the read (`_DEMap`'s `nothing`),
        # which is the same 0.0 the scalar arm returns for it.
        nds = b.nodes
        srcs = Vector{_DESlot}(undef, length(nds))
        @inbounds for l in eachindex(nds)
            nd = nds[l]
            slot = _E._state_gather_slot(
                nd.payload::_E._StateGather, length(nd.children),
                d -> _de_index_int(ctx, nd.children[d])
            )
            srcs[l] = slot == 0 ? nothing : _de_src(ctx, ctx.ue, slot)
        end
        return _de_emit_runs(ctx, srcs)
    elseif k === _E._NK_CONTRACTION_LOOP
        # The whole group's reduction in ONE loop of `length(lo:step:hi)`
        # whole-lane steps: write every lane's counter, evaluate the body once
        # over lanes, fold. Per lane this is the scalar loop's ascending-k fold
        # from the same 0̄.
        body = b.children[1]
        refs = b.refs
        terms = _DEVal[]
        for kk in b.lo:b.step:b.hi
            @inbounds for r in refs
                _de_set_counter!(ctx, r, kk)
            end
            push!(terms, _de_batch(ctx, body, L, cache))
        end
        return _de_fold_terms(ctx, b.op, b.literal, terms)
    elseif k === _E._NK_CONTRACTION
        terms = _DEVal[_de_batch(ctx, c, L, cache) for c in b.children]
        return _de_fold_terms(ctx, b.op, b.literal, terms)
    elseif k === _E._NK_OP
        if (b.op === :^ || b.op === :pow) && length(b.children) == 2
            e = b.children[2]
            if e.kind === _E._NK_LITERAL && isempty(e.lanes_f)
                base = _de_batch(ctx, b.children[1], L, cache)
                return _de_bin(ctx, _hlo.power, base, _de_const(ctx, e.literal))
            end
        end
        exact = _de_exact_compare(ctx, b)
        exact === nothing || return exact
        c = _DEVal[_de_batch(ctx, ch, L, cache) for ch in b.children]
        return _de_op(ctx, b.op, c)
    end
    return _de_refuse(
        ctx,
        "the lane-batched node kind $(_de_kindname(k))",
        "no arm of `_de_batch` lowers it. The batch lowering " *
            "(`_oop_batch_lower`) and this walk must cover the same kinds; a kind " *
            "it can group and this cannot is the gap."
    )
end

# ---- one scalar surface ------------------------------------------------------
#
# The batch surface in SSA form: the leftover singles through the
# per-entry scalar walk, then each group as one whole-lane evaluation landing
# through one write into the target slot map.

function _de_scalar_surface!(
        ctx::_DECtx, out::_DEMap,
        sb::_E._OopScalarBatches, cache::Vector{_DEVal},
        what::AbstractString
    )
    for (slot, nd) in sb.rest
        _de_rule!(ctx, "$what for $(_de_slotname(ctx, slot))") do
            _de_write!(ctx, out, Int[slot], _de_scalar(ctx, nd, cache))
        end
    end
    for g in sb.groups
        slots = g.slots
        _de_rule!(
            ctx,
            "$what for the lane-batched group writing " *
                "$(_de_slotsname(ctx, slots))"
        ) do
            val = _de_batch(ctx, g.root, length(slots), cache)
            _de_tally!(ctx, :scalar_batch)
            _de_write!(ctx, out, slots, val)
        end
    end
    return nothing
end
