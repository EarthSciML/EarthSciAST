# ========================================================================
# tree_walk/acc_merge.jl — part of the tree-walk evaluator (array-IR B, stage 3).
# Included by src/tree_walk.jl AFTER vectorize.jl (it reuses `_struct_sig!` and
# `_check_fn_group_specs`) and access_kernel.jl (`_AccKernel` and descriptors).
#
# The PER-CELL fallback's whole-array host: group an array equation's compiled
# per-cell `(du_slot, _Node)` entries by structural signature — exactly the
# `_vectorize_cell_entries` partition — and merge each group into ONE
# `_AccKernel` over an INDIRECT-OUTS cell set, instead of a `_VecKernel` on the
# `_VecNode` overlay. The Phase-A lane-tape machinery then runs the kernel
# de-scalarized at Float64 (per-node tile loops over the merged per-cell
# tables), the scalar `_eval_acc` walk stays the eltype-generic / lazy-guard
# reference, and the oop vectorized form gets whole-array gathers — one IR
# family for every array-equation tier.
#
# Bit-identity by construction: the merge is the same structural transpose
# `_merge_nodes` performed — a leaf that is equal across the group stays a
# scalar (literal / fixed slot / invariant), a varying one becomes a per-cell
# table indexed by the cell ordinal — and the evaluators apply the identical
# scalar op sequence per lane (`_eval_acc_op` mirrors `_eval_node_op`;
# `_NK_CONTRACTION` keeps its seeded sequential ⊕-fold on every runner).
# The forced per-cell reference (`ESS_STENCIL_DISABLE=1`) still builds the
# `_VecNode` overlay, so the acc≡percell differentials compare two genuinely
# independent merges.
#
# LAZY GUARDS. `_eval_acc_op`'s `ifelse`/`and`/`or` arms short-circuit exactly
# like the scalar walker's, so a merged group with a lazy guard keeps per-cell
# guard semantics on the scalar runner (the lane tape declines lazy ops and
# leaves such kernels there — the documented policy: stop REQUIRING the
# overlay, don't force eagerness). For the same reason the per-cell/invariant
# CSE tiers are SKIPPED on a lazy-bearing spine: their prelude is
# unconditional, and hoisting a subtree whose occurrences sit under a guard
# could evaluate what the guarded walk would skip.
# ========================================================================

# Does this spine carry an op whose scalar evaluation is lazy?
_acc_node_has_lazy(n::_Node) =
    (n.kind === _NK_OP && (n.op === :ifelse || n.op === :and || n.op === :or)) ||
    any(_acc_node_has_lazy, n.children)

# Merge one structurally-identical group of per-cell nodes into an access
# spine, appending per-cell tables to `acc` (the kernel's descriptor table).
# Mirrors `_merge_nodes` (vectorize.jl) case for case:
#   LITERAL   all-equal → spine literal; varying → CONST_BOX ordinal table
#   STATE     all-equal → STATE_FIXED (invariant tier hoists it); varying →
#             STATE_TBL_BOX ordinal slot table (never 0 here — a per-cell ghost
#             is a LITERAL 0.0 leaf, not a slot)
#   PARAM/TIME  pass through (spine kinds)
#   PARAM_GATHER all-equal → ARR_FIXED (live); varying → ARR_TBL_BOX (live)
#   CONTRACTION children merged element-wise (the signature pins the width)
#   OP / fn   children merged; a `fn` group's specs are verified content-equal
#             (`_check_fn_group_specs`) since the merged node carries ONE spec
# The ordinal tables use box-local addressing `s1=1, off=1` — the outs runner
# threads the cell ordinal through `midx[1]`.
function _acc_merge_nodes(nodes::Vector{_Node}, len::Int,
                          acc::Vector{_AccDesc})::_Node
    n1 = nodes[1]
    k = n1.kind
    if k === _NK_LITERAL
        v1 = n1.literal
        all(isequal(nd.literal, v1) for nd in nodes) && return n1
        push!(acc, _AccConstBox(Float64[nd.literal for nd in nodes], 1, 0, 0, 1))
        return _acc(length(acc))
    elseif k === _NK_STATE
        i1 = n1.idx
        if all(nd.idx == i1 for nd in nodes)
            push!(acc, _AccStateFixed(i1))
        else
            push!(acc, _AccStateTblBox(Int[nd.idx for nd in nodes], 1, 0, 0, 1))
        end
        return _acc(length(acc))
    elseif k === _NK_PARAM || k === _NK_TIME
        return n1
    elseif k === _NK_PARAM_GATHER
        # All cells share the captured live buffer (`payload`, guaranteed equal
        # by the signature); the per-lane linear offsets become an index table.
        # Both lowerings read the ALIASED buffer at run time — never a frozen
        # copy — so an in-place refresh is always seen (and the J5 trace guard
        # covers both kinds).
        buf = n1.payload::Vector{Float64}
        i1 = n1.idx
        if all(nd.idx == i1 for nd in nodes)
            push!(acc, _AccArrFixed(buf, i1))
        else
            push!(acc, _AccArrTblBox(buf, Int[nd.idx for nd in nodes], 1, 0, 0, 1))
        end
        return _acc(length(acc))
    elseif k === _NK_CONTRACTION
        m = length(n1.children)
        ch = _Node[_acc_merge_nodes(_Node[nd.children[c] for nd in nodes], len, acc)
                   for c in 1:m]
        return _mknode(kind=_NK_CONTRACTION, op=n1.op, literal=n1.literal,
                       children=ch)
    else  # _NK_OP / fn
        n1.op === :fn && _check_fn_group_specs(nodes)
        m = length(n1.children)
        ch = _Node[_acc_merge_nodes(_Node[nd.children[c] for nd in nodes], len, acc)
                   for c in 1:m]
        return _mknode(kind=_NK_OP, op=n1.op, payload=n1.payload, children=ch)
    end
end

# Group an array equation's per-cell `(du_slot, node)` entries by structure and
# build one indirect-outs `_AccKernel` per group. Same signature partition and
# first-seen order as `_vectorize_cell_entries` — kernel boundaries, lane
# order, and out-slot order are identical to the overlay merge this replaces.
function _acc_from_cell_entries(entries::Vector{Tuple{Int,_Node}})::Vector{_AccKernel}
    isempty(entries) && return _AccKernel[]
    order = String[]
    groups = Dict{String,Tuple{Vector{Int},Vector{_Node}}}()
    sigbuf = IOBuffer()
    for (slot, node) in entries
        sig = String(take!(_struct_sig!(sigbuf, node)))
        if !haskey(groups, sig)
            groups[sig] = (Int[], _Node[])
            push!(order, sig)
        end
        slots, nds = groups[sig]
        push!(slots, slot)
        push!(nds, node)
    end
    kernels = _AccKernel[]
    for sig in order
        slots, nds = groups[sig]
        len = length(slots)
        acc = _AccDesc[]
        spine = _acc_merge_nodes(nds, len, acc)
        # CSE + invariant hoisting on the merged spine — skipped on a
        # lazy-bearing one (see the header) so guard semantics survive.
        spine, cse = _acc_node_has_lazy(spine) ? (spine, _ACC_NO_CSE) :
                     _build_acc_cse(spine, acc)
        push!(kernels, _AccKernel(_outs_cells(slots), spine, acc,
                                  _FixedBound(0), 0.0, cse))
    end
    return kernels
end
