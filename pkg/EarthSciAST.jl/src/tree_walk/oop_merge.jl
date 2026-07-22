# ========================================================================
# tree_walk/oop_merge.jl — part of the tree-walk evaluator (array-IR B).
# Included by src/tree_walk.jl AFTER oop.jl (`_OopAccPlan`,
# `_build_oop_acc_plan`) and acc_merge.jl (`_fn_spec_hash`,
# `_check_fn_group_specs`). Owns the :oop KERNEL-CLASS merge: the post-plan
# pass `_make_rhs_oop` runs to collapse per-cell-fragmented `_AccKernel`s
# into lane-batched class kernels.
#
# WHY. `_acc_from_cell_entries` merges the per-cell entries OF ONE ARRAY
# EQUATION; what it cannot see is that a stencil model instantiates the same
# equation once per cell/column with different ghost patterns and interp
# specs, yielding thousands of structurally identical mostly-1-lane kernels
# (ReSEACT transport at 7×7×8: 4,119 kernels, 7.93M IR nodes, only ~346
# distinct classes). The interpreted walkers tolerate that; an XLA tracer
# (Reactant) does not — it retraces every kernel body, so IR volume is the
# whole cost. This pass groups kernels by a lockstep-structure signature and
# merges each class into ONE kernel whose varying leaves become per-lane
# tables using the STOCK descriptors:
#
#   varying state slot   -> _AccStateTblBox(tbl,1,0,0,1)   (0 entry = ghost 0.0)
#   varying const/literal-> _AccConstBox(tbl,1,0,0,1)      (frozen per-lane)
#   varying forcing index-> _AccArrTblBox(buf,tbl,1,0,0,1) (LIVE re-gather)
#
# with `_outs_cells` lane addressing (m1 = lane ordinal, so s1=1/off=1).
# Per-lane index/const data comes from each member's already-built
# `_OopAccPlan` tables; template-body sub-kernels are merged recursively the
# same way (their plans are parent-lane-aligned), with the sub inv-CSE tier
# folded into the cell tier (same values, lane-vectorized). Evaluation is
# stock `_build_oop_acc_plan` + `_oop_run_acc_vec` — per-lane semantics
# (fold order, ghost select, interp) stay EarthSciAST's.
#
# BIT-IDENTITY BY CONSTRUCTION. A leaf equal across the group stays scalar;
# a varying one is transposed into a table indexed by lane ordinal; the op
# sequence applied per lane is byte-identical to the unmerged kernel's.
# `_oop_scatter` is ASSIGNMENT, and the pass merges only when every kernel
# out-slot is globally unique, so concatenating groups cannot reorder any
# read-after-write. Closed-function payloads ride from the class
# representative and are guarded by `_check_fn_group_specs` (content-equal
# or loud build error — never silent wrong numbers).
#
# SAFETY POSTURE. This is a default-on optimization of a correct baseline,
# so every "can't" is a fallback, not an error: overlapping out-slots, a
# blocked kernel (reduce segment / unmergeable descriptor kind / nested
# sub-subs), a failed group merge, or a merged kernel whose fresh plan is
# not vectorizable — each falls back to the original kernels for that scope.
# `ESS_OOP_MERGE_DISABLE=1` restores the unmerged build byte for byte.
# ========================================================================

_oop_merge_disabled() = get(ENV, "ESS_OOP_MERGE_DISABLE", "") == "1"

_oop_mergeable_acc_kind(k) =
    k in (_AK_STATE_AFFINE, _AK_STATE_TBL_BOX, _AK_STATE_FIXED,
          _AK_SCALAR, _AK_CONST_AFFINE, _AK_CONST_BOX,
          _AK_CONST_CELL, _AK_LOOP_IDX, _AK_ARR_FIXED,
          _AK_FORCING_BOX, _AK_ARR_TBL_BOX)

# Signature equal for two kernels iff they can be evaluated in LOCKSTEP: same
# tree shape and op/payload structure, with per-lane-varying leaves (state
# slots, const values, literals, forcing indices) left free — those become
# tables. Access descriptors key by FAMILY (state / const / per-buffer
# forcing), not exact kind: the clone tables every member of a family
# identically, so an interior AFFINE cell and a boundary TBL_BOX cell of the
# same equation share a class.
function _oop_merge_sig!(io::IOBuffer, n::_Node, K::_AccKernel, parentsubs,
                         why::Base.RefValue{Symbol})
    k = n.kind
    if k === _NK_ACCESS
        a = K.acc[n.idx]
        _oop_mergeable_acc_kind(a.kind) || (why[] = :acc_kind)
        if a.kind in (_AK_STATE_AFFINE, _AK_STATE_TBL_BOX, _AK_STATE_FIXED)
            print(io, "AS")
        elseif a.kind in (_AK_ARR_FIXED, _AK_FORCING_BOX, _AK_ARR_TBL_BOX)
            print(io, "AF", "b", objectid(a.arr))
        else
            print(io, "AC")
        end
    elseif k === _NK_LITERAL
        print(io, "L")                     # value free (tabled if varying)
    elseif k === _NK_PARAM
        print(io, "P", n.sym)
    elseif k === _NK_TIME
        print(io, "T")
    elseif k === _NK_CACHED
        print(io, "C", n.payload === K.cse.scratch ? "c" : "i", n.idx)
    elseif k === _NK_CONTRACTION
        print(io, "K", n.op, "s", n.literal, "(")
        for c in n.children; _oop_merge_sig!(io, c, K, parentsubs, why); end
        print(io, ")")
    elseif k === _NK_SUBCALL
        pos = findfirst(s -> s === n.payload, parentsubs)
        pos === nothing && (why[] = :subcall_unknown; return)
        print(io, "S", pos)
    elseif k === _NK_REDUCE
        why[] = :reduce; print(io, "X")
    elseif k === _NK_OP
        print(io, "O", n.op)
        pl = n.payload
        if pl isa Tuple && length(pl) >= 1
            print(io, "@", pl[1])
            # CONTENT hash (see acc_merge.jl): the merged kernel carries ONE
            # spec, so cells with different interp tables must land in
            # different classes. A collision is caught loudly by
            # `_check_fn_group_specs` in the clone.
            length(pl) >= 2 && print(io, "#", _fn_spec_hash(pl[2]))
        end
        print(io, "(")
        for c in n.children; _oop_merge_sig!(io, c, K, parentsubs, why); end
        print(io, ")")
    else
        why[] = :node_kind; print(io, "?", Int(k))
    end
    return io
end

function _oop_merge_trees_sig!(io::IOBuffer, K::_AccKernel, parentsubs, why)
    print(io, "z", K.zerobar, "|")
    _oop_merge_sig!(io, K.spine, K, parentsubs, why); print(io, "|I")
    for r in K.cse.inv_recipes; _oop_merge_sig!(io, r, K, parentsubs, why); print(io, ";"); end
    print(io, "|R")
    for r in K.cse.recipes; _oop_merge_sig!(io, r, K, parentsubs, why); print(io, ";"); end
    return io
end

function _oop_merge_kernel_sig(K::_AccKernel, plan::_OopAccPlan)
    why = Ref(:ok)
    plan.vectorizable || (why[] = :unvectorizable)
    isempty(plan.red_seg) || (why[] = :reduce)
    io = IOBuffer()
    _oop_merge_trees_sig!(io, K, K.subs, why)
    for (si, S) in enumerate(K.subs)
        isempty(S.subs) || (why[] = :nested_sub_subs)
        print(io, "|SUB", si, ":")
        _oop_merge_trees_sig!(io, S, K.subs, why)
    end
    return why[] === :ok ? String(take!(io)) : nothing, why[]
end

# Merge one class of lockstep-identical kernels (indices `js` into
# kernels/plans) into a single lane-batched kernel. Members' lanes are
# concatenated in `js` order; each varying leaf becomes a table over the
# merged lane ordinal, read through `_outs_cells` addressing (s1=1, off=1).
function _oop_merge_group(kernels, plans, js::Vector{Int})
    m = length(js); Ls = Int[length(plans[j].out_slots) for j in js]; L = sum(Ls)
    rep = kernels[js[1]]
    nsubs = length(rep.subs)
    @assert all(j -> length(kernels[j].subs) == nsubs, js)
    merged_subs = Vector{_AccKernel}(undef, nsubs)

    # Merge one aligned tree-family (parent trees or sub-si trees). Kof(i) /
    # Pof(i): member i's context kernel and the plan whose tables resolve that
    # context's descriptors — sub plans are built against PARENT lanes, so
    # every table below has member-lane length by construction.
    function merge_trees(Kof, Pof)
        accvec = _AccDesc[]
        n_inv = length(Kof(1).cse.inv_recipes); n_cell = length(Kof(1).cse.recipes)
        @assert all(i -> length(Kof(i).cse.inv_recipes) == n_inv &&
                         length(Kof(i).cse.recipes) == n_cell, 1:m)
        newscr = _AccScratch(n_inv + n_cell)
        function clone(nodes::Vector{_Node})::_Node
            r = nodes[1]; k = r.kind
            if k === _NK_LITERAL
                vals = Float64[n.literal for n in nodes]
                if all(==(vals[1]), vals)
                    return _Node(k, r.op, r.literal, r.idx, r.sym, nothing, _Node[])
                end
                tbl = Vector{Float64}(undef, L); q = 0
                for i in 1:m
                    tbl[q+1:q+Ls[i]] .= vals[i]; q += Ls[i]
                end
                push!(accvec, _AccConstBox(tbl, 1, 0, 0, 1))
                return _Node(_NK_ACCESS, :acc, 0.0, length(accvec), Symbol(""), nothing, _Node[])
            elseif k === _NK_PARAM || k === _NK_TIME
                return _Node(k, r.op, r.literal, r.idx, r.sym, r.payload, _Node[])
            elseif k === _NK_CACHED
                # Sub inv tier folds into the cell tier: recompute per lane
                # (values identical; the lanes ARE the vectorization).
                tier_cell = r.payload === Kof(1).cse.scratch
                @assert all(i -> (nodes[i].payload === Kof(i).cse.scratch) == tier_cell, 1:m)
                nidx = tier_cell ? n_inv + r.idx : r.idx
                return _Node(k, r.op, r.literal, nidx, r.sym, newscr, _Node[])
            elseif k === _NK_SUBCALL
                pos = findfirst(s -> s === r.payload, kernels[js[1]].subs)
                @assert pos !== nothing
                @assert all(i -> kernels[js[i]].subs[pos] === nodes[i].payload, 1:m)
                @assert isassigned(merged_subs, pos) "nested-first order violated"
                return _Node(k, r.op, r.literal, r.idx, r.sym, merged_subs[pos], _Node[])
            elseif k === _NK_ACCESS
                akind = Kof(1).acc[r.idx].kind
                if akind in (_AK_STATE_AFFINE, _AK_STATE_TBL_BOX, _AK_STATE_FIXED)
                    tbl = Vector{Int}(undef, L); q = 0
                    for i in 1:m
                        lk = Ls[i]; idx = nodes[i].idx
                        a = Kof(i).acc[idx]; pl = Pof(i)
                        if a.kind === _AK_STATE_FIXED
                            tbl[q+1:q+lk] .= a.idx
                        elseif a.kind === _AK_STATE_AFFINE
                            tbl[q+1:q+lk] .= pl.gathers[idx]
                        else # TBL_BOX: reconstruct the raw table (0 = ghost)
                            g = pl.gathers[idx]; gh = pl.ghost[idx]
                            if isempty(gh); tbl[q+1:q+lk] .= g
                            else; for mm in 1:lk; tbl[q+mm] = gh[mm] ? 0 : g[mm]; end; end
                        end
                        q += lk
                    end
                    push!(accvec, _AccStateTblBox(tbl, 1, 0, 0, 1))
                elseif akind in (_AK_SCALAR, _AK_CONST_AFFINE, _AK_CONST_BOX,
                                 _AK_CONST_CELL, _AK_LOOP_IDX)
                    tbl = Vector{Float64}(undef, L); q = 0
                    for i in 1:m
                        lk = Ls[i]; idx = nodes[i].idx
                        a = Kof(i).acc[idx]; pl = Pof(i)
                        if a.kind === _AK_SCALAR
                            tbl[q+1:q+lk] .= a.v
                        else
                            tbl[q+1:q+lk] .= pl.consts[idx]
                        end
                        q += lk
                    end
                    push!(accvec, _AccConstBox(tbl, 1, 0, 0, 1))
                else # ARR_FIXED / FORCING_BOX / ARR_TBL_BOX (live; same buffer by sig)
                    arr = Kof(1).acc[r.idx].arr
                    tbl = Vector{Int}(undef, L); q = 0
                    for i in 1:m
                        lk = Ls[i]; idx = nodes[i].idx
                        a = Kof(i).acc[idx]; pl = Pof(i)
                        if a.kind === _AK_ARR_FIXED
                            tbl[q+1:q+lk] .= a.idx
                        else
                            tbl[q+1:q+lk] .= pl.forc[idx]
                        end
                        q += lk
                    end
                    push!(accvec, _AccArrTblBox(arr, tbl, 1, 0, 0, 1))
                end
                return _Node(_NK_ACCESS, :acc, 0.0, length(accvec), Symbol(""), nothing, _Node[])
            else # _NK_OP / _NK_CONTRACTION: payload rides from the rep — guard fn specs
                (k === _NK_OP && r.op === :fn && r.payload isa Tuple) &&
                    _check_fn_group_specs(nodes)
                ch = Vector{_Node}(undef, length(r.children))
                for ci in eachindex(r.children)
                    ch[ci] = clone(_Node[n.children[ci] for n in nodes])
                end
                return _Node(k, r.op, r.literal, r.idx, r.sym, r.payload, ch)
            end
        end
        spine = clone(_Node[Kof(i).spine for i in 1:m])
        recipes = Vector{_Node}(undef, n_inv + n_cell)
        for i2 in 1:n_inv
            recipes[i2] = clone(_Node[Kof(i).cse.inv_recipes[i2] for i in 1:m])
        end
        for i2 in 1:n_cell
            recipes[n_inv + i2] = clone(_Node[Kof(i).cse.recipes[i2] for i in 1:m])
        end
        return spine, recipes, accvec, newscr
    end

    for si in 1:nsubs
        # NOTE: these names must not collide with `clone`'s locals — a nested
        # function assigning a name bound in this scope REBINDS the shared box.
        msp_, mrc_, mav_, msc_ = merge_trees(i -> kernels[js[i]].subs[si],
                                             i -> plans[js[i]].sub_plans[si])
        repsub = rep.subs[si]
        merged_subs[si] = _AccKernel(repsub.cells, msp_, mav_, repsub.bound, repsub.zerobar,
                                     _AccCSE(mrc_, msc_, _Node[], _AccScratch(0)),
                                     _AccKernel[])
    end
    msp_, mrc_, mav_, msc_ = merge_trees(i -> kernels[js[i]], i -> plans[js[i]])
    outs = reduce(vcat, (plans[j].out_slots for j in js))
    return _AccKernel(_outs_cells(outs), msp_, mav_, rep.bound, rep.zerobar,
                      _AccCSE(mrc_, msc_, _Node[], _AccScratch(0)), merged_subs)
end

"""
    _merge_oop_acc_kernels(kernels, plans) -> (kernels′, plans′, diag)

The :oop kernel-class merge pass (see the file header). Returns the merged
kernel/plan vectors — value-exact replacements for the inputs — plus a
diagnostics NamedTuple `(n_in, n_out, n_classes, n_blocked, n_failed)`.
Falls back to the inputs (whole pass or per group) whenever a precondition
does not hold; never errors on a merge-ineligible input.
"""
function _merge_oop_acc_kernels(kernels::AbstractVector{_AccKernel},
                                plans::AbstractVector{_OopAccPlan})
    nodiag = (; n_in = length(kernels), n_out = length(kernels),
              n_classes = 0, n_blocked = length(kernels), n_failed = 0)
    length(kernels) <= 1 && return (kernels, plans, nodiag)

    # Assignment scatter + globally unique out-slots ⇒ concatenating lanes
    # across kernels cannot reorder any write. Without uniqueness, decline.
    allouts = reduce(vcat, (pl.out_slots for pl in plans); init = Int[])
    allunique(allouts) || return (kernels, plans, nodiag)

    groups = Dict{String,Vector{Int}}()
    passthrough = Int[]
    for j in eachindex(kernels)
        s, _why = _oop_merge_kernel_sig(kernels[j], plans[j])
        s === nothing ? push!(passthrough, j) : push!(get!(groups, s, Int[]), j)
    end

    out_kernels = _AccKernel[]
    out_plans = _OopAccPlan[]
    n_failed = 0
    # Deterministic output order: classes by first-member kernel index.
    for js in sort!(collect(values(groups)); by = first)
        if length(js) == 1
            push!(out_kernels, kernels[js[1]]); push!(out_plans, plans[js[1]])
            continue
        end
        merged = try
            K = _oop_merge_group(kernels, plans, js)
            pl = _build_oop_acc_plan(K)
            pl.vectorizable ? (K, pl) : nothing
        catch
            nothing
        end
        if merged === nothing
            n_failed += 1
            for j in js
                push!(out_kernels, kernels[j]); push!(out_plans, plans[j])
            end
        else
            push!(out_kernels, merged[1]); push!(out_plans, merged[2])
        end
    end
    for j in passthrough
        push!(out_kernels, kernels[j]); push!(out_plans, plans[j])
    end
    diag = (; n_in = length(kernels), n_out = length(out_kernels),
            n_classes = length(groups), n_blocked = length(passthrough),
            n_failed)
    return (out_kernels, out_plans, diag)
end
