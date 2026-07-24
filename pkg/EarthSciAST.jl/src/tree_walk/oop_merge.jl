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
#   varying interp spec  -> (_Interp*LaneSpec)(specs,1,0,0,1) (per-lane tables)
#
# The last line is what collapses the per-cell/per-column interp-table split:
# the class signature keys an interp spec's SHAPE (knot count), not its
# CONTENT, so kernels identical except for their interp const tables share a
# class and the clone transposes the specs into per-lane tables (see
# `_oop_merge_fn_payload` and registered_functions.jl `_Interp*LaneSpec`).
# On ReSEACT transport that is 346 classes -> ~a few dozen.
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
# The `:fn` payload's class-signature token. Interp specs key their SHAPE
# (knot count) only: same-shape specs with different content are MERGEABLE —
# the clone tables them per lane. `Nothing` (boxed `datetime.*`) has no
# content at all. Any OTHER spec type cannot be lane-tabled, so it keys by
# `_fn_spec_hash` (content, or identity for unknown types) exactly as before —
# the merged node would carry the rep's payload for all lanes.
_oop_merge_fn_sig_token(::Nothing) = "n"
_oop_merge_fn_sig_token(s::_InterpLinearSpec) = string("L", length(s.axis))
_oop_merge_fn_sig_token(s::_InterpBilinearSpec) =
    string("B", length(s.axis_x), "x", length(s.axis_y))
_oop_merge_fn_sig_token(s::_InterpSearchsortedSpec) = string("S", length(s.xs))
# A per-lane spec (a ROUND-1 merge product, seen by the round-2 signature)
# keys the same shape as its scalar kin, so already-tabled and not-yet-tabled
# members of one shape share a class and re-table by concatenation.
_oop_merge_fn_sig_token(h::_InterpLinearLaneSpec) = string("L", length(h.axis_cols))
_oop_merge_fn_sig_token(h::_InterpBilinearLaneSpec) =
    string("B", length(h.axis_x_cols), "x", length(h.axis_y_cols))
_oop_merge_fn_sig_token(h::_InterpSearchsortedLaneSpec) = string("S", length(h.xs_cols))
_oop_merge_fn_sig_token(s) = string("h", _fn_spec_hash(s))

# (interp-kind, knot shape...) of a scalar OR per-lane spec; `nothing` for
# anything that cannot be lane-tabled.
_oop_fn_shape(::Any) = nothing
_oop_fn_shape(s::_InterpLinearSpec) = (:linear, length(s.axis))
_oop_fn_shape(h::_InterpLinearLaneSpec) = (:linear, length(h.axis_cols))
_oop_fn_shape(s::_InterpBilinearSpec) = (:bilinear, length(s.axis_x), length(s.axis_y))
_oop_fn_shape(h::_InterpBilinearLaneSpec) =
    (:bilinear, length(h.axis_x_cols), length(h.axis_y_cols))
_oop_fn_shape(s::_InterpSearchsortedSpec) = (:searchsorted, length(s.xs))
_oop_fn_shape(h::_InterpSearchsortedLaneSpec) = (:searchsorted, length(h.xs_cols))

# Append one member's per-lane specs (a scalar spec broadcast over its lanes,
# or an existing lane spec's per-lane list verified against the member's lane
# count) to the merged per-lane list.
function _oop_fn_append_lanes!(out::Vector{S}, spec, lanes::Int) where {S}
    if spec isa S
        for _ in 1:lanes
            push!(out, spec)
        end
    else
        specs = spec.specs::Vector{S}
        length(specs) == lanes ||
            error("lane-spec lane count $(length(specs)) != member lanes $(lanes)")
        append!(out, specs)
    end
    return out
end

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
            # SHAPE key, not content (contrast acc_merge.jl `_struct_sig!`,
            # whose per-cell merge rides ONE spec and therefore must key
            # content): the CLASS merge tables per-lane-varying interp specs
            # (`_oop_merge_fn_payload` → `_Interp*LaneSpec`), so kernels
            # calling `interp.*` against DIFFERENT same-shape tables belong
            # in ONE class — the knot COUNT is what the lockstep select/blend
            # evaluation needs pinned. An unknown (non-interp) spec type still
            # keys by content/identity hash, and the clone re-verifies
            # name/type/shape loudly (`_check_fn_group_specs` path — never
            # silent wrong numbers).
            length(pl) >= 2 && print(io, "#", _oop_merge_fn_sig_token(pl[2]))
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

# Merged payload for one aligned `:fn` node group (`nodes[i]` is member i's
# node; member i owns `Ls[i]` of the `L` merged lanes, in member order).
#   * Specs CONTENT-EQUAL across members (the common case — one source `fn`
#     node instantiated per cell over one shared table): the representative's
#     payload rides, exactly as before this pass learned to table specs.
#   * Specs VARYING: the signature grouped these kernels because the specs
#     share fn name, type and SHAPE (knot count — `_oop_merge_fn_sig_token`),
#     so transpose them into a per-lane spec table (`_Interp*LaneSpec`) with
#     `_outs_cells` box addressing (1,0,0,1) — the interp analog of the
#     `_AccConstBox` a varying literal becomes.
#   * Anything else reaching here (name/type/shape mismatch — a signature
#     invariant break, the analog of a `_fn_spec_hash` collision) fails LOUDLY
#     through `_check_fn_group_specs`, whose throw degrades to the per-group
#     unmerged fallback in `_merge_oop_acc_kernels` — never silent wrong
#     numbers.
# Kept-inv safety: a lane spec is only minted when specs VARY across members,
# and `_oop_inv_nodes_identical` declines exactly those groups, so a PRESERVED
# invariant tier can never carry a per-lane spec (the payload analog of the
# `nacc0` lane-table pin in the kept-inv clone).
function _oop_merge_fn_payload(nodes::Vector{_Node}, Ls::Vector{Int}, L::Int)
    m = length(nodes)
    fname1, spec1 = (nodes[1].payload)::Tuple{String,Any}
    # A per-lane spec is ALWAYS re-tabled when merging further (round 2 over
    # round-1 products): the rep's lane list covers only ITS OWN lanes, so
    # riding it would misalign — concatenation below is the correct merge.
    varying = m > 1 && (spec1 isa _InterpLinearLaneSpec ||
                        spec1 isa _InterpBilinearLaneSpec ||
                        spec1 isa _InterpSearchsortedLaneSpec)
    if !varying
        for i in 2:m
            fnamei, speci = (nodes[i].payload)::Tuple{String,Any}
            if !(fnamei == fname1 &&
                 (speci === spec1 || _fn_spec_content_equal(speci, spec1)))
                varying = true
                break
            end
        end
    end
    varying || return nodes[1].payload
    sh = _oop_fn_shape(spec1)
    if sh !== nothing &&
       all(i -> begin
               fni, spi = (nodes[i].payload)::Tuple{String,Any}
               fni == fname1 && _oop_fn_shape(spi) == sh
           end, 2:m)
        if sh[1] === :linear
            specs = _InterpLinearSpec[]
            sizehint!(specs, L)
            for i in 1:m
                _oop_fn_append_lanes!(specs,
                    ((nodes[i].payload)::Tuple{String,Any})[2], Ls[i])
            end
            return (fname1, _InterpLinearLaneSpec(specs, 1, 0, 0, 1))
        elseif sh[1] === :bilinear
            specs = _InterpBilinearSpec[]
            sizehint!(specs, L)
            for i in 1:m
                _oop_fn_append_lanes!(specs,
                    ((nodes[i].payload)::Tuple{String,Any})[2], Ls[i])
            end
            return (fname1, _InterpBilinearLaneSpec(specs, 1, 0, 0, 1))
        else # :searchsorted
            specs = _InterpSearchsortedSpec[]
            sizehint!(specs, L)
            for i in 1:m
                _oop_fn_append_lanes!(specs,
                    ((nodes[i].payload)::Tuple{String,Any})[2], Ls[i])
            end
            return (fname1, _InterpSearchsortedLaneSpec(specs, 1, 0, 0, 1))
        end
    end
    _check_fn_group_specs(nodes)   # loud: grouping-invariant break
    return nodes[1].payload        # unreachable — the guard throws on mismatch
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
            else # _NK_OP / _NK_CONTRACTION: payload rides from the rep, except
                 # a `:fn` whose specs vary across members — that becomes a
                 # per-lane spec table (or a loud `_check_fn_group_specs`
                 # error on any signature-invariant break; see
                 # `_oop_merge_fn_payload`).
                pay = (k === _NK_OP && r.op === :fn && r.payload isa Tuple) ?
                      _oop_merge_fn_payload(nodes, Ls, L) : r.payload
                ch = Vector{_Node}(undef, length(r.children))
                for ci in eachindex(r.children)
                    ch[ci] = clone(_Node[n.children[ci] for n in nodes])
                end
                return _Node(k, r.op, r.literal, r.idx, r.sym, pay, ch)
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

# ============================================================================
# ROUND 2: expansion-normalized (CSE-slicing-insensitive) kernel-class merge.
#
# WHY. Round 1 groups kernels by their POST-CSE structure: the signature walks
# the stored spine + recipe tiers, so two kernels of the SAME formula whose
# per-kernel CSE pass sliced different recipe sets (a boundary cell's slightly
# different tree changes which subtrees repeat, and a single early difference
# renumbers every later slot) land in different classes even though their
# fully-expanded arithmetic is lockstep-identical. Measured on ReSEACT
# transport (7×7×72): 4,119 kernels → 346 round-1 classes, of which 343 share
# ONE spine and differ mainly in recipe slicing/slot numbering plus
# literal-vs-frozen-const leaf flips — NOT in interp specs and NOT in
# forcing-buffer identity (both measured no-ops). Expansion-normalizing the
# signature (inline every own-scratch `_NK_CACHED` read through its recipe,
# treat a LITERAL and a frozen const-family access as one "value leaf")
# collapses 346 → 150.
#
# HOW. A second grouping pass over the round-1 output:
#   * SIGNATURE: a memoized structural HASH of the fully-EXPANDED trees —
#     `_NK_CACHED` reads of the kernel's own tiers are resolved through the
#     recipe they name, so recipe slicing and slot numbering vanish. Leaf
#     tokens: state family (AS) / per-buffer forcing family / one VALUE token
#     for literal + frozen const family / param sym / fn payload by SHAPE
#     (`_oop_merge_fn_sig_token`, so same-shape interp tables merge and are
#     lane-tabled).
#   * CLONE: the round-1 clone generalized to walk members in lockstep WITH
#     on-the-fly expansion (each member's CACHED reads resolved through its
#     own recipes) and a member-identity-tuple memo, so sharing common to all
#     members is preserved (the clone builds a DAG, not a tree). Leaf groups
#     mixing literals and frozen consts become one `_AccConstBox` per-lane
#     table (each lane's value is exactly what that member's leaf read).
#     Because the hash is not injective, the clone RE-VERIFIES structure at
#     every aligned node and throws on any mismatch — a hash collision
#     degrades to the per-class fallback, never silent wrong numbers.
#   * CSE REBUILD: the merged kernel's tiers were consumed by expansion, so an
#     identity-based CSE pass re-slices the cloned DAG (every OP/CONTRACTION
#     node referenced ≥2× becomes a cell-tier recipe, topologically ordered).
#     Caching vs recomputing a pure subtree is bit-identical; only WHERE the
#     value is computed moves. The invariant tier is folded into the cell tier
#     (the round-1 fold-to-cell semantics — value-identical, lane-vectorized).
#
# BIT-IDENTITY. Per lane, the op sequence is the member's own expanded op
# sequence with its own leaf values (state slots / consts / forcing indices /
# interp knots ride per-lane tables); expansion and re-CSE only move pure
# deterministic subcomputations between "cached once" and "recomputed", which
# cannot change any bit. The stencil-vs-unmerged differential tests and the
# ReSEACT maxabs==0.0 gate are the oracles.
#
# SAFETY. Same posture as round 1: any ineligible input, structural mismatch,
# clone-budget overrun, or unvectorizable rebuilt plan falls back to the
# round-1 kernels for that class; ESS_OOP_MERGE_DISABLE=1 (or the alias)
# disables both rounds; ESS_OOP_MERGE_EXPAND_DISABLE=1 disables round 2 only.
# ============================================================================

_oop_merge_expand_disabled() =
    get(ENV, "ESS_OOP_MERGE_EXPAND_DISABLE", "") == "1"

_oop_x_statefam(k) = k in (_AK_STATE_AFFINE, _AK_STATE_TBL_BOX, _AK_STATE_FIXED)
_oop_x_forcfam(k)  = k in (_AK_ARR_FIXED, _AK_FORCING_BOX, _AK_ARR_TBL_BOX)
_oop_x_constfam(k) = k in (_AK_SCALAR, _AK_CONST_AFFINE, _AK_CONST_BOX,
                           _AK_CONST_CELL, _AK_LOOP_IDX)

# Resolve a node through the OWNING kernel's CSE tiers: an own-scratch
# `_NK_CACHED` read IS its recipe, structurally. Foreign-scratch reads (xcse
# rewrites — cannot appear pre-xcse, defensively kept) stay put and decline
# the signature downstream.
@inline function _oop_x_resolve(n::_Node, K::_AccKernel)
    while n.kind === _NK_CACHED
        if n.payload === K.cse.scratch
            n = K.cse.recipes[n.idx]
        elseif n.payload === K.cse.inv_scratch
            n = K.cse.inv_recipes[n.idx]
        else
            return n
        end
    end
    return n
end

# Memoized expansion-normalized structural hash of one tree in kernel context
# `K`. `parentsubs` positions `_NK_SUBCALL` payloads exactly as round 1 does.
function _oop_x_sig(n0::_Node, K::_AccKernel, parentsubs,
                    memo::IdDict{_Node,UInt}, why::Base.RefValue{Symbol})::UInt
    n = _oop_x_resolve(n0, K)
    h0 = get(memo, n, UInt(0))
    h0 != 0 && return h0
    k = n.kind
    local r::UInt
    if k === _NK_ACCESS
        a = K.acc[n.idx]
        if _oop_x_statefam(a.kind)
            r = hash(:AS, UInt(0x9d3f))
        elseif _oop_x_forcfam(a.kind)
            r = hash((:AF, objectid(a.arr)), UInt(0x51c2))
        elseif _oop_x_constfam(a.kind)
            r = hash(:V, UInt(0x2b71))        # value leaf: == a literal
        else
            why[] = :acc_kind
            r = hash(:badacc, UInt(0x7))
        end
    elseif k === _NK_LITERAL
        r = hash(:V, UInt(0x2b71))            # value leaf: == a frozen const
    elseif k === _NK_PARAM
        r = hash((:P, n.sym), UInt(0x77aa))
    elseif k === _NK_TIME
        r = hash(:T, UInt(0x33cc))
    elseif k === _NK_CACHED                    # foreign scratch survived resolve
        why[] = :foreign_cached
        r = hash(:Cf, UInt(0x44dd))
    elseif k === _NK_SUBCALL
        pos = findfirst(s -> s === n.payload, parentsubs)
        pos === nothing && (why[] = :subcall_unknown)
        r = hash((:S, pos === nothing ? 0 : pos), UInt(0x55ee))
    elseif k === _NK_REDUCE
        why[] = :reduce
        r = hash(:X, UInt(0x66ff))
    elseif k === _NK_OP || k === _NK_CONTRACTION
        pl = n.payload
        paytok = if n.op === :fn && pl isa Tuple && length(pl) >= 2
            (pl[1], _oop_merge_fn_sig_token(pl[2]))     # SHAPE key (lane-tabled)
        elseif pl === nothing
            0x0
        else
            objectid(pl)                                # identity: never wrongly merged
        end
        r = hash((k === _NK_OP ? :O : :K, n.op, paytok,
                  k === _NK_CONTRACTION ? reinterpret(UInt64, n.literal) : UInt64(0),
                  length(n.children)), UInt(0x8811))
        for c in n.children
            r = hash(_oop_x_sig(c, K, parentsubs, memo, why), r)
        end
    else
        why[] = :node_kind
        r = hash((:unk, Int(k)), UInt(0x9922))
    end
    memo[n] = r
    return r
end

function _oop_x_kernel_sig(K::_AccKernel, plan::_OopAccPlan)
    why = Ref(:ok)
    plan.vectorizable || (why[] = :unvectorizable)
    isempty(plan.red_seg) || (why[] = :reduce)
    memo = IdDict{_Node,UInt}()
    h = hash(reinterpret(UInt64, K.zerobar), UInt(0xaa33))
    h = hash(_oop_x_sig(K.spine, K, K.subs, memo, why), h)
    for (si, S) in enumerate(K.subs)
        isempty(S.subs) || (why[] = :nested_sub_subs)
        smemo = IdDict{_Node,UInt}()
        hs = hash(reinterpret(UInt64, S.zerobar), UInt(0xbb44))
        hs = hash(_oop_x_sig(S.spine, S, K.subs, smemo, why), hs)
        h = hash((si, hs), h)
    end
    return (why[] === :ok ? h : nothing), why[]
end

# Identity-based CSE over a cloned DAG: every OP/CONTRACTION node referenced
# more than once (the clone memo preserved member-common sharing) becomes a
# cell-tier recipe read through a fresh scratch; recipes are emitted in
# topological (children-first) order, so recipe i only ever reads lower slots
# — the invariant every runner's prelude fill relies on. Caching a pure
# deterministic subtree instead of re-walking it cannot change any bit.
function _oop_x_apply_cse(root::_Node)
    refcnt = IdDict{_Node,Int}()
    order = _Node[]                      # post-order, each node once
    seen = IdDict{_Node,Bool}()
    stack = Tuple{_Node,Int}[(root, 0)]
    refcnt[root] = 1
    while !isempty(stack)
        n, ci = pop!(stack)
        if ci == 0
            if haskey(seen, n)
                continue
            end
            seen[n] = true
        end
        if ci < length(n.children)
            push!(stack, (n, ci + 1))
            c = n.children[ci + 1]
            refcnt[c] = get(refcnt, c, 0) + 1
            haskey(seen, c) || push!(stack, (c, 0))
        else
            push!(order, n)
        end
    end
    isrec(n) = (n.kind === _NK_OP || n.kind === _NK_CONTRACTION) &&
               get(refcnt, n, 0) >= 2 && n !== root
    nrec = count(isrec, order)
    nrec == 0 && return (root, _Node[], _AccScratch(0))
    scr = _AccScratch(nrec)
    recipes = Vector{_Node}(undef, nrec)
    repl = IdDict{_Node,_Node}()         # old node -> read/rebuilt replacement
    slot = 0
    for n in order                        # children before parents
        if isempty(n.children)
            nn = n
        else
            ch = Vector{_Node}(undef, length(n.children))
            changed = false
            for i in eachindex(n.children)
                ch[i] = get(repl, n.children[i], n.children[i])
                changed |= ch[i] !== n.children[i]
            end
            nn = changed ? _Node(n.kind, n.op, n.literal, n.idx, n.sym,
                                 n.payload, ch) : n
        end
        if isrec(n)
            slot += 1
            recipes[slot] = nn
            repl[n] = _Node(_NK_CACHED, Symbol(""), 0.0, slot, Symbol(""),
                            scr, _Node[])
        elseif nn !== n
            repl[n] = nn
        end
    end
    newroot = get(repl, root, root)
    return (newroot, recipes, scr)
end

# Round-2 clone: merge one expansion-normalized class (indices `js`) into a
# single lane-batched kernel. Walks all members in lockstep WITH on-the-fly
# expansion, verifying structure at every aligned node (the hash grouped them;
# the walk is the collision guard — any mismatch throws, degrading to the
# per-class fallback). The member-identity-tuple memo preserves sharing that
# is common to every member, so the clone builds a DAG whose size is bounded
# by the members' own DAGs wherever their sharing agrees; a node budget guards
# the pathological case where it does not.
function _oop_x_merge_group(kernels, plans, js::Vector{Int})
    m = length(js); Ls = Int[length(plans[j].out_slots) for j in js]; L = sum(Ls)
    rep = kernels[js[1]]
    nsubs = length(rep.subs)
    @assert all(j -> length(kernels[j].subs) == nsubs, js)
    merged_subs = Vector{_AccKernel}(undef, nsubs)
    budget = Ref(2_000_000)              # cloned-node budget (throw ⇒ fallback)

    function merge_trees(Kof, Pof)
        accvec = _AccDesc[]
        memo = Dict{Vector{UInt},_Node}()
        function clone(nodes0::Vector{_Node})::_Node
            nodes = _Node[_oop_x_resolve(nodes0[i], Kof(i)) for i in 1:m]
            key = UInt[objectid(n) for n in nodes]
            hit = get(memo, key, nothing)
            hit !== nothing && return hit
            (budget[] -= 1) < 0 && error("round-2 clone budget exceeded")
            r = nodes[1]; k = r.kind
            isacc(i) = nodes[i].kind === _NK_ACCESS
            akind(i) = Kof(i).acc[nodes[i].idx].kind
            out = if all(i -> isacc(i) && _oop_x_statefam(akind(i)), 1:m)
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
                _Node(_NK_ACCESS, :acc, 0.0, length(accvec), Symbol(""), nothing, _Node[])
            elseif all(i -> isacc(i) && _oop_x_forcfam(akind(i)), 1:m)
                arr = Kof(1).acc[r.idx].arr
                all(i -> Kof(i).acc[nodes[i].idx].arr === arr, 1:m) ||
                    error("round-2: forcing buffer mismatch in a class")
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
                _Node(_NK_ACCESS, :acc, 0.0, length(accvec), Symbol(""), nothing, _Node[])
            elseif all(i -> nodes[i].kind === _NK_LITERAL ||
                            (isacc(i) && _oop_x_constfam(akind(i))), 1:m)
                # VALUE leaf group: literal and frozen-const members mix — each
                # lane's table entry is exactly the value that member's leaf
                # reads (a literal's value, a scalar's v, or the plan-resolved
                # per-lane const). All-equal ⇒ stays a scalar literal.
                tbl = Vector{Float64}(undef, L); q = 0
                for i in 1:m
                    lk = Ls[i]; nd = nodes[i]
                    if nd.kind === _NK_LITERAL
                        tbl[q+1:q+lk] .= nd.literal
                    else
                        a = Kof(i).acc[nd.idx]
                        if a.kind === _AK_SCALAR
                            tbl[q+1:q+lk] .= a.v
                        else
                            tbl[q+1:q+lk] .= Pof(i).consts[nd.idx]
                        end
                    end
                    q += lk
                end
                if all(==(tbl[1]), tbl)
                    _Node(_NK_LITERAL, :lit, tbl[1], 0, Symbol(""), nothing, _Node[])
                else
                    push!(accvec, _AccConstBox(tbl, 1, 0, 0, 1))
                    _Node(_NK_ACCESS, :acc, 0.0, length(accvec), Symbol(""), nothing, _Node[])
                end
            elseif k === _NK_PARAM || k === _NK_TIME
                all(i -> nodes[i].kind === k && nodes[i].sym === r.sym, 1:m) ||
                    error("round-2: param/time mismatch in a class")
                _Node(k, r.op, r.literal, r.idx, r.sym, r.payload, _Node[])
            elseif k === _NK_SUBCALL
                pos = findfirst(s -> s === r.payload, kernels[js[1]].subs)
                pos !== nothing &&
                    all(i -> nodes[i].kind === _NK_SUBCALL &&
                             kernels[js[i]].subs[pos] === nodes[i].payload, 1:m) ||
                    error("round-2: subcall alignment mismatch")
                @assert isassigned(merged_subs, pos) "nested-first order violated"
                _Node(k, r.op, r.literal, r.idx, r.sym, merged_subs[pos], _Node[])
            elseif k === _NK_OP || k === _NK_CONTRACTION
                nch = length(r.children)
                all(i -> nodes[i].kind === k && nodes[i].op === r.op &&
                         length(nodes[i].children) == nch &&
                         (k !== _NK_CONTRACTION ||
                          isequal(nodes[i].literal, r.literal)), 1:m) ||
                    error("round-2: op/contraction mismatch in a class")
                pay = if k === _NK_OP && r.op === :fn && r.payload isa Tuple
                    _oop_merge_fn_payload(nodes, Ls, L)
                else
                    all(i -> nodes[i].payload === r.payload, 1:m) ||
                        error("round-2: op payload mismatch in a class")
                    r.payload
                end
                ch = Vector{_Node}(undef, nch)
                for ci in 1:nch
                    ch[ci] = clone(_Node[n.children[ci] for n in nodes])
                end
                _Node(k, r.op, r.literal, r.idx, r.sym, pay, ch)
            else
                error("round-2: unmergeable node kind $(Int(k))")
            end
            memo[key] = out
            return out
        end
        spine0 = clone(_Node[Kof(i).spine for i in 1:m])
        spine, recipes, scr = _oop_x_apply_cse(spine0)
        return spine, recipes, accvec, scr
    end

    for si in 1:nsubs
        msp_, mrc_, mav_, msc_ = merge_trees(i -> kernels[js[i]].subs[si],
                                             i -> plans[js[i]].sub_plans[si])
        repsub = rep.subs[si]
        merged_subs[si] = _AccKernel(repsub.cells, msp_, mav_, repsub.bound,
                                     repsub.zerobar,
                                     _AccCSE(mrc_, msc_, _Node[], _AccScratch(0)),
                                     _AccKernel[])
    end
    msp_, mrc_, mav_, msc_ = merge_trees(i -> kernels[js[i]], i -> plans[js[i]])
    outs = reduce(vcat, (plans[j].out_slots for j in js))
    return _AccKernel(_outs_cells(outs), msp_, mav_, rep.bound, rep.zerobar,
                      _AccCSE(mrc_, msc_, _Node[], _AccScratch(0)), merged_subs)
end

# Round-2 driver: mirrors `_merge_oop_acc_kernels` (same preconditions, same
# per-class fallback posture) with the expansion-normalized hash signature.
function _merge_oop_x_kernels(kernels::AbstractVector{_AccKernel},
                              plans::AbstractVector{_OopAccPlan})
    nodiag = (; n_in = length(kernels), n_out = length(kernels),
              n_classes = 0, n_blocked = length(kernels), n_failed = 0)
    length(kernels) <= 1 && return (kernels, plans, nodiag)
    allouts = reduce(vcat, (pl.out_slots for pl in plans); init = Int[])
    allunique(allouts) || return (kernels, plans, nodiag)

    groups = Dict{UInt,Vector{Int}}()
    passthrough = Int[]
    for j in eachindex(kernels)
        s, _why = _oop_x_kernel_sig(kernels[j], plans[j])
        s === nothing ? push!(passthrough, j) : push!(get!(groups, s, Int[]), j)
    end

    out_kernels = _AccKernel[]
    out_plans = _OopAccPlan[]
    n_failed = 0
    for js in sort!(collect(values(groups)); by = first)
        if length(js) == 1
            push!(out_kernels, kernels[js[1]]); push!(out_plans, plans[js[1]])
            continue
        end
        merged = try
            K = _oop_x_merge_group(kernels, plans, js)
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
    merged, mplans, diag = _merge_oop_acc_kernels(kernels, plans)
    # Round 2 (expansion-normalized; see the section header above): collapse
    # classes that differ only in per-kernel CSE slicing / slot numbering /
    # literal-vs-frozen-const leaves / same-shape interp tables. Same
    # per-class fallback posture; ESS_OOP_MERGE_EXPAND_DISABLE=1 keeps the
    # round-1 output byte for byte.
    if !_oop_merge_expand_disabled() && length(merged) > 1
        merged2, _plans2, diag2 = _merge_oop_x_kernels(merged, mplans)
        diag = (; n_in = diag.n_in, n_out = length(merged2),
                diag.n_classes, diag.n_blocked,
                n_failed = diag.n_failed + diag2.n_failed,
                n_x_in = diag2.n_in, n_x_out = diag2.n_out,
                n_x_classes = diag2.n_classes, n_x_blocked = diag2.n_blocked)
        merged = merged2
    end
    return (merged, diag)
end
