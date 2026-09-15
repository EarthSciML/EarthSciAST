# ========================================================================
# tree_walk/oop.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4d: the OUT-OF-PLACE build product — the compiled
# intermediate representation a COMPILED backend lowers, built from the same
# `_Node` spines and `_AccKernel`s that `_make_rhs` (acc_merge.jl) lowers
# into `f!(du, u, p, t)`.
# ========================================================================

# ============================================================
# 4d. The out-of-place build: `build_evaluator(model; form = :oop)`
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
#      arms — the gather, the pgather, the `du` scatter, the interp kernels. XLA
#      rejects scalar indexing of a traced array outright, so the plan data
#      here (`_OopAccPlan`) describes every access as a whole-array op instead.
#
# WHAT IS IN HERE
#
#   * the lane-batched grouping of the per-cell scalar surface (ess-oop-batch):
#     congruent entries bucketed at BUILD time so a backend emits one whole-lane
#     program per group rather than one per cell;
#   * the vectorization PLAN per access kernel (`_OopAccPlan`): the gather slot
#     vectors, frozen lane constants, ghost masks, sub-kernel tables and CSR
#     reduce segments, plus the analysis that decides whether a kernel admits
#     the vectorized form at all and, when it does not, says why;
#   * the build product itself (`_OopRHS`, `_CompiledIR`, `_make_rhs_oop`).
#
# `build_evaluator(model; form = :oop)` returns the `_OopRHS` in the `f!` slot of
# the usual `(f, u0, p, tspan, var_map)` tuple.

# ---- Lane-batched scalar entries (ess-oop-batch) -----------------------------
#
# WHY. The per-CELL scalar surface of this emitter — `rhs_list` entries a state
# equation lowers to when it declines the kernel path (a runtime contraction
# loop routes there BY DESIGN, see resolve.jl's `_ARRAY_CELL_DEPTH` note), and
# the per-column `scalars` of a materialized-observed fill level — is walked one
# entry at a time through `_oop_eval`. Correct, and on host cheap; under a TRACE
# it is the one remaining place the emitted program's size scales with the grid:
# every entry re-traces its whole tree, so a contraction loop over L levels
# inside a per-column fill emits O(columns × L) scalar-indexed reads — tens of
# `stablehlo.dynamic_slice` ops per grid cell, which is what makes XLA compile
# time blow up on a real grid.
#
# WHAT. Those entries are per-cell INSTANTIATIONS of one expression: same tree,
# same ops, same loop ranges — only the baked-in cell data differ (state slots,
# forcing offsets, gather subscripts, inlined per-cell constants). So at closure
# build the entries are GROUPED by a canonical structural signature
# (`_oop_batch_sig`) that wildcards exactly those lane-varying leaves, each
# group is lowered ONCE to a lane-batched tree (`_OopBatchNode`,
# `_oop_batch_lower`), and the whole group evaluates through `_oop_eval_batch`
# as whole-array ops over its lane axis: a state leaf is ONE `_oop_gather` over
# the per-lane slots, a contraction loop runs its L iterations ONCE with a
# whole-lane accumulate per iteration, and the group's result lands through ONE
# `_oop_scatter`. Emitted-program size: O(tree × L), independent of the lane
# (grid) count.
#
# BIT-IDENTITY. Per lane, every arm performs the same operations in the same
# order the scalar walker performs them (broadcast is elementwise; the loop
# fold accumulates per lane in the same ascending-k order seeded from the same
# 0̄; a ghost state-gather selects the same 0; a pow keeps its literal exponent
# — the signature PINS the exponent, so a group never blends the power rule).
# The one semantic divergence is inherited from every vectorized tier of this
# codebase: `ifelse`/`and`/`or` evaluate EAGERLY over lanes (the `_scalar_op`
# folded arms, value-identical to the lazy scalar arms) rather than
# short-circuiting, so a guard that exists to dodge a DomainError does not
# dodge it here — exactly the `_eval_acc` / `_oop_run_acc_vec` contract. Under
# a trace the lazy arms could not run anyway (branching on a traced Bool
# throws), so for the traced consumer this path is strictly more capable.
#
# SAFETY. Grouping is conservative: a signature mismatch, a singleton group, an
# unknown node kind, or any congruence check failing in `_oop_batch_lower`
# leaves the affected entries on the existing one-at-a-time scalar path,
# unchanged. `ESS_OOP_BATCH=0` disables the whole feature (every entry single).
# Entries within one batch surface write DISJOINT slots and never read each
# other (rhs_list writes `du` reading only `ue`/cache; a fill level's scalars
# read only strictly-lower levels — the level scheduler's invariant), so
# evaluating groups after the leftover singles reorders only WRITES to disjoint
# slots, never a read-after-write.
_oop_batch_enabled() = get(ENV, "ESS_OOP_BATCH", "1") != "0"

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
#   _NK_OP            shared `op` (+ `payload` for `:fn`); batched children
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
function _mkbatch(; kind::UInt8, op::Symbol=Symbol(""), literal::Float64=0.0,
                  idx::Int=0, sym::Symbol=Symbol(""), payload=nothing,
                  lanes_f::Vector{Float64}=Float64[], slots::Vector{Int}=Int[],
                  nodes::Vector{_Node}=_Node[],
                  refs::Vector{Base.RefValue{Int}}=Base.RefValue{Int}[],
                  lo::Int=0, hi::Int=0, step::Int=1,
                  children::Vector{_OopBatchNode}=_OopBatchNode[])
    return _OopBatchNode(kind, op, literal, idx, sym, payload, lanes_f, slots,
                         nodes, refs, lo, hi, step, children)
end

# One batched group: the (disjoint) output slots, lane-aligned, and the lowered
# tree. `_OopScalarBatches` is one whole batch surface (rhs_list, or one fill
# level's scalars): the groups plus the leftover singles in their ORIGINAL
# relative order. `n_batched` is Σ group lanes — the build-observability number
# (and the closure-reflection witness the tests pin).
struct _OopScalarBatch
    slots::Vector{Int}
    root::_OopBatchNode
end
struct _OopScalarBatches
    groups::Vector{_OopScalarBatch}
    rest::Vector{Tuple{Int,_Node}}
    n_batched::Int
end
const _OOP_NO_BATCH = _OopScalarBatches(_OopScalarBatch[], Tuple{Int,_Node}[], 0)

# Canonical structural signature: two entries share one iff `_oop_batch_lower`
# can lane-batch them together. Writes into `io`; returns `false` for a node
# kind the batch walker does not model (the entry then stays single). What is
# PINNED (in the key) vs WILDCARDED (varies per lane):
#   pinned:    tree shape, every op, param syms, cache slot ids, loop ranges +
#              ⊕ + 0̄, fn identity (typed-core id / boxed name / interp spec
#              object), the forcing BUFFER identity, pow's literal exponent
#              (so a Dual walk keeps the power rule — see `_oop_pow`)
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
        print(io, "cl(", n.op, ",", n.literal, ",", spec.lo, ":", spec.step,
              ":", spec.hi, "){")
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
        if op === :fn
            pl = n.payload
            if pl isa Tuple{String,_FnTypedCoreSpec}
                print(io, "fn(", pl[1], ",", pl[2].id, ")")
            elseif pl isa Tuple{String,Nothing}
                print(io, "fn0(", pl[1], ")")
            elseif pl isa Tuple{String,_InterpLinearSpec} ||
                   pl isa Tuple{String,_InterpBilinearSpec} ||
                   pl isa Tuple{String,_InterpSearchsortedSpec}
                # Spec OBJECT identity: the build memo shares one compiled node
                # (hence one spec) across cells; content-equal distinct objects
                # merely fragment the group, never miscompile it.
                print(io, "fni", objectid(pl[2]))
            else
                return false
            end
            print(io, "{")
            for c in n.children
                _oop_batch_sig!(io, c, false) || return false
                print(io, ",")
            end
            print(io, "}")
        elseif op === :^ || op === :pow
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
function _oop_batch_sig(n::_Node)::Union{Nothing,String}
    io = IOBuffer()
    return _oop_batch_sig!(io, n, false) ? String(take!(io)) : nothing
end

# Lower `L` congruent lane nodes to one batched node. Defensive: every
# congruence the signature promises is RE-CHECKED here (a `nothing` return
# declines the whole group back to the scalar path — a signature collision can
# lose batching, never correctness).
function _oop_batch_lower(nodes::Vector{_Node})::Union{Nothing,_OopBatchNode}
    n1 = @inbounds nodes[1]
    k = n1.kind
    @inbounds for l in 2:length(nodes)
        nodes[l].kind === k || return nothing
    end
    if k === _NK_LITERAL
        all(nd -> isequal(nd.literal, n1.literal), nodes) &&
            return _mkbatch(kind=k, literal=n1.literal)
        return _mkbatch(kind=k, lanes_f=Float64[nd.literal for nd in nodes])
    elseif k === _NK_STATE
        all(nd -> nd.idx == n1.idx, nodes) && return _mkbatch(kind=k, idx=n1.idx)
        return _mkbatch(kind=k, slots=Int[nd.idx for nd in nodes])
    elseif k === _NK_PARAM
        # `idx` rides along with `sym` (the read seam wants both). It is not part
        # of the congruence test because it is a FUNCTION of `sym` — one build's
        # parameter order — so equal syms already imply equal indices.
        all(nd -> nd.sym === n1.sym, nodes) || return nothing
        return _mkbatch(kind=k, sym=n1.sym, idx=n1.idx)
    elseif k === _NK_TIME
        return _mkbatch(kind=k)
    elseif k === _NK_CACHED
        all(nd -> nd.idx == n1.idx && nd.payload === n1.payload, nodes) || return nothing
        return _mkbatch(kind=k, idx=n1.idx, payload=n1.payload)
    elseif k === _NK_PARAM_GATHER
        arr = n1.payload::Vector{Float64}
        all(nd -> nd.payload === arr, nodes) || return nothing
        all(nd -> nd.idx == n1.idx, nodes) &&
            return _mkbatch(kind=k, idx=n1.idx, payload=arr)
        return _mkbatch(kind=k, payload=arr, slots=Int[nd.idx for nd in nodes])
    elseif k === _NK_CONST_GATHER || k === _NK_STATE_GATHER
        return _mkbatch(kind=k, nodes=nodes)
    elseif k === _NK_LOOPVAR
        return _mkbatch(kind=k,
            refs=Base.RefValue{Int}[nd.payload::Base.RefValue{Int} for nd in nodes])
    elseif k === _NK_CONTRACTION_LOOP
        spec = n1.payload::_ContractLoop
        for nd in nodes
            sp = nd.payload::_ContractLoop
            (nd.op === n1.op && isequal(nd.literal, n1.literal) &&
             sp.lo == spec.lo && sp.hi == spec.hi && sp.step == spec.step &&
             length(nd.children) == 1) || return nothing
        end
        body = _oop_batch_lower(_Node[nd.children[1] for nd in nodes])
        body === nothing && return nothing
        return _mkbatch(kind=k, op=n1.op, literal=n1.literal,
            refs=Base.RefValue{Int}[(nd.payload::_ContractLoop).ref for nd in nodes],
            lo=spec.lo, hi=spec.hi, step=spec.step,
            children=_OopBatchNode[body])
    elseif k === _NK_CONTRACTION || k === _NK_OP
        nc = length(n1.children)
        for nd in nodes
            (nd.op === n1.op && length(nd.children) == nc &&
             (k !== _NK_CONTRACTION || isequal(nd.literal, n1.literal))) ||
                return nothing
        end
        if k === _NK_OP && n1.op === :fn
            pl = n1.payload
            ok = if pl isa Tuple{String,_FnTypedCoreSpec}
                all(nd -> (q = nd.payload;
                           q isa Tuple{String,_FnTypedCoreSpec} &&
                           q[1] == pl[1] && q[2].id === pl[2].id), nodes)
            elseif pl isa Tuple{String,Nothing}
                all(nd -> (q = nd.payload;
                           q isa Tuple{String,Nothing} && q[1] == pl[1]), nodes)
            elseif pl isa Tuple{String,_InterpLinearSpec} ||
                   pl isa Tuple{String,_InterpBilinearSpec} ||
                   pl isa Tuple{String,_InterpSearchsortedSpec}
                all(nd -> nd.payload isa Tuple && length(nd.payload) == 2 &&
                          nd.payload[2] === pl[2], nodes)
            else
                false
            end
            ok || return nothing
        end
        children = Vector{_OopBatchNode}(undef, nc)
        for i in 1:nc
            ci = _oop_batch_lower(_Node[nd.children[i] for nd in nodes])
            ci === nothing && return nothing
            children[i] = ci
        end
        return _mkbatch(kind=k, op=n1.op, literal=n1.literal,
                        payload=(k === _NK_OP ? n1.payload : nothing),
                        children=children)
    end
    return nothing
end

# Group one batch surface. Groups (≥2 congruent lanes, lowered successfully)
# come out in first-appearance order with lanes in original entry order; every
# other entry stays in `rest`, original relative order preserved. With the
# feature disabled (`ESS_OOP_BATCH=0`) everything is `rest` — byte-identical to
# the pre-feature closure. `ESS_OOP_PROBE=1` tallies the outcome per entry
# (`:oop_batch_lane` / `:oop_batch_single`) and per group (`:oop_batch_group`).
function _oop_batch_scalars(entries::AbstractVector{Tuple{Int,_Node}})
    (!_oop_batch_enabled() || length(entries) < 2) &&
        return _OopScalarBatches(_OopScalarBatch[],
                                 collect(Tuple{Int,_Node}, entries), 0)
    order = Dict{String,Int}()          # key -> first-appearance group ordinal
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
    probe = get(ENV, "ESS_OOP_PROBE", "") == "1"
    for idxs in members
        length(idxs) >= 2 || continue
        root = _oop_batch_lower(_Node[entries[i][2] for i in idxs])
        root === nothing && continue
        push!(groups, _OopScalarBatch(Int[entries[i][1] for i in idxs], root))
        n_batched += length(idxs)
        for i in idxs
            single[i] = false
        end
        probe && _tally_cascade!(:oop_batch_group)
    end
    rest = Tuple{Int,_Node}[entries[i] for i in eachindex(entries) if single[i]]
    if probe
        for _ in 1:n_batched; _tally_cascade!(:oop_batch_lane); end
        for _ in 1:length(rest); _tally_cascade!(:oop_batch_single); end
    end
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
    # Template-body sub-kernels (compile-once tier, `_NK_SUBCALL`): the parent's
    # FLAT transitive `K.subs` list and, aligned with it, each sub-kernel's own
    # lane plan built against the PARENT's lane enumeration (a sub is evaluated at
    # the parent's `(c,n,oln,midx)`, so its descriptors index by the parent lanes).
    # Empty for every reference-free kernel. Nested subs are all present here
    # (K.subs is transitive), so a `_NK_SUBCALL` in a sub's spine resolves against
    # this same list. A sub whose spine does not vectorize forces `vectorizable`
    # false on the whole parent.
    subs::Vector{_AccKernel}
    sub_plans::Vector{_OopAccPlan}
    # Variable-valence reduction (`_NK_REDUCE` + `_VarBound`/`_FixedBound`,
    # `_AK_STATE_INDIRECT[_COL]` / `_AK_CONST_EDGE`), CSR-segmented (gordian
    # reduce-vectorize): `red_seg` is the row-pointer vector (length N+1, so cell
    # `c`'s neighbour entries are `red_seg[c]:red_seg[c+1]-1` in the flat E-lane
    # buffers), and `red_plan[1]` is the body's descriptor plan resolved at E-lane
    # (per-entry `(c,n)`) granularity. Empty ⇒ this kernel carries no reduce. The
    # E-lane gather is the ONLY state access; the segment fold runs on the gathered
    # host buffer in child (CSR) order — bit-identical to `_eval_acc`'s seeded fold.
    red_seg::Vector{Int}
    red_plan::Vector{_OopAccPlan}
end
const _OOP_ACC_FALLBACK =
    _OopAccPlan(false, Int[], Vector{Int}[], Vector{Float64}[], Vector{Int}[], Vector{Bool}[],
                _AccKernel[], _OopAccPlan[], Int[], _OopAccPlan[])

# Identity lookup of a sub-kernel in the parent plan's flat transitive list.
@inline function _oop_sub_index(subs::Vector{_AccKernel}, S::_AccKernel)
    @inbounds for j in eachindex(subs)
        subs[j] === S && return j
    end
    throw(TreeWalkError("E_TREEWALK_ACC_SUBCALL_UNKNOWN",
        "vectorized oop: a _NK_SUBCALL references a sub-kernel absent from the " *
        "parent's transitive K.subs list — a `_collect_subkernels` invariant break."))
end

# Lane enumeration mirroring `_run_acc_kernel!` / `_run_box_kernel!` order.
function _oop_acc_lanes(cs::_CellSet)
    if _is_outs(cs)
        # Indirect out slots: the cell ORDINAL rides m1 (the box-addressed
        # per-cell tables index by it, s1=1/off=1), `out` is the slot list.
        L = length(cs.outs)
        return copy(cs.outs), collect(1:L), fill(1, L), fill(1, L)
    end
    if _is_contig(cs)
        rng = cs.ranges[1]
        out = collect(Int, rng)
        return out, copy(out), fill(1, length(out)), fill(1, length(out))
    end
    st = cs.strides; rg = cs.ranges; b = cs.base; nd = length(st)
    L = prod(length, rg)
    out = Vector{Int}(undef, L); m1 = Vector{Int}(undef, L)
    m2 = fill(1, L); m3 = fill(1, L)
    q = 0
    @inbounds for idxs in Iterators.product(rg...)
        q += 1
        oln = b
        for d in 1:nd; oln += idxs[d]*st[d]; end
        out[q] = oln
        m1[q] = idxs[1]
        nd >= 2 && (m2[q] = idxs[2])
        nd >= 3 && (m3[q] = idxs[3])
    end
    return out, m1, m2, m3
end

# The descriptor kinds the E-lane (in-reduce) plan builder can resolve per entry
# `(c,n)`. The n-indexed kinds (`_AK_STATE_INDIRECT[_COL]`, `_AK_CONST_EDGE`) are
# ONLY meaningful inside a reduce; the affine/cell/invariant kinds broadcast a
# cell value across the cell's segment. Box/forcing/tbl kinds are left to the
# per-cell fallback (they need a per-entry `midx` the CSR layout does not carry).
@inline _oop_reduce_desc_ok(ak::UInt8) =
    ak === _AK_STATE_AFFINE || ak === _AK_STATE_INDIRECT ||
    ak === _AK_STATE_INDIRECT_COL || ak === _AK_CONST_EDGE ||
    ak === _AK_CONST_CELL || ak === _AK_CONST_AFFINE ||
    ak === _AK_SCALAR || ak === _AK_STATE_FIXED || ak === _AK_ARR_FIXED ||
    ak === _AK_LOOP_IDX

# Can the whole spine (plus CSE recipes) evaluate as lane vectors? A `_NK_CACHED`
# must resolve to THIS kernel's scratch tiers. (Ghost-bearing STATE_TBL_BOX no
# longer declines — gordian total-vectorize closed it via gather-then-select; the
# sub-kernel class no longer declines — gordian subcall-vectorize evaluates each
# template body as its own whole-array op over the parent lanes; a variable-valence
# reduction no longer declines — gordian reduce-vectorize evaluates the body over a
# flat CSR gather and folds each segment in child order, see `_oop_run_acc_vec`.)
# `in_reduce` permits the n-indexed descriptors that only make sense inside a fold.
_oop_acc_vecable(n::_Node, K::_AccKernel) = _oop_acc_vecable(n, K, false)
function _oop_acc_vecable(n::_Node, K::_AccKernel, in_reduce::Bool)
    k = n.kind
    if k === _NK_REDUCE
        # A reduce vectorizes as a CSR segment fold iff its OUTPUT set is
        # contiguous (so cell ordinal == out slot == lane, the only layout a
        # variable-valence unstructured reduction ever has) and its body's
        # descriptors are all E-lane resolvable. Nested reduces are not modelled.
        in_reduce && return false
        _is_contig(K.cells) || return false
        return _oop_acc_vecable(n.children[1], K, true)
    end
    if k === _NK_SUBCALL
        # A template-body sub-kernel vectorizes iff its OWN spine + CSE recipes do
        # (checked against the SUB's descriptor table — a sub's `_NK_CACHED`
        # resolves to the sub's scratch, not the parent's). Nested subcalls recurse
        # the same way. `K.subs` being transitive means every reachable sub is also
        # planned at the parent, so this check and the plan build agree.
        S = n.payload::_AccKernel
        return _oop_acc_vecable(S.spine, S) &&
               all(r -> _oop_acc_vecable(r, S), S.cse.recipes) &&
               all(r -> _oop_acc_vecable(r, S), S.cse.inv_recipes)
    end
    if k === _NK_ACCESS
        a = K.acc[n.idx]
        ak = a.kind
        if ak === _AK_CONST_EDGE || ak === _AK_STATE_INDIRECT ||
           ak === _AK_STATE_INDIRECT_COL
            # n-indexed: only resolvable inside a CSR segment fold.
            return in_reduce && _oop_reduce_desc_ok(ak)
        end
        # Inside a reduce, restrict to the E-lane-resolvable kinds (box/forcing/tbl
        # need a per-entry midx the CSR layout omits — keep the per-cell fallback).
        in_reduce && !_oop_reduce_desc_ok(ak) && return false
        # An unstructured slot-table gather vectorizes as a plain precomputed
        # gather (gather-of-gather resolved host-side). A ghost slot (0) in the
        # table also vectorizes (gordian total-vectorize): gather at a SAFE index
        # and select 0.0 on the ghost lanes against a host-precomputed mask (see
        # `_build_oop_acc_plan`) — no per-cell fallback, still whole-array only.
        # CONST_CELL addresses by `oln`, which equals the ordinal only for a
        # contiguous set — an indirect-outs kernel would freeze wrong lanes.
        # (The builder never emits it there; this guards hand-built kernels.)
        ak === _AK_CONST_CELL && _is_outs(K.cells) && return false
    elseif k === _NK_CACHED
        (n.payload === K.cse.scratch || n.payload === K.cse.inv_scratch) || return false
    end
    return all(c -> _oop_acc_vecable(c, K, in_reduce), n.children)
end

# Build observability (parallels `_CASCADE_TALLY`): why did an acc kernel decline
# the vectorized oop plan? Returns `:ok`, or the first blocking reason — a
# `_NK_REDUCE` / `_AK_STATE_INDIRECT[_COL]` / `_AK_CONST_EDGE` (the last remaining
# per-cell oop fallback class, a latent IR capability with no production builder).
# Sub-kernels (`_NK_SUBCALL`) are NOT a decline reason — they now vectorize
# (gordian subcall-vectorize) — so the walk recurses into each. Read corpus-wide
# via the `ESS_OOP_PROBE=1` hook in `_make_rhs` (records `:oop_vec` / `:oopdecl_*`
# into the cascade tally).
function _oop_decline_reason(K::_AccKernel)
    r = _oop_decline_walk(K.spine, K)
    r === :ok || return r
    for rec in K.cse.recipes
        rr = _oop_decline_walk(rec, K); rr === :ok || return rr
    end
    for rec in K.cse.inv_recipes
        rr = _oop_decline_walk(rec, K); rr === :ok || return rr
    end
    return :ok
end
function _oop_decline_walk(n::_Node, K::_AccKernel)
    k = n.kind
    if k === _NK_REDUCE
        _is_contig(K.cells) || return :reduce_noncontig
        return _oop_decline_walk(n.children[1], K)   # report the real blocker in the body
    end
    if k === _NK_SUBCALL
        S = n.payload::_AccKernel
        r = _oop_decline_walk(S.spine, S); r === :ok || return r
        for rec in S.cse.recipes
            rr = _oop_decline_walk(rec, S); rr === :ok || return rr
        end
        for rec in S.cse.inv_recipes
            rr = _oop_decline_walk(rec, S); rr === :ok || return rr
        end
        return :ok
    end
    if k === _NK_ACCESS
        ak = K.acc[n.idx].kind
        ak === _AK_CONST_EDGE && return :const_edge
        ak === _AK_STATE_INDIRECT && return :state_indirect
        ak === _AK_STATE_INDIRECT_COL && return :state_indirect_col
        (ak === _AK_CONST_CELL && _is_outs(K.cells)) && return :const_cell_outs
    elseif k === _NK_CACHED
        (n.payload === K.cse.scratch || n.payload === K.cse.inv_scratch) || return :cached
    end
    for c in n.children
        r = _oop_decline_walk(c, K); r === :ok || return r
    end
    return :ok
end

# Resolve one descriptor table's per-lane host data against a GIVEN lane
# enumeration (`out`/`m1`/`m2`/`m3`). Split out of `_build_oop_acc_plan` so a
# template-body sub-kernel — evaluated at the PARENT's lanes — resolves its own
# descriptors against those same parent lanes (its `_contig_cells(0)` carries no
# lanes of its own). Returns the four aligned per-descriptor vectors.
function _build_oop_desc_vectors(acc::Vector{_AccDesc},
                                 out::Vector{Int}, m1::Vector{Int},
                                 m2::Vector{Int}, m3::Vector{Int})
    L = length(out)
    nacc = length(acc)
    gathers = [Int[] for _ in 1:nacc]
    consts  = [Float64[] for _ in 1:nacc]
    forc    = [Int[] for _ in 1:nacc]
    ghost   = [Bool[] for _ in 1:nacc]
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
            raw = Int[@inbounds a.conn[a.off + (m1[l]-1)*a.s1 +
                      (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3] for l in 1:L]
            if any(==(0), raw)
                ghost[i]   = Bool[s == 0 for s in raw]
                gathers[i] = Int[s == 0 ? 1 : s for s in raw]
            else
                gathers[i] = raw
            end
        elseif k === _AK_CONST_AFFINE
            gathers_i = out .+ a.delta
            consts[i] = a.arr[gathers_i]
        elseif k === _AK_CONST_BOX
            consts[i] = Float64[@inbounds a.arr[a.off + (m1[l]-1)*a.s1 +
                                (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3] for l in 1:L]
        elseif k === _AK_FORCING_BOX
            forc[i] = Int[a.off + (m1[l]-1)*a.s1 + (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3
                          for l in 1:L]
        elseif k === _AK_ARR_TBL_BOX
            # LIVE forcing through a per-cell index table: freeze the INDICES
            # (host data), re-gather the aliased buffer per call.
            forc[i] = Int[@inbounds a.conn[a.off + (m1[l]-1)*a.s1 +
                          (m2[l]-1)*a.s2 + (m3[l]-1)*a.s3] for l in 1:L]
        elseif k === _AK_LOOP_IDX
            mi = a.dim === 1 ? m1 : a.dim === 2 ? m2 : m3
            consts[i] = Float64.(mi)
        elseif k === _AK_CONST_CELL
            consts[i] = a.arr[out]        # cell ordinal == oln (see _run_box_kernel!)
        end
        # SCALAR / STATE_FIXED / ARR_FIXED: read directly by the walker.
    end
    return gathers, consts, forc, ghost
end

# CSR row pointers + per-entry (cell, neighbour) tables for a variable-valence
# reduction. Cell `c`'s neighbour entries occupy the flat range
# `seg_off[c]:seg_off[c+1]-1`, in ascending `n` (= child) order — so a per-segment
# fold over the flat E-lane body buffer reproduces `_eval_acc`'s seeded child-order
# sum exactly. `N` is the cell count (== lane count for a contiguous set).
function _oop_reduce_segments(K::_AccKernel, N::Int)
    seg_off = Vector{Int}(undef, N + 1)
    seg_off[1] = 1
    @inbounds for c in 1:N
        seg_off[c+1] = seg_off[c] + _nbrcount(K.bound, c)
    end
    E = seg_off[N+1] - 1
    seg_cell = Vector{Int}(undef, E)
    seg_n    = Vector{Int}(undef, E)
    @inbounds for c in 1:N
        base = seg_off[c] - 1
        for n in 1:_nbrcount(K.bound, c)
            seg_cell[base+n] = c
            seg_n[base+n]    = n
        end
    end
    return seg_off, seg_cell, seg_n
end

# The E-lane (in-reduce) descriptor plan: one value per flat entry `e = (c, n)`.
# The n-indexed kinds resolve per entry; cell/affine/invariant kinds broadcast a
# cell value across the cell's whole segment (matching `_fetch`, which is n-blind
# for them). `out[c]` is cell `c`'s output slot (== c for the contiguous set a
# reduce always has). Only the state kinds produce a `gathers` vector (the sole
# state access, whole-array); everything else is frozen `consts`.
function _build_oop_reduce_desc_vectors(acc::Vector{_AccDesc}, seg_cell::Vector{Int},
                                        seg_n::Vector{Int}, out::Vector{Int})
    E = length(seg_cell)
    nacc = length(acc)
    gathers = [Int[] for _ in 1:nacc]
    consts  = [Float64[] for _ in 1:nacc]
    for (i, a) in enumerate(acc)
        k = a.kind
        if k === _AK_STATE_AFFINE
            gathers[i] = Int[@inbounds out[seg_cell[e]] + a.delta for e in 1:E]
        elseif k === _AK_STATE_INDIRECT
            gathers[i] = Int[@inbounds a.conn[(seg_cell[e]-1)*a.width + seg_n[e]] for e in 1:E]
        elseif k === _AK_STATE_INDIRECT_COL
            gathers[i] = Int[@inbounds a.conn[(seg_cell[e]-1)*a.width + a.col] for e in 1:E]
        elseif k === _AK_CONST_EDGE
            consts[i] = Float64[@inbounds a.arr[(seg_cell[e]-1)*a.width + seg_n[e]] for e in 1:E]
        elseif k === _AK_CONST_CELL
            consts[i] = Float64[@inbounds a.arr[seg_cell[e]] for e in 1:E]   # c == oln (contiguous)
        elseif k === _AK_CONST_AFFINE
            consts[i] = Float64[@inbounds a.arr[out[seg_cell[e]] + a.delta] for e in 1:E]
        elseif k === _AK_LOOP_IDX
            # contiguous reduce: midx == (c, 1, 1); dim 1 → c, higher dims → 1.
            consts[i] = a.dim === 1 ? Float64[Float64(seg_cell[e]) for e in 1:E] : fill(1.0, E)
        end
        # SCALAR / STATE_FIXED / ARR_FIXED: read directly by the walker (scalars,
        # broadcast over the segment). Box/forcing/tbl kinds were declined upstream.
    end
    return gathers, consts
end

function _build_oop_acc_plan(K::_AccKernel)
    _t0 = time_ns()
    r = _build_oop_acc_plan_inner(K)
    _bench_phase!(:oop_plan, _t0)
    return r
end
function _build_oop_acc_plan_inner(K::_AccKernel)
    ok = _oop_acc_vecable(K.spine, K) &&
         all(r -> _oop_acc_vecable(r, K), K.cse.recipes) &&
         all(r -> _oop_acc_vecable(r, K), K.cse.inv_recipes)
    ok || return _OOP_ACC_FALLBACK
    out, m1, m2, m3 = _oop_acc_lanes(K.cells)
    gathers, consts, forc, ghost = _build_oop_desc_vectors(K.acc, out, m1, m2, m3)
    # Template-body sub-kernels (`K.subs`, transitive/nested-first): each is
    # evaluated at the parent's `(c,n,oln,midx)`, so resolve its descriptor tables
    # against the PARENT's lane enumeration. `_oop_acc_vecable` already accepted
    # every `_NK_SUBCALL` above (recursing into each sub), so the subs vectorize by
    # construction; build their aligned lane plans here so the walker can splice
    # each variant's whole-array result into the parent operand stream.
    subs = K.subs
    sub_plans = _OopAccPlan[]
    if !isempty(subs)
        sub_plans = Vector{_OopAccPlan}(undef, length(subs))
        for j in eachindex(subs)
            S = subs[j]
            sg, sc, sf, sgh = _build_oop_desc_vectors(S.acc, out, m1, m2, m3)
            # A sub carries no cells of its own; `out_slots` is unused for a sub
            # (only the top-level plan scatters), so reuse the parent lane slots.
            sub_plans[j] = _OopAccPlan(true, out, sg, sc, sf, sgh,
                                       _AccKernel[], _OopAccPlan[], Int[], _OopAccPlan[])
        end
    end
    # Variable-valence reduction: build the CSR segments + the E-lane body plan.
    # `_build_acc_cse` never CSE's a reduce spine, so the reduce sits directly on
    # `K.spine` (no recipes carry one) and there is exactly one to model.
    red_seg = Int[]
    red_plan = _OopAccPlan[]
    if _acc_has_reduce(K.spine)
        N = length(out)
        seg_off, seg_cell, seg_n = _oop_reduce_segments(K, N)
        eg, ec = _build_oop_reduce_desc_vectors(K.acc, seg_cell, seg_n, out)
        nacc = length(K.acc)
        red_seg = seg_off
        red_plan = _OopAccPlan[_OopAccPlan(true, Int[], eg, ec,
                        [Int[] for _ in 1:nacc], [Bool[] for _ in 1:nacc],
                        _AccKernel[], _OopAccPlan[], Int[], _OopAccPlan[])]
    end
    return _OopAccPlan(true, out, gathers, consts, forc, ghost, subs, sub_plans,
                       red_seg, red_plan)
end

# ---- The build's out-of-place product ---------------------------------------
#
# `build_evaluator(model; form = :oop)` returns one of these in the `f!` slot: a
# handle on the compiled intermediate representation (`rhs`) together with the
# live forcing buffers this build bound. A compiled backend lowers `rhs` into a
# program of its own; `direct_rhs` (ext/reactant_direct/) is the one in tree.
#
# ARITY IS THE FORM. The single call method takes three arguments, which is what
# SciMLBase reads as out-of-place, and a consumer that probes for in-place-ness
# by method applicability gets the right answer. There is deliberately NO 4-arg
# method: SciMLBase infers in-place-ness from one, so adding it would make
# `ODEProblem(f, …)` misread this product as an `f!`.
struct _OopRHS{F,B} <: Function
    rhs::F                          # the compiled IR (`_CompiledIR`)
    buffers::B                      # NamedTuple: name => aliased HOST buffer, stable order
    buffer_index::Dict{String,Int}  # buffer name -> position in `buffers`
end

# Host evaluation of this form is a compiled backend's job. The in-place `f!`
# (`form = :inplace`, the default) is the host evaluator, and it is also the
# reference the compiled backends are gated against; `ESS_UNTIERED=1` gives its
# untiered variant, which recomputes every prelude slot on every call.
(f::_OopRHS)(u, p, t) = throw(TreeWalkError("E_TREEWALK_OOP_NOT_EVALUABLE",
    "an out-of-place build (`build_evaluator(model; form = :oop)`) is the " *
    "compiled intermediate representation a backend lowers, not a host " *
    "evaluator. Compile it — `EarthSciASTReactantExt.direct_rhs(f)`, then " *
    "`Reactant.@compile` — or build `form = :inplace` and call " *
    "`f!(du, u, p, t)` on the host."))

"""
    forcing_buffers(f) -> NamedTuple

The live forcing buffers of an out-of-place RHS from
`build_evaluator(model; form = :oop)`, as a NamedTuple in a STABLE order (buffer
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
struct _CompiledIR{R,C,K,S,M,A,B,MB}
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

function _make_rhs_oop(rhs_list::AbstractVector{Tuple{Int,_Node}},
                       cse_prelude::AbstractVector{_Node},
                       acc_kernels::AbstractVector{_AccKernel},
                       n_states::Int,
                       pgather::AbstractDict=_EMPTY_PGATHER,
                       scan_folds::AbstractVector{_ScanFold}=_ScanFold[],
                       mat_levels::Tuple=(),
                       n_total::Int=n_states,
                       array_contractions::AbstractVector{_ArrayContraction}=
                           _ArrayContraction[])
    # Vectorized lane plans for the acc kernels (host index data, built once).
    # The kernel-CLASS merge (oop_merge.jl) no longer runs here: it is hoisted
    # into `_build_evaluator_impl` phase 4 (`_merge_acc_kernel_classes`), before
    # the xcse gate, so BOTH emitters receive already-merged kernels and this
    # plan build is over the merged (fewer) list. `acc_kernels` and `acc_plans`
    # reach the build product under the stable field names :acc_kernels /
    # :acc_plans that external tooling reflects on.
    acc_plans = _OopAccPlan[_build_oop_acc_plan(K) for K in acc_kernels]
    # Lane-batched scalar surfaces (ess-oop-batch), grouped ONCE at build:
    # the rhs_list per-cell entries and each fill level's per-column scalars.
    # `rhs_list`/`mat_levels` keep their own stable field names (external
    # tooling reflects on them); `rhs_batches`/`mat_batches` are ADDITIVE
    # fields — a group count of zero means everything runs the scalar path.
    rhs_batches = _oop_batch_scalars(rhs_list)
    mat_batches = map(lvl -> _oop_batch_scalars(lvl[1]::Vector{Tuple{Int,_Node}}),
                      mat_levels)
    # The buffers container: every live forcing buffer this build registered —
    # raw `param_arrays` entries AND DiscreteMaterializer caches, both of which
    # live in `pgather` by the time this runs — in a STABLE order (names
    # sorted), as a NamedTuple of the aliased flat host views. A backend passes
    # an aligned container of device arrays to the explicit-buffers form, so a
    # discrete-cadence refresh reaches the compiled program (`sync_forcing!`).
    buf_names = sort!(String[String(k) for k in keys(pgather)])
    host_bufs = NamedTuple{Tuple(Symbol(n) for n in buf_names)}(
        Tuple((pgather[n]::_PGatherArray).flat for n in buf_names))
    buffer_index = Dict{String,Int}(n => i for (i, n) in enumerate(buf_names))
    return _OopRHS(_CompiledIR(rhs_list, cse_prelude, acc_kernels, acc_plans,
                               scan_folds, mat_levels, array_contractions,
                               rhs_batches, mat_batches, n_states, n_total),
                   host_bufs, buffer_index)
end
