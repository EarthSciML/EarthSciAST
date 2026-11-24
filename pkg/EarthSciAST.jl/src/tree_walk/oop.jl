# ========================================================================
# tree_walk/oop.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4d: the OUT-OF-PLACE build product — the compiled
# intermediate representation a COMPILED backend lowers, built from the same
# `_Node` spines and `_AccKernel`s that `_make_rhs` (rhs_assembly.jl) lowers
# into `f!(du, u, p, t)`.
# ========================================================================

# ============================================================
# 4d. The out-of-place build: `_build_evaluator(model; form = :oop)`
# ============================================================
#
# WHAT THIS FILE PRODUCES, and what it does not.
# ---------------------------------------------
# `form = :oop` does NOT return a second host evaluator. It returns the
# COMPILED IR itself (`_CompiledIR`, below) wrapped in an `_OopRHS` that also
# carries the build's live forcing buffers. Host evaluation is `f!`
# (`form = :inplace`, the default): zero-alloc at Float64, eltype-generic, and
# so differentiable under ForwardDiff over the state or over the parameters.
# Differentiate with `f!`. Solve with `f!`.
#
# THIS PRODUCT EXISTS TO BE COMPILED — to StableHLO by
# ext/EarthSciASTReactantExt.jl's `direct_rhs` today, by any device backend
# tomorrow. What `f!` cannot give a backend is not the out-of-place SIGNATURE,
# which is incidental, but the IR in a form it can walk:
#
#   1. NO CAPTURED HOST BUFFERS. `f!` writes into preallocated `Vector{Float64}`
#      scratch created at build time — the CSE prelude's `_cse_buf` and each
#      `_AccKernel`'s `_AccCSE` tiers. An emitted program assigns its own
#      buffers, and XLA has nothing to do with a host one.
#   2. NO PER-LANE SCALAR LOOPS. `f!` still walks lanes one at a time in several
#      arms — the gather, the pgather, the `du` scatter. XLA
#      rejects scalar indexing of a traced array outright, so the plan data
#      here (`_OopAccPlan`) describes every access as a whole-array op instead.
#
# WHAT IS IN HERE
#
#   * the lane-batched grouping of the per-cell scalar surface:
#     congruent entries bucketed at BUILD time so a backend emits one whole-lane
#     program per group rather than one per cell;
#   * the vectorization PLAN per access kernel (`_OopAccPlan`): the gather slot
#     vectors, frozen lane constants and ghost masks, plus
#     the analysis that decides whether a kernel admits
#     the vectorized form at all and, when it does not, says why;
#   * the build product itself (`_OopRHS`, `_CompiledIR`, `_make_rhs_oop`).
#
# `_build_evaluator(model; form = :oop)` returns the `_OopRHS` in the `f!` slot of
# the usual `(f, u0, p, tspan, var_map)` tuple.

# ---- Lane-batched scalar entries ----------------------------------------------
#
# WHY. The per-CELL scalar surface of a build — `rhs_list` entries a state
# equation lowers to when it declines the kernel path (a runtime contraction
# loop routes there BY DESIGN, see the array-cell depth note in resolve_loops.jl), and
# the per-column `scalars` of a materialized-observed fill level — is one entry
# per cell. Emitted one at a time, that is the one place a compiled program's
# SIZE scales with the grid: every entry emits its whole tree, so a contraction
# loop over L levels inside a per-column fill costs O(columns × L) single-element
# reads, which is what makes XLA compile time blow up on a real grid.
#
# WHAT. Those entries are per-cell INSTANTIATIONS of one expression: same tree,
# same ops, same loop ranges — only the baked-in cell data differ (state slots,
# forcing offsets, gather subscripts, inlined per-cell constants). So at BUILD
# the entries are GROUPED by a canonical structural signature (`_oop_batch_sig`)
# that wildcards exactly those lane-varying leaves, and each group is lowered
# ONCE to a lane-batched tree (`_OopBatchNode`, `_oop_batch_lower`) a backend
# emits as whole-array ops over its lane axis: a state leaf is ONE gather over
# the per-lane slots, a contraction loop runs its L iterations once with a
# whole-lane accumulate per iteration, and the group's result lands through one
# scatter. Program size: O(tree × L), independent of the lane (grid) count.
#
# VALUE IDENTITY. Per lane, every arm performs the same operations in the same
# order the scalar walker performs them (broadcast is elementwise; the loop fold
# accumulates per lane in the same ascending-k order seeded from the same 0̄; a
# ghost state-gather selects the same 0; a pow keeps its literal exponent — the
# signature PINS the exponent, so a group never blends the power rule). The one
# semantic divergence is inherited from every vectorized tier of this codebase:
# `ifelse`/`and`/`or` evaluate EAGERLY over lanes rather than short-circuiting,
# so a guard that exists to dodge a DomainError does not dodge it here — exactly
# the `_eval_acc` contract. A compiled program could not branch on a traced Bool
# anyway.
#
# SAFETY. Grouping is conservative: a signature mismatch, a singleton group, an
# unknown node kind, or any congruence check failing in `_oop_batch_lower`
# leaves the affected entries as singles, unchanged. Off, every entry is a
# single. Entries within one batch surface write
# DISJOINT slots and never read each other (rhs_list writes `du` reading only the
# extended state and the cache; a fill level's scalars read only strictly-lower
# levels — the level scheduler's invariant), so emitting groups after the
# leftover singles reorders only WRITES to disjoint slots, never a
# read-after-write.
_oop_batch_enabled() = !_oop_merge_disabled()

# One position of a lane-batched tree. `kind` mirrors the `_NK_*` of every
# lane's node at this position; which fields are live depends on it:
#   _NK_LITERAL       shared `literal`, or per-lane `lanes_f`
#   _NK_STATE         shared `idx`, or per-lane `slots` (one whole-array gather)
#   _NK_PARAM/_NK_TIME/_NK_CACHED  shared `sym`/`idx` (lane-invariant scalar)
#   _NK_PARAM_GATHER  `payload` the ONE shared buffer; shared `idx` or `slots`
#   _NK_CONST_GATHER / _NK_STATE_GATHER  `nodes`: each lane's ORIGINAL node,
#                     resolved per lane at eval (subscripts are host integer
#                     arithmetic — `_index_int` — so this is host work; the
#                     state read is still one whole-array gather)
#   _NK_LOOPVAR       `refs`: each lane's counter Ref (values read per lane)
#   _NK_CONTRACTION_LOOP  shared `op`/`literal`/`lo:step:hi`; `refs` all lanes'
#                     counters; `children[1]` the batched body
#   _NK_CONTRACTION   shared `op`/`literal`; batched children
#   _NK_OP            shared `op` and `payload`; batched children
struct _OopBatchNode
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    payload::Any
    lanes_f::Vector{Float64}
    slots::Vector{Int}
    nodes::Vector{_Node}
    refs::Vector{Base.RefValue{Int}}
    lo::Int
    hi::Int
    step::Int
    children::Vector{_OopBatchNode}
end
function _mkbatch(;
        kind::UInt8, op::Symbol = Symbol(""), literal::Float64 = 0.0,
        idx::Int = 0, sym::Symbol = Symbol(""), payload = nothing,
        lanes_f::Vector{Float64} = Float64[], slots::Vector{Int} = Int[],
        nodes::Vector{_Node} = _Node[],
        refs::Vector{Base.RefValue{Int}} = Base.RefValue{Int}[],
        lo::Int = 0, hi::Int = 0, step::Int = 1,
        children::Vector{_OopBatchNode} = _OopBatchNode[]
    )
    return _OopBatchNode(
        kind, op, literal, idx, sym, payload, lanes_f, slots,
        nodes, refs, lo, hi, step, children
    )
end

# One batched group: the (disjoint) output slots, lane-aligned, and the lowered
# tree. `_OopScalarBatches` is one whole batch surface (rhs_list, or one fill
# level's scalars): the groups plus the leftover singles in their ORIGINAL
# relative order. `n_batched` is Σ group lanes — the build-observability number
# a backend's tests pin to prove the grouping engaged.
struct _OopScalarBatch
    slots::Vector{Int}
    root::_OopBatchNode
end
struct _OopScalarBatches
    groups::Vector{_OopScalarBatch}
    rest::Vector{Tuple{Int, _Node}}
    n_batched::Int
end
const _OOP_NO_BATCH = _OopScalarBatches(_OopScalarBatch[], Tuple{Int, _Node}[], 0)

# Canonical structural signature: two entries share one iff `_oop_batch_lower`
# can lane-batch them together. Writes into `io`; returns `false` for a node
# kind the batch walker does not model (the entry then stays single). What is
# PINNED (in the key) vs WILDCARDED (varies per lane):
#   pinned:    tree shape, every op, param syms, cache slot ids, loop ranges +
#              ⊕ + 0̄, the forcing BUFFER identity, pow's literal exponent
#              (so a Dual walk keeps the power rule)
#   wildcard:  state slot idx, forcing offset idx, value-position literals,
#              const/state-gather payloads AND their whole subscript subtrees
#              (each lane resolves its own — congruence across lanes is not
#              required there, only that the kind sits at the same position)
function _oop_batch_sig!(io::IO, n::_Node, fixed_lit::Bool)::Bool
    k = n.kind
    if k === _NK_LITERAL
        fixed_lit ? print(io, "L", n.literal) : print(io, "l")
    elseif k === _NK_STATE
        print(io, "s")
    elseif k === _NK_PARAM
        print(io, "p", n.sym)
    elseif k === _NK_TIME
        print(io, "t")
    elseif k === _NK_CACHED
        print(io, "c", n.idx)
    elseif k === _NK_PARAM_GATHER
        print(io, "pg", objectid(n.payload))
    elseif k === _NK_CONST_GATHER
        print(io, "cg")
    elseif k === _NK_STATE_GATHER
        print(io, "sg")
    elseif k === _NK_LOOPVAR
        print(io, "lv")
    elseif k === _NK_CONTRACTION_LOOP
        spec = n.payload::_ContractLoop
        print(
            io, "cl(", n.op, ",", n.literal, ",", spec.lo, ":", spec.step,
            ":", spec.hi, "){"
        )
        _oop_batch_sig!(io, n.children[1], false) || return false
        print(io, "}")
    elseif k === _NK_CONTRACTION
        print(io, "cn(", n.op, ",", n.literal, "){")
        for c in n.children
            _oop_batch_sig!(io, c, false) || return false
            print(io, ",")
        end
        print(io, "}")
    elseif k === _NK_OP
        op = n.op
        if op === :^ || op === :pow
            length(n.children) == 2 || return false
            print(io, "pw{")
            _oop_batch_sig!(io, n.children[1], false) || return false
            print(io, ",")
            # The exponent's IMMEDIATE literal is pinned; a non-literal exponent
            # recurses normally (its own literals stay wildcards).
            _oop_batch_sig!(io, n.children[2], true) || return false
            print(io, "}")
        else
            print(io, "o(", op, "){")
            for c in n.children
                _oop_batch_sig!(io, c, false) || return false
                print(io, ",")
            end
            print(io, "}")
        end
    else
        return false
    end
    return true
end
function _oop_batch_sig(n::_Node)::Union{Nothing, String}
    io = IOBuffer()
    return _oop_batch_sig!(io, n, false) ? String(take!(io)) : nothing
end

# Lower `L` congruent lane nodes to one batched node. Defensive: every
# congruence the signature promises is RE-CHECKED here (a `nothing` return
# declines the whole group back to the scalar path — a signature collision can
# lose batching, never correctness).
function _oop_batch_lower(nodes::Vector{_Node})::Union{Nothing, _OopBatchNode}
    n1 = @inbounds nodes[1]
    k = n1.kind
    @inbounds for l in 2:length(nodes)
        nodes[l].kind === k || return nothing
    end
    if k === _NK_LITERAL
        all(nd -> isequal(nd.literal, n1.literal), nodes) &&
            return _mkbatch(kind = k, literal = n1.literal)
        return _mkbatch(kind = k, lanes_f = Float64[nd.literal for nd in nodes])
    elseif k === _NK_STATE
        all(nd -> nd.idx == n1.idx, nodes) && return _mkbatch(kind = k, idx = n1.idx)
        return _mkbatch(kind = k, slots = Int[nd.idx for nd in nodes])
    elseif k === _NK_PARAM
        # `idx` rides along with `sym` (the read seam wants both). It is not part
        # of the congruence test because it is a FUNCTION of `sym` — one build's
        # parameter order — so equal syms already imply equal indices.
        all(nd -> nd.sym === n1.sym, nodes) || return nothing
        return _mkbatch(kind = k, sym = n1.sym, idx = n1.idx)
    elseif k === _NK_TIME
        return _mkbatch(kind = k)
    elseif k === _NK_CACHED
        all(nd -> nd.idx == n1.idx && nd.payload === n1.payload, nodes) || return nothing
        return _mkbatch(kind = k, idx = n1.idx, payload = n1.payload)
    elseif k === _NK_PARAM_GATHER
        arr = n1.payload::Vector{Float64}
        all(nd -> nd.payload === arr, nodes) || return nothing
        all(nd -> nd.idx == n1.idx, nodes) &&
            return _mkbatch(kind = k, idx = n1.idx, payload = arr)
        return _mkbatch(kind = k, payload = arr, slots = Int[nd.idx for nd in nodes])
    elseif k === _NK_CONST_GATHER || k === _NK_STATE_GATHER
        return _mkbatch(kind = k, nodes = nodes)
    elseif k === _NK_LOOPVAR
        return _mkbatch(
            kind = k,
            refs = Base.RefValue{Int}[nd.payload::Base.RefValue{Int} for nd in nodes]
        )
    elseif k === _NK_CONTRACTION_LOOP
        spec = n1.payload::_ContractLoop
        for nd in nodes
            sp = nd.payload::_ContractLoop
            (
                nd.op === n1.op && isequal(nd.literal, n1.literal) &&
                    sp.lo == spec.lo && sp.hi == spec.hi && sp.step == spec.step &&
                    length(nd.children) == 1
            ) || return nothing
        end
        body = _oop_batch_lower(_Node[nd.children[1] for nd in nodes])
        body === nothing && return nothing
        return _mkbatch(
            kind = k, op = n1.op, literal = n1.literal,
            refs = Base.RefValue{Int}[(nd.payload::_ContractLoop).ref for nd in nodes],
            lo = spec.lo, hi = spec.hi, step = spec.step,
            children = _OopBatchNode[body]
        )
    elseif k === _NK_CONTRACTION || k === _NK_OP
        nc = length(n1.children)
        for nd in nodes
            (
                nd.op === n1.op && length(nd.children) == nc &&
                    (k !== _NK_CONTRACTION || isequal(nd.literal, n1.literal))
            ) ||
                return nothing
        end
        children = Vector{_OopBatchNode}(undef, nc)
        for i in 1:nc
            ci = _oop_batch_lower(_Node[nd.children[i] for nd in nodes])
            ci === nothing && return nothing
            children[i] = ci
        end
        return _mkbatch(
            kind = k, op = n1.op, literal = n1.literal,
            payload = (k === _NK_OP ? n1.payload : nothing),
            children = children
        )
    end
    return nothing
end

# Group one batch surface. Groups (≥2 congruent lanes, lowered successfully)
# come out in first-appearance order with lanes in original entry order; every
# other entry stays in `rest`, original relative order preserved. With the
# feature disabled everything is `rest`, the per-entry surface.
function _oop_batch_scalars(entries::AbstractVector{Tuple{Int, _Node}})
    (!_oop_batch_enabled() || length(entries) < 2) &&
        return _OopScalarBatches(
        _OopScalarBatch[],
        collect(Tuple{Int, _Node}, entries), 0
    )
    order = Dict{String, Int}()          # key -> first-appearance group ordinal
    members = Vector{Vector{Int}}()     # ordinal -> entry indices
    for (i, (_, nd)) in enumerate(entries)
        s = _oop_batch_sig(nd)
        s === nothing && continue
        g = get!(order, s) do
            push!(members, Int[])
            length(members)
        end
        push!(members[g], i)
    end
    groups = _OopScalarBatch[]
    single = trues(length(entries))
    n_batched = 0
    for idxs in members
        length(idxs) >= 2 || continue
        root = _oop_batch_lower(_Node[entries[i][2] for i in idxs])
        root === nothing && continue
        push!(groups, _OopScalarBatch(Int[entries[i][1] for i in idxs], root))
        n_batched += length(idxs)
        for i in idxs
            single[i] = false
        end
    end
    rest = Tuple{Int, _Node}[entries[i] for i in eachindex(entries) if single[i]]
    return _OopScalarBatches(groups, rest, n_batched)
end

# ---- The vectorized (traceable) acc form ------------------------------------
#
# Per-kernel host-side lane index, built ONCE at build: the output slots
# in the EXACT `_run_acc_kernel!` cell order, the loop multi-index per lane, and
# — per access descriptor — either a precomputed state-gather slot vector, a
# frozen const lane vector, or (for a LIVE forcing box) the flat indices to
# re-gather per call. All `Int`/`Float64` host data: under tracing these are the
# constant index sets a gather/scatter op wants, never traced values.
struct _OopAccPlan
    vectorizable::Bool
    out_slots::Vector{Int}
    gathers::Vector{Vector{Int}}      # per descriptor: state gather slots (empty otherwise)
    consts::Vector{Vector{Float64}}   # per descriptor: frozen lane values (empty otherwise)
    forc::Vector{Vector{Int}}         # per descriptor: LIVE forcing flat indices (empty otherwise)
    ghost::Vector{Vector{Bool}}       # per descriptor: ghost-lane mask for a STATE_TBL_BOX with
    # a 0 slot (empty ⇒ no ghost); true lanes select 0.0 after
    # a gather at a SAFE index (see _build_oop_acc_plan)
end
const _OOP_ACC_FALLBACK =
    _OopAccPlan(
    false, Int[], Vector{Int}[], Vector{Float64}[], Vector{Int}[], Vector{Bool}[]
)

# Lane enumeration mirroring `_run_acc_kernel!` / `_run_box_kernel!` order:
# the out slot of every lane, and the lane's loop multi-index as one vector per
# dim (at least three, the padded dims all 1s — the runners' padded `midx`).
function _oop_acc_lanes(cs::_CellSet)
    if _is_outs(cs)
        # Indirect out slots: the cell ORDINAL rides m1 (the box-addressed
        # per-cell tables index by it, s1=1/off=1), `out` is the slot list.
        L = length(cs.outs)
        return copy(cs.outs), [collect(1:L), fill(1, L), fill(1, L)]
    end
    _is_cellless(cs) && return Int[], [Int[], Int[], Int[]]
    nd = length(cs.strides)
    return _oop_box_lanes(
        cs.base, ntuple(d -> cs.strides[d], nd),
        ntuple(d -> cs.ranges[d], nd)
    )
end

function _oop_box_lanes(b::Int, st::NTuple{N, Int}, rg::NTuple{N, UnitRange{Int}}) where {N}
    L = prod(length, rg)
    out = Vector{Int}(undef, L)
    mis = [fill(1, L) for _ in 1:max(N, 3)]
    q = 0
    @inbounds for I in CartesianIndices(rg)
        q += 1
        oln = b
        for d in 1:N
            oln += I[d] * st[d]
        end
        out[q] = oln
        for d in 1:N
            mis[d][q] = I[d]
        end
    end
    return out, mis
end

# Lane `l`'s box address `off + Σ_d (m_d[l] - 1)·s_d` — `_acc_boxaddr` over the
# lane multi-index vectors.
@inline function _oop_boxaddr(a::_AccDesc, mis::Vector{Vector{Int}}, l::Int)
    x = a.off + (mis[1][l] - 1) * a.s1 + (mis[2][l] - 1) * a.s2 + (mis[3][l] - 1) * a.s3
    @inbounds for d in eachindex(a.sx)
        x += (mis[d + 3][l] - 1) * a.sx[d]
    end
    return x
end

# Can the whole spine (plus CSE recipes) evaluate as lane vectors? A `_NK_CACHED`
# must resolve to THIS kernel's scratch tiers. A ghost-bearing STATE_TBL_BOX
# vectorizes as gather-then-select. Every descriptor kind is named: a
# kind this plan does not know is an error (`_oop_unknown_kind`), never a
# vectorizable kernel with no data.
function _oop_acc_vecable(n::_Node, K::_AccKernel)
    k = n.kind
    # An affine reduction's body is evaluated at lanes of (cell, contracted
    # index) that the lane enumeration does not carry.
    k === _NK_AREDUCE && return false
    if k === _NK_ACCESS
        _oop_known_kind(K.acc[n.idx].kind) || _oop_unknown_kind(K.acc[n.idx].kind)
    elseif k === _NK_CACHED
        (n.payload === K.cse.scratch || n.payload === K.cse.inv_scratch) || return false
    end
    return _allof(c -> _oop_acc_vecable(c, K), n.children)
end

# Resolve one descriptor table's per-lane host data against a GIVEN lane
# enumeration (`out`/`mis`). Returns the four aligned per-descriptor vectors.
function _build_oop_desc_vectors(
        acc::Vector{_AccDesc},
        out::Vector{Int}, mis::Vector{Vector{Int}}
    )
    L = length(out)
    nacc = length(acc)
    gathers = [Int[] for _ in 1:nacc]
    consts = [Float64[] for _ in 1:nacc]
    forc = [Int[] for _ in 1:nacc]
    ghost = [Bool[] for _ in 1:nacc]
    for (i, a) in enumerate(acc)
        k = a.kind
        if k === _AK_STATE_AFFINE
            gathers[i] = out .+ a.delta
        elseif k === _AK_STATE_TBL_BOX
            # Gather-of-gather resolved on host: the per-lane state slot is the
            # box-addressed table entry. A ghost slot (0) — which the in-place
            # runners read as 0.0 — is gathered at a SAFE index (1, always valid)
            # and masked: the eval selects 0.0 on those lanes, so the trace still
            # sees ONE whole-array gather plus a select against a constant mask.
            raw = Int[@inbounds a.conn[_oop_boxaddr(a, mis, l)] for l in 1:L]
            if any(==(0), raw)
                ghost[i] = Bool[s == 0 for s in raw]
                gathers[i] = Int[s == 0 ? 1 : s for s in raw]
            else
                gathers[i] = raw
            end
        elseif k === _AK_CONST_BOX
            consts[i] = Float64[@inbounds a.arr[_oop_boxaddr(a, mis, l)] for l in 1:L]
        elseif k === _AK_FORCING_BOX
            forc[i] = Int[_oop_boxaddr(a, mis, l) for l in 1:L]
        elseif k === _AK_ARR_TBL_BOX
            # LIVE forcing through a per-cell index table: freeze the INDICES
            # (host data), re-gather the aliased buffer per call.
            forc[i] = Int[@inbounds a.conn[_oop_boxaddr(a, mis, l)] for l in 1:L]
        elseif k === _AK_LOOP_IDX
            consts[i] = Float64.(mis[a.dim])
        elseif k === _AK_STATE_FIXED || k === _AK_ARR_FIXED
            # Read directly by the walker.
        else
            _oop_unknown_kind(k)
        end
    end
    return gathers, consts, forc, ghost
end

_oop_known_kind(k::UInt8) = UInt8(1) <= k <= _AK_ARR_TBL_BOX

_oop_unknown_kind(k::UInt8) = throw(
    TreeWalkError(
        "E_TREEWALK_INTERNAL",
        "the out-of-place plan has no rule for access descriptor kind $(Int(k)); " *
            "add one to `_oop_acc_vecable` and `_build_oop_desc_vectors`"
    )
)

function _build_oop_acc_plan(K::_AccKernel)
    return _build_oop_acc_plan_inner(K)
end
# Whether `K` has a vectorized lane plan (else `_build_oop_acc_plan` returns
# `_OOP_ACC_FALLBACK`): a structural test, with no lane built.
_oop_plan_vecable(K::_AccKernel) =
    _oop_acc_vecable(K.spine, K) &&
    all(r -> _oop_acc_vecable(r, K), K.cse.recipes) &&
    all(r -> _oop_acc_vecable(r, K), K.cse.inv_recipes)

function _build_oop_acc_plan_inner(K::_AccKernel)
    _oop_plan_vecable(K) || return _OOP_ACC_FALLBACK
    out, mis = _oop_acc_lanes(K.cells)
    gathers, consts, forc, ghost = _build_oop_desc_vectors(K.acc, out, mis)
    return _OopAccPlan(true, out, gathers, consts, forc, ghost)
end

# ---- The build's out-of-place product ---------------------------------------
#
# `_build_evaluator(model; form = :oop)` returns one of these in the `f!` slot: a
# handle on the compiled intermediate representation (`rhs`) together with the
# live forcing buffers this build bound. A compiled backend lowers `rhs` into a
# program of its own; `direct_rhs` (ext/reactant_direct/) is the one in tree.
#
# ARITY IS THE FORM. The single call method takes three arguments, which is what
# SciMLBase reads as out-of-place, and a consumer that probes for in-place-ness
# by method applicability gets the right answer. There is deliberately NO 4-arg
# method: SciMLBase infers in-place-ness from one, so adding it would make
# `ODEProblem(f, …)` misread this product as an `f!`.
"""
    _forcing_buffer_container(pgather) -> (NamedTuple, Dict{String,Int})

Every live forcing buffer a build registered — raw `param_arrays` entries AND
[`DiscreteMaterializer`](@ref) caches, both of which live in `pgather` by the
time this runs — as a NamedTuple of the ALIASED flat host views in a stable
(name-sorted) order, plus the name → position map.

Factored out of `_make_rhs_oop` because BOTH build forms now publish it: the
out-of-place product carries it as a field (a compiled backend passes an aligned
container of device arrays to the explicit-buffers form), and every build
publishes it on the `inspect` sink, which is how it reaches
[`forcing_buffers`](@ref)`(prob)` on an `EsmProblem` whatever compiler built it.
"""
function _forcing_buffer_container(pgather)
    buf_names = sort!(String[String(k) for k in keys(pgather)])
    host_bufs = NamedTuple{Tuple(Symbol(n) for n in buf_names)}(
        Tuple((pgather[n]::_PGatherArray).flat for n in buf_names)
    )
    buffer_index = Dict{String, Int}(n => i for (i, n) in enumerate(buf_names))
    return host_bufs, buffer_index
end

struct _OopRHS{F, B} <: Function
    rhs::F                          # the compiled IR (`_CompiledIR`)
    buffers::B                      # NamedTuple: name => aliased HOST buffer, stable order
    buffer_index::Dict{String, Int}  # buffer name -> position in `buffers`
end

# Printed short. A callable struct prints field by field, and this one's fields
# are the whole compiled IR, whose shared subexpressions `show` writes out at
# every reference. A compiled backend asks for that text without anyone reading
# it: Reactant names each program it compiles with `string(f)`.
Base.show(io::IO, f::_OopRHS) =
    print(io, "EarthSciAST._OopRHS(", f.rhs.n_states, " states)")

# Host evaluation of this form is a compiled backend's job. The in-place `f!`
# (`form = :inplace`, the default) is the host evaluator, and it is also the
# reference the compiled backends are gated against; `compiler=:interpreter`
# gives its untiered variant, which recomputes every prelude slot on every call.
(f::_OopRHS)(u, p, t) = throw(
    TreeWalkError(
        "E_TREEWALK_OOP_NOT_EVALUABLE",
        "an out-of-place build product is the compiled intermediate " *
            "representation a backend lowers, not a host evaluator. For a compiled " *
            "right-hand side build `esm_problem(input, tspan; compiler = :xla)`; for " *
            "the host evaluator build `esm_problem(input, tspan)` and call " *
            "`prob.f!(du, u, prob.p, t)`."
    )
)

"""
    forcing_buffers(f) -> NamedTuple

The live forcing buffers of an out-of-place build product (the compiled
intermediate representation a backend lowers), as a NamedTuple in a STABLE order (buffer
names sorted): every `param_arrays` entry and every [`DiscreteMaterializer`](@ref)
cache, each value the aliased flat host view of the exact array the build bound
— NOT a copy, so a discrete-cadence refresh writing the original array is
visible through this container. Position of a name is
[`forcing_buffer_index`](@ref)`(f)[name]`. Empty for a model with no live
forcing.
"""
forcing_buffers(f::_OopRHS) = f.buffers

"""
    forcing_buffer_index(f) -> Dict{String,Int}

Name → position map for [`forcing_buffers`](@ref)`(f)`: `forcing_buffer_index(f)[name]`
is the index of buffer `name` in the buffers container (and in any aligned
container passed to the explicit-buffers form of a compiled RHS). Treat as
read-only.
"""
forcing_buffer_index(f::_OopRHS) = f.buffer_index

# ---- The compiled intermediate representation --------------------------------
#
# What a backend lowers, carried under STABLE field names: the same `_Node`
# spines, access kernels, fill levels and fold descriptors `_make_rhs`
# (acc_merge.jl) lowers into `f!`, but reachable as data rather than closed over
# by an evaluator. `_make_rhs_oop` below assembles one per build.
struct _CompiledIR{R, C, K, S, M, A, B, MB}
    rhs_list::R                        # (slot, node) scalar state equations
    cse_prelude::C                     # shared-subexpression prelude, in slot order
    acc_kernels::K                     # the unified array IR
    acc_plans::Vector{_OopAccPlan}     # one vectorization plan per kernel
    scan_folds::S                      # cumulative (prefix) reductions
    mat_levels::M                      # materialized-observed fill levels
    array_contractions::A              # whole-array contractions
    rhs_batches::B                     # lane-batched form of `rhs_list`
    mat_batches::MB                    # lane-batched form of each level's scalars
    n_states::Int                      # flat ODE state length
    n_total::Int                       # extended state length (states + materialized observeds)
end

function _make_rhs_oop(
        rhs_list::AbstractVector{Tuple{Int, _Node}},
        cse_prelude::AbstractVector{_Node},
        acc_kernels::AbstractVector{_AccKernel},
        n_states::Int,
        pgather::AbstractDict = _EMPTY_PGATHER,
        scan_folds::AbstractVector{_ScanFold} = _ScanFold[],
        mat_levels::Tuple = (),
        n_total::Int = n_states,
        array_contractions::AbstractVector = _ArrayContraction[]
    )
    # Vectorized lane plans for the acc kernels (host index data, built once).
    # The kernel-CLASS merge (oop_merge.jl) does not run here: it is hoisted
    # into `_build_evaluator_impl` phase 4 (`_merge_acc_kernel_classes`), before
    # the xcse gate, so BOTH emitters receive already-merged kernels and this
    # plan build is over the merged (fewer) list. `acc_kernels` and `acc_plans`
    # reach the build product under the stable field names :acc_kernels /
    # :acc_plans that external tooling reflects on.
    acc_plans = _OopAccPlan[_build_oop_acc_plan(K) for K in acc_kernels]
    # Lane-batched scalar surfaces, grouped ONCE at build:
    # the rhs_list per-cell entries and each fill level's per-column scalars.
    # `rhs_list`/`mat_levels` keep their own stable field names (external
    # tooling reflects on them); `rhs_batches`/`mat_batches` are ADDITIVE
    # fields — a group count of zero means everything runs the scalar path.
    rhs_batches = _oop_batch_scalars(rhs_list)
    mat_batches = map(
        lvl -> _oop_batch_scalars(lvl.scalars),
        mat_levels
    )
    # The buffers container: every live forcing buffer this build registered —
    # raw `param_arrays` entries AND DiscreteMaterializer caches, both of which
    # live in `pgather` by the time this runs — in a STABLE order (names
    # sorted), as a NamedTuple of the aliased flat host views. A backend passes
    # an aligned container of device arrays to the explicit-buffers form, so a
    # discrete-cadence refresh reaches the compiled program (`sync_forcing!`).
    host_bufs, buffer_index = _forcing_buffer_container(pgather)
    return _OopRHS(
        _CompiledIR(
            rhs_list, cse_prelude, acc_kernels, acc_plans,
            scan_folds, mat_levels,
            map!(_ac_drop_remit, similar(array_contractions), array_contractions),
            rhs_batches, mat_batches, n_states, n_total
        ),
        host_bufs, buffer_index
    )
end
