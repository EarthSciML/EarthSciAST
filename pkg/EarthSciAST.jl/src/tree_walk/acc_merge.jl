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

# ---- DIRECT CLASS EMISSION (per-cell scalarizer → lane-batched class kernels)
#
# The kernel-CLASS merge (oop_merge.jl) exists because the per-cell grouping
# below used to key an `interp.*` node's spec by CONTENT (`_fn_spec_hash`):
# cells calling the same function against DIFFERENT same-shape const tables
# (a `makearray` whose regions each carry their own table, indexed inside an
# equation on the per-cell path) split into one kernel PER DISTINCT TABLE —
# an O(#tables) kernel count the post-hoc merge then repaired by re-grouping
# the assembled kernels on a SHAPE key and transposing the specs into
# per-lane tables (`_Interp*LaneSpec`).
#
# Direct emission folds that repair into the emitter: the grouping signature
# keys an interp spec's SHAPE (knot count — `_direct_fn_shape_token`), so
# same-shape cells share ONE group, and `_acc_merge_nodes` mints the per-lane
# spec table AT MERGE TIME (`_direct_merge_fn_payload`) exactly as it mints an
# `_AccConstBox` for a varying literal or an `_AccStateTblBox` for a varying
# state slot. The kernel count is then grid-independent BY CONSTRUCTION — a
# class is a fact of the document (the set of distinct call SHAPES), never of
# the grid — and the post-hoc merge becomes a residual repair pass that finds
# nothing to do on kernels this emitter produced (pinned by
# test/direct_class_emission_test.jl).
#
# BIT-IDENTITY. Per lane the evaluated op sequence is byte-identical to the
# split kernel's: the lane-spec arms of every runner (`_eval_acc`, the lane
# tape's `_TC_INTERP_*_TBL`, the :oop lane evaluator, the codegen tier) select
# lane `l`'s OWN spec by the `_outs_cells` box addressing (s1=1, off=1, lane
# == cell ordinal — the same shape the post-hoc merge mints) and call the SAME
# `_interp_*_core`. Grouping coarser can only change WHICH kernel hosts a
# cell, never the scalar sequence its lane evaluates.
#
# GENERALITY VS THE MERGE'S BAIL-OUTS. The per-cell entries this emitter sees
# are compiled scalar trees: no `_NK_REDUCE` (contractions arrive unrolled as
# fixed-width `_NK_CONTRACTION`), no `_NK_SUBCALL` (templates are fused on
# this path), no `_NK_CACHED` (per-kernel CSE runs after the merge), no
# n-indexed descriptors (the merge mints only STATE_FIXED/STATE_TBL_BOX/
# CONST_BOX/ARR_FIXED/ARR_TBL_BOX), and out slots are globally unique within
# the equation (`covered` throws on a duplicate derivative) with an
# assignment scatter — so every semantic bail-out of the post-hoc merge is
# structurally unreachable here. The merge's remaining bail-outs
# (`:unvectorizable` members, fold-to-cell of a varying inv tier) were
# artifacts of merging post-hoc — needing member `_OopAccPlan`s as the table
# source, and having to relocate already-built CSE tiers. Direct emission
# needs neither: tables come from the cell nodes themselves, and
# `_build_acc_cse` runs AFTER the merge, so genuinely loop-invariant subtrees
# keep a REAL invariant tier even when the interp specs vary per lane (the
# case the merge must fold to the cell tier). The one hazard that creates is
# pinned in `_build_acc_cse` itself: a lane-spec `:fn` node is never
# classified invariant (`_acc_fn_pay_lane_varying`, access_kernel.jl), the
# scalarizer-side twin of the merge's kept-inv `nacc0` pin.
#
# Anything the shape key does not model — `Nothing` (boxed closed fn),
# `_FnTypedCoreSpec`, an unknown spec type — keeps the CONTENT/identity key
# and the rep-payload + `_check_fn_group_specs` guard byte-for-byte, so those
# groups decline to exactly today's behavior.
#
# KILL SWITCH. `ESS_DIRECT_CLASS_EMIT_DISABLE=1` restores the assemble-then-
# merge pipeline byte for byte (content-keyed signature, loud spec-mismatch
# guard) — the differential oracle. The emitter also stands down under the
# class-merge umbrella switches (`ESS_KERNEL_CLASS_MERGE_DISABLE=1` /
# `ESS_OOP_MERGE_DISABLE=1`): those mean "no lane-batched class kernels in
# this build", and a direct-emitted class kernel would violate that contract.
_direct_class_emit_disabled() =
    get(ENV, "ESS_DIRECT_CLASS_EMIT_DISABLE", "") == "1"
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
# KILL SWITCH. `ESS_CROSS_EQ_CLASS_EMIT_DISABLE=1` restores the per-equation
# emitter + repair-only pipeline byte for byte. The stage also stands down
# whenever per-equation direct emission itself is off — under
# `ESS_DIRECT_CLASS_EMIT_DISABLE=1` and under the class-merge umbrella
# switches (`_direct_class_emit_enabled` folds both in), so every existing
# oracle configuration behaves exactly as before this landed.
_cross_eq_class_emit_disabled() =
    get(ENV, "ESS_CROSS_EQ_CLASS_EMIT_DISABLE", "") == "1"
_cross_eq_class_emit_enabled() =
    !_cross_eq_class_emit_disabled() && _direct_class_emit_enabled()

# SHAPE token of a spec the direct emitter can lane-table, `nothing` for
# anything it cannot (which then keys by content/identity exactly as before).
# Mirrors `_oop_merge_fn_sig_token` (oop_merge.jl) for the scalar spec types;
# per-lane specs never appear in per-cell entries (they are minted by merges).
_direct_fn_shape_token(::Any) = nothing
_direct_fn_shape_token(s::_InterpLinearSpec) = string("L", length(s.axis))
_direct_fn_shape_token(s::_InterpBilinearSpec) =
    string("B", length(s.axis_x), "x", length(s.axis_y))
_direct_fn_shape_token(s::_InterpSearchsortedSpec) = string("S", length(s.xs))

# Same fn name + same spec type + same knot shape ⇒ the group can ride one
# per-lane spec table. Cross-type pairs are unequal by dispatch.
_direct_lane_shape_ok(::Any, ::Any) = false
_direct_lane_shape_ok(a::_InterpLinearSpec, b::_InterpLinearSpec) =
    length(a.axis) == length(b.axis)
_direct_lane_shape_ok(a::_InterpBilinearSpec, b::_InterpBilinearSpec) =
    length(a.axis_x) == length(b.axis_x) && length(a.axis_y) == length(b.axis_y)
_direct_lane_shape_ok(a::_InterpSearchsortedSpec, b::_InterpSearchsortedSpec) =
    length(a.xs) == length(b.xs)

_direct_is_lanespec(::Any) = false
_direct_is_lanespec(::_InterpLinearLaneSpec) = true
_direct_is_lanespec(::_InterpBilinearLaneSpec) = true
_direct_is_lanespec(::_InterpSearchsortedLaneSpec) = true

# Does this (pre-CSE, tree-shaped) merged spine carry a per-lane spec — i.e.
# did direct emission produce a true CLASS kernel (one the content-keyed
# pipeline would have split)? Observability only.
function _acc_spine_has_lanespec(n::_Node)
    if n.kind === _NK_OP && n.op === :fn
        pl = n.payload
        pl isa Tuple && length(pl) >= 2 && _direct_is_lanespec(pl[2]) && return true
    end
    return any(_acc_spine_has_lanespec, n.children)
end

# Merged payload for one aligned per-cell `:fn` group under direct emission
# (each cell is exactly ONE lane, in group cell order). Content-equal specs
# ride the representative's payload — byte-for-byte the pre-direct behavior.
# Varying specs whose (name, type, shape) agree — guaranteed by the shape-
# keyed signature — transpose into a per-lane spec table with `_outs_cells`
# addressing (1,0,0,1): the interp analog of the varying-literal
# `_AccConstBox` right above it in `_acc_merge_nodes`. Anything else reaching
# here is a grouping-invariant break and fails LOUDLY through
# `_check_fn_group_specs` — never silent wrong numbers. The `_Interp*LaneSpec`
# outer constructors intern their `.specs` through the build-scoped lane pool,
# same as the post-hoc merge's mints.
function _direct_merge_fn_payload(nodes::Vector{_Node})
    m = length(nodes)
    fname1, spec1 = (nodes[1].payload)::Tuple{String,Any}
    varying = false
    @inbounds for k in 2:m
        fnamek, speck = (nodes[k].payload)::Tuple{String,Any}
        if !(fnamek == fname1 &&
             (speck === spec1 || _fn_spec_content_equal(speck, spec1)))
            varying = true
            break
        end
    end
    varying || return nodes[1].payload
    ok = spec1 isa _InterpLinearSpec || spec1 isa _InterpBilinearSpec ||
         spec1 isa _InterpSearchsortedSpec
    if ok
        @inbounds for k in 2:m
            fnamek, speck = (nodes[k].payload)::Tuple{String,Any}
            if !(fnamek == fname1 && _direct_lane_shape_ok(spec1, speck))
                ok = false
                break
            end
        end
    end
    if ok
        if spec1 isa _InterpLinearSpec
            specs = _InterpLinearSpec[((nodes[k].payload)::Tuple{String,Any})[2]
                                      for k in 1:m]
            return (fname1, _InterpLinearLaneSpec(specs, 1, 0, 0, 1))
        elseif spec1 isa _InterpBilinearSpec
            specs = _InterpBilinearSpec[((nodes[k].payload)::Tuple{String,Any})[2]
                                        for k in 1:m]
            return (fname1, _InterpBilinearLaneSpec(specs, 1, 0, 0, 1))
        else # _InterpSearchsortedSpec
            specs = _InterpSearchsortedSpec[((nodes[k].payload)::Tuple{String,Any})[2]
                                            for k in 1:m]
            return (fname1, _InterpSearchsortedLaneSpec(specs, 1, 0, 0, 1))
        end
    end
    _check_fn_group_specs(nodes)   # loud: grouping-invariant break
    return nodes[1].payload        # unreachable — the guard throws on mismatch
end


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
#
# `direct` (direct class emission, see the section above): key a lane-tablable
# interp spec's SHAPE instead of its content, so same-shape cells share one
# group and the merge mints a per-lane spec table. `false` (the 2-arg form and
# the kill-switch path) emits byte-for-byte the content-keyed signature.
_struct_sig!(io::IOBuffer, n::_Node) = _struct_sig!(io, n, false)
function _struct_sig!(io::IOBuffer, n::_Node, direct::Bool)
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
        _sig_children!(io, n.children, direct)
        print(io, ')')
    elseif k === _NK_CONTRACTION_LOOP || k === _NK_LOOPVAR
        # Defensive: a runtime contraction loop (ess-runtime-contraction) is
        # CONFINED to scalar contexts and never reaches the array-equation merge.
        # Should one ever arrive, key it by object identity so DISTINCT loops can
        # never be wrongly merged into one kernel (fail-safe: no merge, not a
        # silent miscompile). The access-plan builder then declines it
        # (`_AccPlanDecline`) and the cell falls back to the per-cell scalar walk.
        print(io, "CL:", objectid(n))
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
            #
            # Under DIRECT CLASS EMISSION the interp families key their SHAPE
            # instead (`_direct_fn_shape_token`): same-shape different-content
            # cells then share one group whose merged node carries a per-lane
            # spec table (`_direct_merge_fn_payload`) — each lane still reads
            # ITS OWN table, so the hazard the content key excluded stays
            # excluded, by tabling instead of splitting. Non-interp payloads
            # (boxed fn / typed core / unknown spec) keep the content key and
            # the loud `_check_fn_group_specs` guard byte-for-byte.
            tok = direct ? _direct_fn_shape_token(pl[2]) : nothing
            if tok === nothing
                print(io, '@', pl[1], '#', _fn_spec_hash(pl[2]))
            else
                print(io, '@', pl[1], '#', tok)
            end
        elseif pl isa Tuple && length(pl) >= 1
            print(io, '@', pl[1])
        end
        print(io, '(')
        _sig_children!(io, n.children, direct)
        print(io, ')')
    end
    return io
end

_sig_children!(io::IOBuffer, children) = _sig_children!(io, children, false)
function _sig_children!(io::IOBuffer, children, direct::Bool)
    first = true
    for ch in children
        first || print(io, ',')
        first = false
        _struct_sig!(io, ch, direct)
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
_fn_spec_hash(::Nothing) = UInt(0)                      # boxed all-scalar fn
_fn_spec_hash(s::_InterpLinearSpec) = hash(s.axis, hash(s.table, UInt(0x11)))
_fn_spec_hash(s::_InterpBilinearSpec) =
    hash(s.axis_y, hash(s.axis_x, hash(s.table, UInt(0x22))))
_fn_spec_hash(s::_InterpSearchsortedSpec) = hash(s.xs, UInt(0x33))
# A typed-core spec's content IS its two ints (`_fn_typed_core_spec` mints it
# deterministically from the fname), so same-name nodes always content-match —
# the payload analog of the `Nothing` it replaced (ess-dtcore).
_fn_spec_hash(s::_FnTypedCoreSpec) = hash(s.arity, hash(s.id, UInt(0x77)))
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
_fn_spec_content_equal(a::_FnTypedCoreSpec, b::_FnTypedCoreSpec) =
    a.id == b.id && a.arity == b.arity

# ---- Lane-table interning (build-scoped) -------------------------------------
#
# `_compile_fn_node` mints a fresh `_Interp*Spec` per SOURCE `fn` node, so two
# calls over content-equal const tables routinely hold DISTINCT spec objects
# (AST interning catches structurally identical const spellings, but not e.g.
# `[1, 2]` vs `[1.0, 2.0]`, distinct-but-equal const vectors, or template-
# manufactured copies). Everything downstream already keys those by CONTENT
# (`_struct_sig!`, `_AccFnPayKey`, xcse) — the objects just stayed distinct, so
# a merged kernel's `_Interp*LaneSpec.specs` vector carries one table copy per
# content-twin and every backend re-discovers the sharing (the Reactant ext
# groups lanes by `isequal` at trace time).
#
# The pool below makes content-equal specs the SAME object (`===`) at BUILD
# time instead: every mint (`_build_interp_spec`) and every collection into a
# lane-spec `.specs` vector (the `_Interp*LaneSpec` outer constructors) routes
# through `_lane_intern`, which returns the pool's canonical object for the
# content. Keying mirrors `_AccFnPayKey`'s hash-then-confirm posture over the
# SAME matched (`_fn_spec_hash`, `_fn_spec_content_equal`) pair the merge guard
# trusts: the Dict confirms `isequal` after the hash bucket, so a hash
# collision degrades to a missed share (a duplicate object), never to aliasing
# two different tables. `isequal` semantics are bitwise per element (NaN
# unifies with NaN, `-0.0` stays apart from `0.0`), so canonicalization can
# never swap a signed zero between tables. Content-equal tables are
# interchangeable by the same argument that justifies `_AccFnPayKey` — every
# admitted closed function is a pure function of (spec, scalar args) — so any
# identity-keyed consumer (`_cg_tab!`'s table memo, `objectid` fallbacks) can
# only MERGE MORE, never confuse two different tables.
#
# The pool is BUILD-SCOPED: `_build_evaluator_impl` installs a fresh Dict for
# the duration of one build (saving/restoring any outer pool, so nested builds
# stay correct) and clears it after, so canonical objects never leak across
# builds and the pool cannot grow without bound. Outside a build the ref is
# `nothing` and `_lane_intern` is the identity — direct constructor use (tests,
# tooling) sees exactly the pre-interning behavior.
#
# Kill switch: `ESS_LANE_INTERN_DISABLE=1` (read at build entry, like
# `ESS_STENCIL_DISABLE`) keeps the ref `nothing` for the whole build, restoring
# today's un-interned build byte for byte — the differential oracle
# (test/lane_table_intern_test.jl).
_lane_intern_disabled() = get(ENV, "ESS_LANE_INTERN_DISABLE", "") == "1"

struct _LaneInternKey
    spec::Any
end
Base.hash(k::_LaneInternKey, h::UInt) = hash(_fn_spec_hash(k.spec), h)
Base.isequal(a::_LaneInternKey, b::_LaneInternKey) =
    _fn_spec_content_equal(a.spec, b.spec)
Base.:(==)(a::_LaneInternKey, b::_LaneInternKey) = isequal(a, b)

const _LANE_INTERN_POOL =
    Base.RefValue{Union{Nothing,Dict{_LaneInternKey,Any}}}(nothing)

# The closed set of spec types the pool canonicalizes — exactly the types
# `_fn_spec_hash`/`_fn_spec_content_equal` content-model AND whose tables are
# worth sharing. `_FnTypedCoreSpec`/`Nothing` carry no table (nothing to
# share); an unknown spec type falls through untouched (its content pair keys
# by identity anyway, so pooling it would be a no-op that still paid the hash).
_lane_internable(::_InterpLinearSpec) = true
_lane_internable(::_InterpBilinearSpec) = true
_lane_internable(::_InterpSearchsortedSpec) = true
_lane_internable(::Any) = false

@inline function _lane_intern(spec)
    _lane_internable(spec) || return spec
    pool = _LANE_INTERN_POOL[]
    pool === nothing && return spec
    return get!(pool, _LaneInternKey(spec), spec)::typeof(spec)
end

# Canonicalize one lane-spec `.specs` vector: content-equal lanes come out
# holding the SAME (`===`) spec object. Identity (the very vector, untouched)
# whenever the pool is off — the `_Interp*LaneSpec` constructors then store
# exactly what they were handed, today's build.
function _lane_intern_specs(specs::Vector{S}) where {S}
    _LANE_INTERN_POOL[] === nothing && return specs
    return S[_lane_intern(s) for s in specs]
end

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
#
# `direct` (direct class emission): a `:fn` group whose same-shape specs VARY
# in content becomes a per-lane spec table (`_direct_merge_fn_payload`) — the
# interp analog of the varying-literal `_AccConstBox` — instead of a build
# error. The 3-arg form (white-box tests, kill-switch path) keeps today's
# content-equal-or-throw contract byte for byte.
_acc_merge_nodes(nodes::Vector{_Node}, len::Int, acc::Vector{_AccDesc})::_Node =
    _acc_merge_nodes(nodes, len, acc, false)
function _acc_merge_nodes(nodes::Vector{_Node}, len::Int,
                          acc::Vector{_AccDesc}, direct::Bool)::_Node
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
        ch = _Node[_acc_merge_nodes(_Node[nd.children[c] for nd in nodes], len,
                                    acc, direct)
                   for c in 1:m]
        return _mknode(kind=_NK_CONTRACTION, op=n1.op, literal=n1.literal,
                       children=ch)
    else  # _NK_OP / fn
        pay = n1.payload
        if n1.op === :fn
            if direct
                pay = _direct_merge_fn_payload(nodes)
            else
                _check_fn_group_specs(nodes)
            end
        end
        m = length(n1.children)
        ch = _Node[_acc_merge_nodes(_Node[nd.children[c] for nd in nodes], len,
                                    acc, direct)
                   for c in 1:m]
        return _mknode(kind=_NK_OP, op=n1.op, payload=pay, children=ch)
    end
end

# Group an array equation's per-cell `(du_slot, node)` entries by structure and
# build one indirect-outs `_AccKernel` per group, in first-seen group order —
# deterministic kernel boundaries, lane order, and out-slot order.
function _acc_from_cell_entries(entries::Vector{Tuple{Int,_Node}})::Vector{_AccKernel}
    isempty(entries) && return _AccKernel[]
    # Direct class emission (see the section above `_direct_class_emit_disabled`):
    # group by SHAPE-keyed signature and mint per-lane spec tables at merge
    # time, so the kernel count is grid-independent by construction. Disabled
    # (or under the class-merge umbrella switches) this is byte-for-byte the
    # content-keyed assemble-then-merge front half.
    direct = _direct_class_emit_enabled()
    order = String[]
    groups = Dict{String,Tuple{Vector{Int},Vector{_Node}}}()
    sigbuf = IOBuffer()
    for (slot, node) in entries
        sig = String(take!(_struct_sig!(sigbuf, node, direct)))
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
        spine = _acc_merge_nodes(nds, len, acc, direct)
        # Observability (test/direct_class_emission_test.jl): one bump per
        # emitted kernel that carries a per-lane spec table — a TRUE class
        # kernel the content-keyed pipeline would have split and the post-hoc
        # merge would have had to repair. Grid-independent (a per-group fact).
        direct && _acc_spine_has_lanespec(spine) &&
            _tally_cascade!(:direct_class_kernel)
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
                   time_slots::AbstractVector{Int},
                   dyn_slots::AbstractVector{Int},
                   scan_folds::AbstractVector{_ScanFold}=_ScanFold[])
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
    # Since the kernel-CLASS merge hoisted into build.jl, `acc_kernels` here is the
    # POST-merge list, so the tally reflects exactly the kernels a `:oop` build of
    # the same model would plan — which is the point of the probe.
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
            @inbounds for i in eachindex(const_slots)
                s = const_slots[i]
                cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
            end
            _cse_mark_const!(cse_cache, T, p)
        end

        # ---- Tier 2: TIME-cadence slots — refilled when (p, t, epoch) moved ----
        # These slots' defs read no state; they are pure functions of `p`, `t`, and
        # the CONTENTS of any live forcing buffer they gather (const_tier.jl). They
        # stay good in THIS buffer while `p` and `t` are egal to the stamp and no
        # in-place forcing refresh has bumped `_FORCING_EPOCH` — exactly what
        # `_cse_t_stale` tests. The payoff is the FD-Jacobian shape: N+1 calls at
        # the bit-same `t` with perturbed `u` evaluate the FastJX-style photolysis /
        # met-gather / w_time chains ONCE instead of N+1 times. A time def may read
        # const slots (valid or refilled above — every trigger that refills them
        # also invalidates this stamp: `p` egal is part of it, and buffer
        # replacement clears `tpalt`) and lower time slots (this loop, ascending).
        # Memoizing on `t` is safe under step rejection: the defs carry no history,
        # so revisiting a `t` reuses/recomputes the same pure function of it.
        if !isempty(time_slots) && _cse_t_stale(cse_cache, T, p, t)
            @inbounds for i in eachindex(time_slots)
                s = time_slots[i]
                cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
            end
            _cse_mark_t!(cse_cache, T, p, t)
        end

        # ---- Tier 3: DYNAMIC slots — refilled every call ----
        # A dynamic def may read const/time slots (valid or filled, above) and lower
        # dynamic slots (filled by this loop, which is ascending) — so every read is
        # already filled, exactly as in the single-loop prelude this replaces.
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

        # ---- Cumulative (prefix) reductions (ess-scan, scan.jl) ----
        # Each fold reads back the per-cell TERMS its own kernels just wrote
        # into `du` and accumulates them along the scanned axis in place. Runs
        # here, after the whole kernel section, so it is ordered behind every
        # threaded chunk and every codegen'd loop nest. Empty on every model
        # without a forward prefix reduction, which is the common case.
        isempty(scan_folds) || _apply_scan_folds!(du, scan_folds)
        return nothing
    end
    return f!
end
