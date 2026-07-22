# ========================================================================
# tree_walk/oop_merge.jl — part of the tree-walk evaluator (array-IR B).
# Included by src/tree_walk.jl AFTER oop.jl (`_OopAccPlan`,
# `_build_oop_acc_plan`) and acc_merge.jl (`_fn_spec_hash`,
# `_check_fn_group_specs`). Owns the KERNEL-CLASS merge: a build-time pass
# (`_merge_acc_kernel_classes`, called from `_build_evaluator_impl` phase 4
# BEFORE the xcse gate and the emitter branch, so BOTH the `:inplace` and the
# `:oop` RHS run over merged kernels) that collapses per-cell-fragmented
# `_AccKernel`s into lane-batched class kernels.
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
# folded into the cell tier (same values, lane-vectorized). The PARENT
# kernel's inv tier is PRESERVED when every member's inv recipes are
# VALUE-identical (no access/subcall leaves, equal literals, content-equal fn
# specs — `_oop_inv_nodes_identical`): the merged kernel then keeps a real
# invariant tier evaluated once per call, so a FastJX-style interp chain
# shared by a class of species balances is NOT demoted to a per-lane
# recompute, the B4 xcse pass still sees it, and the `n_acc_inv_slots` build
# diagnostic stays truthful. When any inv recipe varies across members
# (all-or-nothing, per class) the whole tier folds into the cell tier as
# before — same values, lane-vectorized. Evaluation is stock
# `_build_oop_acc_plan` + `_oop_run_acc_vec` (`:oop`) or the lane
# tape / codegen / scalar runners (`:inplace`) — per-lane semantics
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

# The historical name (the pass landed :oop-only) and a form-neutral alias —
# the pass now runs for BOTH emitters, but existing tests and tooling set
# `ESS_OOP_MERGE_DISABLE`, so that name must keep working forever.
_oop_merge_disabled() =
    get(ENV, "ESS_OOP_MERGE_DISABLE", "") == "1" ||
    get(ENV, "ESS_KERNEL_CLASS_MERGE_DISABLE", "") == "1"

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

# Are the members' aligned inv-recipe trees VALUE-identical, so the merged
# kernel can keep them in a REAL invariant tier (evaluated once per call by
# `_fill_invariant!` / the oop prelude) instead of folding them into the
# per-lane cell tier? Deliberately conservative: any access or subcall leaf,
# any literal that differs across members, or a cached read outside the inv
# tier declines — the fold-to-cell fallback is always value-correct, this
# only decides WHERE the (identical) value is computed. fn payloads ride from
# the rep in the clone, so their specs must be content-equal here.
function _oop_inv_nodes_identical(nodes::Vector{_Node}, Kof, m::Int)
    r = nodes[1]; k = r.kind
    if k === _NK_LITERAL
        return all(i -> isequal(nodes[i].literal, r.literal), 1:m)
    elseif k === _NK_PARAM || k === _NK_TIME
        return true
    elseif k === _NK_CACHED
        # An inv recipe may only read other inv slots (same idx across members
        # by the signature); a cell-tier read here would not be lane-invariant.
        return all(i -> nodes[i].payload === Kof(i).cse.inv_scratch, 1:m)
    elseif k === _NK_OP || k === _NK_CONTRACTION
        if k === _NK_OP && r.op === :fn && r.payload isa Tuple
            fn1, spec1 = (r.payload)::Tuple{String,Any}
            for i in 2:m
                fni, speci = (nodes[i].payload)::Tuple{String,Any}
                (fni == fn1 && (speci === spec1 ||
                                _fn_spec_content_equal(speci, spec1))) || return false
            end
        end
        for ci in eachindex(r.children)
            _oop_inv_nodes_identical(_Node[n.children[ci] for n in nodes],
                                     Kof, m) || return false
        end
        return true
    else # _NK_ACCESS / _NK_SUBCALL / anything else: decline, fold to cell
        return false
    end
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
    # every table below has member-lane length by construction. `keep_inv`
    # (parent trees only): when every member's inv recipes are VALUE-identical
    # the merged kernel keeps a real inv tier — evaluated once per call — and
    # only the cell tier goes per-lane; otherwise (and always for subs, whose
    # runners lane-vectorize the whole prelude) the inv tier folds into the
    # cell tier exactly as before. Both placements compute the same bits.
    function merge_trees(Kof, Pof, keep_inv::Bool)
        accvec = _AccDesc[]
        n_inv = length(Kof(1).cse.inv_recipes); n_cell = length(Kof(1).cse.recipes)
        @assert all(i -> length(Kof(i).cse.inv_recipes) == n_inv &&
                         length(Kof(i).cse.recipes) == n_cell, 1:m)
        keep = keep_inv && n_inv > 0 &&
               all(i2 -> _oop_inv_nodes_identical(
                       _Node[Kof(i).cse.inv_recipes[i2] for i in 1:m], Kof, m),
                   1:n_inv)
        newscr = _AccScratch(keep ? n_cell : n_inv + n_cell)
        invscr = _AccScratch(keep ? n_inv : 0)
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
                # With `keep`, inv reads stay inv reads (same idx, fresh inv
                # scratch); otherwise the inv tier folds into the cell tier:
                # recompute per lane (values identical; the lanes ARE the
                # vectorization).
                tier_cell = r.payload === Kof(1).cse.scratch
                @assert all(i -> (nodes[i].payload === Kof(i).cse.scratch) == tier_cell, 1:m)
                if tier_cell
                    nidx = keep ? r.idx : n_inv + r.idx
                    return _Node(k, r.op, r.literal, nidx, r.sym, newscr, _Node[])
                elseif keep       # preserved inv-tier read
                    return _Node(k, r.op, r.literal, r.idx, r.sym, invscr, _Node[])
                else              # folded inv-tier read (slots 1..n_inv of cell)
                    return _Node(k, r.op, r.literal, r.idx, r.sym, newscr, _Node[])
                end
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
        if keep
            recipes = Vector{_Node}(undef, n_cell)
            for i2 in 1:n_cell
                recipes[i2] = clone(_Node[Kof(i).cse.recipes[i2] for i in 1:m])
            end
            # Kept inv recipes are value-identical across members, so the
            # clone is a pure remap (cached reads onto the fresh scratches) —
            # it must not mint a lane table. `nacc0` pins that: a table here
            # would be read per-lane by a tier evaluated ONCE, i.e. garbage.
            # The @assert throw degrades to the per-group fallback (the
            # `try`/`catch` in `_merge_oop_acc_kernels`), never wrong numbers.
            nacc0 = length(accvec)
            invrec = Vector{_Node}(undef, n_inv)
            for i2 in 1:n_inv
                invrec[i2] = clone(_Node[Kof(i).cse.inv_recipes[i2] for i in 1:m])
            end
            @assert length(accvec) == nacc0 "kept-inv recipe minted a lane table"
            return spine, recipes, invrec, invscr, accvec, newscr
        end
        recipes = Vector{_Node}(undef, n_inv + n_cell)
        for i2 in 1:n_inv
            recipes[i2] = clone(_Node[Kof(i).cse.inv_recipes[i2] for i in 1:m])
        end
        for i2 in 1:n_cell
            recipes[n_inv + i2] = clone(_Node[Kof(i).cse.recipes[i2] for i in 1:m])
        end
        return spine, recipes, _Node[], invscr, accvec, newscr
    end

    for si in 1:nsubs
        # NOTE: these names must not collide with `clone`'s locals — a nested
        # function assigning a name bound in this scope REBINDS the shared box.
        msp_, mrc_, _mi_, _ms_, mav_, msc_ = merge_trees(i -> kernels[js[i]].subs[si],
                                                         i -> plans[js[i]].sub_plans[si],
                                                         false)
        repsub = rep.subs[si]
        merged_subs[si] = _AccKernel(repsub.cells, msp_, mav_, repsub.bound, repsub.zerobar,
                                     _AccCSE(mrc_, msc_, _Node[], _AccScratch(0)),
                                     _AccKernel[])
    end
    msp_, mrc_, minv_, mis_, mav_, msc_ = merge_trees(i -> kernels[js[i]],
                                                      i -> plans[js[i]], true)
    outs = reduce(vcat, (plans[j].out_slots for j in js))
    return _AccKernel(_outs_cells(outs), msp_, mav_, rep.bound, rep.zerobar,
                      _AccCSE(mrc_, msc_, minv_, mis_), merged_subs)
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

"""
    _merge_acc_kernel_classes(kernels) -> (kernels′, diag_or_nothing)

The build-time front-door `_build_evaluator_impl` calls once, on the final
compiled kernel list, BEFORE the xcse gate and before the emitter branch —
so BOTH `_make_rhs` (`:inplace`) and `_make_rhs_oop` (`:oop`) receive the
merged kernels. The ordering is a hard correctness constraint: xcse rewrites
kernel invariant-tier defs into reads of the SCALAR `_CSECache` (`_NK_CACHED`
nodes whose payload is not any kernel scratch), which the merge signature and
clone do not model — merge first, then let xcse run over the (fewer) merged
kernels. The `_OopAccPlan`s built here serve purely as the host-side per-lane
table source for the merge (`pl.gathers`/`consts`/`forc`/`ghost`); each
emitter rebuilds its own plans from the merged kernels. Returns the input
unchanged (diag `nothing`) when disabled or trivially small.
"""
function _merge_acc_kernel_classes(kernels::AbstractVector{_AccKernel})
    (_oop_merge_disabled() || length(kernels) <= 1) && return (kernels, nothing)
    plans = _OopAccPlan[_build_oop_acc_plan(K) for K in kernels]
    merged, _plans, diag = _merge_oop_acc_kernels(kernels, plans)
    return (merged, diag)
end
