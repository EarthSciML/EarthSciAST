# ========================================================================
# ext/reactant_direct/batch.jl — the LANE-BATCHED scalar surface.
# ========================================================================
#
# WHY THIS FILE EXISTS. A scalar surface — the `rhs_list` entries a state
# equation lowers to when it declines the kernel path, and a materialized
# observed level's per-column `scalars` — is a list of (slot, tree) entries that
# are per-cell INSTANTIATIONS OF ONE EXPRESSION: same tree, same ops, same loop
# ranges, differing only in the baked-in cell data (state slots, forcing
# offsets, gather subscripts, inlined per-cell constants). Walking them one at a
# time emits the tree once per cell, and every state leaf of every instance is
# its own ONE-ELEMENT read.
#
# The `:oop` build already groups them: `_oop_batch_scalars` (src/tree_walk/
# oop.jl, ess-oop-batch) buckets the entries by a canonical structural signature
# that wildcards exactly the lane-varying leaves, lowers each bucket ONCE to a
# lane-batched tree (`_OopBatchNode`) and leaves everything it could not group
# in `rest`. The interpreter runs a group as whole-lane operations over its lane
# axis, landing through one scatter. This file is the emission twin: the same
# groups, the same lane axis, `stablehlo` ops instead of broadcasts — so a state
# leaf is ONE gather of L slots instead of L one-element slices, and the emitted
# program is O(tree) per group rather than O(tree × cells).
#
# WHAT IT BUYS, AND WHY IT IS THE SHAPE THAT MATTERS. The single-position slice
# is the op the post-differentiation `enzyme-hlo-opt` pass is quadratic in: its
# `cse_slice` pattern compares slices pairwise, Enzyme's reverse of a slice is a
# pad-and-add, and the adjoint of ReSEACT's transport half carried tens of
# thousands of them. Every other lever against that population (the read cost
# model, the gather base budget, emitter-side CSE, pass exclusion) works on
# reads the emitter had already decided to SHATTER; this one removes the
# shattering, because a group's varying state leaf is a lane VECTOR and a lane
# vector is one gather. See reseact.esm's COMPILE_COST.md section 6.
#
# BIT-IDENTITY. Every arm below performs, per lane, the operations the scalar
# walk performs for that lane's own entry, in the same order: `_de_fold_terms`
# keeps the contraction's seeded ⊕-fold and the loop's ascending-k accumulate,
# a ghost state-gather reads the same structural zero, a literal exponent stays
# a literal (the signature pins it, so a group never blends the power rule), and
# a subtree that is host data in every lane is folded on host by the SAME
# `_de_hostval` the scalar walk uses — per lane, so the folded constant is the
# scalar walk's constant. `ESS_OOP_BATCH=0` puts every entry in `rest` and this
# file then emits nothing at all.
#
# ORDER. `rest` first, then the groups, exactly as `_oop_run_scalar_batches`
# runs them. The reorder is sound for the reason stated at the ess-oop-batch
# section header: entries within one surface write DISJOINT slots and never read
# each other, so it moves only writes.

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
        b.op === :fn && return false
        (haskey(_DE_UNARY, b.op) || haskey(_DE_COMPARE, b.op) ||
         haskey(_DE_UNARY_CHLO, b.op) ||
         b.op in (:+, :*, :-, :neg, :/, :^, :pow, :max, :min, :ifelse, :not,
                  :and, :or, :pi, :π, :e, :Pre, :atan, :atan2, :log10)) || return false
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
        return Float64(b.refs[l][])
    elseif k === _E._NK_PARAM
        return Float64(getfield(ctx.p, b.sym)::Real)
    elseif k === _E._NK_CONST_GATHER
        return _de_hostval(ctx, b.nodes[l])
    elseif k === _E._NK_CONTRACTION
        s = b.literal
        g = _de_semiring_jl(b.op)
        for c in b.children
            s = g(s, _de_bhostval(ctx, c, l))
        end
        return s
    elseif k === _E._NK_CONTRACTION_LOOP
        g = _de_semiring_jl(b.op)
        s = b.literal
        body = b.children[1]
        r = b.refs[l]
        for kk in b.lo:b.step:b.hi
            r[] = kk
            s = g(s, _de_bhostval(ctx, body, l))
        end
        return s
    end
    c = Any[_de_bhostval(ctx, ch, l) for ch in b.children]
    return Float64(_E._scalar_op(b.op, c, Float64))
end

function _de_btry_fold(ctx::_DECtx, b::_E._OopBatchNode, L::Int)::Union{Nothing,_DEVal}
    b.kind === _E._NK_LITERAL && return nothing     # already one constant
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

function _de_batch(ctx::_DECtx, b::_E._OopBatchNode, L::Int,
                   cache::Vector{_DEVal})::_DEVal
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
            _de_refuse("a lane-batched `_NK_CACHED` read",
                "the group references CSE slot $(b.idx) on a surface emitted " *
                "without a CSE cache.")
        return cache[b.idx]
    elseif k === _E._NK_PARAM_GATHER
        buf = _de_buffer(ctx, b.payload::Vector{Float64})
        return isempty(b.slots) ? _de_slice(ctx, buf, b.idx, b.idx; why=:pgather) :
                                  _de_take(ctx, buf, b.slots)
    elseif k === _E._NK_LOOPVAR
        # Per lane: congruent trees may bind DIFFERENT enclosing loops at this
        # position, so read each lane's own counter.
        refs = b.refs
        v1 = refs[1][]
        all(r -> r[] == v1, refs) && return _de_const(ctx, Float64(v1))
        return _de_arrconst(ctx, Float64[Float64(r[]) for r in refs])
    elseif k === _E._NK_CONST_GATHER
        # `_de_btry_fold` above already took every case where the subscripts are
        # host data, which is every case `_NK_CONST_GATHER` can be in.
        _de_refuse("a lane-batched const gather with non-host subscripts",
            "a `_NK_CONST_GATHER` subscript is loop-counter and literal " *
            "arithmetic by construction; this one did not resolve on host.")
    elseif k === _E._NK_STATE_GATHER
        # Per-lane slot resolution on host, then ONE read of the slot map.
        # A ghost lane is a STRUCTURAL ZERO in the read (`_DEMap`'s `nothing`),
        # which is the same 0.0 the scalar arm returns for it.
        nds = b.nodes
        srcs = Vector{_DESlot}(undef, length(nds))
        @inbounds for l in eachindex(nds)
            nd = nds[l]
            sg = nd.payload::_E._StateGather
            off = 0
            ghost = false
            for d in eachindex(nd.children)
                sub = _de_index_int(nd.children[d])
                if !(sg.lo[d] <= sub <= sg.hi[d])
                    ghost = true
                    break
                end
                off += (sub - sg.lo[d]) * sg.strides[d]
            end
            srcs[l] = ghost ? nothing : _de_src(ctx, ctx.ue, sg.slot_flat[off + 1])
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
                r[] = kk
            end
            push!(terms, _de_batch(ctx, body, L, cache))
        end
        return _de_fold_terms(ctx, b.op, b.literal, terms)
    elseif k === _E._NK_CONTRACTION
        terms = _DEVal[_de_batch(ctx, c, L, cache) for c in b.children]
        return _de_fold_terms(ctx, b.op, b.literal, terms)
    elseif k === _E._NK_OP
        if b.op === :fn
            return _de_fn_pl(ctx, b.payload,
                             _DEVal[_de_batch(ctx, c, L, cache) for c in b.children])
        end
        if (b.op === :^ || b.op === :pow) && length(b.children) == 2
            e = b.children[2]
            if e.kind === _E._NK_LITERAL && isempty(e.lanes_f)
                base = _de_batch(ctx, b.children[1], L, cache)
                return _de_bin(ctx, _hlo.power, base, _de_const(ctx, e.literal))
            end
        end
        c = _DEVal[_de_batch(ctx, ch, L, cache) for ch in b.children]
        return _de_op(ctx, b.op, c)
    end
    _de_refuse("the lane-batched node kind $(_de_kindname(k))",
        "no arm of `_de_batch` lowers it. The batch lowering " *
        "(`_oop_batch_lower`) and this walk must cover the same kinds; a kind " *
        "it can group and this cannot is the gap.")
end

# ---- one scalar surface ------------------------------------------------------
#
# `_oop_run_scalar_batches` in SSA form: the leftover singles through the
# per-entry scalar walk, then each group as one whole-lane evaluation landing
# through one write into the target slot map.

function _de_scalar_surface!(ctx::_DECtx, out::_DEMap,
                             sb::_E._OopScalarBatches, cache::Vector{_DEVal},
                             what::AbstractString)
    for (slot, nd) in sb.rest
        _de_rule!("$what for $(_de_slotname(ctx, slot))") do
            _de_write!(ctx, out, Int[slot], _de_scalar(ctx, nd, cache))
        end
    end
    for g in sb.groups
        slots = g.slots
        _de_rule!("$what for the lane-batched group writing " *
                  "$(_de_slotsname(ctx, slots))") do
            val = _de_batch(ctx, g.root, length(slots), cache)
            _de_tally!(ctx, :scalar_batch)
            _de_write!(ctx, out, slots, val)
        end
    end
    return nothing
end
