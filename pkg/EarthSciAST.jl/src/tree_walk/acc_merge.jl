# ========================================================================
# tree_walk/acc_merge.jl — part of the tree-walk evaluator (array-IR B, stage 3/4).
# Included by src/tree_walk.jl AFTER access_kernel.jl (`_AccKernel` and
# descriptors). Owns the per-cell → access-kernel merge, the structural
# grouping signature, and the in-place RHS closure generator `_make_rhs`.
#
# The PER-CELL fallback's whole-array host: group an array equation's compiled
# per-cell `(du_slot, _Node)` entries by structural signature and merge each
# group into ONE `_AccKernel` over an INDIRECT-OUTS cell set. The lane-tape
# machinery then runs the kernel de-scalarized at Float64 (per-node tile loops
# over the merged per-cell tables), the scalar `_eval_acc` walk stays the
# eltype-generic / lazy-guard reference, and the oop vectorized form gets
# whole-array gathers — one IR family for every array-equation tier.
#
# Bit-identity by construction: the merge is a structural transpose — a leaf
# that is equal across the group stays a scalar (literal / fixed slot /
# invariant), a varying one becomes a per-cell table indexed by the cell
# ordinal — and the evaluators apply the identical scalar op sequence per lane
# (`_eval_acc_op` mirrors `_eval_node_op`; `_NK_CONTRACTION` keeps its seeded
# sequential ⊕-fold on every runner). The forced per-cell reference
# (`ESS_STENCIL_DISABLE=1`) skips the merge entirely — plain compiled scalar
# nodes on `rhs_list`, evaluated by `_eval_node` — so the differentials
# compare against a build with no merge machinery at all.
#
# LAZY GUARDS. `_eval_acc_op`'s `ifelse`/`and`/`or` arms short-circuit exactly
# like the scalar walker's, so on the SCALAR reference runner a merged group
# with a lazy guard keeps per-cell guard semantics. The lane tape no longer
# declines these kernels (gordian total-vectorize): it evaluates the guards
# EAGERLY as select/blend, on a spine copy `_acc_sanitize_guards` makes total,
# so a throwing op under an unentered branch cannot raise (see access_kernel.jl).
#
# The per-cell/invariant CSE tiers are still SKIPPED on a lazy-bearing spine —
# but the reason is the SCALAR path alone, not the tape. `_build_acc_cse` counts
# total occurrences (not unconditional ones), so hoisting a subtree whose
# occurrences all sit under a guard into the UNCONDITIONAL CSE prelude would
# evaluate what the lazy scalar walk skips. Since the same `_AccKernel` backs
# both runners and the scalar path must stay lazy, we skip CSE here. (The tape's
# own sanitized selects ARE total, so a tape-LOCAL CSE across selects would be
# sound — a future optimization, out of scope for the eager-select landing.)
# ========================================================================

# Does this spine carry an op whose scalar evaluation is lazy?
_acc_node_has_lazy(n::_Node) =
    (n.kind === _NK_OP && (n.op === :ifelse || n.op === :and || n.op === :or)) ||
    any(_acc_node_has_lazy, n.children)


# ---- Structural grouping signature (moved here from the deleted _VecNode
# overlay, vectorize.jl — same bytes, same partition) ----------------------

# A signature that is equal for two per-cell nodes iff they have an identical
# tree shape ignoring the values that legitimately vary per cell (STATE slot
# index, LITERAL value). Same signature ⇒ unambiguous merge into one template.
# Different signatures (in-bounds STATE vs ghost LITERAL, makearray region A vs
# B, valence-5 vs valence-6 contraction) ⇒ separate kernels.
#
# The signature is written token-by-token into a caller-supplied `IOBuffer` and
# materialised to a `String` exactly ONCE per top-level node (see the reusable
# buffer in `_acc_from_cell_entries`). The earlier `string(…, join(…), …)` form
# allocated an intermediate `String` at every interior node and re-copied every
# descendant's bytes at each level up the tree — O(nodes × depth) garbage. The
# emitted bytes are unchanged, so the grouping is identical.
function _struct_sig!(io::IOBuffer, n::_Node)
    k = n.kind
    if k === _NK_STATE
        print(io, 'S')
    elseif k === _NK_LITERAL
        print(io, 'L')
    elseif k === _NK_PARAM
        print(io, "P:", n.sym)
    elseif k === _NK_PARAM_GATHER
        # Cells gathering from the SAME captured buffer (same `payload` object)
        # merge into one live-forcing table read; the per-lane linear `idx`
        # becomes the index table. Different buffers ⇒ different `objectid` ⇒
        # separate kernels.
        print(io, "PG:", objectid(n.payload))
    elseif k === _NK_TIME
        print(io, 'T')
    elseif k === _NK_CONTRACTION
        print(io, "C:", n.op, '(')
        _sig_children!(io, n.children)
        print(io, ')')
    else  # _NK_OP (including closed `fn`)
        print(io, "O:", n.op)
        pl = n.payload
        if pl isa Tuple && length(pl) >= 2
            # A closed `fn`: `payload === (fname, spec_or_nothing)`. The NAME alone
            # is NOT a sufficient key. An `interp.*` node's const table/axis live in
            # the typed spec, NOT in its children (`_compile_fn_node` pulls the const
            # args out of the arg list), so two cells calling `interp.linear` against
            # DIFFERENT tables have identical children and would otherwise share a
            # signature — and `_merge_fn_node` puts ONE spec on the merged kernel, so
            # every cell would silently compute against `nodes[1]`'s table. Reachable:
            # a `makearray` whose regions each call `interp.*` with their own table,
            # indexed inside an arrayop that takes the per-cell path (any contraction,
            # i.e. an einsum/aggregate RHS). Keying the spec's CONTENT splits those
            # into one kernel per distinct table.
            #
            # CONTENT, deliberately, not `objectid(spec)`: specs are rebuilt per
            # `_compile_fn_node` call, so two cells with the SAME table routinely hold
            # DIFFERENT spec objects. Identity keying would split groups that must
            # merge and destroy the N-independence of the kernel count. Content keying
            # keeps it: the number of DISTINCT tables is a property of the document,
            # not of the grid.
            print(io, '@', pl[1], '#', _fn_spec_hash(pl[2]))
        elseif pl isa Tuple && length(pl) >= 1
            print(io, '@', pl[1])
        end
        print(io, '(')
        _sig_children!(io, n.children)
        print(io, ')')
    end
    return io
end

function _sig_children!(io::IOBuffer, children)
    first = true
    for ch in children
        first || print(io, ',')
        first = false
        _struct_sig!(io, ch)
    end
    return io
end

# Content hash / content equality for a closed function's build-time spec — the
# matched (`hash`, `isequal`) pair the grouping and its guard need. `isequal`
# (not `==`) so a table holding a NaN still compares equal to itself: two cells
# genuinely sharing such a table must merge, not throw.
#
# `_fn_spec_hash` keys `_struct_sig!`'s grouping; `_fn_spec_content_equal` is the
# exact check `_merge_fn_node` re-runs on the resulting group, so a hash COLLISION
# degrades to a loud build error instead of back to silent wrong numbers.
_fn_spec_hash(::Nothing) = UInt(0)                      # all-scalar `datetime.*`
_fn_spec_hash(s::_InterpLinearSpec) = hash(s.axis, hash(s.table, UInt(0x11)))
_fn_spec_hash(s::_InterpBilinearSpec) =
    hash(s.axis_y, hash(s.axis_x, hash(s.table, UInt(0x22))))
_fn_spec_hash(s::_InterpSearchsortedSpec) = hash(s.xs, UInt(0x33))
# An unknown spec type cannot be content-hashed, so key it by IDENTITY: over-splitting
# (a group per object) is safe — worst case an extra kernel — where under-splitting is
# the silent wrong number this whole mechanism exists to prevent. No such spec exists
# today (`_FN_CONST_ARG_SPECS` is the closed set); this is the fail-safe default for one
# added without updating the three methods above.
_fn_spec_hash(s) = objectid(s)

_fn_spec_content_equal(a, b) = false                    # different spec types never match
_fn_spec_content_equal(::Nothing, ::Nothing) = true
_fn_spec_content_equal(a::_InterpLinearSpec, b::_InterpLinearSpec) =
    isequal(a.table, b.table) && isequal(a.axis, b.axis)
_fn_spec_content_equal(a::_InterpBilinearSpec, b::_InterpBilinearSpec) =
    isequal(a.table, b.table) && isequal(a.axis_x, b.axis_x) && isequal(a.axis_y, b.axis_y)
_fn_spec_content_equal(a::_InterpSearchsortedSpec, b::_InterpSearchsortedSpec) =
    isequal(a.xs, b.xs)

# Every cell in a `fn` group must carry a CONTENT-equal spec, because the merged
# kernel carries exactly one. Throws rather than merging cells whose const tables
# differ — the hazard this guards is a SILENT one (identical shapes, different
# numbers), so it must fail at build.
#
# The `===` fast path is what keeps this free in practice: the per-equation build
# memo makes every cell of one source `fn` node share ONE spec object, so the loop is
# N pointer compares and the content compare is reached only for genuinely distinct
# objects (an unmemoized rebuild, or a hash collision).
function _check_fn_group_specs(nodes::Vector{_Node})
    length(nodes) <= 1 && return nothing
    fname1, spec1 = (nodes[1].payload)::Tuple{String,Any}
    @inbounds for k in 2:length(nodes)
        fnamek, speck = (nodes[k].payload)::Tuple{String,Any}
        speck === spec1 && fnamek == fname1 && continue
        (fnamek == fname1 && _fn_spec_content_equal(speck, spec1)) && continue
        throw(TreeWalkError("E_TREEWALK_FN_SPEC_MISMATCH",
            "vectorized array kernel: cells grouped as structurally identical carry " *
            "DIFFERENT closed-function specs for '$(fname1)' (cell 1 vs cell $(k)" *
            (fnamek == fname1 ? ": same function, different const table/axis" :
                                ": different functions '$(fname1)' vs '$(fnamek)'") *
            "). A merged kernel carries ONE spec for all its lanes, so these cells " *
            "cannot share a vectorized kernel — evaluating them together would " *
            "silently compute every cell against the FIRST cell's table. Cells whose " *
            "const tables differ (e.g. `makearray` regions each calling `interp.*` " *
            "with their own table) must land in SEPARATE structural groups; " *
            "`_struct_sig!` keys the spec's content precisely so they do, so reaching " *
            "this is a grouping-invariant break (a hash collision, or a signature that " *
            "stopped keying the spec), not a model error."))
    end
    return nothing
end

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
# build one indirect-outs `_AccKernel` per group, in first-seen group order —
# deterministic kernel boundaries, lane order, and out-slot order.
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
        # lazy-bearing one (see the header) so the SCALAR reference stays lazy;
        # the tape sanitizes and eager-blends the guards from this same spine.
        spine, cse = _acc_node_has_lazy(spine) ? (spine, _ACC_NO_CSE) :
                     _build_acc_cse(spine, acc)
        push!(kernels, _AccKernel(_outs_cells(slots), spine, acc,
                                  _FixedBound(0), 0.0, cse))
    end
    return kernels
end

# Inner closure generator — separated so the closure's body is small
# enough to stay inferable. `rhs_list` and `acc_kernels` are captured by the
# closure; Julia specializes the generated method to the captured types.
# Scalar/indexed-D equations evaluate through `rhs_list` (one slot each); array
# (`arrayop`) equations evaluate through `acc_kernels` as whole-array access
# kernels (in-place lane tapes at Float64, the eltype-generic scalar walk
# otherwise). Accepts any AbstractVector so both the pre-allocated and the
# dynamically-grown forms produced by build_evaluator work. The whole RHS is
# allocation-free in steady state (ess-9cc), so it can be reused across every
# RK stage without GC pressure — pinned by the `@allocated f!(du,u,p,t) == 0`
# test.
#
# ELTYPE-GENERIC, STILL ZERO-ALLOC. `f!` computes in `T = _rhs_value_type(u, p, t)`,
# which is a compile-time constant per specialization — so at `T === Float64` the
# scratch lookups below (`_cse_buf`, and the acc scratch tiers) are field
# loads and this is exactly the Float64 RHS it always was. Hand it `Dual` state
# (a ForwardDiff Jacobian for a stiff solver) or a `Dual`-valued parameter
# NamedTuple (a sensitivity) and the SAME closure evaluates in `Dual`, reusing the
# per-node Dual buffers created on the first such call. `t` is folded into the value
# type alongside `u` and `p` precisely so the parameter axis works: there `u` stays
# `Vector{Float64}` and only the parameter VALUES are `Dual`, so a scratch sized
# from `eltype(u)` alone would compile and then throw `Float64(::Dual)` on its first
# store.
function _make_rhs(rhs_list::AbstractVector{Tuple{Int,_Node}},
                   cse_prelude::AbstractVector{_Node},
                   cse_cache::_CSECache,
                   acc_kernels::AbstractVector{_AccKernel},
                   const_slots::AbstractVector{Int},
                   dyn_slots::AbstractVector{Int})
    # Lane tapes for the affine access kernels (access_kernel.jl): compiled once
    # here, run in place of the per-cell scalar walk wherever a strided
    # formulation exists (`nothing` ⇒ that kernel keeps the scalar runner). The
    # tape is Float64-only; every other value type (ForwardDiff `Dual`) takes
    # the eltype-generic scalar path below, which computes the SAME values.
    acc_plans = Union{Nothing,_AccPlan}[_build_acc_plan(K) for K in acc_kernels]
    # Build observability: with ESS_OOP_PROBE=1, record how each array kernel would
    # plan for the vectorized (traceable) `:oop` form — `:oop_vec` when it
    # vectorizes whole-array, else `:oopdecl_<reason>` — into the cascade tally, so
    # the corpus's oop-fallback coverage is readable from an ordinary in-place build.
    if get(ENV, "ESS_OOP_PROBE", "") == "1"
        for K in acc_kernels
            P = _build_oop_acc_plan(K)
            _tally_cascade!(P.vectorizable ? :oop_vec : Symbol("oopdecl_", _oop_decline_reason(K)))
        end
    end
    # B1 codegen tier (codegen_kernel.jl): every kernel the emitter can model is
    # compiled ONCE, here at build time, into a single RuntimeGeneratedFunction
    # (bit-identical, eltype-generic); the rest keep the tape/scalar runners
    # above. `ESS_CODEGEN_DISABLE=1` yields exactly the pre-codegen kernel loop.
    kernel_section = _make_kernel_section(acc_kernels, acc_plans)
    function f!(du, u, p, t)
        _reject_float32_state(u)   # loud, statically-folded (see compile.jl)
        T = _rhs_value_type(u, p, t)
        # CSE prelude (ess-r7h), in its TWO CADENCE TIERS (4qf, const_tier.jl):
        # evaluate each distinct shared subexpression once into the scratch cache,
        # in slot order. `defs[s]` references only slots < s (topological), so each
        # read is already filled. The cache makes `f!` non-reentrant (one instance
        # per integrator, which is how ODE RHS closures are used). Empty prelude ⇒
        # both loops are no-ops and `f!` is identical to the pre-CSE evaluator.
        #
        # Both loops are UNCONDITIONAL — every slot is evaluated before any equation
        # runs, whether or not the guard above its occurrence would have fired. That
        # is safe only because `_cse_compile_scalar` refuses to hoist a key whose
        # every occurrence sits under a lazy `ifelse`/`and`/`or` arm (see the GUARDS
        # note in compile.jl); a slot that exists always has an occurrence the walk
        # would have evaluated anyway.
        cache = _cse_buf(cse_cache, T)

        # ---- Tier 1: CONST-cadence slots — refilled only when `p` moved ----
        # These slots' defs read no state, no time and no live forcing buffer, and
        # every cache ref in them lands on another CONST slot (the classification
        # rule, const_tier.jl), so their values are a pure function of `p`. They stay
        # good in THIS buffer until `p` changes or the buffer is replaced — which is
        # exactly what `_cse_const_stale` tests. This is the whole point of the tier:
        # a parameter-only Arrhenius chain `A*exp(-Ea/(R*Tref))` is evaluated once per
        # parameter epoch instead of once per stage of every step, forever.
        #
        # NOT constant-folded at build time, deliberately: `p` legitimately changes
        # (sweeps, `remake`) and under ForwardDiff-over-parameters its VALUES are
        # `Dual`s. Freezing these slots would zero every parameter sensitivity.
        if !isempty(const_slots) && _cse_const_stale(cse_cache, T, p)
            @inbounds for i in eachindex(const_slots)
                s = const_slots[i]
                cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
            end
            _cse_mark_const!(cse_cache, T, p)
        end

        # ---- Tier 2: DYNAMIC slots — refilled every call ----
        # A dynamic def may read const slots (all filled, above) and lower dynamic
        # slots (filled by this loop, which is ascending) — so every read is already
        # filled, exactly as in the single-loop prelude this replaces.
        @inbounds for i in eachindex(dyn_slots)
            s = dyn_slots[i]
            cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
        end
        @inbounds for k in 1:length(rhs_list)
            idx_and_node = rhs_list[k]
            du[idx_and_node[1]] = _eval_node(idx_and_node[2], u, p, t, T)
        end

        # ---- Access kernels (the unified array IR, access_kernel.jl) ----
        # Each resolves its gathers at runtime from an access-descriptor table over
        # a strided output box — no per-lane slot vectors were built. The reduction
        # bound / connectivity are data, so one kernel covers every valence.
        # The kernel section (codegen_kernel.jl) runs the codegen-emitted kernels
        # through their compiled loop nests (any value type), then each residual
        # kernel exactly as before: at Float64 a kernel with a lane tape runs
        # de-scalarized (`_run_acc_plan!`, bit-identical + zero-alloc); everything
        # else walks the eltype-generic scalar runner.
        kernel_section(du, u, p, t, T)
        return nothing
    end
    return f!
end
