# ========================================================================
# tree_walk/oop_merge.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl AFTER oop.jl (`_OopAccPlan`,
# `_build_oop_acc_plan`) and acc_merge.jl. Owns the KERNEL-CLASS merge: a build-time pass
# (`_merge_acc_kernel_classes`, called from `_build_evaluator_impl` phase 4
# BEFORE the xcse gate and the emitter branch, so BOTH the `:inplace` and the
# `:oop` RHS run over merged kernels) that collapses per-cell-fragmented
# `_AccKernel`s into lane-batched class kernels.
#
# WHY. `_acc_from_cell_entries` merges the per-cell entries OF ONE ARRAY
# EQUATION; what it cannot see is that a stencil model instantiates the same
# equation once per cell/column with different ghost patterns, yielding thousands of structurally identical mostly-1-lane kernels
# over only a few hundred distinct classes. The interpreted walkers tolerate
# that; an XLA tracer
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
# `_OopAccPlan` tables. The kernel's inv tier is PRESERVED when every
# member's inv recipes are VALUE-identical (no access leaves, equal literals —
# `_oop_inv_nodes_identical`): the merged kernel then keeps a real
# invariant tier evaluated once per call, so a chain shared by a class of
# species balances is NOT demoted to a per-lane recompute, the B4 xcse pass still sees it, and the `n_acc_inv_slots` build
# diagnostic stays truthful. When any inv recipe varies across members
# (all-or-nothing, per class) the whole tier folds into the cell tier as
# before — same values, lane-vectorized. Evaluation is the codegen / scalar
# runners (`:inplace`) or whatever a compiled backend emits from
# `_build_oop_acc_plan`'s plan (`:oop`) — per-lane semantics (fold order, ghost
# select) stay EarthSciAST's.
#
# BIT-IDENTITY BY CONSTRUCTION. A leaf equal across the group stays scalar;
# a varying one is transposed into a table indexed by lane ordinal; the op
# sequence applied per lane is byte-identical to the unmerged kernel's.
# A kernel's write is ASSIGNMENT, and the pass merges only when every kernel
# out-slot is globally unique, so concatenating groups cannot reorder any
# read-after-write. A node carrying a payload keeps its kernel out of round 1; round 2
# checks every member's payload is the same object.
#
# SAFETY POSTURE. This is a default-on optimization of a correct baseline,
# so every "can't" is a fallback, not an error: overlapping out-slots, a
# blocked kernel (reduce segment / unmergeable descriptor kind), a failed
# group merge, or a merged kernel whose fresh plan is
# not vectorizable — each falls back to the original kernels for that scope.
# ========================================================================

# The class merge runs for both build forms.
_oop_merge_disabled() = !_compiler_plan_now().oop_merge

# Signature equal for two kernels iff they can be evaluated in LOCKSTEP: same
# tree shape and op/payload structure, with per-lane-varying leaves (state
# slots, const values, literals, forcing indices) left free — those become
# tables. Access descriptors key by FAMILY (state / const / per-buffer
# forcing), not exact kind: the clone tables every member of a family
# identically, so an interior AFFINE cell and a boundary TBL_BOX cell of the
# same equation share a class.
#
# WRITTEN OVER NODE CLASSES. A kernel's trees are DAGs (a subexpression is
# referenced from several places, and the references nest), so a signature that
# writes each node where it stands grows with the unfolded tree, exponentially
# in the nesting. Each node instead gets a CLASS: the id `intern` (one per merge
# round, so classes compare across the round's kernels) assigns to its own
# token and its children's classes, computed once per distinct node
# (`_node_fold`). Two nodes share a class iff their trees agree token by token
# and child by child; a kernel's signature is the classes of its roots, tier by
# tier.

# What a node says about itself, in kernel `K`.
function _oop_merge_token(n::_Node, K::_AccKernel)
    k = n.kind
    if k === _NK_ACCESS
        a = K.acc[n.idx]
        _oop_x_statefam(a.kind) && return :AS
        _oop_x_forcfam(a.kind) && return (:AF, objectid(a.arr))
        return :AC
    elseif k === _NK_LITERAL
        return :L                          # value free (tabled if varying)
    elseif k === _NK_PARAM
        return (:P, n.sym)
    elseif k === _NK_TIME
        return :T
    elseif k === _NK_CACHED
        return (:C, n.payload === K.cse.scratch, n.idx)
    elseif k === _NK_CONTRACTION
        # The seed by value, every NaN one seed.
        return (:K, n.op, isnan(n.literal) ? NaN : n.literal)
    elseif k === _NK_OP
        return (:O, n.op)
    elseif k === _NK_CALL
        # A template call: the target by identity, its arguments structurally.
        return (:F, objectid(n.payload))
    end
    return (:node_kind, k)
end

# Why a node keeps its kernel out of the merge, or `:ok`. The clone takes a
# node's payload from the class representative, so a payload the signature
# cannot compare keeps the kernel out.
function _oop_merge_why(n::_Node)
    k = n.kind
    (k === _NK_CONTRACTION || k === _NK_OP) && n.payload !== nothing && return :op_payload
    (
        k === _NK_ACCESS || k === _NK_LITERAL || k === _NK_PARAM || k === _NK_TIME ||
            k === _NK_CACHED || k === _NK_CONTRACTION || k === _NK_OP || k === _NK_CALL
    ) && return :ok
    return :node_kind
end

# A root's class, and the decline reason of the LAST node that has one in the
# root's preorder (a node before its children, children in order), so a kernel
# with several reasons reports the same one whatever the sharing. A node of a
# kind the merge does not know is a class of its own kind, whatever is under it.
function _oop_merge_class(root::_Node, K::_AccKernel, intern::_SigIntern)
    return _node_fold(root, Tuple{Int, Symbol}) do n, kids
        ids = Int[]
        why = _oop_merge_why(n)
        if why !== :node_kind
            for (id, w) in kids
                push!(ids, id)
                w === :ok || (why = w)
            end
        end
        (get!(intern, (_oop_merge_token(n, K), ids), length(intern) + 1), why)
    end
end

# `(signature, why)`: the classes of the spine, then of the invariant recipes,
# then of the cell recipes (a negative entry opens each recipe tier), or
# `nothing` when the kernel stays out of the merge, and why.
function _oop_merge_kernel_sig(K::_AccKernel, vectorizable::Bool, intern::_SigIntern)
    why = vectorizable ? :ok : :unvectorizable
    sig = Int[]
    for (tier, roots) in enumerate(((K.spine,), K.cse.inv_recipes, K.cse.recipes))
        tier > 1 && push!(sig, -tier)
        for r in roots
            id, w = _oop_merge_class(r, K, intern)
            push!(sig, id)
            w === :ok || (why = w)
        end
    end
    return why === :ok ? sig : nothing, why
end

# Are the members' aligned inv-recipe trees VALUE-identical, so the merged
# kernel can keep them in a REAL invariant tier (evaluated once per call by
# `_fill_invariant!` / the oop prelude) instead of folding them into the
# per-lane cell tier? Deliberately conservative: any access leaf,
# any literal that differs across members, or a cached read outside the inv
# tier declines — the fold-to-cell fallback is always value-correct, this
# only decides WHERE the (identical) value is computed. No node here carries a
# payload: the signature keeps such kernels out of this round.
function _oop_inv_nodes_identical(nodes::Vector{_Node}, Kof, m::Int)
    r = nodes[1]; k = r.kind
    if k === _NK_LITERAL
        return _allof(i -> isequal(nodes[i].literal, r.literal), 1:m)
    elseif k === _NK_PARAM || k === _NK_TIME
        return true
    elseif k === _NK_CACHED
        # An inv recipe may only read other inv slots (same idx across members
        # by the signature); a cell-tier read here would not be lane-invariant.
        return _allof(i -> nodes[i].payload === Kof(i).cse.inv_scratch, 1:m)
    elseif k === _NK_OP || k === _NK_CONTRACTION || k === _NK_CALL
        for ci in eachindex(r.children)
            _oop_inv_nodes_identical(
                _Node[n.children[ci] for n in nodes],
                Kof, m
            ) || return false
        end
        return true
    else # _NK_ACCESS / anything else: decline, fold to cell
        return false
    end
end

# ---- Leaf tables shared by both rounds ---------------------------------------
# A group of aligned leaves, one per class member (`nodes[i]` in member `i`'s
# context kernel `Kof(i)` and lane plan `Pof(i)`), becomes one table over the
# merged lanes: member `i`'s `Ls[i]` lanes follow member `i - 1`'s, and each
# lane's entry is what that member's leaf reads at that lane.

# State family: the slot read (0 = ghost).
function _lane_state_table(nodes::Vector{_Node}, Kof, Pof, Ls::Vector{Int})
    tbl = Vector{Int}(undef, sum(Ls)); q = 0
    for i in eachindex(nodes)
        lk = Ls[i]; idx = nodes[i].idx
        a = Kof(i).acc[idx]; pl = Pof(i)
        if a.kind === _AK_STATE_FIXED
            tbl[(q + 1):(q + lk)] .= a.idx
        elseif a.kind === _AK_STATE_AFFINE
            tbl[(q + 1):(q + lk)] .= pl.gathers[idx]
        else # TBL_BOX: the raw table, ghosts back to 0
            g = pl.gathers[idx]; gh = pl.ghost[idx]
            if isempty(gh)
                tbl[(q + 1):(q + lk)] .= g
            else
                for mm in 1:lk
                    tbl[q + mm] = gh[mm] ? 0 : g[mm]
                end
            end
        end
        q += lk
    end
    return tbl
end

# Live forcing family: the index into the one shared buffer.
function _lane_forcing_table(nodes::Vector{_Node}, Kof, Pof, Ls::Vector{Int})
    tbl = Vector{Int}(undef, sum(Ls)); q = 0
    for i in eachindex(nodes)
        lk = Ls[i]; idx = nodes[i].idx
        a = Kof(i).acc[idx]
        tbl[(q + 1):(q + lk)] .= a.kind === _AK_ARR_FIXED ? a.idx : Pof(i).forc[idx]
        q += lk
    end
    return tbl
end

# Value leaves (literals and frozen-const reads, mixed): the value read.
function _lane_value_table(nodes::Vector{_Node}, Pof, Ls::Vector{Int})
    tbl = Vector{Float64}(undef, sum(Ls)); q = 0
    for i in eachindex(nodes)
        lk = Ls[i]; nd = nodes[i]
        if nd.kind === _NK_LITERAL
            tbl[(q + 1):(q + lk)] .= nd.literal
        else
            tbl[(q + 1):(q + lk)] .= Pof(i).consts[nd.idx]
        end
        q += lk
    end
    return tbl
end

# Append `desc` to the merged kernel's descriptor table; the access node reading it.
function _push_lane_desc!(accvec::Vector{_AccDesc}, desc::_AccDesc)
    push!(accvec, desc)
    return _Node(_NK_ACCESS, :acc, 0.0, length(accvec), Symbol(""), nothing, _Node[])
end

# Merge one class of lockstep-identical kernels (indices `js` into
# kernels/plans) into a single lane-batched kernel. Members' lanes are
# concatenated in `js` order; each varying leaf becomes a table over the
# merged lane ordinal, read through `_outs_cells` addressing (s1=1, off=1).
function _oop_merge_group(kernels, plans, js::Vector{Int})
    m = length(js); Ls = Int[length(plans[j].out_slots) for j in js]
    # Merge the members' aligned trees. Kof(i) / Pof(i): member i's kernel and
    # the plan whose tables resolve its descriptors, so every table below has
    # member-lane length by construction. `keep_inv`: when every member's inv
    # recipes are VALUE-identical the merged kernel keeps a real inv tier —
    # evaluated once per call — and only the cell tier goes per-lane;
    # otherwise the inv tier folds into the cell tier. Both placements compute
    # the same bits.
    function merge_trees(Kof, Pof, keep_inv::Bool)
        accvec = _AccDesc[]
        n_inv = length(Kof(1).cse.inv_recipes); n_cell = length(Kof(1).cse.recipes)
        @assert _allof(
            i -> length(Kof(i).cse.inv_recipes) == n_inv &&
                length(Kof(i).cse.recipes) == n_cell, 1:m
        )
        keep = keep_inv && n_inv > 0 &&
            _allof(
            i2 -> _oop_inv_nodes_identical(
                _Node[Kof(i).cse.inv_recipes[i2] for i in 1:m], Kof, m
            ),
            1:n_inv
        )
        newscr = _AccScratch(keep ? n_cell : n_inv + n_cell)
        invscr = _AccScratch(keep ? n_inv : 0)
        # The members' trees are DAGs, and a clone that descends into every
        # reference unfolds them. `cloned` maps an aligned member tuple, by
        # identity, to the node already built for it, so a subexpression the
        # members share at the same places is cloned once and stays shared. A
        # repeated tuple names the same descriptors and literals in every
        # member, so the node built for it, a lane table read included, holds
        # the same values.
        cloned = _MergeMemo()
        function clone(nodes::Vector{_Node})::_Node
            key = _NodeKey[_NodeKey(n) for n in nodes]
            hit = get(cloned, key, nothing)
            hit === nothing || return hit
            out = clone_new(nodes)
            cloned[key] = out
            return out
        end
        function clone_new(nodes::Vector{_Node})::_Node
            r = nodes[1]; k = r.kind
            if k === _NK_LITERAL
                if _allof(i -> isequal(nodes[i].literal, r.literal), 1:m)
                    return _Node(k, r.op, r.literal, r.idx, r.sym, nothing, _Node[])
                end
                return _push_lane_desc!(
                    accvec, _AccConstBox(_lane_value_table(nodes, Pof, Ls), 1, 0, 0, 1)
                )
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
            elseif k === _NK_ACCESS
                akind = Kof(1).acc[r.idx].kind
                desc = if _oop_x_statefam(akind)
                    _AccStateTblBox(_lane_state_table(nodes, Kof, Pof, Ls), 1, 0, 0, 1)
                elseif _oop_x_constfam(akind)
                    _AccConstBox(_lane_value_table(nodes, Pof, Ls), 1, 0, 0, 1)
                else # live forcing (same buffer by the signature)
                    _AccArrTblBox(
                        Kof(1).acc[r.idx].arr, _lane_forcing_table(nodes, Kof, Pof, Ls),
                        1, 0, 0, 1
                    )
                end
                return _push_lane_desc!(accvec, desc)
            else # operator or contraction (payload-free, by the signature)
                pay = r.payload
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

    # NOTE: these names must not collide with `clone`'s locals — a nested
    # function assigning a name bound in this scope REBINDS the shared box.
    msp_, mrc_, minv_, mis_, mav_, msc_ = merge_trees(
        i -> kernels[js[i]],
        i -> plans[js[i]], true
    )
    outs = reduce(vcat, (plans[j].out_slots for j in js))
    return _AccKernel(
        _outs_cells(outs), msp_, mav_,
        _AccCSE(mrc_, msc_, minv_, mis_)
    )
end

# The class merge's per-kernel lane plans, built on first use. Grouping reads
# only whether a kernel vectorizes, and the
# global out-slot check reads only its cell set, so a full plan (its per-lane
# tables) is built only for a kernel whose class actually merges.
#
# `outs_unique` is the global out-slot verdict, shared by every plan vector a
# merge round derives from this one: a round replaces the members of a class
# by one kernel whose lanes are exactly theirs, so the vectorized kernels' out
# slots, taken together, are the same multiset after the round as before it.
struct _LazyOopPlans <: AbstractVector{_OopAccPlan}
    kernels::Vector{_AccKernel}
    plans::Vector{Union{Nothing, _OopAccPlan}}
    vecable::Vector{Int8}                  # -1 not yet known, else 0 / 1
    outs_unique::Base.RefValue{Int8}       # -1 not yet known, else 0 / 1
end
_LazyOopPlans(kernels::AbstractVector{_AccKernel}) =
    _LazyOopPlans(
    collect(_AccKernel, kernels),
    Union{Nothing, _OopAccPlan}[nothing for _ in kernels],
    fill(Int8(-1), length(kernels)), Ref(Int8(-1))
)
Base.size(v::_LazyOopPlans) = (length(v.kernels),)
function Base.getindex(v::_LazyOopPlans, j::Int)
    p = v.plans[j]
    p === nothing || return p
    p = _build_oop_acc_plan(v.kernels[j])
    v.plans[j] = p
    v.vecable[j] = p.vectorizable ? 1 : 0
    return p
end

function _plan_vecable(v::_LazyOopPlans, j::Int)
    if v.vecable[j] < 0
        v.vecable[j] = _oop_plan_vecable(v.kernels[j]) ? 1 : 0
    end
    return v.vecable[j] == 1
end
_plan_vecable(v::AbstractVector{_OopAccPlan}, j::Int) = v[j].vectorizable

_plans_empty(v::_LazyOopPlans) =
    _LazyOopPlans(_AccKernel[], Union{Nothing, _OopAccPlan}[], Int8[], v.outs_unique)
_plans_empty(::AbstractVector{_OopAccPlan}) = _OopAccPlan[]
function _plans_push!(out::_LazyOopPlans, v::_LazyOopPlans, j::Int)
    push!(out.kernels, v.kernels[j]); push!(out.plans, v.plans[j])
    push!(out.vecable, v.vecable[j])
    return out
end
_plans_push!(out::AbstractVector{_OopAccPlan}, v::AbstractVector{_OopAccPlan}, j::Int) =
    push!(out, v[j])
function _plans_push!(out::_LazyOopPlans, K::_AccKernel, pl::_OopAccPlan)
    push!(out.kernels, K); push!(out.plans, pl)
    push!(out.vecable, pl.vectorizable ? 1 : 0)
    return out
end
_plans_push!(out::AbstractVector{_OopAccPlan}, ::_AccKernel, pl::_OopAccPlan) = push!(out, pl)

# Every vectorized plan's out slots, together, are distinct (an unvectorized
# plan scatters nothing).
function _plans_outs_unique(kernels, v::_LazyOopPlans)
    if v.outs_unique[] < 0
        v.outs_unique[] = _cellsets_outs_unique(
                kernels[j].cells for j in eachindex(kernels)
                if _plan_vecable(v, j)
            ) ? 1 : 0
    end
    return v.outs_unique[] == 1
end
_plans_outs_unique(kernels, v::AbstractVector{_OopAccPlan}) =
    allunique(reduce(vcat, (pl.out_slots for pl in v); init = Int[]))

"""
    _merge_classes(kernels, plans, sig, merge_group, tally) -> (kernels′, plans′, diag)

One class-merge round: group the kernels by the structural signature
`sig(K, vectorizable)` (`(key, why)`, `key === nothing` keeps the kernel out),
merge each group of two or more with `merge_group(kernels, plans, js)`, and
return the merged kernel/plan vectors — value-exact replacements for the
inputs — plus `(n_in, n_out, n_classes, n_blocked, n_failed)`. Falls back to
the inputs (whole round or per group) whenever a precondition does not hold;
never errors on a merge-ineligible input. `tally` is the cascade counter
bumped once per merged class. Output order: classes by first-member kernel
index, then the kernels no class took.
"""
function _merge_classes(
        kernels::AbstractVector{_AccKernel},
        plans::AbstractVector{_OopAccPlan},
        sig::S, merge_group::G, tally::Symbol
    ) where {S, G}
    nodiag = (;
        n_in = length(kernels), n_out = length(kernels),
        n_classes = 0, n_blocked = length(kernels), n_failed = 0,
    )
    length(kernels) <= 1 && return (kernels, plans, nodiag)

    # Assignment scatter + globally unique out-slots ⇒ concatenating lanes
    # across kernels cannot reorder any write. Without uniqueness, decline.
    _plans_outs_unique(kernels, plans) || return (kernels, plans, nodiag)

    groups = Dict{Any, Vector{Int}}()
    passthrough = Int[]
    for j in eachindex(kernels)
        s, _why = sig(kernels[j], _plan_vecable(plans, j))
        s === nothing ? push!(passthrough, j) : push!(get!(groups, s, Int[]), j)
    end

    out_kernels = _AccKernel[]
    out_plans = _plans_empty(plans)
    n_failed = 0
    for js in sort!(collect(values(groups)); by = first)
        if length(js) == 1
            push!(out_kernels, kernels[js[1]]); _plans_push!(out_plans, plans, js[1])
            continue
        end
        merged = try
            K = merge_group(kernels, plans, js)
            pl = _build_oop_acc_plan(K)
            pl.vectorizable ? (K, pl) : nothing
        catch err
            _is_resource_error(err) && rethrow()
            nothing
        end
        if merged === nothing
            n_failed += 1
            for j in js
                push!(out_kernels, kernels[j]); _plans_push!(out_plans, plans, j)
            end
        else
            push!(out_kernels, merged[1]); _plans_push!(out_plans, merged[1], merged[2])
            _tally_cascade!(tally)
        end
    end
    for j in passthrough
        push!(out_kernels, kernels[j]); _plans_push!(out_plans, plans, j)
    end
    diag = (;
        n_in = length(kernels), n_out = length(out_kernels),
        n_classes = length(groups), n_blocked = length(passthrough),
        n_failed,
    )
    return (out_kernels, out_plans, diag)
end

# Round 1: classes by POST-CSE structure (`_oop_merge_kernel_sig`), over one
# class table for the round.
function _merge_oop_acc_kernels(
        kernels::AbstractVector{_AccKernel}, plans::AbstractVector{_OopAccPlan},
        tally::Symbol = :classmerge_round1_merge
    )
    intern = _SigIntern()
    sig(K, vectorizable) = _oop_merge_kernel_sig(K, vectorizable, intern)
    return _merge_classes(kernels, plans, sig, _oop_merge_group, tally)
end

# ============================================================================
# ROUND 2: expansion-normalized (CSE-slicing-insensitive) kernel-class merge.
#
# WHY. Round 1 groups kernels by their POST-CSE structure: the signature walks
# the stored spine + recipe tiers, so two kernels of the SAME formula whose
# per-kernel CSE pass sliced different recipe sets (a boundary cell's slightly
# different tree changes which subtrees repeat, and a single early difference
# renumbers every later slot) land in different classes even though their
# fully-expanded arithmetic is lockstep-identical. On a real transport equation
# the great majority of round-1 classes share ONE spine and differ only in recipe
# slicing/slot numbering plus literal-vs-frozen-const leaf flips — not in
# forcing-buffer identity. Expansion-normalizing the signature
# (inline every own-scratch `_NK_CACHED` read through its recipe, treat a LITERAL
# and a frozen const-family access as one "value leaf") more than halves them.
#
# HOW. A second grouping pass over the round-1 output:
#   * SIGNATURE: a memoized structural HASH of the fully-EXPANDED trees —
#     `_NK_CACHED` reads of the kernel's own tiers are resolved through the
#     recipe they name, so recipe slicing and slot numbering vanish. Leaf
#     tokens: state family (AS) / per-buffer forcing family / one VALUE token
#     for literal + frozen const family / param sym.
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
# sequence with its own leaf values (state slots / consts / forcing indices
# ride per-lane tables); expansion and re-CSE only move pure
# deterministic subcomputations between "cached once" and "recomputed", which
# cannot change any bit. The stencil-vs-unmerged differential tests and the
# ReSEACT maxabs==0.0 gate are the oracles.
#
# SAFETY. Same posture as round 1: any ineligible input, structural mismatch,
# clone-budget overrun, or unvectorizable rebuilt plan falls back to the
# round-1 kernels for that class. The class-merge gate disables both rounds;
# the gate below disables round 2 only.
# ============================================================================

# The lockstep-mergeable kinds by what they read (`_ak_source`).
_oop_x_statefam(k) = _ak_source(k) === :state
_oop_x_forcfam(k) = _ak_source(k) === :forcing
_oop_x_constfam(k) = (s = _ak_source(k); s === :const || s === :loop)

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
# `K`.
function _oop_x_sig(
        n0::_Node, K::_AccKernel,
        memo::IdDict{_Node, UInt}, why::Base.RefValue{Symbol}
    )::UInt
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
            r = hash(:badacc, UInt(0x07))
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
    elseif k === _NK_OP || k === _NK_CONTRACTION || k === _NK_CALL
        pl = n.payload
        paytok = if pl === nothing
            0x00
        else
            objectid(pl)                                # identity: never wrongly merged
        end
        r = hash(
            (
                k === _NK_OP ? :O : k === _NK_CALL ? :F : :K, n.op, paytok,
                k === _NK_CONTRACTION ? reinterpret(UInt64, n.literal) : UInt64(0),
                length(n.children),
            ), UInt(0x8811)
        )
        for c in n.children
            r = hash(_oop_x_sig(c, K, memo, why), r)
        end
    else
        why[] = :node_kind
        r = hash((:unk, Int(k)), UInt(0x9922))
    end
    memo[n] = r
    return r
end

_oop_x_kernel_sig(K::_AccKernel, plan::_OopAccPlan) =
    _oop_x_kernel_sig(K, plan.vectorizable)
function _oop_x_kernel_sig(K::_AccKernel, vectorizable::Bool)
    why = Ref(:ok)
    vectorizable || (why[] = :unvectorizable)
    memo = IdDict{_Node, UInt}()
    h = hash(_oop_x_sig(K.spine, K, memo, why), UInt(0xaa33))
    return (why[] === :ok ? h : nothing), why[]
end

# Identity-based CSE over a cloned DAG: every OP/CONTRACTION node referenced
# more than once (the clone memo preserved member-common sharing), at least
# once outside a lazily evaluated operand (`_cg_lazy_operand`), becomes a
# cell-tier recipe read through a fresh scratch; recipes are emitted in
# topological (children-first) order, so recipe i only ever reads lower slots
# — the invariant every runner's prelude fill relies on. Caching a pure
# deterministic subtree instead of re-walking it cannot change any bit; a node
# referenced only under guards stays in place, because the recipe prelude runs
# unconditionally and would evaluate what the lazy walk skips.
function _oop_x_apply_cse(root::_Node)
    refcnt = IdDict{_Node, Int}()
    order = _Node[]                      # post-order, each node once
    seen = IdDict{_Node, Bool}()
    stack = Tuple{_Node, Int}[(root, 0)]
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
    dorder, dpos = _dag_postorder(root, _dag_children, _dag_every)
    _, uncond = _dag_path_counts(dorder, dpos, _dag_children, _dag_every, _cg_lazy_operand)
    isrec(n) = (n.kind === _NK_OP || n.kind === _NK_CONTRACTION || n.kind === _NK_CALL) &&
        get(refcnt, n, 0) >= 2 && n !== root && uncond[dpos[n]] >= 1
    nrec = count(isrec, order)
    nrec == 0 && return (root, _Node[], _AccScratch(0))
    scr = _AccScratch(nrec)
    recipes = Vector{_Node}(undef, nrec)
    repl = IdDict{_Node, _Node}()         # old node -> read/rebuilt replacement
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
            nn = changed ? _Node(
                    n.kind, n.op, n.literal, n.idx, n.sym,
                    n.payload, ch
                ) : n
        end
        if isrec(n)
            slot += 1
            recipes[slot] = nn
            repl[n] = _Node(
                _NK_CACHED, Symbol(""), 0.0, slot, Symbol(""),
                scr, _Node[]
            )
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
    m = length(js); Ls = Int[length(plans[j].out_slots) for j in js]
    budget = Ref(2_000_000)              # cloned-node budget (throw ⇒ fallback)

    function merge_trees(Kof, Pof)
        accvec = _AccDesc[]
        memo = Dict{Vector{UInt}, _Node}()
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
                _push_lane_desc!(
                    accvec,
                    _AccStateTblBox(_lane_state_table(nodes, Kof, Pof, Ls), 1, 0, 0, 1)
                )
            elseif all(i -> isacc(i) && _oop_x_forcfam(akind(i)), 1:m)
                arr = Kof(1).acc[r.idx].arr
                all(i -> Kof(i).acc[nodes[i].idx].arr === arr, 1:m) ||
                    error("round-2: forcing buffer mismatch in a class")
                _push_lane_desc!(
                    accvec,
                    _AccArrTblBox(arr, _lane_forcing_table(nodes, Kof, Pof, Ls), 1, 0, 0, 1)
                )
            elseif all(
                    i -> nodes[i].kind === _NK_LITERAL ||
                        (isacc(i) && _oop_x_constfam(akind(i))), 1:m
                )
                # Value leaf group: literal and frozen-const members mix. All
                # lanes equal ⇒ it stays a scalar literal.
                tbl = _lane_value_table(nodes, Pof, Ls)
                if all(==(tbl[1]), tbl)
                    _Node(_NK_LITERAL, :lit, tbl[1], 0, Symbol(""), nothing, _Node[])
                else
                    _push_lane_desc!(accvec, _AccConstBox(tbl, 1, 0, 0, 1))
                end
            elseif k === _NK_PARAM || k === _NK_TIME
                all(i -> nodes[i].kind === k && nodes[i].sym === r.sym, 1:m) ||
                    error("round-2: param/time mismatch in a class")
                _Node(k, r.op, r.literal, r.idx, r.sym, r.payload, _Node[])
            elseif k === _NK_OP || k === _NK_CONTRACTION || k === _NK_CALL
                nch = length(r.children)
                all(
                    i -> nodes[i].kind === k && nodes[i].op === r.op &&
                        length(nodes[i].children) == nch &&
                        (
                        k !== _NK_CONTRACTION ||
                            isequal(nodes[i].literal, r.literal)
                    ), 1:m
                ) ||
                    error("round-2: op/contraction mismatch in a class")
                all(i -> nodes[i].payload === r.payload, 1:m) ||
                    error("round-2: op payload mismatch in a class")
                pay = r.payload
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

    msp_, mrc_, mav_, msc_ = merge_trees(i -> kernels[js[i]], i -> plans[js[i]])
    outs = reduce(vcat, (plans[j].out_slots for j in js))
    return _AccKernel(
        _outs_cells(outs), msp_, mav_,
        _AccCSE(mrc_, msc_, _Node[], _AccScratch(0))
    )
end

# Round 2: classes by the expansion-normalized hash (`_oop_x_kernel_sig`).
_merge_oop_x_kernels(
    kernels::AbstractVector{_AccKernel}, plans::AbstractVector{_OopAccPlan},
    tally::Symbol = :classmerge_round2_merge
) = _merge_classes(kernels, plans, _oop_x_kernel_sig, _oop_x_merge_group, tally)

# ---- Affine boxes stay out of the merge on the compiled in-place path ------
#
# A class merge turns every member's reads into per-lane slot tables: one
# indexed load and a ghost test per operand per cell, where the member's own
# affine box reads `u[o + Δ]` at a constant offset. On a stencil's boundary
# classes (the faces, edges and corners around an affine interior) that is
# several times the arithmetic it feeds. The in-place emitter compiles each
# affine box kernel into its own loop nest, so for it a box kernel is better
# left alone; what the merge buys there is fewer kernels, which matters only
# when the count is large. So `keep_affine` (the in-place build, with the
# emitter on) holds back every box kernel of rank 2 or more that reads only
# through affine, fixed or box-addressed descriptors and spans more than one cell along at least one axis, up to `_AFFINE_KEEP_MAX`
# kernels (by the number of such axes, then build order, both independent of
# the grid size); the merge runs on the rest. Corner boxes (one cell along
# every axis) are merged: they are a handful of cells whatever the grid size.
# One-axis boxes are merged too: there the box processor
# also cuts an irregular gather into affine runs, whose number moves with the
# grid size, and only the merge keeps that program the same at every size. The out-of-place product
# (the compiled backends' input) and the interpreter runner keep the full
# merge. Keeping a kernel out of a merge never changes a value: each cell
# evaluates the same op sequence either way.
const _AFFINE_KEEP_MAX = 256

_affine_keep_kind(k) =
    k in (
    _AK_STATE_AFFINE, _AK_CONST_BOX, _AK_STATE_FIXED,
    _AK_LOOP_IDX, _AK_ARR_FIXED, _AK_FORCING_BOX,
)

# The number of axes along which `K`'s box is more than one cell thick, or 0
# when `K` is not an affine box kernel the emitter compiles as its own nest.
_affine_keep_reads(K::_AccKernel) = _allof(a -> _affine_keep_kind(a.kind), K.acc)
function _affine_box_rank(K::_AccKernel)
    cs = K.cells
    (_is_outs(cs) || length(cs.strides) < 2 || !_affine_keep_reads(K)) && return 0
    return count(d -> !_cellset_slab(cs, d), eachindex(cs.strides))
end

# Sorted indices of the kernels `keep_affine` holds back (see above).
function _affine_boxes_to_keep(kernels::AbstractVector{_AccKernel})
    (_codegen_disabled() || _codegen_node_budget() <= 0) && return Int[]
    cap = _AFFINE_KEEP_MAX
    rk = [_affine_box_rank(K) for K in kernels]
    cand = [j for j in eachindex(kernels) if rk[j] > 0]
    sort!(cand; by = j -> (-rk[j], j))
    length(cand) > cap && resize!(cand, cap)
    return sort!(cand)
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

The two rounds run once each (counted `:classmerge_round{1,2}_merge`, one
bump per merged class). They are idempotent: a second application to their
output merges nothing, which the tests check by building under
`_with_merge_recheck`, where the build applies them again and counts any merge
as `:classmerge_recheck`. Diag: `n_in`/`n_classes`/`n_blocked` describe round
1, `n_out` the final list, `n_failed` the sum over both rounds.
"""
function _merge_acc_kernel_classes(
        kernels::AbstractVector{_AccKernel};
        keep_affine::Bool = false
    )
    (_oop_merge_disabled() || length(kernels) <= 1) && return (kernels, nothing)
    # A tile that shares its code keeps every box kernel: it may own none of a
    # box's cells, and a class of such boxes would have no cell
    # to list, which no merged kernel represents.
    kept = _range_shared_code(_range_spec_now()) ?
        [
            j for j in eachindex(kernels)
            if !_is_outs(kernels[j].cells) && !isempty(kernels[j].cells.strides)
        ] :
        keep_affine ? _affine_boxes_to_keep(kernels) : Int[]
    # A shifted equality scatter's pieces (scatter.jl) are a fixed number of
    # boxes at every grid size, and two scatters of one document are the same
    # box at different shifts; merged, each would read through per-lane tables
    # built over all of its cells. They stay their own loop nests.
    keep = _scatter_keep_now()
    if keep !== nothing && !isempty(keep)
        extra = Int[j for j in eachindex(kernels) if haskey(keep, kernels[j])]
        isempty(extra) || sort!(unique!(append!(kept, extra)))
    end
    if !isempty(kept)
        rest = _AccKernel[kernels[j] for j in eachindex(kernels) if !insorted(j, kept)]
        merged, diag = _merge_acc_kernel_classes(rest)
        out = vcat(_AccKernel[kernels[j] for j in kept], merged)
        diag === nothing && return (out, nothing)
        return (
            out, (;
                diag..., n_in = length(kernels), n_out = length(out),
                n_blocked = diag.n_blocked + length(kept),
            ),
        )
    end
    plans = _LazyOopPlans(kernels)
    merged, mplans, rdiag = _merge_oop_acc_kernels(kernels, plans)
    # Round 2 (expansion-normalized; see the section header above): collapse
    # classes that differ only in per-kernel CSE slicing / slot numbering /
    # literal-vs-frozen-const leaves, with the same per-class fallback posture.
    rxdiag = nothing
    if length(merged) > 1
        merged, mplans, rxdiag = _merge_oop_x_kernels(merged, mplans)
    end
    if _merge_recheck_on() && length(merged) > 1
        m2, p2, _ = _merge_oop_acc_kernels(merged, mplans, :classmerge_recheck)
        length(m2) > 1 && _merge_oop_x_kernels(m2, p2, :classmerge_recheck)
    end
    base = rdiag
    basex = rxdiag
    n_failed = rdiag.n_failed + (rxdiag === nothing ? 0 : rxdiag.n_failed)
    diag = (;
        n_in = base.n_in, n_out = length(merged),
        base.n_classes, base.n_blocked, n_failed,
    )
    if basex !== nothing
        diag = (;
            diag..., n_x_in = basex.n_in, n_x_out = basex.n_out,
            n_x_classes = basex.n_classes, n_x_blocked = basex.n_blocked,
        )
    end
    return (merged, diag)
end
