# tree_walk/acc_merge.jl — the per-cell build's merge into access kernels: an
# array equation's compiled per-cell `(du_slot, _Node)` entries grouped by
# structural signature, each group merged into one `_AccKernel` over an
# indirect-outs cell set, which the codegen tier, the scalar `_eval_acc`
# runner and the out-of-place form all consume.
#
# Bit identity: the merge is a structural transpose. A leaf equal across the
# group stays a scalar; a varying one becomes a per-cell table read by the cell
# ordinal; every runner applies the same scalar op sequence per cell
# (`_eval_acc_op` mirrors `_eval_node_op`, and a contraction keeps its seeded
# sequential fold).
#
# Lazy guards: `ifelse`/`and`/`or` short-circuit on every runner as in the
# scalar walker, and a spine carrying one skips the merged CSE, so no value
# computed only under a guard reaches an unconditional prelude.

# Does this spine carry an op whose scalar evaluation is lazy?
_acc_node_has_lazy(n::_Node) =
    _node_any(m -> m.kind === _NK_OP && _op_lazy_from(m.op) > 0, n)

# Cross-equation classes: `_compile_derivative_equations` pools every per-cell
# equation's entries and groups them once, so structurally identical cells of
# different equations share a kernel. Out-slots are unique across equations
# and kernels write disjoint `du` slots, so which kernel hosts a cell changes no
# bit. Kernels the affine tier mints per box merge at assembly instead
# (`_merge_acc_kernel_classes`, oop_merge.jl). Both run whenever the class
# merge does.
_cross_eq_class_emit_enabled() = !_oop_merge_disabled()

# Does a per-cell node hold a kind only the scalar walker evaluates: a state
# read at a slot computed per call, a recurrence's causal self-read, or a
# run-time loop? An access-kernel spine has no form for these, so a cell
# holding one is walked per cell (`percell_scalar`) and never reaches the merge
# below. Memoized on node identity: a compiled cell is a DAG.
function _acc_scalar_only(n::_Node, seen::IdDict{_Node, Bool} = IdDict{_Node, Bool}())
    hit = get(seen, n, nothing)
    hit === nothing || return hit
    k = n.kind
    r = k === _NK_STATE_GATHER || k === _NK_RECUR_GATHER || k === _NK_LOOPVAR ||
        k === _NK_CONTRACTION_LOOP || k === _NK_RAGGED_LOOP ||
        _anyof(c -> _acc_scalar_only(c, seen), n.children)
    seen[n] = r
    return r
end

# ---- Structural grouping signature ------------------------------------------

# A structural id, equal for two per-cell nodes iff they have an identical tree
# shape ignoring the values that legitimately vary per cell (STATE slot index,
# LITERAL value). Same id ⇒ unambiguous merge into one template. Different ids
# (in-bounds STATE vs ghost LITERAL, makearray region A vs B, valence-5 vs
# valence-6 contraction) ⇒ separate kernels.
#
# Ids are hash-consed in `intern`, shared by every node of one grouping: a
# node's id is the interned pair of its own token and its children's ids. A
# spine is a DAG with shared nodes, so the fold visits each distinct node once.
const _SigIntern = Dict{Tuple{Any, Vector{Int}}, Int}

function _struct_sig_id(root::_Node, intern::_SigIntern)::Int
    return _node_fold(root, Int) do n, kids
        get!(intern, (_struct_sig_token(n), collect(Int, kids)), length(intern) + 1)
    end
end

function _struct_sig_token(n::_Node)
    k = n.kind
    if k === _NK_STATE || k === _NK_LITERAL || k === _NK_TIME
        return k
    elseif k === _NK_PARAM
        return (k, n.sym)
    elseif k === _NK_PARAM_GATHER || k === _NK_CONST_GATHER
        # Cells reading the SAME captured array (`payload` object) merge into one
        # table read; different arrays ⇒ separate kernels.
        return (k, objectid(n.payload))
    elseif k === _NK_CONTRACTION
        return (k, n.op)
    elseif k === _NK_OP
        # The merge takes an op's payload from the group's first member, so a
        # payload is part of the structure.
        return n.payload === nothing ? (k, n.op) : (k, n.op, objectid(n.payload))
    elseif k === _NK_CALL
        # A template call: cells calling the same target merge argument-wise.
        return (k, objectid(n.payload))
    elseif k === _NK_CONTRACTION_LOOP || k === _NK_LOOPVAR || k === _NK_RAGGED_LOOP ||
            k === _NK_LIVE_GATHER
        # A run-time contraction loop or a ragged loop is confined to scalar
        # contexts: a cell holding one is walked by the scalar walker
        # (`_acc_scalar_only`) and never reaches the array-equation merge. A
        # live gather merges as an operator node (`_acc_merge_nodes`) but is
        # never grouped with another cell's. Should a loop arrive, it is keyed by
        # object identity so distinct loops never share a group, and
        # `_acc_merge_nodes` then refuses it by name (`_unknown_kind`).
        return (:loop, objectid(n))
    end
    return _unknown_kind(n, "the per-cell merge signature")
end

# Merge one structurally-identical group of per-cell nodes into an access
# spine, appending per-cell tables to `acc` (the kernel's descriptor table):
#   LITERAL   all-equal → spine literal; varying → CONST_BOX ordinal table
#   STATE     all-equal → STATE_FIXED (invariant tier hoists it); varying →
#             STATE_TBL_BOX ordinal slot table (never 0 here — a per-cell ghost
#             is a LITERAL 0.0 leaf, not a slot)
#   PARAM/TIME  pass through (spine kinds)
#   PARAM_GATHER all-equal → ARR_FIXED (live); varying → ARR_TBL_BOX (live)
#   CONTRACTION children merged element-wise (the structural id pins the width)
#   OP        children merged
#   CONST_GATHER / LIVE_GATHER  children merged, as an operator node with no
#             operator carrying the gather (same array, by the structural id)
# The ordinal tables use box-local addressing `s1=1, off=1` — the outs runner
# threads the cell ordinal through `midx[1]`.
#
# `memo` maps a tuple of member nodes (by identity) to its merged node, so a
# sub-tree every member shares at the same position is merged once and the
# merged spine keeps the sharing.
const _MergeMemo = Dict{Vector{_NodeKey}, _Node}

_acc_merge_nodes(nodes::Vector{_Node}, len::Int, acc::Vector{_AccDesc}) =
    _acc_merge_nodes(nodes, len, acc, _MergeMemo())

function _acc_merge_nodes(
        nodes::Vector{_Node}, len::Int, acc::Vector{_AccDesc}, memo::_MergeMemo
    )::_Node
    key = _NodeKey[_NodeKey(n) for n in nodes]
    hit = get(memo, key, nothing)
    hit === nothing || return hit
    merged = _acc_merge_nodes_uncached(nodes, len, acc, memo)
    memo[key] = merged
    return merged
end

function _acc_merge_nodes_uncached(
        nodes::Vector{_Node}, len::Int, acc::Vector{_AccDesc}, memo::_MergeMemo
    )::_Node
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
        # by the structural id); the per-lane linear offsets become an index
        # table. Both lowerings read the aliased buffer at run time, never a
        # frozen copy, so an in-place refresh is always seen.
        buf = n1.payload::Vector{Float64}
        i1 = n1.idx
        if all(nd.idx == i1 for nd in nodes)
            push!(acc, _AccArrFixed(buf, i1))
        else
            push!(acc, _AccArrTblBox(buf, Int[nd.idx for nd in nodes], 1, 0, 0, 1))
        end
        return _acc(length(acc))
    elseif k === _NK_CONTRACTION
        ch = _merge_children(nodes, len, acc, memo)
        return _mknode(
            kind = _NK_CONTRACTION, op = n1.op, literal = n1.literal,
            children = ch
        )
    elseif k === _NK_OP || k === _NK_CONST_GATHER || k === _NK_LIVE_GATHER
        # An operator's children merge element-wise. A table read at a computed
        # subscript (`_NK_CONST_GATHER`, `_NK_LIVE_GATHER`) is carried on the
        # access spine as an operator node with no operator holding the
        # `_ConstGatherArray`, the encoding the direct emitter reads as a table
        # read (`_de_is_cgather`, ext/reactant_direct/closed.jl).
        ch = _merge_children(nodes, len, acc, memo)
        return _mknode(kind = _NK_OP, op = n1.op, payload = n1.payload, children = ch)
    elseif k === _NK_CALL
        ch = _merge_children(nodes, len, acc, memo)
        return _mknode(kind = _NK_CALL, op = n1.op, payload = n1.payload, children = ch)
    end
    return _unknown_kind(n1, "the per-cell merge")
end

_merge_children(nodes::Vector{_Node}, len::Int, acc::Vector{_AccDesc}, memo::_MergeMemo) =
    _Node[
    _acc_merge_nodes(_Node[nd.children[c] for nd in nodes], len, acc, memo)
        for c in eachindex(nodes[1].children)
]

# Group an array equation's per-cell `(du_slot, node)` entries by structure and
# build one indirect-outs `_AccKernel` per group, in first-seen group order —
# deterministic kernel boundaries, lane order, and out-slot order.
function _acc_from_cell_entries(entries::Vector{Tuple{Int, _Node}})::Vector{_AccKernel}
    isempty(entries) && return _AccKernel[]
    order = Int[]
    groups = Dict{Int, Tuple{Vector{Int}, Vector{_Node}}}()
    intern = _SigIntern()
    for (slot, node) in entries
        sig = _struct_sig_id(node, intern)
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
        acc = _AccDesc[]
        spine = _acc_merge_nodes(nds, length(slots), acc)
        # CSE + invariant hoisting on the merged spine — skipped on a
        # lazy-bearing one (see the header) so the SCALAR reference stays lazy.
        spine, cse = _acc_node_has_lazy(spine) ? (spine, _ACC_NO_CSE) :
            _build_acc_cse(spine, acc)
        push!(
            kernels, _AccKernel(_outs_cells(slots), spine, acc, cse)
        )
    end
    return kernels
end
