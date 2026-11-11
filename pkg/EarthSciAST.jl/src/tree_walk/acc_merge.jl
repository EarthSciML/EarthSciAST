# ========================================================================
# tree_walk/acc_merge.jl — part of the tree-walk evaluator (array-IR B, stage 3/4).
# Included by src/tree_walk.jl AFTER access_kernel.jl (`_AccKernel` and
# descriptors). Owns the per-cell → access-kernel merge, the structural
# grouping signature, and the in-place RHS closure generator `_make_rhs`.
#
# The PER-CELL fallback's whole-array host: group an array equation's compiled
# per-cell `(du_slot, _Node)` entries by structural signature and merge each
# group into ONE `_AccKernel` over an INDIRECT-OUTS cell set. The codegen tier
# then compiles the kernel into a straight loop nest, the scalar `_eval_acc`
# walk stays the eltype-generic / lazy-guard reference (and the runner for
# declined kernels), and the oop vectorized form gets whole-array gathers —
# one IR family for every array-equation tier.
#
# Bit-identity by construction: the merge is a structural transpose — a leaf
# that is equal across the group stays a scalar (literal / fixed slot /
# invariant), a varying one becomes a per-cell table indexed by the cell
# ordinal — and the evaluators apply the identical scalar op sequence per lane
# (`_eval_acc_op` mirrors `_eval_node_op`; `_NK_CONTRACTION` keeps its seeded
# sequential ⊕-fold on every runner). The per-cell reference skips the merge
# entirely — plain compiled scalar nodes on `rhs_list`, evaluated by
# `_eval_node` — so the differentials compare against a build with no merge
# machinery at all.
#
# LAZY GUARDS. `_eval_acc_op`'s `ifelse`/`and`/`or` arms short-circuit exactly
# like the scalar walker's, so on the SCALAR reference runner a merged group
# with a lazy guard keeps per-cell guard semantics (the codegen tier emits the
# same lazy semantics — ternaries and `&&`/`||` chains).
#
# The per-cell/invariant CSE tiers are SKIPPED on a lazy-bearing spine:
# `_build_acc_cse` counts total occurrences (not unconditional ones), so
# hoisting a subtree whose occurrences all sit under a guard into the
# UNCONDITIONAL CSE prelude would evaluate what the lazy scalar walk skips.
# ========================================================================

# Does this spine carry an op whose scalar evaluation is lazy?
_acc_node_has_lazy(n::_Node) =
    (n.kind === _NK_OP && (n.op === :ifelse || n.op === :and || n.op === :or)) ||
    _anyof(_acc_node_has_lazy, n.children)

# ---- DIRECT CLASS EMISSION switch
#
# The umbrella switch the cross-equation stage below requires. It stands down
# whenever the class merge is off: that means "no lane-batched class kernels in
# this build".
_direct_class_emit_disabled() = !_compiler_plan_now().direct_class_emit
_direct_class_emit_enabled() =
    !_direct_class_emit_disabled() && !_oop_merge_disabled()

# CROSS-EQUATION + AFFINE-BOX direct class emission — the two class families
# the per-equation emitter above cannot see, folded into direct emission:
#
#   1. CROSS-EQUATION per-cell classes. The scalarizer's grouping runs per
#      `_acc_from_cell_entries` call, and that call used to be per EQUATION —
#      so structurally identical cells arising in DIFFERENT equations (twin
#      species balances, per-band photolysis equations) always split into one
#      kernel per equation and reached a class only through the post-hoc
#      repair pass. Under this switch `_compile_derivative_equations`
#      (build.jl) POOLS every per-cell equation's cell entries and calls
#      `_acc_from_cell_entries` ONCE, above the equation loop — the same
#      emitter, the same shape-keyed signature, one global grouping. Out-slot
#      uniqueness across equations is guaranteed by `covered` (a duplicate
#      derivative throws at compile), and kernels only read `u`/`p`/`t`/live
#      forcing and assignment-scatter disjoint `du` slots, so which kernel
#      hosts a cell — and where in the kernel list it lands — cannot change
#      any evaluated bit.
#
#   2. AFFINE-BOX (assembled-kernel) classes. The affine stencil path mints
#      `_AccKernel`s per box directly — including the subterm-granular
#      LANE_EXPRTBL per-box tables (`:affine_subtree_tbl`, stencil.jl) — with
#      no per-cell scalar trees for the scalarizer-level emitter to pool:
#      the box compiler exists precisely to never scalarize. For that family
#      the class facts only come into existence AT ASSEMBLY, so the emitter
#      for it is sited at the assembled-kernel level:
#      `_merge_acc_kernel_classes` (oop_merge.jl) runs its two class-merge
#      rounds as a DIRECT EMISSION stage (tallies
#      `:direct_classmerge_round{1,2}_merge`) and then re-runs them as the
#      counted repair safety net — which is expected to find NOTHING
#      (`:classmerge_round{1,2}_merge` == 0, pinned by
#      test/cross_eq_class_emission_test.jl). Reusing the proven lockstep
#      clone instead of writing a parallel box-level emitter keeps the
#      bit-identity argument exactly the one the repair pass already carries.
#
# Off, the build is the per-equation emitter + repair-only pipeline byte for
# byte. The stage also stands down whenever per-equation direct emission itself
# is off, or the class merge is (`_direct_class_emit_enabled` folds both in).
_cross_eq_class_emit_disabled() = !_compiler_plan_now().cross_eq_class_emit
_cross_eq_class_emit_enabled() =
    !_cross_eq_class_emit_disabled() && _direct_class_emit_enabled()

# ---- Structural grouping signature ------------------------------------------

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
    elseif k === _NK_CONTRACTION_LOOP || k === _NK_LOOPVAR || k === _NK_RAGGED_LOOP ||
            k === _NK_LIVE_GATHER
        # Defensive: a runtime contraction loop (ess-runtime-contraction) or a
        # ragged loop is CONFINED to scalar contexts and never reaches the
        # array-equation merge. Should one ever arrive, key it by object
        # identity so DISTINCT loops can never be wrongly merged into one kernel
        # (fail-safe: no merge, not a silent miscompile); a ragged loop's
        # `[body, lo, hi]` children would otherwise read as an n-ary op's. The
        # codegen emitter then declines it and the cell falls back to the
        # per-cell scalar walk.
        print(io, "CL:", objectid(n))
    else  # _NK_OP
        print(io, "O:", n.op)
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

# Merge one structurally-identical group of per-cell nodes into an access
# spine, appending per-cell tables to `acc` (the kernel's descriptor table):
#   LITERAL   all-equal → spine literal; varying → CONST_BOX ordinal table
#   STATE     all-equal → STATE_FIXED (invariant tier hoists it); varying →
#             STATE_TBL_BOX ordinal slot table (never 0 here — a per-cell ghost
#             is a LITERAL 0.0 leaf, not a slot)
#   PARAM/TIME  pass through (spine kinds)
#   PARAM_GATHER all-equal → ARR_FIXED (live); varying → ARR_TBL_BOX (live)
#   CONTRACTION children merged element-wise (the signature pins the width)
#   OP        children merged
# The ordinal tables use box-local addressing `s1=1, off=1` — the outs runner
# threads the cell ordinal through `midx[1]`.
function _acc_merge_nodes(nodes::Vector{_Node}, len::Int, acc::Vector{_AccDesc})::_Node
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
        ch = _Node[
            _acc_merge_nodes(_Node[nd.children[c] for nd in nodes], len, acc)
                for c in 1:m
        ]
        return _mknode(
            kind = _NK_CONTRACTION, op = n1.op, literal = n1.literal,
            children = ch
        )
    else  # _NK_OP
        pay = n1.payload
        m = length(n1.children)
        ch = _Node[
            _acc_merge_nodes(_Node[nd.children[c] for nd in nodes], len, acc)
                for c in 1:m
        ]
        return _mknode(kind = _NK_OP, op = n1.op, payload = pay, children = ch)
    end
end

# Group an array equation's per-cell `(du_slot, node)` entries by structure and
# build one indirect-outs `_AccKernel` per group, in first-seen group order —
# deterministic kernel boundaries, lane order, and out-slot order.
function _acc_from_cell_entries(entries::Vector{Tuple{Int, _Node}})::Vector{_AccKernel}
    isempty(entries) && return _AccKernel[]
    order = String[]
    groups = Dict{String, Tuple{Vector{Int}, Vector{_Node}}}()
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
        # lazy-bearing one (see the header) so the SCALAR reference stays lazy.
        spine, cse = _acc_node_has_lazy(spine) ? (spine, _ACC_NO_CSE) :
            _build_acc_cse(spine, acc)
        push!(
            kernels, _AccKernel(
                _outs_cells(slots), spine, acc,
                _FixedBound(0), 0.0, cse
            )
        )
    end
    return kernels
end

# Inner closure generator — separated so the closure's body is small
# enough to stay inferable. `rhs_list` and `acc_kernels` are captured by the
# closure; Julia specializes the generated method to the captured types.
# Scalar/indexed-D equations evaluate through `rhs_list` (one slot each); array
# (`faq`) equations evaluate through `acc_kernels` as whole-array access
# kernels (codegen-compiled loop nests, the eltype-generic scalar walk for
# declined kernels). Accepts any AbstractVector so both the pre-allocated and the
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
function _make_rhs(
        rhs_list::AbstractVector{Tuple{Int, _Node}},
        cse_prelude::AbstractVector{_Node},
        cse_cache::_CSECache,
        acc_kernels::AbstractVector{_AccKernel},
        const_slots::AbstractVector{Int},
        time_slots::AbstractVector{Int},
        dyn_slots::AbstractVector{Int},
        scan_folds::AbstractVector{_ScanFold} = _ScanFold[],
        array_contractions = _make_contraction_section(_ArrayContraction[]);
        scalar = nothing, fused_scans::Tuple = (), nst::Int = 0
    )
    # The prefix scans: the unfused folds and the fused ones (scan_fused.jl).
    scan_section = _make_scan_section(scan_folds, fused_scans)
    # The scalar codegen tier (scalar_codegen.jl): with a scalar section the
    # equations and the prelude run as generated code, and only what it left
    # behind is walked.
    scalar === nothing ||
        return _make_rhs_scalar_cg(
        scalar, cse_prelude, cse_cache, acc_kernels,
        const_slots, time_slots, scan_section,
        array_contractions; nst = nst
    )
    # B1 codegen tier (codegen_kernel.jl): every kernel the emitter can model is
    # compiled ONCE, here at build time, into a single RuntimeGeneratedFunction
    # (bit-identical, eltype-generic); the rest keep the per-cell scalar
    # runner. With the tier off this is exactly the interpreter kernel loop.
    # `shared_cache = cse_cache` (ess-cgfsc): THIS call site may compile
    # shared-prelude (`_CSECache`) reads into the generated kernels, because
    # `f!` below fills every prelude tier into that exact cache — at the same
    # value type `T` — before `kernel_section(du, u, p, t, T)` runs.
    kernel_section = _make_kernel_section(
        acc_kernels;
        shared_cache = cse_cache, nst = nst
    )
    # Without a scalar section every prelude slot and scalar equation is walked:
    # the interpreter's walker, which takes a license (scalar_codegen.jl).
    n_slots = length(const_slots) + length(time_slots) + length(dyn_slots)
    walk = _scalar_walk_license(
        n_slots + length(rhs_list) > 0,
        isempty(rhs_list) ? "the scalar prelude" : "state slot $(rhs_list[1][1])",
        "$(length(rhs_list)) scalar equations and $n_slots shared-subexpression slots",
        () -> vcat(_Node[nd for (_, nd) in rhs_list], cse_prelude)
    )
    function f!(du, u, p, t)
        _reject_float32_state(u)   # loud, statically-folded (see compile.jl)
        T = _rhs_value_type(u, p, t)
        # CSE prelude (ess-r7h), in its THREE CADENCE TIERS (4qf + B3, const_tier.jl):
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
            _walk_prelude_slots!(walk, cache, const_slots, cse_prelude, u, p, t, T)
            _cse_mark_const!(cse_cache, T, p)
        end

        # ---- Tier 2: TIME-cadence slots — refilled when (p, t, epoch) moved ----
        # These slots' defs read no state; they are pure functions of `p`, `t`, and
        # the CONTENTS of any live forcing buffer they gather (const_tier.jl). They
        # stay good in THIS buffer while `p` and `t` are egal to the stamp and no
        # in-place forcing refresh has bumped the build's forcing epoch — exactly what
        # `_cse_t_stale` tests. The payoff is the FD-Jacobian shape: N+1 calls at
        # the bit-same `t` with perturbed `u` evaluate the FastJX-style photolysis /
        # met-gather / w_time chains ONCE instead of N+1 times. A time def may read
        # const slots (valid or refilled above — every trigger that refills them
        # also invalidates this stamp: `p` egal is part of it, and buffer
        # replacement clears `tpalt`) and lower time slots (this loop, ascending).
        # Memoizing on `t` is safe under step rejection: the defs carry no history,
        # so revisiting a `t` reuses/recomputes the same pure function of it.
        if !isempty(time_slots) && _cse_t_stale(cse_cache, T, p, t)
            _walk_prelude_slots!(walk, cache, time_slots, cse_prelude, u, p, t, T)
            _cse_mark_t!(cse_cache, T, p, t)
        end

        # ---- Tier 3: DYNAMIC slots — refilled every call ----
        # A dynamic def may read const/time slots (valid or filled, above) and lower
        # dynamic slots (filled by this loop, which is ascending) — so every read is
        # already filled, exactly as in the single-loop prelude this replaces.
        _walk_prelude_slots!(walk, cache, dyn_slots, cse_prelude, u, p, t, T)
        _walk_scalar_rhs!(walk, du, rhs_list, u, p, t, T)

        # ---- Access kernels (the unified array IR, access_kernel.jl) ----
        # Each resolves its gathers at runtime from an access-descriptor table over
        # a strided output box — no per-lane slot vectors were built. The reduction
        # bound / connectivity are data, so one kernel covers every valence.
        # The kernel section (codegen_kernel.jl) runs the codegen-emitted kernels
        # through their compiled loop nests (any value type), then each residual
        # kernel through the eltype-generic scalar runner (or, when the Float64
        # overflow routing is armed, the compiled overflow function).
        kernel_section(du, u, p, t, T)

        # ---- Cumulative (prefix) reductions (ess-scan, scan.jl) ----
        # Each fold reads back the per-cell TERMS its own kernels just wrote
        # into `du` and accumulates them along the scanned axis in place. Runs
        # here, after the whole kernel section, so it is ordered behind every
        # threaded chunk and every codegen'd loop nest. A fused scan
        # (scan_fused.jl) computes its terms itself in the same pass. Empty on
        # every model without a forward prefix reduction, which is the common
        # case.
        isempty(scan_section) || _apply_scan_folds!(du, u, p, t, scan_section)

        # ---- Whole-array contractions (ess-array-contraction) ----
        # Each runs its own output loop nest over disjoint `du` slots, so it is
        # ordered behind the kernel section for the same reason the folds are:
        # every other section has finished writing. Empty on every model whose
        # reductions stay under the tier's length floor, which is the common case.
        isempty(array_contractions) ||
            _apply_array_contractions!(du, u, p, t, array_contractions, T)
        return nothing
    end
    return f!
end
