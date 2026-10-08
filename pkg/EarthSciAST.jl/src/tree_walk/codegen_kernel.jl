# ========================================================================
# tree_walk/codegen_kernel.jl — the Julia CODEGEN tier for access kernels
# (perf-gap-closure plan, item B1).
#
# The scalar access-kernel runner (`_run_acc_kernel!`, access_kernel.jl) walks
# the spine `_Node` tree once per cell: one dynamic kind/op dispatch per node
# per cell per RHS call. This tier removes that interpretation entirely where
# it can: at `build_evaluator` time each `_AccKernel` is EMITTED as Julia
# source — the kernel's exact per-box loop nest with the spine as a
# straight-line expression using direct indexing (`u[oln + Δ]`, literal
# strides/offsets baked in) — and every emitted kernel is fused into ONE
# function compiled once via RuntimeGeneratedFunctions.jl.
#
# BIT-EXACTNESS IS THE CONTRACT. The emitter mirrors `_eval_acc` /
# `_eval_acc_op` (and through them `_eval_node_op`) operation for operation:
#   * same operand order and the same LEFT-nested fold for n-ary `+`/`*`/
#     `min`/`max` (`((c1 ⊕ c2) ⊕ c3)…`), the same 0̄-seeded fold for
#     `_NK_CONTRACTION`/`_NK_REDUCE` (`((0̄ ⊕ c1) ⊕ c2)…`);
#   * NO `@simd`, NO `@fastmath`, NO `muladd`, NO reassociation of any kind
#     (`@inbounds` only — indices were validated at build);
#   * LAZY guard semantics preserved verbatim: `ifelse` emits a ternary (only
#     the taken branch evaluates), `and`/`or` emit `&&`/`||` chains with the
#     interpreter's exact `== 0`/`!= 0` tests and `1.0`/`0.0` results;
#   * leaves keep their native types (a literal stays `Float64`, so `x ^ 2.0`
#     lands on `Dual^Float64` under AD exactly as the walker's leaf discipline
#     guarantees); CSE slot values convert to `T` exactly where the
#     interpreter's `buf[i] = …` store does;
#   * `fn` nodes call the SAME functions the interpreter calls
#     (`_interp_*_core` with the node's typed `_Interp*Spec` — or, for the
#     per-lane `_Interp*LaneSpec` tables the kernel-class merge mints, the
#     member spec selected by the interpreter's exact `_interp_lane` box
#     addressing — boxed `_eval_closed_fn` for `datetime.*`) — interpolation
#     is not reimplemented.
#
# ELTYPE-GENERIC: the emitted function derives `T = _rhs_value_type(u, p, t)`
# exactly as the interpreter does, so the SAME generated code integrates at
# Float64 and differentiates under ForwardDiff `Dual` (state or parameters).
#
# FALLBACK CONTRACT: anything the emitter cannot model — an unknown node kind
# or descriptor, a foreign CSE scratch (except the build's own shared
# scalar-prelude cache, which since ess-cgfsc is emitted as the interpreter's
# `_cse_read`; see the tier note below), an oversized spine —
# declines THAT kernel silently (`_CodegenDecline`); the kernel keeps the
# per-cell interpreter (`_run_acc_kernel!`, eltype-generic). Declines are
# counted per reason in `_CASCADE_TALLY` (`:codegen_kernel` /
# `:codegen_decline_<reason>`), the `_tally_cascade!` pattern.
#
# GENERATED CODE NEVER TOUCHES INTERPRETER STATE: CSE/invariant slots become
# SSA-style locals, never writes into the kernel's `_AccScratch` buffers — so
# an emitted kernel and an interpreted one coexist within one RHS call.
#
# With the tier off (`compiler=:interpreter`) BOTH generated functions (primary
# and overflow) stand down and every kernel runs the per-cell interpreter: that
# is the differential oracle, slower but bit-identical by the emitter's
# contract.
# Budget: ESS_CODEGEN_NODE_BUDGET overrides the emitted-node cap (default
# 64_000_000 across all kernels of one build) that backstops a runaway build.
#
# TEMPLATE SUB-KERNELS COMPILE ONCE (ess-cg-subcall-fn, OPT-IN via
# ESS_CG_SUBCALL_FN=1): a `_NK_SUBCALL` body is emitted into ONE top-level
# `@noinline` function (structurally deduped across sub-kernels that differ
# only in descriptor constants) and every site becomes a call — see
# `_cg_emit_subcall` / `_cg_cell_fn!` and the default-off rationale at
# `_cg_subcall_fn_disabled`. ESS_CG_SUBCALL_FN_MIN_NODES sets the stay-inline
# size floor.
# ========================================================================

_codegen_disabled() = !_compiler_plan_now().codegen
# CUMULATIVE emitted-node budget across all kernels in one build call — a
# build-latency backstop, NOT a per-function compile bound (the intra-kernel
# split, ess-iip-split, handles that: every generated function stays under
# `_codegen_fn_node_cap` regardless of a kernel's total size). Since a kernel
# that exceeds this used to DECLINE to the interpreter — which is forbidden
# (runtime speed is critical) — the default is high enough that realistic
# models always emit fully; it only backstops a runaway. The duo LMARS `:inplace`
# state RHS is ~1.5e6 nodes (13 spine-dominated momentum kernels, ~1.1e5–1.6e5
# each); the AST build of that is ~3 GB and cheap. Override with
# ESS_CODEGEN_NODE_BUDGET — a REFUSAL BOUNDARY under `native`, since a kernel
# past it that the overflow emission also declines is a refused rule, not a
# quiet demotion.
_codegen_node_budget() =
    something(tryparse(Int, get(ENV, "ESS_CODEGEN_NODE_BUDGET", "")), 64_000_000)

# Emitted-node size of a kernel: its spine, both CSE recipe tiers, and
# (recursively) every template sub-kernel it inlines. A sub-kernel shared by
# several parents is counted once per parent.
_cg_node_tree_size(n::_Node) = 1 + sum(_cg_node_tree_size, n.children; init=0)
function _cg_kernel_node_size(K::_AccKernel)
    s = _cg_node_tree_size(K.spine)
    for r in K.cse.recipes;     s += _cg_node_tree_size(r); end
    for r in K.cse.inv_recipes; s += _cg_node_tree_size(r); end
    for sub in K.subs;          s += _cg_kernel_node_size(sub); end
    return s
end

# ---- Dual overflow tier (ess-dualfp) ----------------------------------------
# Kernels the primary emission declines — in practice on the node BUDGET, which
# exists to bound Float64 build latency — used to drop to the per-cell
# interpreter `_run_acc_kernel!` under non-Float64 `T` (ForwardDiff `Dual` in a
# stiff-solver Jacobian). The dual overflow tier re-emits those residual
# kernels into a SECOND generated function with its own (default unbounded)
# budget. Under non-Float64 `T` it is called unconditionally, so its
# native-compile cost is paid at the first Dual call.
# (Since ess-f64ofl, below, the same function also serves Float64 calls when
# the Float64 overflow routing is armed.)
# Off, the routing is the pre-dual one; the tier is also off under
# `compiler=:interpreter`, which disables codegen wholesale, so the oracle stays
# a pure interpreter build.
# Budget: ESS_DUAL_CODEGEN_NODE_BUDGET overrides the overflow emission budget
# (default unbounded — per-function size is still capped by
# ESS_CODEGEN_FN_NODE_CAP chunking, which is what bounds LLVM memory). It is a
# REFUSAL BOUNDARY under `native`: this is the emission whose decline is what
# leaves a tree walk in the right-hand side.
# Build tally: `:dual_codegen_kernel` / `:dual_codegen_decline_<reason>` in
# `_CASCADE_TALLY` — the observability hook for which tier Dual evaluation uses.
_dual_codegen_disabled() = !_compiler_plan_now().dual_codegen
_dual_codegen_node_budget() =
    something(tryparse(Int, get(ENV, "ESS_DUAL_CODEGEN_NODE_BUDGET", "")), typemax(Int))

# ---- Float64 overflow routing (ess-f64ofl) ----------------------------------
# The SAME overflow generated function, called at Float64 too — so a
# budget-declined kernel runs compiled code, like every other kernel. The
# overflow RGF is eltype-generic and its emission is already paid at build (a
# few ms); what this routing adds is the residual kernels' NATIVE compile at the
# first Float64 call — roughly linear in emitted nodes, the per-function
# `ESS_CODEGEN_FN_NODE_CAP` chunking being what keeps it linear, and the same
# latency a Dual caller already pays at its first call. With more than one
# thread, the overflow RGF runs CHUNKED on its own threaded cell axis (see
# "Threaded cell axis for the codegen tier" below).
#
# Off, every residual Float64 kernel routes to the per-cell interpreter
# instead — the differential oracle for this routing.
# Kernels even the overflow emission declines (`dual_resid`) keep the
# interpreter at Float64.
# The routing is inert unless the PRIMARY emission declined something and the
# overflow function exists, so turning the overflow tier off turns this off
# too. On every model within the primary budget — all repo fixtures — nothing
# changes at all.
# Build tally: `:f64_overflow_armed` when a section is built with the routing
# armed (overflow function present + feature on).
_f64_overflow_codegen_enabled() = _compiler_plan_now().f64_overflow

# ---- Shared-prelude (xcse) cache reads (ess-cgfsc) ---------------------------
# The cross-kernel fn-CSE pass (xcse.jl, plan B4) rewrites kernel invariant-tier
# defs into bare `_NK_CACHED` reads of the build's SCALAR prelude cache — a
# `_CSECache` payload that is no kernel's scratch. The emitter used to decline
# every such kernel (`:foreign_scratch`), dropping it to the interpreter.
# This tier emits the read instead, as the very call the interpreter makes
# (`_cse_read(cache, idx, T)` — eltype-generic, so the Float64 AND the Dual
# specialization of the generated code read the same buffer the interpreter
# would: `f64` at Float64, the lazily-allocated `alt::Vector{T}` otherwise).
#
# FILL-ORDERING SOUNDNESS. Acceptance is gated on IDENTITY with the one cache
# the build threads in (`shared_cache` below): `_make_rhs` fills every prelude
# tier (const/time/dynamic) into that exact cache — for the SAME value type `T`
# the kernel section is about to run at — before `kernel_section(du,u,p,t,T)`
# is called, in the same `f!` body (acc_merge.jl). Both generated functions
# (primary and dual/f64 overflow) are only ever invoked from inside that
# section, so every accepted read lands on a slot filled this call. Call sites
# that cannot pin that ordering (the materialized-observed fill sections in
# build.jl, hand-built test sections) pass `shared_cache = nothing` and keep
# today's decline — as does ANY payload that is not that one cache object.
#
# Off, every such read is an unconditional `:foreign_scratch` decline.
# Build tally: `:cg_foreign_scratch_emit` — one bump per kernel that COMPILED
# carrying at least one shared-prelude read (primary or overflow emission; a
# kernel that later declines for another reason is not counted).
_cg_foreign_scratch_disabled() = !_compiler_plan_now().cg_foreign_scratch

# Per-kernel decline: the kernel keeps the per-cell interpreter runner.
# Never an error — the tier is a pure optimization.
struct _CodegenDecline <: EarthSciASTError
    reason::Symbol
end

# ---- Emission context (one per generated function) --------------------------
mutable struct _CGCtx
    # Runtime objects the generated code needs (const arrays, connectivity /
    # valence tables, interp specs, outs vectors), GROUPED BY CONCRETE TYPE into
    # homogeneous containers (ess-iip-tabgroup). The generated code indexes a
    # concrete-element container — `_cggrpG[pos]` — so its element type infers in
    # O(1); the runtime `tabs` argument is a small tuple of those containers, one
    # per distinct type. This replaces a per-object heterogeneous N-tuple whose
    # TYPE alone made inference super-linear: the duo LMARS momentum RHS registers
    # ~2.5e5 tabs, EVERY one a `Vector{Int}`; as `Tuple{Vector{Int},…×2.5e5}` it
    # drove the split helpers' compile to ~850 s, as one `Vector{Vector{Int}}` it
    # is cheap. `tab_types[g]` is group g's element type, `tab_objs[g]` its objects
    # (deduped by identity via `tabid` → (group, position)).
    tab_types::Vector{DataType}
    tab_objs::Vector{Vector{Any}}
    tabid::IdDict{Any,Tuple{Int,Int}}
    # Invariant-slot local names per kernel object (parent or sub), filled by
    # prologue statements in `_run_acc_kernel!`'s nested-first order. Values
    # are recomputed-identical across sharing parents, so one fill suffices.
    invdone::IdDict{Any,Vector{Symbol}}
    invlog::Vector{Any}          # registration order, for decline rollback
    prologue::Vector{Any}        # invariant-fill statements
    nodes::Int                   # emitted-node tally (budget enforcement)
    budget::Int
    nname::Int                   # unique-name counter
    # Shared-prelude cache reads (ess-cgfsc): the ONE `_CSECache` whose
    # `_NK_CACHED` reads may be emitted (`nothing` ⇒ decline as before), and a
    # per-build count of reads emitted (tally bookkeeping in the build loop).
    shared_cache::Union{Nothing,_CSECache}
    fscratch::Int
    # Intra-kernel split (ess-iip-split): top-level `@noinline` helper defs a
    # large kernel's body was partitioned into. Spliced ahead of the chunk
    # sub-functions so both call them by name; each captures nothing (params
    # only), so the RHS stays allocation-free.
    helpers::Vector{Any}
    # Helper dedup (ess-iip-helper-dedup): identical spilled bodies (same code —
    # the momentum spine bears LAZY nodes, so scalar CSE was skipped and its
    # redundant sub-expressions reach codegen un-shared) collapse to ONE compiled
    # `@noinline`, still called per occurrence. Body string → the helper name it
    # was first minted as. Reset per kernel so a declined kernel's rolled-back
    # helpers are never referenced (dedup scope is one kernel — where the
    # redundancy is; distinct kernels are distinct equations).
    # In the by-value transport (`_cg_split_by_value`) the stored value is the
    # `_cgfns[k]` INDEX EXPRESSION rather than a name, so the field is `Any`.
    helper_dedup::Dict{String,Any}
    # Sub-kernel function memo (ess-cg-subcall-fn): sub-`_AccKernel` → the
    # `@noinline` function serving its body, as `(fname, extra_params,
    # int_consts::Vector{Int}, flt_consts::Vector{Float64})`, or `:inline` for
    # a body under the size floor (kept inlined per site, the pre-tier
    # emission). CROSS-kernel, like `invdone` — a sub-kernel shared by several
    # parents compiles once and every site calls it — with `sublog` mirroring
    # `invlog` so a declined kernel's entries roll back (their function defs
    # are discarded from `helpers` by the same rollback).
    subfn::IdDict{Any,Any}
    sublog::Vector{Any}
    # STRUCTURAL dedup across distinct sub-kernels (ess-cg-subcall-struct): the
    # canonical body text (locals positionally renamed, every Int/Float64
    # literal lifted into the per-instance constant vectors, invariant slots
    # read through the `_cgivt` tuple argument) → the one compiled function.
    # Two `_AccKernel`s that differ only in descriptor CONTENT — the same
    # physics template applied at two offsets, or in two region classes —
    # canonicalize to the same text and share one LLVM compile; each call site
    # passes its own constants. `substruct_log` mirrors `sublog` for rollback.
    substruct::Dict{String,Tuple{Symbol,Vector{Symbol}}}
    substruct_log::Vector{String}
    # True while emitting a sub-kernel body: `_NK_CACHED` invariant reads emit
    # `_cgivt[idx]` (the tuple argument) instead of a prologue local name.
    subivt::Bool
    # Run-time geometry (see "Geometry as data" below): the integers the emitted
    # loops read instead of literals, one tab object for the whole function;
    # `geosink` is the statement list the `local` that reads each one goes
    # into (the current kernel's block, or the invariant prologue), and
    # `geomemo` names one local per geometry field within that list.
    geo::Vector{Int}
    geosink::Vector{Any}
    geomemo::IdDict{Any,Symbol}
    # Set when a fetch reads the state through a slot table (`_cg_tabh!`); the
    # loop nests read and clear it to keep such a loop scalar (`_cg_tblread!`).
    tblread::Bool
    # Slot-table reads and their two emitted versions (`_cg_tbl_versions`):
    # `tblaffine` emits every `_AK_STATE_TBL_BOX` read as its run form, and
    # `tblcbs` collects the run-mode locals the version guard tests.
    tblaffine::Bool
    tblcbs::Vector{Symbol}
    # A fused prefix scan's nest (scan_fused.jl): `nothing`, or the names and
    # rule its loop body folds each cell's term with — `(acc, a, b, op,
    # inclusive)`, the nest running ordinals `[a, b)` (one lane).
    scanmode::Any
    # Two-buffer addressing (`_ObsSplitVec`, build.jl): the state length of the
    # slot space the section runs on, or 0 for one plain vector. With `nst > 0`
    # each state read is emitted against the buffer its slots live in
    # (`_cg_side`); `olnext` holds the output-slot extent of every kernel whose
    # loop nest binds `oln` (an affine read's slots are `oln + delta`),
    # `subks` the sub-kernels emitted with a parent's `oln`, and `sidememo`
    # the slot extent of each slot table already scanned.
    nst::Int
    olnext::IdDict{Any,Tuple{Int,Int}}
    subks::IdDict{Any,Bool}
    sidememo::IdDict{Any,Tuple{Int,Int}}
    # A fused scan's consumer body (scan_fused.jl): `nothing`, or `(K, ix, v)`
    # — kernel `K`'s descriptor `ix` reads as the local `v`.
    subst::Any
end
_CGCtx(budget::Int, shared_cache::Union{Nothing,_CSECache}=nothing; nst::Int=0) =
    _CGCtx(DataType[], Vector{Any}[], IdDict{Any,Tuple{Int,Int}}(),
           IdDict{Any,Vector{Symbol}}(),
           Any[], Any[], 0, budget, 0, shared_cache, 0, Any[], Dict{String,Any}(),
           IdDict{Any,Any}(), Any[],
           Dict{String,Tuple{Symbol,Vector{Symbol}}}(), String[], false,
           Int[], Any[], IdDict{Any,Symbol}(), false, false, Symbol[], nothing,
           nst, IdDict{Any,Tuple{Int,Int}}(), IdDict{Any,Bool}(),
           IdDict{Any,Tuple{Int,Int}}(), nothing)

_cg_helper_dedup_disabled() = !_compiler_plan_now().cg_helper_dedup

# Sub-kernel / cell-body function tier (ess-cg-subcall-fn). EXPERIMENTAL, and
# it ships OFF: `ESS_CG_SUBCALL_FN=1` is the one `ESS_*` variable that turns it
# on. It is not an oracle selector — no tier stands down when it is unset, the
# tier simply does not exist in the default build. Measured on the duo LMARS RHS (2026-08-28) the
# tier is value-exact and shares real structure (94/120 sub-bodies dedup), but
# the emitted-node total is unchanged — the mass is ~28 near-identical cell
# bodies fragmented per region class by value-dependent boundary folds, which
# no post-fold canonicalization can soundly unify — and first-call compile
# memory goes UP (38+ GB vs 32.6 GB) from the added function boundaries. Until
# the duo rules gather affinely over shared cell sets (where this tier's
# sharing actually lands), the fused emission is the better default.
_cg_subcall_fn_disabled() = get(ENV, "ESS_CG_SUBCALL_FN", "") != "1"

# Bodies at or under this emitted-node floor stay inlined per site: a leaf
# template of a handful of nodes is cheaper re-emitted than behind a `@noinline`
# call per cell per site. Override with ESS_CG_SUBCALL_FN_MIN_NODES — a refusal
# boundary under `native` while the tier above it is opted in, since it decides
# which bodies the emitter is asked to carve out.
_cg_subcall_fn_min_nodes() =
    something(tryparse(Int, get(ENV, "ESS_CG_SUBCALL_FN_MIN_NODES", "")), 64)

_cg_name(ctx::_CGCtx, base::String) = Symbol("_cg", base, ctx.nname += 1)

# The local that holds group `g`'s homogeneous tab container (`_cggrpG`).
_cg_grp_sym(g::Int) = Symbol("_cggrp", g)

@inline function _cg_budget!(ctx::_CGCtx)
    ctx.nodes += 1
    ctx.nodes > ctx.budget && throw(_CodegenDecline(:budget))
    return nothing
end

# Register a runtime object; returns the indexing expression `_cggrpG[pos]` into
# its by-type container (ess-iip-tabgroup). Deduped by identity; a new object is
# appended to the container for its concrete type (a new group if that type is
# unseen). The returned `_cggrpG[pos]` reads a CONCRETE-element container, so its
# element type infers in O(1) — the whole point of grouping.
function _cg_tab!(ctx::_CGCtx, obj)
    got = get(ctx.tabid, obj, nothing)
    got !== nothing && return :($(_cg_grp_sym(got[1]))[$(got[2])])
    T = typeof(obj)
    g = findfirst(==(T), ctx.tab_types)
    if g === nothing
        push!(ctx.tab_types, T); push!(ctx.tab_objs, Any[])
        g = length(ctx.tab_types)
    end
    push!(ctx.tab_objs[g], obj)
    pos = length(ctx.tab_objs[g])
    ctx.tabid[obj] = (g, pos)
    return :($(_cg_grp_sym(g))[$pos])
end

# ---- Geometry as data --------------------------------------------------------
# A box's bounds, base slot and strides, a stencil's slot offsets, a cell count,
# a fixed slot: every integer that says WHERE a kernel reads and writes is a
# function of the grid size, and a literal of it would make every N a different
# generated function, each paying its own Julia compile. So the emitter writes
# them as locals read from one `Vector{Int}` tab (`ctx.geo`), hoisted ahead of
# the loops that use them: two documents that differ only in N emit the same
# expression, and RuntimeGeneratedFunctions (which keys a function on its
# expression) compiles it once. The integer arithmetic is the same either way,
# and no floating-point value moves, so the result is bit-identical.
#
# What stays a literal: a stride or slot offset of 0, 1 or -1 (`unit = true`),
# which the loops need to see — a zero stride drops its term, and a unit one is
# what lets the compiler see a contiguous run — and which is the same at every
# N (the leading axis's stride and neighbour offset; any other axis has a unit
# stride only on a grid one cell wide). Bounds, bases and fixed slots are data
# even when they are 1. So are extents and cell counts, except a boundary slab's
# (`_CellSet.slab`), which is one cell thick at every N.
# Everything inside a structural sub-kernel body (`ctx.subivt`) stays literal,
# since `_cg_abstract!` already lifts its literals into per-instance data.
#
# `key` (optional) names the geometry FIELD the value came from, by the
# identity of the object that holds it, so two reads of one descriptor share one
# local — keeping identical code identical for the split helpers' dedup — while
# two fields that merely hold equal values at this N stay distinct.
function _cg_geo!(ctx::_CGCtx, v::Int, key=nothing, unit::Bool=false)
    (ctx.subivt || (unit && -1 <= v <= 1)) && return v
    if key !== nothing
        got = get(ctx.geomemo, key, nothing)
        got === nothing || return got
    end
    push!(ctx.geo, v)
    s = _cg_name(ctx, "G")
    push!(ctx.geosink, :(local $s = $(_cg_tab!(ctx, ctx.geo))[$(length(ctx.geo))]))
    key === nothing || (ctx.geomemo[key] = s)
    return s
end

# A table a loop body indexes, as a local read once ahead of the loops (in the
# geometry sink) rather than `_cggrpG[pos]` at every use: a store to `du` may
# alias the container's memory as far as the compiler knows, so the in-loop
# form reloads the table's address on every iteration. Inside a structural
# sub-kernel body (`ctx.subivt`) the table stays the container read, as there
# every name it references must be one of the body's parameters.
function _cg_tabh!(ctx::_CGCtx, obj)
    ref = _cg_tab!(ctx, obj)
    ctx.subivt && return ref
    key = (:tab, obj)
    got = get(ctx.geomemo, key, nothing)
    got === nothing || return got
    s = _cg_name(ctx, "tb")
    push!(ctx.geosink, :(local $s = $ref))
    ctx.geomemo[key] = s
    return s
end

# A gather of the state through a slot table, once its table is a local
# (`_cg_tabh!`), invites the loop vectorizer to turn every neighbour read into
# a vector gather, which is several times slower here than the scalar loop. A
# fetch that emits one sets `ctx.tblread`; `_cg_tblread!` returns the loop
# annotation that keeps the loop scalar (or nothing) and clears the flag.
# Leaving a loop scalar never changes a value.
function _cg_tblread!(ctx::_CGCtx)
    r = ctx.tblread
    ctx.tblread = false
    return r ? Any[_cg_novec()] : Any[]
end

# Run `f()` with geometry locals going to `sink` (and a fresh memo, since a
# memoized local exists only in the list it was defined in).
function _cg_with_geosink(f, ctx::_CGCtx, sink::Vector{Any})
    sink0, memo0 = ctx.geosink, ctx.geomemo
    ctx.geosink = sink
    ctx.geomemo = IdDict{Any,Symbol}()
    try
        return f()
    finally
        ctx.geosink = sink0
        ctx.geomemo = memo0
    end
end

# ---- Per-kernel-evaluation context ------------------------------------------
# The cell coordinates as EXPRESSIONS (a loop-variable Symbol or an Int
# literal), plus the CSE slot → local-name maps for the kernel currently being
# emitted. `cellsyms` is occurrence-scoped (a template sub-kernel inlined at
# two call sites gets two disjoint sets of locals, mirroring the interpreter's
# per-occurrence scratch refill); `invsyms` is kernel-scoped (filled once per
# call by the prologue, as `_fill_invariant!` does).
struct _CGKernCtx
    K::_AccKernel
    c::Any        # cell ordinal
    n::Any        # neighbour index (0 outside a reduction)
    oln::Any      # output linear slot
    mi1::Any      # loop multi-index, padded with literal 1s
    mi2::Any
    mi3::Any
    cellsyms::Vector{Symbol}
    invsyms::Vector{Symbol}
    # The multi-index of loop dims 4, 5, … — empty on a box of rank ≤ 3, where
    # every dim past the third reads as the literal 1, exactly as the
    # interpreter's padded `midx` does.
    mix::Vector{Any}
end
_CGKernCtx(K, c, n, oln, mi1, mi2, mi3, cellsyms, invsyms) =
    _CGKernCtx(K, c, n, oln, mi1, mi2, mi3, cellsyms, invsyms, Any[])

_cg_mi(kc::_CGKernCtx, d::Int) =
    d == 1 ? kc.mi1 : d == 2 ? kc.mi2 : d == 3 ? kc.mi3 :
    d - 3 <= length(kc.mix) ? kc.mix[d - 3] : 1

# The same context with loop dim `d` bound to `v` (an affine reduction binds its
# reduction dims this way, inside its loops).
function _cg_with_mi(kc::_CGKernCtx, d::Int, v)
    mi1, mi2, mi3 = kc.mi1, kc.mi2, kc.mi3
    mix = kc.mix
    if d == 1
        mi1 = v
    elseif d == 2
        mi2 = v
    elseif d == 3
        mi3 = v
    else
        mix = copy(kc.mix)
        while length(mix) < d - 3
            push!(mix, 1)
        end
        mix[d - 3] = v
    end
    return _CGKernCtx(kc.K, kc.c, kc.n, kc.oln, mi1, mi2, mi3, kc.cellsyms,
                      kc.invsyms, mix)
end

# Integer index expression `off + Σ_d (mi_d - 1)·s_d`, folding literal-1 mi
# and zero strides (exact Int arithmetic — folding cannot change the index).
# `sx` carries the strides of dims 4, 5, … (`_AccDesc.sx`). The strides and the
# offset are run-time geometry (`_cg_geo!`), keyed under `key`.
_cg_gkey(key, f) = key === nothing ? nothing : (key, f)
function _cg_boxaddr(ctx::_CGCtx, kc::_CGKernCtx, s1::Int, s2::Int, s3::Int, off::Int,
                     sx::Vector{Int}=_AK_NO_CONN, key=nothing)
    e = nothing
    for (d, mi, s) in ((1, kc.mi1, s1), (2, kc.mi2, s2), (3, kc.mi3, s3))
        s == 0 && continue
        mi === 1 && continue                      # (1-1)*s == 0
        term = :(($mi - 1) * $(_cg_geo!(ctx, s, _cg_gkey(key, d), true)))
        e = e === nothing ? term : :($e + $term)
    end
    for d in eachindex(sx)
        s = sx[d]
        mi = _cg_mi(kc, d + 3)
        (s == 0 || mi === 1) && continue
        term = :(($mi - 1) * $(_cg_geo!(ctx, s, _cg_gkey(key, d + 3), true)))
        e = e === nothing ? term : :($e + $term)
    end
    g = _cg_geo!(ctx, off, _cg_gkey(key, :off))
    return e === nothing ? g : :($g + $e)
end

_cg_offset(base, delta) = delta === 0 ? base : :($base + $delta)

# The first slot of a slot table that is `c0, c0+1, …` with no ghost (0)
# entry, or 0 when it is not one such run.
# The table an `_AK_STATE_TBL_BOX` read passes to the emitted code: a range is
# an identity run (`c0 > 0`), whose table the emitted branch never loads, so
# every such read shares one empty vector and the table types stay `Vector{Int}`.
const _CG_RUN_TBL = Int[]
_cg_run_tbl(conn::Vector{Int}, c0::Int) = conn
_cg_run_tbl(conn::UnitRange{Int}, c0::Int) = c0 > 0 ? _CG_RUN_TBL : collect(conn)
_cg_affine_conn(conn::UnitRange{Int}) = (!isempty(conn) && first(conn) >= 1) ? first(conn) : 0
function _cg_affine_conn(conn::Vector{Int})
    isempty(conn) && return 0
    c0 = conn[1]
    c0 >= 1 || return 0
    @inbounds for k in eachindex(conn)
        conn[k] == c0 + k - 1 || return 0
    end
    return c0
end

# How `_cg_fetch` reads a slot table, as run-time data: `c0 - 1 >= 0` for a run
# starting at slot `c0` (`_cg_affine_conn`), `-2` for a table with no ghost
# entry, `-1` for one that has some.
_cg_conn_mode(conn::UnitRange{Int}) =
    _cg_affine_conn(conn) > 0 ? first(conn) - 1 : _cg_conn_mode(collect(conn))
function _cg_conn_mode(conn::Vector{Int})
    c0 = _cg_affine_conn(conn)
    c0 > 0 && return c0 - 1
    return any(iszero, conn) ? -1 : -2
end

# ---- Two-buffer addressing ------------------------------------------------
# A right-hand side with materialized array observeds runs on a slot space of
# two buffers (`_ObsSplitVec`): the state, then the observed buffer. Where the
# emitter knows which of the two an access reads — every slot it can address
# is a state slot, or every one an observed slot — it indexes that buffer
# directly instead of through the view's per-read test. Both accessors are the
# vector itself on a plain vector, so the emitted code is valid for either.
@inline _cg_bufS(x) = x
@inline _cg_bufS(s::_ObsSplitVec) = s.u
@inline _cg_oview(x) = x
@inline _cg_oview(s::_ObsSplitVec) = _ObsShift(s.o, s.n)

# The observed buffer addressed by slot: slot `i` is `o[i - n]`.
struct _ObsShift{T,O} <: AbstractVector{T}
    o::O
    n::Int
end
_ObsShift(o::AbstractVector{T}, n::Int) where {T} = _ObsShift{T,typeof(o)}(o, n)
Base.size(s::_ObsShift) = (s.n + length(s.o),)
Base.IndexStyle(::Type{<:_ObsShift}) = IndexLinear()
@inline function Base.getindex(s::_ObsShift, i::Int)
    @boundscheck checkbounds(s.o, i - s.n)
    return @inbounds s.o[i - s.n]
end
@inline function Base.setindex!(s::_ObsShift, v, i::Int)
    @boundscheck checkbounds(s.o, i - s.n)
    @inbounds s.o[i - s.n] = v
    return s
end

# The `du` a section writes through: its state part (`Val(:s)`) or its
# observed part (`Val(:o)`) when every slot the section writes is one of them.
@inline _cg_dview(du, ::Val) = du
@inline _cg_dview(du::_ObsSplitVec, ::Val{:s}) = du.u
@inline _cg_dview(du::_ObsSplitVec, ::Val{:o}) = _ObsShift(du.o, du.n)

# Which buffer slots `lo:hi` live in: `:s` (state), `:o` (observed) or `:x`
# (both, or unknown — read through the view).
_cg_slot_side(nst::Int, lo::Int, hi::Int) =
    nst <= 0 || lo > hi ? :x : (lo >= 1 && hi <= nst) ? :s : lo > nst ? :o : :x

# The output-slot extent of a kernel's cells.
function _cg_oln_extent(cs::_CellSet)
    _is_outs(cs) && return extrema(cs.outs)
    _is_contig(cs) && return (first(cs.ranges[1]), last(cs.ranges[1]))
    lo = hi = cs.base
    for d in eachindex(cs.strides)
        a = cs.strides[d] * first(cs.ranges[d])
        b = cs.strides[d] * last(cs.ranges[d])
        lo += min(a, b)
        hi += max(a, b)
    end
    return (lo, hi)
end
_cg_oln_extent(Ks::AbstractVector{_AccKernel}) =
    isempty(Ks) ? (1, 0) :
    (minimum(K -> _cg_oln_extent(K.cells)[1], Ks), maximum(K -> _cg_oln_extent(K.cells)[2], Ks))

# Record that `K`'s loop nest binds `oln` over its own cells.
function _cg_note_nest!(ctx::_CGCtx, K::_AccKernel)
    ctx.nst > 0 && !haskey(ctx.olnext, K) && (ctx.olnext[K] = _cg_oln_extent(K.cells))
    return nothing
end

# The slot extent of a slot table, ghost (0) entries left out.
function _cg_table_extent(ctx::_CGCtx, conn)
    got = get(ctx.sidememo, conn, nothing)
    got === nothing || return got
    ext = if conn isa UnitRange{Int}
        isempty(conn) ? (1, 0) : (first(conn), last(conn))
    else
        lo, hi = typemax(Int), typemin(Int)
        @inbounds for s in conn
            s == 0 && continue
            lo = min(lo, s); hi = max(hi, s)
        end
        lo > hi ? (1, 0) : (lo, hi)
    end
    ctx.sidememo[conn] = ext
    return ext
end

# The buffer descriptor `a` reads in kernel context `kc`.
function _cg_side(ctx::_CGCtx, kc::_CGKernCtx, a::_AccDesc)
    ctx.nst > 0 || return :x
    k = a.kind
    if k === _AK_STATE_AFFINE
        (kc.oln isa Symbol && !haskey(ctx.subks, kc.K)) || return :x
        e = get(ctx.olnext, kc.K, nothing)
        e === nothing && return :x
        return _cg_slot_side(ctx.nst, e[1] + a.delta, e[2] + a.delta)
    elseif k === _AK_STATE_FIXED
        return _cg_slot_side(ctx.nst, a.idx, a.idx)
    elseif k === _AK_STATE_INDIRECT || k === _AK_STATE_INDIRECT_COL ||
           k === _AK_STATE_TBL_BOX
        lo, hi = _cg_table_extent(ctx, a.conn)
        # An indirect table has no ghost entry; one that did would read slot 0.
        k !== _AK_STATE_TBL_BOX && lo > hi && return :x
        return _cg_slot_side(ctx.nst, lo, hi)
    end
    return :x
end

# A state read of slot expression `i` from the buffer `side` names.
_cg_uread(side::Symbol, i) =
    side === :s ? :(_cg_bufS(u)[$i]) : side === :o ? :(_cg_oview(u)[$i]) : :(u[$i])

# ---- One access descriptor → one indexing expression (mirrors `_fetch`) -----
# `key` identifies the descriptor (its table and position) for `_cg_geo!`.
function _cg_fetch(ctx::_CGCtx, kc::_CGKernCtx, a::_AccDesc, key=nothing)
    k = a.kind
    if k === _AK_STATE_AFFINE
        return _cg_uread(_cg_side(ctx, kc, a),
                         _cg_offset(kc.oln, _cg_geo!(ctx, a.delta, _cg_gkey(key, :delta), true)))
    elseif k === _AK_CONST_AFFINE
        return :($(_cg_tab!(ctx, a.arr))[$(_cg_offset(kc.oln,
                     _cg_geo!(ctx, a.delta, _cg_gkey(key, :delta), true)))])
    elseif k === _AK_CONST_BOX || k === _AK_FORCING_BOX
        # FORCING_BOX's arr is the aliased LIVE buffer — passing the reference
        # through `tabs` keeps every in-place refresh visible.
        return :($(_cg_tab!(ctx, a.arr))[$(_cg_boxaddr(ctx, kc, a.s1, a.s2, a.s3, a.off,
                                                       a.sx, key))])
    elseif k === _AK_STATE_FIXED
        return _cg_uread(_cg_side(ctx, kc, a), _cg_geo!(ctx, a.idx, _cg_gkey(key, :idx)))
    elseif k === _AK_LOOP_IDX
        return :(Float64($(_cg_mi(kc, a.dim))))
    elseif k === _AK_SCALAR
        return a.v
    elseif k === _AK_CONST_CELL
        return :($(_cg_tab!(ctx, a.arr))[$(kc.c)])
    elseif k === _AK_CONST_EDGE
        return :($(_cg_tab!(ctx, a.arr))[($(kc.c) - 1) * $(a.width) + $(kc.n)])
    elseif k === _AK_ARR_FIXED
        return :($(_cg_tab!(ctx, a.arr))[$(_cg_geo!(ctx, a.idx, _cg_gkey(key, :idx)))])
    elseif k === _AK_STATE_INDIRECT
        ctx.tblread = true
        return _cg_uread(_cg_side(ctx, kc, a),
                         :($(_cg_tabh!(ctx, a.conn))[($(kc.c) - 1) * $(a.width) + $(kc.n)]))
    elseif k === _AK_STATE_INDIRECT_COL
        ctx.tblread = true
        return _cg_uread(_cg_side(ctx, kc, a),
                         :($(_cg_tabh!(ctx, a.conn))[($(kc.c) - 1) * $(a.width) + $(a.col)]))
    elseif k === _AK_STATE_TBL_BOX
        s = _cg_name(ctx, "s")
        addr = _cg_boxaddr(ctx, kc, a.s1, a.s2, a.s3, a.off, a.sx, key)
        # A table that is one ascending run of slots with no ghost (the box of
        # an array laid out as one column-major block) reads the same slot as
        # base + address, without the table load and the ghost test; a table
        # with no ghost entry skips the ghost test. Which of the three a table
        # is can depend on the grid size (a boundary slab one cell wide), so
        # the choice is run-time data (`_cg_conn_mode`) and the emitted code is
        # the same at every N; the branches are loop-invariant.
        cb = _cg_geo!(ctx, _cg_conn_mode(a.conn), _cg_gkey(key, :tblbase))
        side = _cg_side(ctx, kc, a)
        if cb isa Symbol
            # The version of the loop that runs only when every table it reads
            # is a run (`_cg_tbl_versions`).
            ctx.tblaffine && return _cg_uread(side, :($cb + $addr))
            push!(ctx.tblcbs, cb)
        end
        tb = _cg_tabh!(ctx, _cg_run_tbl(a.conn, _cg_affine_conn(a.conn)))
        ctx.tblread = true
        # Exactly `_fetch`'s ghost test: slot 0 ⇒ the ghost literal 0.0.
        return :($cb == -2 ? $(_cg_uread(side, :($tb[$addr]))) :
                 $cb >= 0 ? $(_cg_uread(side, :($cb + $addr))) :
                 let $s = $tb[$addr]
                     $s == 0 ? 0.0 : $(_cg_uread(side, s))
                 end)
    elseif k === _AK_ARR_TBL_BOX
        addr = _cg_boxaddr(ctx, kc, a.s1, a.s2, a.s3, a.off, a.sx, key)
        ctx.tblread = true
        return :($(_cg_tabh!(ctx, a.arr))[$(_cg_tabh!(ctx, a.conn))[$addr]])
    end
    throw(_CodegenDecline(:unsupported_desc))
end

# ---- Op-symbol tables (the same registry rows the four eval ladders use) ----
const _CG_UNARY_FN = Dict{Symbol,Symbol}(row.sym => row.sym for row in _UNARY_ELEMENTWISE_OPS)
const _CG_BINARY_FN = Dict{Symbol,Symbol}(row.sym => row.fnsym for row in _BINARY_ELEMENTWISE_OPS)
const _CG_CMP_FN = Dict{Symbol,Symbol}(row.sym => row.fnsym for row in _COMPARISON_ELEMENTWISE_OPS)
const _CG_MINMAX_FN = Dict{Symbol,Symbol}(row.sym => row.fnsym for row in _NARY_MINMAX_OPS)

# Left-nested binary fold `((e1 op e2) op e3)…` — the interpreters' exact
# `acc = ev(c1); acc = op(acc, ev(ci))` association.
#
# A long fold (a contraction unrolled over thousands of terms) is emitted as
# that accumulation itself, one statement per term in a `let`, rather than as
# a call nested once per term: Julia's lowering recurses on expression depth,
# and a chain some 10^4 calls deep exhausts it ("out of gc handles"). The
# operations, their operands and their order are the same, so are the values.
const _CG_FOLD_NEST_MAX = 64
function _cg_foldl(fnsym::Symbol, exprs::Vector{Any})
    n = length(exprs)
    if n > _CG_FOLD_NEST_MAX
        acc = :_cgfacc
        stmts = Any[:(local $acc = $(exprs[1]))]
        for i in 2:n
            push!(stmts, :($acc = $(Expr(:call, fnsym, acc, exprs[i]))))
        end
        push!(stmts, acc)
        return Expr(:let, Expr(:block), Expr(:block, stmts...))
    end
    acc = exprs[1]
    for i in 2:n
        acc = Expr(:call, fnsym, acc, exprs[i])
    end
    return acc
end

# Short-circuit chain `e1 && (e2 && …)` (head `:&&`/`:||`, NOT a call).
# Right-nested exactly as the parser associates; evaluation is left-to-right
# with the interpreter's short-circuit set either way.
function _cg_chain(head::Symbol, exprs::Vector{Any})
    acc = exprs[end]
    for i in (length(exprs) - 1):-1:1
        acc = Expr(head, exprs[i], acc)
    end
    return acc
end

# ---- Spine node → expression (mirrors `_eval_acc`) --------------------------
function _cg_emit(ctx::_CGCtx, kc::_CGKernCtx, nd::_Node)
    _cg_budget!(ctx)
    k = nd.kind
    if k === _NK_ACCESS
        sb = ctx.subst
        (sb !== nothing && kc.K === sb[1] && nd.idx == sb[2]) && return sb[3]
        return _cg_fetch(ctx, kc, kc.K.acc[nd.idx], (kc.K.acc, nd.idx))
    elseif k === _NK_LITERAL
        return nd.literal
    elseif k === _NK_PARAM
        return :(_read_param(p, $(QuoteNode(nd.sym)), $(nd.idx)))
    elseif k === _NK_TIME
        return :t
    elseif k === _NK_CACHED
        pl = nd.payload
        cse = kc.K.cse
        if pl === cse.scratch && nd.idx <= length(kc.cellsyms)
            return kc.cellsyms[nd.idx]
        elseif pl === cse.inv_scratch && ctx.subivt
            # Sub-kernel body (ess-cg-subcall-struct): invariant slots arrive as
            # ONE homogeneous tuple argument, so bodies stay structurally equal
            # across sub-kernels whose prologue locals have different names.
            return :(_cgivt[$(nd.idx)])
        elseif pl === cse.inv_scratch && nd.idx <= length(kc.invsyms)
            return kc.invsyms[nd.idx]
        elseif pl === ctx.shared_cache && pl isa _CSECache &&
               !_cg_foreign_scratch_disabled()
            # Shared scalar-prelude slot (xcse.jl rewrite; ess-cgfsc). Emit the
            # interpreter's exact read — `_cse_read` selects `f64` at Float64
            # and the `alt::Vector{T}` buffer under any other `T`, both filled
            # by `_make_rhs`'s prelude tiers (at this same `T`) before the
            # kernel section runs; see the fill-ordering note at the tier docs
            # above.
            ctx.fscratch += 1
            return :(_cse_read($(_cg_tab!(ctx, pl)), $(nd.idx), _cgT))
        end
        throw(_CodegenDecline(:foreign_scratch))
    elseif k === _NK_REDUCE
        # `s = K.zerobar; for m in 1:cnt; s += ev(body @ n=m); end` — the
        # `_eval_acc` REDUCE arm verbatim (the ⊕ is always `+`, seeded from
        # the kernel's 0̄).
        b = kc.K.bound
        cnt = b isa _FixedBound ? b.k :
              b isa _VarBound ? :($(_cg_tab!(ctx, b.valence))[$(kc.c)]) :
              throw(_CodegenDecline(:unsupported_bound))
        s = _cg_name(ctx, "r")
        m = _cg_name(ctx, "m")
        inner = _CGKernCtx(kc.K, kc.c, m, kc.oln, kc.mi1, kc.mi2, kc.mi3,
                           kc.cellsyms, kc.invsyms, kc.mix)
        body = _cg_emit(ctx, inner, nd.children[1])
        return quote
            local $s = $(kc.K.zerobar)
            for $m in 1:$cnt
                $s += $body
            end
            $s
        end
    elseif k === _NK_AREDUCE
        return _cg_emit_areduce(ctx, kc, nd)
    elseif k === _NK_CONTRACTION
        # Seeded sequential ⊕-fold in child order — `_eval_acc_contraction`
        # arm for arm (`max`/`min` fold through the function, `+`/`*` through
        # the operator; both are the same left-nested application).
        ch = nd.children
        isempty(ch) && return nd.literal
        exprs = Any[nd.literal]
        for c in ch
            push!(exprs, _cg_emit(ctx, kc, c))
        end
        op = nd.op
        fnsym = op === :+ ? :+ : op === :* ? :* :
                op === :max ? :max : op === :min ? :min :
                op === :or ? :_or_combine :
                throw(_CodegenDecline(:unsupported_op))
        return _cg_foldl(fnsym, exprs)
    elseif k === _NK_SUBCALL
        return _cg_emit_subcall(ctx, kc, nd.payload::_AccKernel)
    elseif k === _NK_OP
        return _cg_emit_op(ctx, kc, nd)
    end
    throw(_CodegenDecline(:unknown_kind))
end

# Affine reduction (`_NK_AREDUCE`) — `_eval_acc_areduce` as a loop nest: one
# accumulator seeded from the node's 0̄ (a `Float64`, as the interpreter seeds
# it), the contracted dims bound to loop counters (the first dim innermost),
# and `s = s ⊕ body` in the innermost loop. The body is emitted once, so the
# kernel's code does not grow with the contraction length.
function _cg_emit_areduce(ctx::_CGCtx, kc::_CGKernCtx, nd::_Node)
    spec = nd.payload::_AReduceSpec
    fnsym = _cg_oplus_fn(nd.op)
    acc = _cg_name(ctx, "r")
    js = Symbol[_cg_name(ctx, "j") for _ in spec.dims]
    inner = kc
    for r in eachindex(spec.dims)
        inner = _cg_with_mi(inner, spec.dims[r], js[r])
    end
    body = _cg_emit(ctx, inner, nd.children[1])
    loop = Expr(:(=), acc, Expr(:call, fnsym, acc, body))
    for r in eachindex(spec.dims)
        rg = spec.ranges[r]
        lo = _cg_geo!(ctx, first(rg), (spec.ranges, r, :lo))
        hi = _cg_geo!(ctx, last(rg), (spec.ranges, r, :hi))
        loop = Expr(:for, :($(js[r]) = $lo:$hi), Expr(:block, loop))
    end
    return quote
        local $acc = $(nd.literal)
        $loop
        $acc
    end
end

# Emit a kernel's per-cell CSE recipes as `local q = …` statements appended to
# `stmts`, registering each local on `kc.cellsyms` so later recipes and the
# spine resolve their `_NK_CACHED` reads (recipes only ever read LOWER slots, so
# each name exists before its first read). Shared by the kernel cell body and
# the subcall inliner.
#
# A recipe keeps the type its expression has, and is NOT converted to the value
# type `T`. The reference build (`compiler = :interpreter`) has no recipes: it
# computes a shared subexpression in place, so a `Float64` one (a const lane,
# `-W[i]`) stays `Float64` and multiplies a `Dual` as a scalar. Converting it
# would make it a `Dual` with zero partials, and `Dual * Dual` then adds
# `value · 0.0` to every partial: a `-0.0` partial of the reference turns into
# `+0.0`, and an infinite value into a `NaN` partial. The interpreted
# access-kernel runner stores its recipes in a `Vector{T}` scratch and does
# convert; it is not the reference, and a strict build never runs it.
function _cg_emit_recipes!(stmts::Vector{Any}, ctx::_CGCtx, kc::_CGKernCtx)
    for r in kc.K.cse.recipes
        e = _cg_bound_body!(ctx, _cg_emit(ctx, kc, r))
        s = _cg_name(ctx, "q")
        push!(stmts, :(local $s = $e))
        push!(kc.cellsyms, s)
    end
    return stmts
end

# Template sub-kernel call (`_NK_SUBCALL`), the COMPILE-ONCE emission
# (ess-cg-subcall-fn). The affine tier already shares one `_AccKernel` per
# (use site, region class) body, and the interpreter recurses into it; inlining
# it here at every call site un-did that sharing at codegen — the fused duo
# momentum RHS emitted 3.2e6 nodes (~127k per kernel, the SAME template chains
# re-emitted per site and per region-class kernel), and Julia's first-call
# compile of that much unshared code cost ~93 min / 33 GB. So a body is now
# emitted ONCE into a top-level `@noinline` function `(u, p, t, <cell context>,
# extra…)` and every site becomes a CALL carrying its own cell-context
# expressions — value- and order-exact, since the body computes the identical
# scalar sequence with the context bound as arguments instead of spliced in.
#
# Bit-exactness and the zero-alloc discipline follow the split helpers'
# (`_cg_spill!`) conventions exactly: per-cell CSE recipes stay function-local
# locals of their own type (`_cg_emit_recipes!`; a fresh call frame computes
# the identical values), `_cgT`
# is recomputed inside from `(u, p, t)` (never passed — constant-propagation),
# the function captures nothing, and the name shares the split helpers'
# `_cgh…` namespace so `_cg_is_spill_call` (partition irreducibility) and
# `_cg_is_passable` (never passed as a value) treat call sites correctly. The
# body's invariant tier was emitted once in the prologue (`_cg_inv!` —
# `K.subs` holds every transitive sub, nested-first); its slot locals arrive
# through the sorted `extra` parameters like any other passable name.
#
# A tiny body (≤ `_cg_subcall_fn_min_nodes()`) stays inlined per site, and
# Julia < 1.12 keeps the pre-tier inlining wholesale — the emitted function is
# the same inner-`function`-under-RGF mechanism as the split's inner-definition
# transport, which boxes and segfaults there (`_cg_split_supported`). This tier
# has not been ported to the by-value transport the split takes instead; it
# ships off, so nothing on those versions depends on it.
# Canonicalizer/parametrizer for one emitted sub-kernel body
# (ess-cg-subcall-struct). Rewrites the expression so that everything that
# varies between two structurally-equal sub-kernels becomes an ARGUMENT:
#   * every `Int` literal      → `_cgai[k]` (collected into `ints`);
#   * every `Float64` literal  → `_cgaf[k]` (collected into `flts`);
#   * every emitter-minted body-local (`_cgq…`/`_cgr…`/`_cgm…`/`_cgs…`) →
#     `_cgxN` in first-appearance order, so two emissions of the same structure
#     print identically even though `_cg_name`'s global counter differed.
# Names that are REAL outer/context references are never renamed: tab group
# containers (`_cggrp…`), helper/sub-function names (`_cgh…`), invariant
# prologue locals (`_cgv…`, referenced by nested call sites), the context
# params (`_cgs…`, matched via `_cgsm`/`_cgsc`/`_cgsn`/`_cgso`), and the
# abstraction's own vectors/tuple (`_cgai`/`_cgaf`/`_cgivt`, digit-free tails).
# `string(result)` is then the structural key: equal text ⇔ the same code with
# different constants, which is exactly what may share one compiled function.
# The values a body computes are unchanged — the same operations are applied
# to the same operand VALUES; they arrive from an indexed read instead of an
# immediate.
mutable struct _CGAbs
    ints::Vector{Int}
    flts::Vector{Float64}
    ren::Dict{Symbol,Symbol}
end
_CGAbs() = _CGAbs(Int[], Float64[], Dict{Symbol,Symbol}())
function _cg_abs_renameable(s::Symbol)
    nm = String(s)
    (startswith(nm, "_cg") && isdigit(nm[end])) || return false
    for p in ("_cggrp", "_cgh", "_cgv", "_cgsm", "_cgiv", "_cgai", "_cgaf", "_cgx")
        startswith(nm, p) && return false
    end
    return true
end
function _cg_abstract!(ab::_CGAbs, ex)
    if ex isa Int
        push!(ab.ints, ex)
        return :(_cgai[$(length(ab.ints))])
    elseif ex isa Float64
        push!(ab.flts, ex)
        return :(_cgaf[$(length(ab.flts))])
    elseif ex isa Symbol
        _cg_abs_renameable(ex) || return ex
        return get!(() -> Symbol("_cgx", length(ab.ren) + 1), ab.ren, ex)
    elseif ex isa Expr
        return Expr(ex.head, Any[_cg_abstract!(ab, a) for a in ex.args]...)
    end
    return ex          # QuoteNode, LineNumberNode, Bool, String, …
end

function _cg_subcall_fn!(ctx::_CGCtx, S::_AccKernel, invsyms::Vector{Symbol})
    got = get(ctx.subfn, S, nothing)
    got !== nothing && return got
    # Formal cell-context parameter names. Function-scoped, so one fixed set
    # serves every sub-kernel; `_cg`-prefixed, so a spill INSIDE this body
    # passes them along like any other in-scope emitter local.
    c = :_cgsc; n = :_cgsn; oln = :_cgso
    m1 = :_cgsm1; m2 = :_cgsm2; m3 = :_cgsm3
    nodes0 = ctx.nodes
    ctx.subks[S] = true
    inner = _CGKernCtx(S, c, n, oln, m1, m2, m3, Symbol[], Symbol[])
    subivt0 = ctx.subivt
    ctx.subivt = true
    local body0
    try
        # Recipes are emitted UN-partitioned here (the pre-tier
        # `_cg_emit_recipes!` bounds each one immediately, which would mint
        # spill helpers before canonicalization): the whole body is partitioned
        # AFTER the structural-dedup decision, so a dedup hit discards nothing.
        stmts = Any[]
        for r in S.cse.recipes
            e = _cg_emit(ctx, inner, r)
            s = _cg_name(ctx, "q")
            push!(stmts, :(local $s = $e))
            push!(inner.cellsyms, s)
        end
        spine = _cg_emit(ctx, inner, S.spine)
        body0 = isempty(stmts) ? spine : Expr(:block, stmts..., spine)
    finally
        ctx.subivt = subivt0
    end
    if ctx.nodes - nodes0 <= _cg_subcall_fn_min_nodes()
        # Under the floor: discard this probe emission (its nodes un-count; tab
        # registrations dedup by identity, so re-emission re-reads the same
        # `_cggrpG[pos]` slots) and inline at every site instead.
        ctx.nodes = nodes0
        ctx.subfn[S] = :inline
        push!(ctx.sublog, S)
        return :inline
    end
    ab = _CGAbs()
    kb = _cg_abstract!(ab, body0)
    key = string(kb)
    hit = get(ctx.substruct, key, nothing)
    if hit !== nothing
        # Same structure as an already-compiled body: this instance's emission
        # is discarded (only its constants survive, in the per-S entry) and
        # every site calls the one existing function.
        ctx.nodes = nodes0
        _tally_cascade!(:cg_subcall_struct_hit)
        fname, extra = hit
        entry = (fname, extra, ab.ints, ab.flts)
        ctx.subfn[S] = entry
        push!(ctx.sublog, S)
        return entry
    end
    body = _cg_bound_body!(ctx, kb)
    syms = Set{Symbol}()
    _cg_collect_syms!(syms, body)
    bound = _cg_collect_bound!(Set{Symbol}(), body)
    ctxparams = (c, n, oln, m1, m2, m3, :_cgai, :_cgaf, :_cgivt)
    extra = sort!([s for s in syms
                   if _cg_is_passable(s) && !(s in bound) && !(s in ctxparams)];
                  by = string)
    fname = _cg_name(ctx, "h")     # the split helpers' `_cgh…` namespace
    ln = LineNumberNode(0, Symbol("ess-cg-subcall-fn"))
    fstmts = Any[]
    (:_cgT in syms) && push!(fstmts, :(local _cgT = _rhs_value_type(u, p, t)))
    push!(fstmts, Expr(:macrocall, Symbol("@inbounds"), ln, :(return $body)))
    params = Symbol[:u, :p, :t, c, n, oln, m1, m2, m3, :_cgai, :_cgaf, :_cgivt]
    append!(params, extra)
    fdef = Expr(:function, Expr(:call, fname, params...), Expr(:block, fstmts...))
    push!(ctx.helpers, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
    _tally_cascade!(:cg_subcall_fn)
    ctx.substruct[key] = (fname, extra)
    push!(ctx.substruct_log, key)
    entry = (fname, extra, ab.ints, ab.flts)
    ctx.subfn[S] = entry
    push!(ctx.sublog, S)
    return entry
end

function _cg_emit_subcall(ctx::_CGCtx, kc::_CGKernCtx, S::_AccKernel)
    invsyms = get(ctx.invdone, S, nothing)
    invsyms === nothing && throw(_CodegenDecline(:subcall_order))
    # The function tier passes the three-dim cell context as its formal
    # parameters, so a body read past the third dim is inlined instead.
    if _cg_split_supported() && !_cg_subcall_fn_disabled() && isempty(kc.mix)
        got = _cg_subcall_fn!(ctx, S, invsyms)
        if got !== :inline
            fname, extra, ints, flts =
                got::Tuple{Symbol,Vector{Symbol},Vector{Int},Vector{Float64}}
            _cg_budget!(ctx)
            # The instance constants ride as tab containers (identity-stable
            # vectors, registered once per S) — an L1-resident indexed read in
            # place of an immediate, never a per-call tuple copy — and the
            # invariant slots as one homogeneous tuple of prologue locals.
            return Expr(:call, fname, :u, :p, :t, kc.c, kc.n, kc.oln,
                        kc.mi1, kc.mi2, kc.mi3,
                        _cg_tab!(ctx, ints), _cg_tab!(ctx, flts),
                        Expr(:tuple, invsyms...), extra...)
        end
    end
    # Pre-tier emission: inline the body at the call site — per-cell CSE
    # recipes become occurrence-local locals, then the body spine evaluates
    # against its OWN descriptor table.
    ctx.subks[S] = true
    inner = _CGKernCtx(S, kc.c, kc.n, kc.oln, kc.mi1, kc.mi2, kc.mi3,
                       Symbol[], invsyms, kc.mix)
    stmts = _cg_emit_recipes!(Any[], ctx, inner)
    spine = _cg_emit(ctx, inner, S.spine)
    isempty(stmts) && return spine
    return Expr(:block, stmts..., spine)
end

# ---- Op application (mirrors `_eval_acc_op` arm for arm) --------------------
# `kc` is left unannotated here and on `_cg_emit_fn`: the op ladder is the op
# REGISTRY rendered as expressions and reads nothing off the evaluation context
# but the recursion, so the scalar-spine emitter (array_contraction.jl)
# shares these two rather than restating every registry row.
function _cg_emit_op(ctx::_CGCtx, kc, nd::_Node)
    op = nd.op
    ch = nd.children
    ev(x) = _cg_emit(ctx, kc, x)
    if op === :+ || op === :*
        isempty(ch) && throw(_CodegenDecline(:unsupported_op))
        length(ch) == 1 && return ev(ch[1])
        return _cg_foldl(op, Any[ev(c) for c in ch])
    elseif op === :-
        length(ch) == 1 && return :(-$(ev(ch[1])))
        length(ch) == 2 && return :($(ev(ch[1])) - $(ev(ch[2])))
        throw(_CodegenDecline(:unsupported_op))
    elseif op === :neg
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return :(-$(ev(ch[1])))
    elseif op === :and
        # `ev(x) == 0 && return 0.0` per child, else 1.0 — as an `&&` chain:
        # same child order, same short-circuit set, same 1.0/0.0 result.
        isempty(ch) && throw(_CodegenDecline(:unsupported_op))
        cond = _cg_chain(:&&, Any[:($(ev(c)) != 0) for c in ch])
        return :($cond ? 1.0 : 0.0)
    elseif op === :or
        isempty(ch) && throw(_CodegenDecline(:unsupported_op))
        cond = _cg_chain(:||, Any[:($(ev(c)) != 0) for c in ch])
        return :($cond ? 1.0 : 0.0)
    elseif op === :not
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return :($(ev(ch[1])) == 0 ? 1.0 : 0.0)
    elseif op === :ifelse
        length(ch) == 3 || throw(_CodegenDecline(:unsupported_op))
        return :($(ev(ch[1])) != 0 ? $(ev(ch[2])) : $(ev(ch[3])))
    elseif op === :atan
        length(ch) == 1 && return :(atan($(ev(ch[1]))))
        length(ch) == 2 && return :(atan($(ev(ch[1])), $(ev(ch[2]))))
        throw(_CodegenDecline(:unsupported_op))
    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)
    elseif op === :Pre
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return ev(ch[1])
    elseif op === :fn
        return _cg_emit_fn(ctx, kc, nd)
    end
    fnsym = get(_CG_BINARY_FN, op, nothing)
    if fnsym !== nothing
        length(ch) == 2 || throw(_CodegenDecline(:unsupported_op))
        return Expr(:call, fnsym, ev(ch[1]), ev(ch[2]))
    end
    fnsym = get(_CG_CMP_FN, op, nothing)
    if fnsym !== nothing
        length(ch) == 2 || throw(_CodegenDecline(:unsupported_op))
        return :($(Expr(:call, fnsym, ev(ch[1]), ev(ch[2]))) ? 1.0 : 0.0)
    end
    fnsym = get(_CG_UNARY_FN, op, nothing)
    if fnsym !== nothing
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return Expr(:call, fnsym, ev(ch[1]))
    end
    fnsym = get(_CG_MINMAX_FN, op, nothing)
    if fnsym !== nothing
        length(ch) >= 2 || throw(_CodegenDecline(:unsupported_op))
        return _cg_foldl(fnsym, Any[ev(c) for c in ch])
    end
    throw(_CodegenDecline(:unsupported_op))
end

# Closed function — the SAME payload dispatch and the SAME core kernels as the
# interpreters' `:fn` arms (compile.jl / access_kernel.jl), so interpolation
# is never reimplemented here. Specs ride the `tabs` tuple (field loads are
# hoisted by the compiler; the spec object is the very one the node carries).
function _cg_emit_fn(ctx::_CGCtx, kc, nd::_Node)
    pl = nd.payload
    ch = nd.children
    if pl isa Tuple{String,_InterpLinearSpec}
        sp = _cg_tab!(ctx, pl[2])
        return :(_interp_linear_core($sp, $(_cg_emit(ctx, kc, ch[1]))))
    elseif pl isa Tuple{String,_InterpBilinearSpec}
        sp = _cg_tab!(ctx, pl[2])
        return :(_interp_bilinear_core($sp, $(_cg_emit(ctx, kc, ch[1])),
                                       $(_cg_emit(ctx, kc, ch[2]))))
    elseif pl isa Tuple{String,_InterpSearchsortedSpec}
        sp = _cg_tab!(ctx, pl[2])
        # `convert(T, …)` exactly as the eval arms: the discrete index must
        # land in the evaluator's value type.
        return :(convert(_cgT, _interp_searchsorted_core($sp, $(_cg_emit(ctx, kc, ch[1])))))
    elseif pl isa Tuple{String,_InterpLinearLaneSpec}
        # Per-LANE spec table (kernel-class merge, oop_merge.jl): select THIS
        # cell's member spec by the box lane addressing, then call the SAME
        # core on the member's own table/axis — the interpreter's lane-spec
        # arm verbatim, bit-identical per lane by construction. The lane index
        # is `_interp_lane(h, midx)` on the loop multi-index, which is exactly
        # `_cg_boxaddr`'s exact-Int address (the `_AccStateTblBox` addressing;
        # its literal-1/zero-stride folding cannot change the index).
        h = pl[2]
        hs = _cg_tab!(ctx, h)
        sp = _cg_name(ctx, "sp")
        addr = _cg_boxaddr(ctx, kc, h.s1, h.s2, h.s3, h.off, _AK_NO_CONN, h)
        return :(let $sp = $hs.specs[$addr]
                     _interp_linear_core($sp, $(_cg_emit(ctx, kc, ch[1])))
                 end)
    elseif pl isa Tuple{String,_InterpBilinearLaneSpec}
        h = pl[2]
        hs = _cg_tab!(ctx, h)
        sp = _cg_name(ctx, "sp")
        addr = _cg_boxaddr(ctx, kc, h.s1, h.s2, h.s3, h.off, _AK_NO_CONN, h)
        return :(let $sp = $hs.specs[$addr]
                     _interp_bilinear_core($sp, $(_cg_emit(ctx, kc, ch[1])),
                                           $(_cg_emit(ctx, kc, ch[2])))
                 end)
    elseif pl isa Tuple{String,_InterpSearchsortedLaneSpec}
        # `convert(_cgT, …)` exactly as the scalar-spec arm above (and the
        # interpreter's lane-spec arm): the discrete index must land in the
        # evaluator's value type.
        h = pl[2]
        hs = _cg_tab!(ctx, h)
        sp = _cg_name(ctx, "sp")
        addr = _cg_boxaddr(ctx, kc, h.s1, h.s2, h.s3, h.off, _AK_NO_CONN, h)
        return :(let $sp = $hs.specs[$addr]
                     convert(_cgT, _interp_searchsorted_core($sp, $(_cg_emit(ctx, kc, ch[1]))))
                 end)
    elseif pl isa Tuple{String,_FnTypedCoreSpec}
        # Registry-declared typed scalar core (ess-dtcore). `_cgT === Float64`
        # folds under the constant propagation the per-chunk `local _cgT =
        # _rhs_value_type(u, p, t)` exists to enable: the Float64 specialization
        # calls the typed core with the row id spliced as a LITERAL — the
        # ladder in `_fn_typed_core_call` then folds to the one core, no arg
        # box — and the `Dual` specialization keeps the boxed registry-on-`T`
        # route below verbatim (AD widening unchanged). The `let` binds the
        # query once so the two arms cannot double-evaluate it.
        spec = pl[2]
        x = _cg_name(ctx, "x")
        return :(let $x = $(_cg_emit(ctx, kc, ch[1]))
                     _cgT === Float64 ?
                         _fn_typed_core_call($(spec.id), $x) :
                         convert(_cgT, _eval_closed_fn($(pl[1]::String), Any[$x], _cgT))
                 end)
    elseif pl isa Tuple{String,Nothing}
        # Boxed all-scalar closed fn WITHOUT a typed-core row (none in the
        # v0.3.0 set): same eager `Any[…]` arg boxing, same `_eval_closed_fn`
        # registry-on-`T` call, same convert.
        args = Any[_cg_emit(ctx, kc, c) for c in ch]
        return :(convert(_cgT, _eval_closed_fn($(pl[1]::String),
                     $(Expr(:ref, :Any, args...)), _cgT)))
    end
    throw(_CodegenDecline(:fn_payload))
end

# ---- Invariant tier → prologue locals (mirrors `_fill_invariant!`) ----------
# Emitted once per kernel OBJECT (a sub-kernel shared by several parents is
# recomputed-identical, so one fill is the same values). The dummy cell
# context (c=1, n=0, oln=1, midx=(1,1,1)) is `_fill_invariant!`'s — invariant
# recipes contain no cell-varying access, so it is never consulted, but a
# hand-built kernel that violates that reproduces the interpreter's reads.
function _cg_inv!(ctx::_CGCtx, K::_AccKernel)
    syms = get(ctx.invdone, K, nothing)
    syms === nothing || return syms
    syms = Symbol[]
    kc = _CGKernCtx(K, 1, 0, 1, 1, 1, 1, Symbol[], syms)
    ctx.invdone[K] = syms
    push!(ctx.invlog, K)
    # Geometry an invariant recipe reads (a fixed slot) is read into the
    # prologue too, just ahead of the statement that uses it.
    _cg_with_geosink(ctx, ctx.prologue) do
        for r in K.cse.inv_recipes
            e = _cg_bound_body!(ctx, _cg_emit(ctx, kc, r))
            s = _cg_name(ctx, "v")
            push!(ctx.prologue, :(local $s = $e))
            push!(syms, s)
        end
    end
    return syms
end

# ---- One kernel → its loop nest (mirrors `_run_acc_kernel!`) ----------------
# CHUNK-PARAMETERIZED (threaded cell axis, see "Threaded cell axis for the
# codegen tier" below): every loop nest iterates the cell ordinals `[a, b)` of
# ITS OWN cell set for chunk `_cgci` of `_cgnc`, where `(a, b)` is the shared
# static partition (`_chunk_ordinals`, access_kernel.jl — one arithmetic, not
# re-derived). The serial call is the `(1, 1)` instance: `a == 0, b == ncells`
# reproduces today's full loops with the inner-loop body instruction-identical
# (outs/contig/rank-1 boxes differ only in loop-bound arithmetic; rank-2/3
# boxes add two per-ROW range clamps that select the full range at `(1, 1)`).
# Partition and iteration order are pure functions of `(ncells, nchunks)`, and
# a cell computes the same instruction sequence on the same inputs whichever
# chunk it lands in, so any chunking reproduces the serial values BIT FOR BIT
# as long as no two cells share a `du` slot (checked at build — see
# `_cg_covered_outs_disjoint`).
# Structural CELL-BODY function (ess-cg-cell-fn): the same canonicalize/
# parametrize/dedup treatment `_cg_subcall_fn!` gives a template sub-kernel,
# applied to a PARENT kernel's whole per-cell body (recipes + `du[oln] = spine`).
# The payoff is across REGION CLASSES: a rule compiled over many wrap/donor/
# corner boxes mints one `_AccKernel` per class whose bodies differ only in
# descriptor deltas and tab positions — exactly what the abstraction lifts into
# arguments — so sixty class kernels compile a handful of distinct functions
# instead of sixty ~50k-node loop bodies. Under the floor (or with the tier
# off) the body is spliced into the loop nest exactly as before.
function _cg_cell_fn!(ctx::_CGCtx, K::_AccKernel, invsyms::Vector{Symbol})
    got = get(ctx.subfn, K, nothing)
    got === :inline && return nothing
    got !== nothing && return got
    c = :_cgsc; n = :_cgsn; oln = :_cgso
    m1 = :_cgsm1; m2 = :_cgsm2; m3 = :_cgsm3
    nodes0 = ctx.nodes
    inner = _CGKernCtx(K, c, n, oln, m1, m2, m3, Symbol[], Symbol[])
    subivt0 = ctx.subivt
    ctx.subivt = true
    local body0
    try
        stmts = Any[]
        for r in K.cse.recipes
            e = _cg_emit(ctx, inner, r)
            s = _cg_name(ctx, "q")
            push!(stmts, :(local $s = $e))
            push!(inner.cellsyms, s)
        end
        spine = _cg_emit(ctx, inner, K.spine)
        body0 = Expr(:block, stmts..., :(du[$oln] = $spine))
    finally
        ctx.subivt = subivt0
    end
    if ctx.nodes - nodes0 <= _cg_subcall_fn_min_nodes()
        ctx.nodes = nodes0
        ctx.subfn[K] = :inline
        push!(ctx.sublog, K)
        return nothing
    end
    ab = _CGAbs()
    kb = _cg_abstract!(ab, body0)
    key = string(kb)
    hit = get(ctx.substruct, key, nothing)
    if hit !== nothing
        ctx.nodes = nodes0
        _tally_cascade!(:cg_cell_struct_hit)
        fname, extra = hit
        entry = (fname, extra, ab.ints, ab.flts)
        ctx.subfn[K] = entry
        push!(ctx.sublog, K)
        return entry
    end
    body = _cg_bound_body!(ctx, kb)
    syms = Set{Symbol}()
    _cg_collect_syms!(syms, body)
    bound = _cg_collect_bound!(Set{Symbol}(), body)
    ctxparams = (c, n, oln, m1, m2, m3, :_cgai, :_cgaf, :_cgivt)
    extra = sort!([s for s in syms
                   if _cg_is_passable(s) && !(s in bound) && !(s in ctxparams)];
                  by = string)
    fname = _cg_name(ctx, "h")
    ln = LineNumberNode(0, Symbol("ess-cg-cell-fn"))
    fstmts = Any[]
    (:_cgT in syms) && push!(fstmts, :(local _cgT = _rhs_value_type(u, p, t)))
    push!(fstmts, Expr(:macrocall, Symbol("@inbounds"), ln,
                       Expr(:block, body, :(return nothing))))
    params = Symbol[:du, :u, :p, :t, c, n, oln, m1, m2, m3, :_cgai, :_cgaf, :_cgivt]
    append!(params, extra)
    fdef = Expr(:function, Expr(:call, fname, params...), Expr(:block, fstmts...))
    push!(ctx.helpers, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
    _tally_cascade!(:cg_cell_fn)
    ctx.substruct[key] = (fname, extra)
    push!(ctx.substruct_log, key)
    entry = (fname, extra, ab.ints, ab.flts)
    ctx.subfn[K] = entry
    push!(ctx.sublog, K)
    return entry
end

function _cg_emit_kernel!(ctx::_CGCtx, K::_AccKernel)
    # Invariant tiers, nested-first (K.subs holds every transitive sub).
    for S in K.subs
        _cg_inv!(ctx, S)
    end
    invsyms = _cg_inv!(ctx, K)
    # The kernel's geometry locals head its own block, outside every loop, so a
    # chunk sub-function that carries the nest carries them too.
    geo = Any[]
    nest = _cg_with_geosink(ctx, geo) do
        _cg_tbl_versions(() -> _cg_emit_kernel_nest!(ctx, K, invsyms), ctx)
    end
    isempty(geo) && return nest
    return Expr(:block, geo..., nest)
end

# A nest that reads the state through slot tables (`_AK_STATE_TBL_BOX`) is
# emitted twice: once with each read in its general form (a run, a table with
# no ghost, or one with ghosts, chosen per table by run-time data), and once
# with every read as its run form, `u[base + address]`, behind a test that
# every table of the nest is a run. A stencil whose tables are runs at this
# grid size runs a loop with no table in it, which the compiler can vectorize,
# whatever the general form's branches; and the general form's loop, which
# gathers, stays scalar (`_cg_tblread!`). Both forms read the same slot of `u`
# for every cell, so the values are the same.
function _cg_tbl_versions(emit, ctx::_CGCtx)
    cbs0 = ctx.tblcbs
    ctx.tblcbs = Symbol[]
    try
        nestG = emit()
        isempty(ctx.tblcbs) && return nestG
        cond = nothing
        for cb in unique(ctx.tblcbs)
            c = :($cb >= 0)
            cond = cond === nothing ? c : :($cond && $c)
        end
        ctx.tblaffine = true
        nestA = try
            emit()
        finally
            ctx.tblaffine = false
        end
        return :(if $cond
                     $nestA
                 else
                     $nestG
                 end)
    finally
        ctx.tblcbs = cbs0
    end
end

# A fused scan's consumer cell (scan_fused.jl): kernel `cons.K`'s body at the
# state slot `oln - delta`, with its scanned-observed read as the local `xv`,
# stored into the state part of `du`.
function _cg_scan_consumer_cell(ctx::_CGCtx, cons, oln::Symbol, xv::Symbol)
    Kc = cons.K
    oc = _cg_name(ctx, "oc")
    d = _cg_geo!(ctx, cons.delta, (Kc, :scan_consumer_delta))
    kc = _CGKernCtx(Kc, oc, 0, oc, 1, 1, 1, Symbol[], cons.invsyms)
    stmts = Any[:(local $oc = $oln - $d)]
    ctx.subst = (Kc, cons.ix, xv)
    try
        _cg_emit_recipes!(stmts, ctx, kc)
        val = _cg_bound_body!(ctx, _cg_emit(ctx, kc, Kc.spine))
        push!(stmts, :(_cg_bufS(du)[$oc] = $val))
    finally
        ctx.subst = nothing
    end
    return stmts
end

function _cg_emit_kernel_nest!(ctx::_CGCtx, K::_AccKernel, invsyms::Vector{Symbol})
    sm = ctx.scanmode
    _cg_note_nest!(ctx, K)
    cellfn = (sm === nothing && _cg_split_supported() && !_cg_subcall_fn_disabled() &&
              length(K.cells.strides) <= 3) ?
             _cg_cell_fn!(ctx, K, invsyms) : nothing

    # Per-cell body: a CALL to the shared cell function when the structural
    # tier is serving this kernel; otherwise CSE recipes as locals (converted
    # to T exactly where the interpreter's scratch store converts), then the
    # spine into du[oln] — spliced into the loop nest as before.
    function cellbody(kc::_CGKernCtx)
        if cellfn !== nothing
            fname, extra, ints, flts =
                cellfn::Tuple{Symbol,Vector{Symbol},Vector{Int},Vector{Float64}}
            _cg_budget!(ctx)
            return Any[Expr(:call, fname, :du, :u, :p, :t, kc.c, kc.n, kc.oln,
                            kc.mi1, kc.mi2, kc.mi3,
                            _cg_tab!(ctx, ints), _cg_tab!(ctx, flts),
                            Expr(:tuple, invsyms...), extra...)]
        end
        stmts = _cg_emit_recipes!(Any[], ctx, kc)
        val = _cg_bound_body!(ctx, _cg_emit(ctx, kc, K.spine))
        if sm === nothing
            push!(stmts, :(du[$(kc.oln)] = $val))
        else
            # A fused scan's cell (scan_fused.jl): the term, converted exactly
            # as its store into `du` would convert it, folded into the lane's
            # running value in `_scan_lanes!`'s order.
            tv = _cg_name(ctx, "term")
            acc = sm.acc
            push!(stmts, :(local $tv = convert(eltype(du), $val)))
            cons = sm.cons
            if cons === nothing
                if sm.inclusive
                    push!(stmts, :($acc = $(sm.op)($acc, $tv)))
                    push!(stmts, :(du[$(kc.oln)] = $acc))
                else
                    push!(stmts, :(du[$(kc.oln)] = $acc))
                    push!(stmts, :($acc = $(sm.op)($acc, $tv)))
                end
            else
                # The cell's value as the store converts it, stored (unless the
                # store was dropped), then the consumer's cell computed from it.
                sm.inclusive && push!(stmts, :($acc = $(sm.op)($acc, $tv)))
                xv = _cg_name(ctx, "x")
                push!(stmts, :(local $xv = convert(eltype(du), $acc)))
                cons.store && push!(stmts, :(_cg_oview(du)[$(kc.oln)] = $xv))
                append!(stmts, _cg_scan_consumer_cell(ctx, cons, kc.oln, xv))
                sm.inclusive || push!(stmts, :($acc = $(sm.op)($acc, $tv)))
            end
        end
        return stmts
    end

    cs = K.cells
    # This kernel's chunk of the cell-ordinal axis (0-based, half-open).
    ncells = _cellset_ncells(cs)
    tv = _cg_name(ctx, "ab")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    # Every bound, base and stride below is run-time geometry (`_cg_geo!`),
    # except the extent of a boundary slab's thin axis (`_cellset_slab`), and
    # the count of a box that is a slab on every axis: it is one cell at every
    # N, and a literal extent lets the compiler drop that axis's loop, where a
    # run-time one leaves a loop set up (and vectorized) for a single cell per
    # row. The slab's index stays data, so the far edge's is one function too.
    geo(v, f, unit::Bool=false) = _cg_geo!(ctx, v, (cs, f), unit)
    function axis(d)
        lo = geo(first(cs.ranges[d]), (d, :first))
        _cellset_slab(cs, d) && return (lo, lo, 1)
        n = length(cs.ranges[d])
        return (lo, geo(last(cs.ranges[d]), (d, :last)), geo(n, (d, :len)))
    end
    corner = !isempty(cs.strides) && all(d -> _cellset_slab(cs, d), eachindex(cs.strides))
    hdr = if sm === nothing
        Any[:(local $tv = _chunk_ordinals($(corner ? 1 : geo(ncells, :n)), _cgci, _cgnc)),
            :(local $av = $tv[1]),
            :(local $bv = $tv[2])]
    else
        # A fused scan's nest runs the one lane its caller bound.
        av = sm.a
        bv = sm.b
        Any[]
    end
    if _is_outs(cs)
        outs = _cg_tab!(ctx, cs.outs)
        c = _cg_name(ctx, "c")
        oln = _cg_name(ctx, "o")
        kc = _CGKernCtx(K, c, 0, oln, c, 1, 1, Symbol[], invsyms)
        ctx.tblread = false
        body = cellbody(kc)
        tv1 = _cg_tblread!(ctx)
        return quote
            $(hdr...)
            for $c in ($av + 1):$bv
                local $oln = $outs[$c]
                $(body...)
                $(tv1...)
            end
        end
    elseif _is_contig(cs)
        c0 = geo(first(cs.ranges[1]), (1, :first))
        c = _cg_name(ctx, "c")
        kc = _CGKernCtx(K, c, 0, c, c, 1, 1, Symbol[], invsyms)
        ctx.tblread = false
        body = cellbody(kc)
        tv1 = _cg_tblread!(ctx)
        return quote
            $(hdr...)
            for $c in ($c0 + $av):($c0 + $bv - 1)
                $(body...)
                $(tv1...)
            end
        end
    end
    # Strided Cartesian box, rank ≤ 3, in `_run_box_kernel!`'s exact iteration
    # order (k-outer, i-inner). c == oln for a box. The flat cell ordinal `o`
    # of `(i, j, k)` is `(i-i0) + ni·((j-j0) + nj·(k-k0))` — exactly the serial
    # enumeration position — and a chunk `[a, b)` is walked as whole i-ROWS
    # with the FIRST and LAST row's i-range clamped to the chunk boundary
    # (the decode is hoisted to the row level so the inner loop stays today's
    # instructions).
    nd = length(cs.strides)
    nd <= 3 || return _cg_emit_box_rank_n(ctx, K, cs, hdr, av, bv, cellbody, geo, axis)
    st = Any[_cg_geo!(ctx, cs.strides[d], (cs, d, :stride), true) for d in 1:nd]
    iv = _cg_name(ctx, "i")
    jv = nd >= 2 ? _cg_name(ctx, "j") : 1
    kv = nd >= 3 ? _cg_name(ctx, "k") : 1
    oln = _cg_name(ctx, "o")
    olnexpr = :($(geo(cs.base, :base)) + $iv * $(st[1]))
    nd >= 2 && (olnexpr = :($olnexpr + $jv * $(st[2])))
    nd >= 3 && (olnexpr = :($olnexpr + $kv * $(st[3])))
    kc = _CGKernCtx(K, oln, 0, oln, iv, jv, kv, Symbol[], invsyms)
    ctx.tblread = false
    body = cellbody(kc)
    # The innermost loop's own annotation: kept scalar when it gathers through
    # a slot table (`_cg_tblread!`).
    tv1 = _cg_tblread!(ctx)
    i0, i1, ni = axis(1)
    if nd == 1 && cellfn === nothing && sm === nothing
        inter = _cg_areduce_interchanged(ctx, K, kc, iv, oln, olnexpr, i0, av, bv)
        if inter !== nothing
            return quote
                $(hdr...)
                if _cgT === Float64 && eltype(du) === Float64
                    $inter
                else
                    for $iv in ($i0 + $av):($i0 + $bv - 1)
                        local $oln = $olnexpr
                        $(body...)
                        $(tv1...)
                    end
                end
            end
        end
    end
    if nd == 1
        return quote
            $(hdr...)
            for $iv in ($i0 + $av):($i0 + $bv - 1)
                local $oln = $olnexpr
                $(body...)
                $(tv1...)
            end
        end
    end
    ohi = _cg_name(ctx, "e")          # last ordinal of the chunk (b - 1)
    # A box one cell thick along its leading axis (a boundary slab of a
    # stencil's x faces) runs one cell per i-loop, so once LLVM folds that
    # loop the j (or k) loop is innermost, and it strides through `u` by a
    # whole row: vectorizing it turns every operand into a gather, which is
    # several times slower than the scalar loop. The outer loops of such a box
    # are kept scalar. Leaving a loop scalar never changes a value.
    nv = _cellset_slab(cs, 1) ? Any[_cg_novec()] : Any[]
    ilo = _cg_name(ctx, "il")
    ihi = _cg_name(ctx, "ih")
    jlo = _cg_name(ctx, "jl")
    jhi = _cg_name(ctx, "jh")
    j0, j1, _ = axis(2)
    if nd == 2
        return quote
            $(hdr...)
            if $av < $bv
                local $ohi = $bv - 1
                local $jlo = $j0 + div($av, $ni)
                local $jhi = $j0 + div($ohi, $ni)
                for $jv in $jlo:$jhi
                    local $ilo = $jv == $jlo ? $i0 + rem($av, $ni) : $i0
                    local $ihi = $jv == $jhi ? $i0 + rem($ohi, $ni) : $i1
                    for $iv in $ilo:$ihi
                        local $oln = $olnexpr
                        $(body...)
                        $(tv1...)
                    end
                    $(nv...)
                end
            end
        end
    end
    # nd == 3: rows are indexed by the flat (j, k) row ordinal `r = o ÷ ni`;
    # the chunk's first/last row clamp j (per k) and i (on exactly the first
    # and last row, `k == klo && j == jlo` / `k == khi && j == jhi`).
    rlo = _cg_name(ctx, "rl")
    rhi = _cg_name(ctx, "rh")
    klo = _cg_name(ctx, "kl")
    khi = _cg_name(ctx, "kh")
    nj = axis(2)[3]; k0 = axis(3)[1]
    return quote
        $(hdr...)
        if $av < $bv
            local $ohi = $bv - 1
            local $rlo = div($av, $ni)
            local $rhi = div($ohi, $ni)
            local $klo = $k0 + div($rlo, $nj)
            local $khi = $k0 + div($rhi, $nj)
            for $kv in $klo:$khi
                local $jlo = $kv == $klo ? $j0 + rem($rlo, $nj) : $j0
                local $jhi = $kv == $khi ? $j0 + rem($rhi, $nj) : $j1
                for $jv in $jlo:$jhi
                    local $ilo = ($kv == $klo && $jv == $jlo) ? $i0 + rem($av, $ni) : $i0
                    local $ihi = ($kv == $khi && $jv == $jhi) ? $i0 + rem($ohi, $ni) : $i1
                    for $iv in $ilo:$ihi
                        local $oln = $olnexpr
                        $(body...)
                        $(tv1...)
                    end
                    $(nv...)
                end
                $(nv...)
            end
        end
    end
end

# ---- Row-fused box kernels ---------------------------------------------------
# A stencil's region classes split each row of the grid along its leading axis:
# the two faces, the near-face classes and the interior of a row are separate
# box kernels with the same rows (identical ranges along every other axis).
# Emitted one by one, each kernel walks all the rows again, and a face kernel
# one cell thick runs a loop per row for that one cell. Row fusion emits such a
# group as ONE nest over the shared rows whose row body runs every member's
# segment of that row in leading-axis order, the way a hand-written loop peels a
# row's ends: each member's cells keep their own body, their own geometry and
# their own invariants, so every cell evaluates the op sequence it did alone.
# Members write disjoint cells (the section's out-slot check covers them) and
# read only `u`, so running them row by row instead of kernel by kernel cannot
# change a value. The threaded cell axis chunks the group's ROWS, so a chunk
# still writes whole cells no other chunk writes.

# The rows a box kernel shares with others of its group, or `nothing` when it is
# not a rank-2/3 box kernel the emitter compiles as its own nest.
function _cg_rowfuse_key(K::_AccKernel)
    cs = K.cells
    nd = length(cs.strides)
    (_is_outs(cs) || !(2 <= nd <= 3)) && return nothing
    return (nd, cs.base, Tuple(cs.strides), Tuple(cs.ranges[2:nd]),
            Tuple(_cellset_slab(cs, d) for d in 2:nd))
end

# Groups of kernel indices to row-fuse (two or more members, leading-axis
# ranges pairwise disjoint, ordered along that axis), keyed by the index of
# the group's first kernel in build order.
function _cg_rowfuse_groups(kernels::AbstractVector{_AccKernel})
    out = Dict{Int,Vector{Int}}()
    (_cg_split_supported() && !_cg_subcall_fn_disabled()) && return out
    byrow = Dict{Any,Vector{Int}}()
    for (j, K) in enumerate(kernels)
        key = _cg_rowfuse_key(K)
        key === nothing || push!(get!(byrow, key, Int[]), j)
    end
    for js in values(byrow)
        length(js) >= 2 || continue
        ord = sort(js; by = j -> first(kernels[j].cells.ranges[1]))
        ok = all(m -> last(kernels[ord[m-1]].cells.ranges[1]) <
                      first(kernels[ord[m]].cells.ranges[1]), 2:length(ord))
        ok && (out[minimum(js)] = ord)
    end
    return out
end

function _cg_emit_rowgroup!(ctx::_CGCtx, Ks::Vector{_AccKernel})
    invs = Vector{Vector{Symbol}}()
    for K in Ks
        for S in K.subs
            _cg_inv!(ctx, S)
        end
        push!(invs, _cg_inv!(ctx, K))
    end
    geo = Any[]
    nest = _cg_with_geosink(ctx, geo) do
        _cg_tbl_versions(() -> _cg_emit_rowgroup_nest!(ctx, Ks, invs), ctx)
    end
    return Expr(:block, geo..., nest)
end

function _cg_emit_rowgroup_nest!(ctx::_CGCtx, Ks::Vector{_AccKernel},
                                 invs::Vector{Vector{Symbol}})
    cs1 = Ks[1].cells
    nd = length(cs1.strides)
    # The same geometry rules as `_cg_emit_kernel_nest!`: bounds, base and
    # strides are run-time data, a slab's thin extent a literal.
    function axis(cs, d)
        g(v, f) = _cg_geo!(ctx, v, (cs, f))
        lo = g(first(cs.ranges[d]), (d, :first))
        _cellset_slab(cs, d) && return (lo, lo, 1)
        return (lo, g(last(cs.ranges[d]), (d, :last)), g(length(cs.ranges[d]), (d, :len)))
    end
    st = Any[_cg_geo!(ctx, cs1.strides[d], (cs1, d, :stride), true) for d in 1:nd]
    base = _cg_geo!(ctx, cs1.base, (cs1, :base))
    jv = _cg_name(ctx, "j")
    kv = nd >= 3 ? _cg_name(ctx, "k") : 1
    j0, j1, nj = axis(cs1, 2)
    k0, _, nk = nd >= 3 ? axis(cs1, 3) : (1, 1, 1)
    olnof(iv) = (e = :($base + $iv * $(st[1]) + $jv * $(st[2]));
                 nd >= 3 ? :($e + $kv * $(st[3])) : e)
    seg(iv, i0, i1, oln, body) = quote
        for $iv in $i0:$i1
            local $oln = $(olnof(iv))
            $(body...)
        end
    end
    parts = Any[]
    for (m, K) in enumerate(Ks)
        iv = _cg_name(ctx, "i")
        oln = _cg_name(ctx, "o")
        _cg_note_nest!(ctx, K)
        kc = _CGKernCtx(K, oln, 0, oln, iv, jv, kv, Symbol[], invs[m])
        ctx.tblread = false
        rec = _cg_emit_recipes!(Any[], ctx, kc)
        val = _cg_bound_body!(ctx, _cg_emit(ctx, kc, K.spine))
        tv1 = _cg_tblread!(ctx)
        i0, i1, _ = axis(K.cells, 1)
        push!(parts, (; iv, oln, rec, val, i0, i1, tv1))
    end
    segs = Any[seg(q.iv, q.i0, q.i1, q.oln,
                   Any[q.rec..., :(du[$(q.oln)] = $(q.val)), q.tv1...])
               for q in parts]
    fis = _cg_row_fission(ctx, Ks, parts)
    if fis !== nothing
        holes, stages, iF, oF = fis
        fsegs = Any[seg(q.iv, q.i0, q.i1, q.oln, Any[:(du[$(q.oln)] = $(holes[m]))])
                    for (m, q) in enumerate(parts)]
        # A stage reads and writes only its own cell's `du` slot, so its
        # iterations are independent; `julia.ivdep` says so to the loop
        # vectorizer, which cannot prove it for a load and a store of one
        # array. It licenses no reassociation (that is `julia.simdloop`).
        for F in stages
            push!(fsegs, seg(iF, parts[1].i0, parts[end].i1, oF,
                             Any[:(du[$oF] = $F), Expr(:loopinfo, Symbol("julia.ivdep"))]))
        end
        # The split form stores each segment's hole value in `du` and reads it
        # back, which is exact only when that value already has `du`'s element
        # type: it does when `u`, `du` and the value type agree (the hole reads
        # `u`), and every other call takes the one-pass form.
        segs = Any[quote
            if eltype(u) === _cgT && eltype(du) === _cgT
                $(fsegs...)
            else
                $(segs...)
            end
        end]
        _tally_cascade!(:cg_row_fission)
    end
    tv = _cg_name(ctx, "ab")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    hdr = Any[:(local $tv = _chunk_ordinals($nj * $nk, _cgci, _cgnc)),
              :(local $av = $tv[1]),
              :(local $bv = $tv[2])]
    if nd == 2
        return quote
            $(hdr...)
            for $jv in ($j0 + $av):($j0 + $bv - 1)
                $(segs...)
            end
        end
    end
    ohi = _cg_name(ctx, "e")
    klo = _cg_name(ctx, "kl")
    khi = _cg_name(ctx, "kh")
    jlo = _cg_name(ctx, "jl")
    jhi = _cg_name(ctx, "jh")
    return quote
        $(hdr...)
        if $av < $bv
            local $ohi = $bv - 1
            local $klo = $k0 + div($av, $nj)
            local $khi = $k0 + div($ohi, $nj)
            for $kv in $klo:$khi
                local $jlo = $kv == $klo ? $j0 + rem($av, $nj) : $j0
                local $jhi = $kv == $khi ? $j0 + rem($ohi, $nj) : $j1
                for $jv in $jlo:$jhi
                    $(segs...)
                end
            end
        end
    end
end

# ---- Loop interchange for an affine reduction over a strided operand --------
# A rank-1 kernel whose whole cell value is one affine reduction
# (`du[o] = ⊕_j body(i, j)`, `_cg_emit_areduce`) runs the reduction innermost,
# so an operand read contiguously along the CELL axis and at a large stride
# along the reduced one — `Σ_j K[i,j]·e[j]` over a column-major `K` — is walked
# at that large stride on every term. The interchanged nest keeps each cell's
# accumulator in its own `du` slot and runs the cells innermost:
#
#     du[o] = 0̄                          for every cell of the chunk
#     for each reduced tuple, in `_cg_emit_areduce`'s order
#         du[o] = du[o] ⊕ body(i, tuple)   for every cell of the chunk
#
# Every cell folds the same terms in the same order from the same Float64 seed,
# so each `du[o]` is bitwise the per-cell nest's; only the order in which
# different cells advance changes, and cells are independent. It is emitted for
# the Float64 value type only (the caller's branch): under any other type a
# `du` slot could not hold the Float64 seed unchanged (`_cg_fold` explains why
# that matters). Chosen when more of the body's box reads are contiguous (or
# invariant) along the cell axis and strided along the innermost reduced axis
# than the other way round. Returns the nest, or `nothing` when it does not
# apply.
function _cg_areduce_interchanged(ctx::_CGCtx, K::_AccKernel, kc::_CGKernCtx,
                                  iv::Symbol, oln::Symbol, olnexpr, i0, av, bv)
    nd = K.spine
    nd.kind === _NK_AREDUCE || return nothing
    isempty(K.cse.recipes) || return nothing
    spec = nd.payload::_AReduceSpec
    isempty(spec.dims) && return nothing
    _cg_reduce_strides_favor_cells(K, nd.children[1], spec.dims[1]) || return nothing
    fnsym = _cg_oplus_fn(nd.op)
    js = Symbol[_cg_name(ctx, "j") for _ in spec.dims]
    inner = kc
    for r in eachindex(spec.dims)
        inner = _cg_with_mi(inner, spec.dims[r], js[r])
    end
    body = _cg_emit(ctx, inner, nd.children[1])
    cap = _codegen_fn_node_cap()
    cap > 0 && _cg_expr_size(body) > cap && return nothing
    loop = quote
        for $iv in ($i0 + $av):($i0 + $bv - 1)
            local $oln = $olnexpr
            du[$oln] = $fnsym(du[$oln], $body)
        end
    end
    for r in eachindex(spec.dims)
        rg = spec.ranges[r]
        lo = _cg_geo!(ctx, first(rg), (spec.ranges, r, :lo))
        hi = _cg_geo!(ctx, last(rg), (spec.ranges, r, :hi))
        loop = Expr(:for, :($(js[r]) = $lo:$hi), Expr(:block, loop))
    end
    return quote
        for $iv in ($i0 + $av):($i0 + $bv - 1)
            du[$olnexpr] = $(nd.literal)
        end
        $loop
    end
end

# Whether the box reads under `body` favour the cell axis (loop dim 1) in the
# inner loop over the reduced axis `rdim`: a read gains when it is contiguous or
# invariant along the cells and strided along `rdim`, and loses the other way.
function _cg_reduce_strides_favor_cells(K::_AccKernel, body::_Node, rdim::Int)
    gain = 0
    stride(a::_AccDesc, d::Int) = d == 1 ? a.s1 : d == 2 ? a.s2 : d == 3 ? a.s3 :
        (d - 3 <= length(a.sx) ? a.sx[d - 3] : 0)
    near(s) = s == 0 || s == 1
    function visit(n::_Node)
        if n.kind === _NK_ACCESS
            a = K.acc[n.idx]
            if a.kind === _AK_STATE_TBL_BOX || a.kind === _AK_CONST_BOX ||
               a.kind === _AK_FORCING_BOX || a.kind === _AK_ARR_TBL_BOX
                so = stride(a, 1)
                sk = stride(a, rdim)
                near(so) && !near(sk) && (gain += 1)
                near(sk) && !near(so) && (gain -= 1)
            end
        end
        foreach(visit, n.children)
        return nothing
    end
    visit(body)
    return gain > 0
end

# ---- Row fission -------------------------------------------------------------
# The members of a row group often differ in ONE subexpression only: a
# transport cell is `-((Dx + Dy) + Dz)` where only `Dx` depends on the cell's
# class along the row, while `Dy` and `Dz` are the same expression with the same
# offsets for every segment. Evaluated per segment, the near-face segments (one
# cell wide) run all of it scalar. Row fission evaluates each segment's own
# subexpression (the hole) into `du`, then the shared context over the whole
# row in one loop that reads the hole back from `du`, the way a hand-written
# loop adds the y and z derivatives over a full row. Each cell computes the
# same operations on the same operands in the same order; the hole's value
# round-trips through `du` at its own element type (see the guard at the call
# site), so the result is bit-identical.
#
# Applies when: every member's body is a single expression (no per-cell CSE
# locals), there is no lazy guard anywhere in it, the members' leading-axis
# ranges tile the row with no gap, the bodies agree everywhere but at one
# position (compared with every geometry local replaced by its value, and each
# segment's own loop and slot variables by placeholders), the hole reads the
# state and is more than a leaf, and the context around it reads the state at
# least `_CG_FISSION_READS` times.
# Returns `(holes, F, iF, oF)` or `nothing`.
function _cg_row_fission(ctx::_CGCtx, Ks::Vector{_AccKernel}, parts)
    length(Ks) >= 2 || return nothing
    all(q -> isempty(q.rec), parts) || return nothing
    for m in 2:length(Ks)
        last(Ks[m-1].cells.ranges[1]) + 1 == first(Ks[m].cells.ranges[1]) || return nothing
    end
    gval = Dict{Symbol,Int}()
    for st in ctx.geosink
        (st isa Expr && st.head === :local && st.args[1] isa Expr) || continue
        a = st.args[1]
        r = a.args[2]
        # Geometry locals only (`_cg_geo!`'s `_cgG…`), not hoisted tables.
        startswith(String(a.args[1]), "_cgG") || continue
        (r isa Expr && r.head === :ref && r.args[2] isa Int) || continue
        gval[a.args[1]] = ctx.geo[r.args[2]]
    end
    canon(e, q) = e === q.iv ? :_cgFI : e === q.oln ? :_cgFO :
                  e isa Symbol ? get(gval, e, e) :
                  e isa Expr ? Expr(e.head, Any[canon(a, q) for a in e.args]...) : e
    lazy(e) = e isa Expr && (e.head in (:if, :&&, :||, :let, :block) ||
                             any(lazy, e.args))
    any(q -> lazy(q.val), parts) && return nothing
    cs = Any[canon(q.val, q) for q in parts]
    # The hole: descend while the members differ in exactly one child.
    function walk(es, at)
        e1 = es[1]
        all(e -> isequal(e, e1), es) && return nothing
        if e1 isa Expr && all(e -> e isa Expr && e.head === e1.head &&
                                  length(e.args) == length(e1.args), es)
            diffs = [i for i in eachindex(e1.args)
                     if !all(e -> isequal(e.args[i], e1.args[i]), es)]
            length(diffs) == 1 &&
                return walk(Any[e.args[diffs[1]] for e in es], (at..., diffs[1]))
        end
        return at
    end
    path = walk(cs, ())
    (path === nothing || isempty(path)) && return nothing
    sub(e, pth) = isempty(pth) ? e : sub(e.args[pth[1]], pth[2:end])
    reads_u(e) = e isa Expr && (_cg_is_uread(e) || any(reads_u, e.args))
    holes = Any[sub(q.val, path) for q in parts]
    all(reads_u, holes) || return nothing
    any(h -> h isa Expr && _cg_expr_size(h) >= 4, holes) || return nothing
    iF = _cg_name(ctx, "i")
    oF = _cg_name(ctx, "o")
    q1 = parts[1]
    rename(e) = e === q1.iv ? iF : e === q1.oln ? oF :
                e isa Expr ? Expr(e.head, Any[rename(a) for a in e.args]...) : e
    E = rename(q1.val)
    # The context, innermost ancestor of the hole first, cut into stages: a new
    # stage starts at an ancestor whose other operands read the state once the
    # current stage already holds one such ancestor. Each stage is one pass
    # over the row that reads the previous value back from `du`, so a long
    # context runs as a few short loops rather than one with many operand
    # streams, as a hand-written loop adds one axis's derivative per pass.
    stages = Any[]
    cur = :(du[$oF])
    nreads = 0
    total = 0
    for d in (length(path) - 1):-1:0
        node = sub(E, path[1:d])
        k = path[d + 1]
        sib = Set{Any}()
        for i in eachindex(node.args)
            (i == k || (node.head === :call && i == 1)) && continue
            _cg_state_reads!(sib, node.args[i])
        end
        if !isempty(sib) && nreads >= _CG_FISSION_READS
            push!(stages, cur)
            cur = :(du[$oF])
            nreads = 0
        end
        args = copy(node.args)
        args[k] = cur
        cur = Expr(node.head, args...)
        nreads += length(sib)
        total += length(sib)
    end
    push!(stages, cur)
    total >= _CG_FISSION_READS || return nothing
    return (holes, stages, iF, oF)
end

# Whether `e` is one emitted state read (`_cg_uread`).
_cg_is_uread(e::Expr) =
    e.head === :ref && (e.args[1] === :u ||
                        (e.args[1] isa Expr && e.args[1].head === :call &&
                         e.args[1].args[1] in (:_cg_bufS, :_cg_oview)))

# The distinct state reads (`u[…]`) in an emitted expression.
function _cg_state_reads!(acc::Set{Any}, e)
    e isa Expr || return acc
    if _cg_is_uread(e)
        push!(acc, e)
    else
        for a in e.args
            _cg_state_reads!(acc, a)
        end
    end
    return acc
end

# Row fission pays when the shared context is heavy enough that evaluating it
# once per row, vectorized, beats the extra pass through `du`: it needs at least
# this many distinct state reads, and a stage is closed (a new pass begun) once
# it holds this many.
const _CG_FISSION_READS = 8

# The loop annotation that keeps a loop scalar (LLVM's loop vectorizer off for
# it). It is the loop body's last statement, where `@simd` puts its own.
_cg_novec() = Expr(:loopinfo, (Symbol("llvm.loop.vectorize.enable"), false))

# A strided Cartesian box of rank above 3, in `_run_box_kernel!`'s iteration
# order (dim 1 fastest). The chunk `[a, b)` is walked as whole dim-1 ROWS, the
# same row walk the rank-2/3 nests use: the chunk's first row ordinal
# `r = a ÷ n1` is decoded into dims 2…D by division once, each later row steps
# that odometer by one (dim 2 fastest, carrying upward), so the inner loop is
# the rank-1 loop over `rowbase + i·s1`, and only the first and last row of a
# chunk clamp dim 1 to the chunk boundary. c == oln for a box.
function _cg_emit_box_rank_n(ctx::_CGCtx, K::_AccKernel, cs::_CellSet, hdr, av, bv,
                             cellbody, geo, axis)
    nd = length(cs.strides)
    st = Any[_cg_geo!(ctx, cs.strides[d], (cs, d, :stride), true) for d in 1:nd]
    ax = [axis(d) for d in 1:nd]
    lo = Any[a[1] for a in ax]
    hi = Any[a[2] for a in ax]
    len = Any[a[3] for a in ax]
    iv = _cg_name(ctx, "i")
    ovs = Any[iv]
    for d in 2:nd
        push!(ovs, _cg_name(ctx, "i"))
    end
    oln = _cg_name(ctx, "o")
    rowb = _cg_name(ctx, "rb")
    rowexpr = geo(cs.base, :base)
    for d in 2:nd
        rowexpr = :($rowexpr + $(ovs[d]) * $(st[d]))
    end
    kc = _CGKernCtx(K, oln, 0, oln, ovs[1], ovs[2], ovs[3], Symbol[], _cg_inv!(ctx, K),
                    Any[ovs[d] for d in 4:nd])
    ctx.tblread = false
    body = cellbody(kc)
    tv1 = _cg_tblread!(ctx)
    i0 = lo[1]; i1 = hi[1]; ni = len[1]
    ohi = _cg_name(ctx, "e")
    rlo = _cg_name(ctx, "rl")
    rhi = _cg_name(ctx, "rh")
    rv = _cg_name(ctx, "r")
    rr = _cg_name(ctx, "rr")
    ilo = _cg_name(ctx, "il")
    ihi = _cg_name(ctx, "ih")
    seek = Any[:(local $rr = $rlo)]
    for d in 2:nd
        push!(seek, :(local $(ovs[d]) = $(lo[d]) + rem($rr, $(len[d]))))
        d < nd && push!(seek, :($rr = div($rr, $(len[d]))))
    end
    # The odometer step after a row: dim 2 up by one, carrying into the next
    # dim when it passes its last index. Past the chunk's last row it may run
    # off the box; nothing reads it then.
    step = :($(ovs[nd]) += 1)
    for d in (nd - 1):-1:2
        step = quote
            if $(ovs[d]) < $(hi[d])
                $(ovs[d]) += 1
            else
                $(ovs[d]) = $(lo[d])
                $step
            end
        end
    end
    return quote
        $(hdr...)
        if $av < $bv
            local $ohi = $bv - 1
            local $rlo = div($av, $ni)
            local $rhi = div($ohi, $ni)
            $(seek...)
            for $rv in $rlo:$rhi
                local $ilo = $rv == $rlo ? $i0 + rem($av, $ni) : $i0
                local $ihi = $rv == $rhi ? $i0 + rem($ohi, $ni) : $i1
                local $rowb = $rowexpr
                for $iv in $ilo:$ihi
                    local $oln = $rowb + $iv * $(st[1])
                    $(body...)
                    $(tv1...)
                end
                $step
            end
        end
    end
end

# The read-only view of `u` the generated section's alias scope reads through
# (see `_build_codegen_rhs`). `Const` wraps an `Array` only.
@inline _cg_readonly(u::Array) = Base.Experimental.Const(u)
@inline _cg_readonly(s::_ObsSplitVec) =
    _ObsSplitVec(_cg_readonly(s.u), _cg_readonly(s.o), s.n)
@inline _cg_readonly(u) = u

# The `let` bindings a generated section runs its kernels under: `u` read-only,
# and on a two-buffer slot space `du` as the buffer all of `Ks`' cells write.
function _cg_section_bindings(nst::Int, Ks::AbstractVector{_AccKernel})
    b = Expr(:block, :(u = _cg_readonly(u)))
    if nst > 0
        side = _cg_slot_side(nst, _cg_oln_extent(Ks)...)
        side === :x || push!(b.args, :(du = _cg_dview(du, Val($(QuoteNode(side))))))
    end
    return b
end

# ---- Build the fused generated RHS section ----------------------------------
struct _CGBuilt{F,TB}
    f::F
    tabs::TB
    covered::Vector{Bool}
    # Why each UNCOVERED kernel was declined, parallel to `covered` (`:none`
    # where `covered[j]`). A strict compiler names the deepest of these when it
    # refuses a rule, so the reason has to survive the emission that produced
    # it — the tally counts reasons, it does not say which kernel had which.
    reasons::Vector{Symbol}
    # Threaded cell axis (see "Threaded cell axis for the codegen tier"):
    # total cells across the covered kernels, and the build-time verdict that
    # every covered out-slot is globally unique (section-chunking is only
    # enabled when it holds).
    ncells::Int
    outs_disjoint::Bool
end

# Build-time SECTION-chunking safety check: are the emitted kernels' output
# slots globally pairwise-distinct ACROSS the whole generated function? Only
# then may one chunk run ALL kernels' cell sub-ranges without a barrier —
# two chunks could otherwise read-modify-write one `du` slot from different
# kernels (indirect-out / scatter merges CAN alias across kernels; the
# `_KernelSection` derivative-section comment says they don't for state
# equations, but this VERIFIES rather than trusts, and materialized-observed
# sections go through the same builder). Returns `(total cells, disjoint)`.
function _cg_covered_outs_disjoint(acc_kernels::AbstractVector{_AccKernel},
                                   covered::Vector{Bool})
    ncells = 0
    for (j, K) in enumerate(acc_kernels)
        covered[j] || continue
        ncells += _cellset_ncells(K.cells)
    end
    return ncells, _cellsets_outs_unique(K.cells for (j, K) in enumerate(acc_kernels)
                                         if covered[j])
end

# Per-generated-FUNCTION emitted-node cap. The node budget above bounds total
# AST size; this bounds the size of any ONE compiled function, because LLVM's
# first-call compile memory is super-linear in single-function size (one ~400k-
# node function OOMs a 40 GB host). Loop nests are packed into `@noinline`
# sub-functions up to this cap so LLVM compiles bounded pieces. Override with
# ESS_CODEGEN_FN_NODE_CAP; 0 disables splitting (one function, one flat body).
# Every supported Julia can split (`_cg_split_by_value` picks the transport), so
# an oversized body is compiled rather than declined, on every version.
_codegen_fn_node_cap() =
    something(tryparse(Int, get(ENV, "ESS_CODEGEN_FN_NODE_CAP", "")), 20_000)

# Whether this Julia can carry an emitted sub-function as an INNER DEFINITION —
# a `function` written inside the emitted body. Julia < 1.12 cannot, and takes
# the by-value transport instead (`_cg_split_by_value`); the split itself is
# available on every version.
#
# Why an inner definition is version-dependent. The emitted body becomes a
# `RuntimeGeneratedFunction`, and RGF rewrites every inner definition into a
# `Base.Experimental.@opaque` closure — it has to, since the body is compiled
# inside a `@generated` function, which may not define methods — and an untyped
# opaque closure is `Core.OpaqueClosure{NTuple{N, Any}}`. On 1.10 and 1.11 that
# boxes every scalar crossing the boundary, which is a per-cell leak linear in
# the grid, and a NEST of them (a helper calling a helper) segfaults: the
# MethodError such a call raises crashes the runtime while it is being
# constructed. 1.12's optimizer types and elides the closure, which is why the
# inner-definition transport is allocation-free and stable only there.
#
# This also gates the EXPERIMENTAL sub-kernel function tier
# (`_cg_subcall_fn`/`_cg_cell_fn!`), which emits inner definitions of its own and
# has not been ported to the by-value transport. That tier ships off.
_cg_split_supported() = VERSION >= v"1.12"

# The name a by-value build gives the tuple of emitted sub-functions.
const _CG_FNS = :_cgfns

# TRANSPORT for the emitted sub-functions. There are two, and they emit the same
# code — they differ only in how a sub-function reaches the body that calls it.
#
#   INNER DEFINITION (Julia ≥ 1.12): the sub-function is an `@noinline function`
#     written inside the generated body and called by name. Cheapest, and what
#     the split shipped as, but it only works where RGF's rewrite of an inner
#     definition into an opaque closure is typed — see `_cg_split_supported`.
#
#   BY VALUE (Julia < 1.12, or `ESS_CODEGEN_SPLIT_TRANSPORT=value`): each
#     sub-function is compiled as its OWN `RuntimeGeneratedFunction` and handed
#     to the body at run time in a tuple, appended to the `tabs` argument; a call
#     site is `_cgfns[k](…)` at a LITERAL `k`, so the callee is a concrete
#     callable the compiler resolves statically — no closure is constructed, and
#     nothing is boxed. The tuple is threaded into every sub-function that calls
#     another, so nesting works to any depth.
#
# The second exists so `compiler=:native` can split a body on EVERY supported
# Julia. `native` is the tier that has to be universally available — no heavy
# external dependency, and no version where an oversized kernel has nowhere to
# go but the per-cell interpreter, which under the strict compiler is a refusal.
# (`:interpreter` stays the simple oracle; `sympy`/`mtk` only take some
# documents; `xla` needs heavy dependencies.) Both transports emit the SAME
# partitioned expression, so a build is value-identical either way — which is
# what the transport override is for: it makes the by-value path testable on a
# Julia that would otherwise never take it.
_cg_split_by_value() =
    !_cg_split_supported() || get(ENV, "ESS_CODEGEN_SPLIT_TRANSPORT", "") == "value"

# Every Symbol referenced anywhere in `ex` (recursively). Used to compute the
# exact set of outer-scope locals a chunk function must receive as arguments.
function _cg_collect_syms!(acc::Set{Symbol}, ex)
    if ex isa Symbol
        push!(acc, ex)
    elseif ex isa Expr
        for a in ex.args
            _cg_collect_syms!(acc, a)
        end
    end
    return acc
end

# LHS symbol of a prologue `local s = …` statement (the invariant-slot name).
function _cg_local_lhs(stmt)
    stmt isa Expr && stmt.head === :local || return nothing
    a = stmt.args[1]
    a isa Expr && a.head === :(=) ? a.args[1] : nothing
end

# ---- Intra-kernel body split (ess-iip-split) --------------------------------
# `_cg_emit` lowers one output cell to a SINGLE Julia expression. For a
# spine-dominated kernel that tree can be ~1e5 nodes; emitted as one function it
# blows the Julia compiler (compile is superlinear in single-function size — the
# duo LMARS momentum kernels OOM a 40 GB `:inplace` build). The kernel-CLASS
# merge already made the cell body grid-INDEPENDENT (one body over a lane axis),
# so the fix is purely to cap the SINGLE-FUNCTION size: partition the emitted
# expression so no generated function exceeds `_codegen_fn_node_cap`, while the
# WHOLE RHS stays compiled and NEVER touches the interpreter.
#
# The transform SPILLS an oversized sub-expression into an `@noinline` helper
# that RETURNS its value; the parent replaces the sub-expression with a CALL to
# that helper, sitting EXACTLY where the sub-expression was. Threading by return
# value (not a scratch buffer) means (a) laziness is preserved automatically — a
# spill inside an `ifelse`/`&&`/`||` arm becomes a call in that same arm, still
# only evaluated when the branch is taken; (b) zero allocation — helpers return
# scalars and capture nothing; (c) eltype-generic — each helper recomputes `_cgT`
# locally from `(u, p, t)`, exactly as the chunk sub-functions do. Bit-identical:
# the arithmetic and its evaluation order are unchanged, only wrapped in calls.
_cg_expr_size(ex) = ex isa Expr ? 1 + sum(_cg_expr_size, ex.args; init=0)::Int : 1

# True for a call to a split helper (`_cgh…(…)`) minted by `_cg_spill!` — an
# irreducible leaf of the partition (re-spilling it cannot shrink it).
function _cg_is_spill_call(ex)
    (ex isa Expr && ex.head === :call && !isempty(ex.args)) || return false
    f = ex.args[1]
    f isa Symbol && return startswith(String(f::Symbol), "_cgh")
    # By-value transport: the callee is `_cgfns[k]`, not a name. Recognising it
    # is what keeps `_cg_partition!` terminating — re-spilling a call wraps one
    # call in another of the same size.
    return f isa Expr && (f::Expr).head === :ref && !isempty((f::Expr).args) &&
           (f::Expr).args[1] === _CG_FNS
end

# A head that introduces its own scope / bindings (a `_NK_REDUCE`/subcall body is
# a `quote` block with a `local` accumulator and a `for` loop var). Partitioning
# must treat such a node ATOMICALLY — never hoist a sub-expression out of it,
# since that sub-expression may reference a name bound INSIDE it — so it is
# spilled whole (with its internal bindings excluded from the helper's params)
# or left inline, never cut open.
_cg_binding_head(h::Symbol) =
    h === :block || h === :for || h === :while || h === :let ||
    h === :local || h === :global || h === :function || h === :(->) || h === :do

# Names bound WITHIN `ex` (`local x`, `for x in …`, `x = …`, loop/let targets):
# excluded from a spilled helper's parameter list because the helper carries the
# binding with it, and the call site does not have that name in scope.
function _cg_collect_bound!(acc::Set{Symbol}, ex)
    ex isa Expr || return acc
    if ex.head === :(=) || ex.head === :local || ex.head === :global
        for a in ex.args
            if a isa Symbol
                push!(acc, a)
            elseif a isa Expr && a.head === :(=) && a.args[1] isa Symbol
                push!(acc, a.args[1])
            end
        end
    elseif ex.head === :for || ex.head === :while
        # `for v in range` / a `while`'s loop spec binds its target(s).
        spec = ex.args[1]
        if spec isa Expr && spec.head === :(=) && spec.args[1] isa Symbol
            push!(acc, spec.args[1])
        end
    end
    for a in ex.args
        _cg_collect_bound!(acc, a)
    end
    return acc
end

# An outer-scope local the emitter minted (coords, tabs, cellsyms, invsyms) —
# every such name is `_cg…` EXCEPT the value-type `_cgT` (recomputed inside each
# helper) and the split helpers `_cgh…` themselves (top-level names, called, not
# passed). Anything else a helper body references (u, p, t, global fns, literals)
# needs no argument.
_cg_is_passable(s::Symbol) =
    (n = String(s); startswith(n, "_cg") && s !== :_cgT && !startswith(n, "_cgh"))

# Spill `sub` (already ≤ cap) into a fresh `@noinline` helper returning its
# value; return the call expression that replaces it. Tab reads in `sub` are
# already the by-type container indices `_cggrpG[pos]` (ess-iip-tabgroup), so the
# helper's tab dependency is ONE argument per GROUP (a few concrete-typed
# containers) no matter how many distinct tabs it touches — this is what keeps
# the split's parameter/inference cost from exploding with the tab count.
function _cg_spill!(ctx::_CGCtx, sub)
    syms = Set{Symbol}()
    _cg_collect_syms!(syms, sub)                     # `_cggrpG` containers + coords + child calls
    bound = _cg_collect_bound!(Set{Symbol}(), sub)   # names the helper binds itself
    extra = sort!([s for s in syms if _cg_is_passable(s) && !(s in bound)]; by = string)
    params = Symbol[:u, :p, :t]
    append!(params, extra)
    # By-value transport: the helper is its own generated function, so the tuple
    # of helpers has to travel INTO it — a helper may call another. It is the
    # last parameter, and it is added unconditionally so the parameter list is a
    # function of the body alone, which is what the dedup key assumes.
    byval = _cg_split_by_value()
    (byval && !(_CG_FNS in params)) && push!(params, _CG_FNS)
    # Helper dedup: an identical body (same code ⇒ same params, since params are
    # exactly the passable names it references) reuses the first helper minted for
    # it. Only the CALL is re-emitted; the compiled function is shared. Value-exact
    # and laziness-preserving — a call in place of the sub-expression evaluates
    # exactly when the sub-expression would.
    dedup = !_cg_helper_dedup_disabled()
    key = dedup ? string(sub) : ""
    if dedup
        got = get(ctx.helper_dedup, key, nothing)
        if got !== nothing
            _tally_cascade!(:cg_helper_deduped)
            return Expr(:call, got, params...)
        end
    end
    ln = LineNumberNode(0, Symbol("ess-iip-split"))
    stmts = Any[]
    (:_cgT in syms) && push!(stmts, :(local _cgT = _rhs_value_type(u, p, t)))
    push!(stmts, Expr(:macrocall, Symbol("@inbounds"), ln, :(return $sub)))
    if byval
        # An ARGUMENT-TUPLE definition, compiled on its own at the end of the
        # build; `ctx.helpers` holds it at the position its call sites name, and
        # the decline rollback truncates that vector, so a declined kernel's
        # helpers and the calls to them disappear together.
        push!(ctx.helpers, Expr(:function, Expr(:tuple, params...),
                                Expr(:block, stmts...)))
        callee = Expr(:ref, _CG_FNS, length(ctx.helpers))
        dedup && (ctx.helper_dedup[key] = callee)
        return Expr(:call, callee, params...)
    end
    fname = _cg_name(ctx, "h")
    fdef = Expr(:function, Expr(:call, fname, params...), Expr(:block, stmts...))
    push!(ctx.helpers, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
    dedup && (ctx.helper_dedup[key] = fname)
    return Expr(:call, fname, params...)
end

# Partition `ex` so every generated function (this expression and every helper
# it spills) is ≤ `cap` nodes. Bottom-up: partition children first (each becomes
# ≤ cap), then, while this node's inlined size exceeds `cap`, spill its largest
# still-inline `Expr` child into a helper CALL (small). A node whose children are
# all spilled is `op(call, call, …)` — small — so the loop always terminates.
# Returns `(bounded_expr, size)`.
function _cg_partition!(ctx::_CGCtx, ex, cap::Int)
    ex isa Expr || return (ex, 1)
    # A scope-introducing node is atomic: do not recurse into it (a hoist could
    # escape a name bound inside). The caller may still spill it WHOLE.
    _cg_binding_head(ex.head) && return (ex, _cg_expr_size(ex))
    total = 1
    argsz = Vector{Int}(undef, length(ex.args))
    for i in eachindex(ex.args)
        (ex.args[i], argsz[i]) = _cg_partition!(ctx, ex.args[i], cap)
        total += argsz[i]
    end
    iscall = ex.head === :call
    while total > cap
        bi = 0; bs = 0
        for i in eachindex(ex.args)
            # The CALLEE position of a call is not a value to hoist. Under the
            # inner-definition transport it is a bare name and could never be
            # chosen anyway; under the by-value one it is `_cgfns[k]`, and
            # spilling it would mint a helper returning a FUNCTION.
            (iscall && i == 1) && continue
            a = ex.args[i]
            # Only a genuine sub-expression is worth spilling; an already-spilled
            # helper call is irreducible (spilling it again just wraps one call in
            # another of the SAME size — the non-termination this guards against).
            if a isa Expr && !_cg_is_spill_call(a) && argsz[i] > bs
                bs = argsz[i]; bi = i
            end
        end
        bi == 0 && break                       # only calls/leaves left — irreducible
        ex.args[bi] = _cg_spill!(ctx, ex.args[bi])
        newsz = _cg_expr_size(ex.args[bi])
        total += newsz - argsz[bi]
        argsz[bi] = newsz
    end
    return (ex, total)
end

# Cap an emitted cell expression to the per-function node target, spilling into
# helpers as needed. A no-op (returns `ex` unchanged, no helper minted) when it
# already fits — so small kernels keep the single-function fast path byte for
# byte. Off, it is the no-op: one flat body per kernel, which is the
# differential oracle and what reproduces the OOM.
function _cg_bound_body!(ctx::_CGCtx, ex)
    _compiler_plan_now().codegen_body_split || return ex
    cap = _codegen_fn_node_cap()
    cap <= 0 && return ex
    _cg_expr_size(ex) <= cap && return ex
    # Oversized: partition it. Which TRANSPORT carries the pieces depends on the
    # Julia (`_cg_split_by_value`), but every supported Julia has one, so an
    # oversized body is compiled rather than declined to the per-cell
    # interpreter — which under a strict compiler is a refusal, and would make
    # `native` unavailable on Julia < 1.12 for exactly the largest kernels.
    return _cg_partition!(ctx, ex, cap)[1]
end

# Emit + compile every codegen-able kernel into a RuntimeGeneratedFunction
# `(du, u, p, t, tabs, ci, nchunks) -> nothing` — the per-CHUNK form of the
# section (see `_cg_emit_kernel!`): each kernel's loop nest covers its cell
# ordinals `[a, b)` for chunk `ci` of `nchunks`, and `(1, 1)` is the serial
# call. The shared invariant prologue is computed
# once in the outer function; the kernel loop nests are partitioned into
# `@noinline` sub-functions (each ≤ `_codegen_fn_node_cap()` nodes) so no single
# function is too large for LLVM to compile. Each sub-function receives du/u/p/t
# plus exactly the outer locals (tables, `_cgT`, invariant slots) its loops
# reference, as explicit arguments — it captures nothing, so the RHS stays
# allocation-free. Kernels that decline stay on their existing runners
# (`covered[j] == false`). Returns `nothing` when no kernel could be emitted.
function _build_codegen_rhs(acc_kernels::AbstractVector{_AccKernel};
                            budget::Int=_codegen_node_budget(),
                            tally::Symbol=:codegen,
                            shared_cache::Union{Nothing,_CSECache}=nothing,
                            nst::Int=0)
    isempty(acc_kernels) && return nothing
    ctx = _CGCtx(budget, shared_cache; nst=nst)
    covered = fill(false, length(acc_kernels))
    reasons = fill(:none, length(acc_kernels))
    kloops = Tuple{Any,Int}[]         # (loop-nest expr, its emitted-node cost)
    # Row-fused groups (see `_cg_emit_rowgroup!`): a group is emitted at its
    # first member's position; if it declines, its members are emitted one by
    # one, exactly as without fusion.
    groups = _cg_rowfuse_groups(acc_kernels)
    ingroup = falses(length(acc_kernels))
    for (j, K) in enumerate(acc_kernels)
        if haskey(groups, j)
            js = groups[j]
            nprologue = length(ctx.prologue)
            ninvlog = length(ctx.invlog)
            nhelpers = length(ctx.helpers)
            nodes0 = ctx.nodes
            fscratch0 = ctx.fscratch
            empty!(ctx.helper_dedup)
            try
                lx = _cg_emit_rowgroup!(ctx, _AccKernel[acc_kernels[m] for m in js])
                push!(kloops, (lx, ctx.nodes - nodes0))
                for m in js
                    covered[m] = true
                    ingroup[m] = true
                    _tally_cascade!(Symbol(tally, :_kernel))
                end
                _tally_cascade!(:cg_rowfused_group)
                ctx.fscratch > fscratch0 && _tally_cascade!(:cg_foreign_scratch_emit)
            catch err
                err isa _CodegenDecline || rethrow()
                resize!(ctx.prologue, nprologue)
                for i in length(ctx.invlog):-1:(ninvlog + 1)
                    delete!(ctx.invdone, ctx.invlog[i])
                end
                resize!(ctx.invlog, ninvlog)
                resize!(ctx.helpers, nhelpers)
                ctx.nodes = nodes0
                ctx.fscratch = fscratch0
            end
        end
        ingroup[j] && continue
        # Snapshot for rollback: a mid-kernel decline must discard its partial
        # prologue statements AND its invariant registrations (a later kernel
        # sharing that sub-kernel would otherwise reference rolled-back locals).
        nprologue = length(ctx.prologue)
        ninvlog = length(ctx.invlog)
        nhelpers = length(ctx.helpers)
        nsublog = length(ctx.sublog)
        nstructlog = length(ctx.substruct_log)
        nodes0 = ctx.nodes
        fscratch0 = ctx.fscratch
        empty!(ctx.helper_dedup)   # dedup scope = this kernel (see the field doc)
        try
            lx = _cg_emit_kernel!(ctx, K)
            push!(kloops, (lx, ctx.nodes - nodes0))
            covered[j] = true
            _tally_cascade!(Symbol(tally, :_kernel))
            # Shared-prelude read observability (ess-cgfsc): this kernel
            # compiled carrying at least one such read.
            ctx.fscratch > fscratch0 && _tally_cascade!(:cg_foreign_scratch_emit)
        catch err
            err isa _CodegenDecline || rethrow()
            resize!(ctx.prologue, nprologue)
            for i in length(ctx.invlog):-1:(ninvlog + 1)
                delete!(ctx.invdone, ctx.invlog[i])
            end
            resize!(ctx.invlog, ninvlog)
            resize!(ctx.helpers, nhelpers)     # discard this kernel's split helpers
            # Sub-kernel function memo entries whose defs were just discarded
            # from `helpers` (a later kernel sharing S would otherwise call a
            # rolled-back name) — the `invdone` rollback's exact mirror.
            for i in length(ctx.sublog):-1:(nsublog + 1)
                delete!(ctx.subfn, ctx.sublog[i])
            end
            resize!(ctx.sublog, nsublog)
            for i in length(ctx.substruct_log):-1:(nstructlog + 1)
                delete!(ctx.substruct, ctx.substruct_log[i])
            end
            resize!(ctx.substruct_log, nstructlog)
            ctx.nodes = nodes0
            ctx.fscratch = fscratch0
            reasons[j] = err.reason
            _tally_cascade!(Symbol(tally, "_decline_", err.reason))
        end
    end
    any(covered) || return nothing
    ln = LineNumberNode(0, Symbol("ess-codegen"))

    # Outer locals a chunk may need as arguments: the table locals and every
    # invariant-slot local defined in the prologue. `_cgT` is deliberately NOT
    # passed — it is the value TYPE (a runtime `DataType`), and passing it across
    # the call boundary loses the constant-propagation that keeps `convert(_cgT,
    # …)` type-stable, boxing every scalar. Each chunk recomputes `_cgT` locally
    # from (u, p, t) instead, so inference constant-propagates it as before.
    ngrp = length(ctx.tab_types)
    outer_passed = Set{Symbol}()
    # The by-type tab containers (`_cggrpG`, one per distinct tab type — a handful,
    # not one per object) are the only tab locals now; every chunk / helper that
    # reads a tab references a container, so it receives that container.
    for g in 1:ngrp
        push!(outer_passed, _cg_grp_sym(g))
    end
    for stmt in ctx.prologue
        s = _cg_local_lhs(stmt)
        s === nothing || push!(outer_passed, s)
    end
    # The chunk index pair rides through like any other outer name: every
    # kernel loop nest references it (its `_chunk_ordinals` header), so the
    # sym-collection below forwards it into each `@noinline` sub-function.
    push!(outer_passed, :_cgci)
    push!(outer_passed, :_cgnc)
    # The helper tuple is an outer local in the by-value transport, so a chunk
    # that calls a helper receives it like any other outer name.
    byval = _cg_split_by_value()
    byval && push!(outer_passed, _CG_FNS)

    # Partition the loop nests into chunks capped by emitted-node count. A
    # non-positive cap means "one chunk".
    cap = _codegen_fn_node_cap()
    chunks = Vector{Vector{Any}}()
    cur = Any[]; curcost = 0
    for (lx, cost) in kloops
        if !isempty(cur) && cap > 0 && curcost + cost > cap
            push!(chunks, cur); cur = Any[]; curcost = 0
        end
        push!(cur, lx); curcost += cost
    end
    isempty(cur) || push!(chunks, cur)

    # One `@noinline` sub-function per chunk, taking du/u/p/t + exactly the outer
    # locals its loops reference (sorted for a deterministic signature).
    #
    # A SINGLE chunk is not a split -- the body is already under the cap -- so
    # its loops go straight into the kernel function instead, with no
    # sub-function at all.
    #
    # A genuine split (several chunks) emits one sub-function per chunk, carried
    # by whichever transport this Julia uses (`_cg_split_by_value`): an inner
    # `@noinline` definition called by name, or its own generated function
    # called out of the helper tuple.
    fndefs = Any[]; callstmts = Any[]
    if length(chunks) == 1
        push!(callstmts,
              Expr(:macrocall, Symbol("@inbounds"), ln, Expr(:block, chunks[1]...)))
    else
        for (ci, chunk) in enumerate(chunks)
            used = Set{Symbol}()
            for lx in chunk
                _cg_collect_syms!(used, lx)
            end
            passed = sort!(collect(intersect(used, outer_passed)); by = string)
            fbody = Expr(:block,
                         :(local _cgT = _rhs_value_type(u, p, t)),
                         Expr(:macrocall, Symbol("@inbounds"), ln, Expr(:block, chunk...)),
                         :(return nothing))
            if byval
                vparams = Symbol[:du, :u, :p, :t]
                append!(vparams, passed)
                push!(ctx.helpers, Expr(:function, Expr(:tuple, vparams...), fbody))
                push!(callstmts, Expr(:call, Expr(:ref, _CG_FNS, length(ctx.helpers)),
                                      vparams...))
            else
                fname = Symbol("_cgchunk_", ci)
                fdef = Expr(:function, Expr(:call, fname, :du, :u, :p, :t, passed...),
                            fbody)
                push!(fndefs, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
                push!(callstmts, Expr(:call, fname, :du, :u, :p, :t, passed...))
            end
        end
    end

    # `tabs` is now a tuple of the by-type containers; hoist each to its `_cggrpG`
    # local (a handful of statements, not one per object).
    grpstmts = Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]
    # By-value transport: every emitted sub-function is compiled on its own and
    # arrives in a tuple appended to `tabs`, hoisted to a local FIRST so the
    # invariant prologue, the chunk sub-functions and the helpers themselves can
    # all call out of it. Inner-definition transport splices the definitions in
    # instead, exactly as before.
    fnstmts = byval && !isempty(ctx.helpers) ?
              Any[:(local $(_CG_FNS) = tabs[$(ngrp + 1)])] : Any[]
    helperdefs = byval ? Any[] : ctx.helpers
    # The kernels run in an alias scope with `u` read-only (`_cg_readonly`): no
    # `du` store aliases a `u` load. The section already rests on that — no cell
    # reads a slot any cell of the section writes, which is what lets the
    # threaded path run its chunks concurrently, and what an observed level's
    # `(ue, ue)` call relies on — and it is what lets the compiler vectorize a
    # row whose reads sit at run-time slot offsets (`_cg_geo!`) without a
    # run-time overlap check per offset. Loads and stores only move relative to
    # each other; no arithmetic changes.
    # On a two-buffer slot space `du` is rebound to the one buffer every cell
    # of the section writes (`_cg_dview`), when there is one.
    kernels = Expr(:macrocall, GlobalRef(Base.Experimental, Symbol("@aliasscope")), ln,
                   Expr(:let, _cg_section_bindings(nst, acc_kernels),
                        Expr(:block,
                             Expr(:macrocall, Symbol("@inbounds"), ln,
                                  Expr(:block, ctx.prologue...)),
                             callstmts...)))
    body = Expr(:block,
                grpstmts...,
                fnstmts...,
                :(local _cgT = _rhs_value_type(u, p, t)),
                # Intra-kernel split helpers (ess-iip-split): defined FIRST so the
                # invariant prologue and every chunk sub-function can call them by
                # name. Each is `@noinline`, params-only (captures nothing).
                helperdefs...,
                fndefs...,
                kernels,
                :(return nothing))
    ex = Expr(:function, Expr(:tuple, :du, :u, :p, :t, :tabs, :_cgci, :_cgnc), body)
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
        @__MODULE__, @__MODULE__, ex)
    # Threaded cell axis: total covered cells + the global out-slot
    # disjointness verdict, both facts of the BUILD (the runtime chunk verdict
    # is `_sec_prep_threads!`'s).
    ncells, disjoint = _cg_covered_outs_disjoint(acc_kernels, covered)
    # The runtime `tabs` argument: one HOMOGENEOUS container per group, converted
    # to the group's concrete element type (`Vector{Vector{Int}}`, …), packed in a
    # small tuple. `_cggrpG[pos]` then reads a concrete-element container.
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    # …plus, in the by-value transport, the sub-function tuple as one more
    # element. It is a heterogeneous tuple of concrete callables, so a call site
    # reading it at a LITERAL index resolves its callee statically.
    if byval && !isempty(ctx.helpers)
        tabpack = (tabpack...,
                   Tuple(RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
                             @__MODULE__, @__MODULE__, h) for h in ctx.helpers))
    end
    ntabs = sum(length, ctx.tab_objs; init=0)
    return _CGBuilt(f, tabpack, covered, reasons, ncells, disjoint)
end

# ---- Threaded cell axis for the codegen tier (RFC threaded-eval-tier) -------
# The shared threading infrastructure (batch-runner hook, verdict tally,
# static partition) lives in access_kernel.jl ("Threading infrastructure" —
# the safety argument lives there). This section threads the generated
# functions themselves; since the Float64 lane tape was retired it is the only
# threaded tier.
#
# GRANULARITY: the WHOLE SECTION is chunked, not each kernel. One batch
# dispatch runs chunk `c` of every emitted kernel back to back —
# `f(du, u, p, t, tabs, c, nchunks)` — with no inter-kernel barrier. That is
# safe because the section builder proves the strong property up front:
# `_cg_covered_outs_disjoint` verifies at build time that every covered
# out-slot is globally unique ACROSS all emitted kernels. When that holds, no
# two cells anywhere in the section touch the same `du` slot, kernels share no
# other mutable state (locals only; `u`/`p`/`t`/tabs are read-only here), and
# the inter-kernel barrier is unnecessary — one dispatch per RHS call, so the
# per-dispatch wake-up latency is paid ONCE instead of #kernels times. When it
# does NOT hold (`:cg_serial_shared_outs`), the section never chunks and every
# generated function runs its serial `(1, 1)` instance.
#
# BIT-IDENTITY, per kernel: chunk boundaries are not observable (a cell
# computes the same instruction sequence on the same inputs whichever chunk it
# lands in; every ⊕-fold is WITHIN a cell — REDUCE/CONTRACTION loops are
# per-cell in the emitted body), the partition is the static
# `_chunk_ordinals`, and disjoint writes commute. Threaded `du` is bitwise
# `===` serial `du`.
#
# One Julia thread ⇒ serial; a section total below the per-chunk min-cells
# threshold (ESS_THREADS_MIN_CELLS) ⇒ serial.
# Verdicts land in `_THREAD_TALLY` (`:cg_threaded` / `:cg_serial_small` /
# `:cg_serial_shared_outs`), documented with the existing keys.

# One-time threading verdict for one generated function's cell axes:
# `state` is 0 unexamined, 1 chunked, -1 serial (too few cells), -2 serial
# (globally shared out-slots — permanent, decided at build).
# `ncells`/`disjoint` are build facts (`_CGBuilt`); `nchunks` is fixed
# at the first threaded call, so the partition is identical call to call.
# `job1`/`job2` hold the section's dispatch jobs (thread_dispatch.jl) for the
# last two argument types it ran at, so a caller alternating between Float64
# and dual-number calls (a solver and its Jacobian) reuses both.
mutable struct _SecTCache
    state::Int
    ncells::Int
    disjoint::Bool
    nchunks::Int
    job1::Any
    job2::Any
end
_SecTCache(ncells::Int, disjoint::Bool) =
    _SecTCache(0, ncells, disjoint, 1, nothing, nothing)
_sec_tcache(cg::_CGBuilt) = _SecTCache(cg.ncells, cg.outs_disjoint)
_sec_tcache(::Nothing) = _SecTCache(0, false)

# Decide once whether this generated function may run chunked: size first
# (the min-cells threshold guards per-DISPATCH work, and the section is one
# dispatch), then the build-time disjointness verdict.
function _sec_prep_threads!(tc::_SecTCache)
    tc.state == 0 || return tc
    minc = _thread_min_cells()
    nchunks = min(Threads.nthreads(), max(1, div(tc.ncells, max(minc, 1))))
    if nchunks < 2
        tc.state = -1                 # too few cells to be worth a dispatch
        _tally_thread!(:cg_serial_small)
        return tc
    end
    if !tc.disjoint
        tc.state = -2                 # shared out-slots: chunks would race
        _tally_thread!(:cg_serial_shared_outs)
        return tc
    end
    tc.nchunks = nchunks
    tc.state = 1
    _tally_thread!(:cg_threaded)
    return tc
end

# This section's job for body type `B` and argument type `A`, from the two
# cached slots or freshly made (the only allocation, once per argument type).
@inline function _section_job!(tc::_SecTCache, ::Type{B}, ::Type{A}) where {B,A}
    J = _ThreadJob{B,A}
    j = tc.job1
    j isa J && return j
    j2 = tc.job2
    tc.job2 = j
    if j2 isa J
        tc.job1 = j2
        return j2
    end
    jn = J()
    tc.job1 = jn
    return jn
end

# Run `body(args, c, nchunks)` for every chunk of the section's verdict.
@inline function _run_chunked!(tc::_SecTCache, body::B, args::A) where {B,A}
    j = _section_job!(tc, B, A)
    j.body = body
    j.args = args
    j.nchunks = tc.nchunks
    _dispatch_job!(j)
    return nothing
end

# A generated function's chunk: the static partition (`_chunk_ordinals`) is
# computed inside it, and each chunk re-runs the (pure) tab-hoist + invariant
# prologue on its own stack and walks its `[a, b)` slice of every kernel.
struct _CGChunk{F,TB}
    f::F
    tabs::TB
end
@inline (b::_CGChunk)(args, c::Int, nchunks::Int) =
    b.f(args[1], args[2], args[3], args[4], b.tabs, c, nchunks)

# Run one generated function chunked when the section's verdict allows, and
# serially otherwise (one thread, too few cells, shared out-slots): its
# `(1, 1)` instance, or `ntiles` serial cell tiles (`_run_cg_section_serial!`).
# Every value type takes the same route: a chunk computes each of
# its cells exactly as the serial instance does.
@inline function _run_cg_maybe_threaded!(f, tabs, du, u, p, t, tc::_SecTCache,
                                         ntiles::Int = 1)
    if _threads_available() && _sec_prep_threads!(tc).state == 1
        _run_chunked!(tc, _CGChunk(f, tabs), (du, u, p, t))
    else
        _run_cg_section_serial!(f, tabs, du, u, p, t, ntiles)
    end
    return nothing
end

# ---- The RHS's kernel section (wired into `_make_rhs`, acc_merge.jl) --------
# One concretely-typed callable holding the generated function (or `Nothing`)
# plus the residual kernels that keep the per-cell interpreter. The
# `F === Nothing` branch folds away per closure specialization, so with the
# tier disabled (or nothing emitted) `f!` is instruction-for-instruction the
# pre-codegen RHS. Emitted kernels write disjoint du slots from residual ones
# (each state slot has exactly one equation/cell), so running the generated
# section first is value-identical to the original in-order kernel loop.
struct _KernelSection{F,TB,G,GTB}
    cgf::F
    cgtabs::TB
    n_emitted::Int                # kernels compiled into the generated function
    kernels::Vector{_AccKernel}   # residual kernels (interpreter runner)
    # Dual overflow tier (ess-dualfp): a second generated function covering the
    # residual kernels the PRIMARY emission declined (in practice on the node
    # budget). Under non-Float64 `T` it is called unconditionally, so Duals run
    # compiled code instead of the per-cell interpreter; at Float64 it serves
    # the residual kernels whenever `f64cg` below is armed. `dual_resid`
    # indexes `kernels`: the kernels even the overflow emission declined, which
    # keep the eltype-generic interpreter under every `T`.
    dualf::G
    dualtabs::GTB
    n_dual_emitted::Int
    dual_resid::Vector{Int}
    # Float64 overflow routing (ess-f64ofl): when true, the overflow function
    # above also serves Float64 calls (in place of the per-cell interpreter).
    # Baked at build time from the plan's Float64 overflow routing.
    f64cg::Bool
    # Threaded cell axis: one lazily-decided chunk verdict per generated
    # function (primary / overflow), see `_SecTCache` above.
    tcache::_SecTCache
    dual_tcache::_SecTCache
    # Serial cell tiling of the primary function: the number of static chunks
    # a serial call runs back to back (1 = one pass per kernel). See
    # `_section_tiles`.
    ntiles::Int
end

# SERIAL TILING. The primary function runs chunk `c` of every emitted kernel
# back to back (the threaded path's granularity, above), so a serial call can
# run the chunks one after another instead of each kernel over all its cells:
# several kernels over the same cells — one per species of a reaction system
# lifted onto a grid — then share the cells' operands while they are still in
# cache, where one pass per kernel streams every operand from memory once per
# kernel. Chunk boundaries are not observable (the threaded path's argument:
# every fold is inside one cell, out-slots are disjoint, `u` is read-only), so
# a tiled call is bitwise the untiled one. Tiled only when the section has
# several kernels and globally disjoint out-slots, with about
# `_SECTION_TILE_CELLS` cells of each kernel per chunk.
const _SECTION_TILE_CELLS = 1024
function _section_tiles(ncells::Int, n_emitted::Int, disjoint::Bool)
    (disjoint && n_emitted >= 2) || return 1
    return max(1, div(ncells, n_emitted * _SECTION_TILE_CELLS))
end

@inline function _run_cg_section_serial!(f, tabs, du, u, p, t, ntiles::Int)
    if ntiles == 1
        f(du, u, p, t, tabs, 1, 1)
    else
        for c in 1:ntiles
            f(du, u, p, t, tabs, c, ntiles)
        end
    end
    return nothing
end

@inline function (s::_KernelSection{F,TB,G})(du, u, p, t, ::Type{T}) where {F,TB,G,T}
    if F !== Nothing
        # PRIMARY generated function, chunked when the section verdict allows
        # (threaded cell axis above), at every value type. Any serial verdict
        # (small, shared outs, one thread) runs it tiled serially.
        _run_cg_maybe_threaded!(s.cgf, s.cgtabs, du, u, p, t, s.tcache, s.ntiles)
    end
    kernels = s.kernels
    if G !== Nothing && T !== Float64
        # Dual fast path: the overflow function covers every kernel not in
        # `dual_resid`. Emitted kernels write disjoint du slots from residual
        # ones (each state slot has exactly one equation/cell), so the order
        # generated-first is value-identical to the in-order kernel loop.
        _run_cg_maybe_threaded!(s.dualf, s.dualtabs, du, u, p, t, s.dual_tcache)
        @inbounds for j in s.dual_resid
            _run_acc_kernel!(du, u, p, t, kernels[j], T)
        end
        return nothing
    end
    if G !== Nothing && T === Float64 && s.f64cg
        # Float64 overflow routing (ess-f64ofl): budget-declined kernels run
        # the SAME compiled overflow function as the Dual path, bit-identical
        # to the interpreter by the emitter's contract — CHUNKED whenever the
        # section verdict allows, serial `(1, 1)` otherwise. In particular, a
        # shared-outs section (`:cg_serial_shared_outs`) under threading runs
        # the overflow RGF SERIAL: before the lane-tape retirement this case
        # fell back to the tape, whose per-kernel chunking (barriers between
        # kernels) could still thread it. That is an accepted theoretical
        # regression — the verdict has never been produced by any real build
        # (globally shared out-slots require two equations writing one state
        # slot; the threaded-codegen work could not construct it outside a
        # hand-poisoned cache), and serial-compiled is still far faster than
        # the per-cell interpreter. Kernels the overflow emission itself
        # declined keep the interpreter, in the same order as the plain loop
        # below.
        _run_cg_maybe_threaded!(s.dualf, s.dualtabs, du, u, p, t, s.dual_tcache)
        @inbounds for j in s.dual_resid
            _run_acc_kernel!(du, u, p, t, kernels[j], Float64)
        end
        return nothing
    end
    @inbounds for j in 1:length(kernels)
        _run_acc_kernel!(du, u, p, t, kernels[j], T)
    end
    return nothing
end

# Partition the kernels between the codegen tier and the pre-existing runners.
# With the codegen tier off (or an empty emission) the section is exactly the
# pre-codegen kernel loop; with only the overflow tier off it is the pre-dual
# routing (Duals interpret every residual kernel) with the primary tier intact.
# `shared_cache` (ess-cgfsc): the build's scalar prelude `_CSECache`, passed
# ONLY by the `_make_rhs` call site (acc_merge.jl) — the one place where the
# section provably runs after that cache's prelude tiers were filled in the
# same `f!` call. Every other caller keeps the default `nothing`, which keeps
# the `:foreign_scratch` decline for shared-prelude reads.
# A kernel BOTH emissions declined runs on `_run_acc_kernel!` — the `_eval_acc`
# tree walk, once per output cell, on every right-hand-side call (§0 of the
# phase-0 census). That is the one thing a compiled compiler promises not to do,
# so a strict compiler refuses at BUILD, naming the rule the cascade has open
# and the reason the OVERFLOW emission gave: the primary pass's reasons are not
# refusals, since the overflow pass compiles what the budget declined.
function _refuse_interpreted_kernels(kernels::AbstractVector{_AccKernel},
                                     resid::AbstractVector{Int},
                                     reasons::AbstractVector{Symbol},
                                     emission_empty::Bool)
    (_compiler_is_strict() && !isempty(resid)) || return nothing
    why = :emission_produced_nothing
    if !emission_empty
        for j in resid
            j <= length(reasons) || continue
            reasons[j] === :none && continue
            why = reasons[j]
            break
        end
    end
    _refuse_rule(_current_rule_label("the assembled right-hand side"),
        "$(length(resid)) of $(length(kernels)) access kernel" *
        (length(kernels) == 1 ? "" : "s") * " reached the end of both codegen " *
        "emissions undeclared (deepest reason: $why), so they would run on the " *
        "per-cell tree-walk kernel runner on every right-hand-side call. Build " *
        "with compiler=:interpreter to run it, or grow the emitter to cover " *
        "this construct")
end

# The same promise for the per-cell scalar entries that ride `rhs_list`: each is
# a compiled `_Node` tree that the in-place `f!` walks with `_eval_node`, one per
# output cell, on every right-hand-side call. No emission is attempted for them,
# so there is no deeper reason to carry than the count.
function _refuse_interpreted_cells(cells::AbstractVector)
    (_compiler_is_strict() && !isempty(cells)) || return nothing
    _refuse_rule(_current_rule_label("the assembled right-hand side"),
        "$(length(cells)) array cell" * (length(cells) == 1 ? "" : "s") *
        " would run as per-cell trees on the scalar walker (`_eval_node`) on " *
        "every right-hand-side call. Build with compiler=:interpreter to run it")
end

function _make_kernel_section(acc_kernels::AbstractVector{_AccKernel};
                              shared_cache::Union{Nothing,_CSECache}=nothing,
                              nst::Int=0)
    cg = _codegen_disabled() ? nothing :
         _build_codegen_rhs(acc_kernels; shared_cache=shared_cache, nst=nst)
    if cg === nothing
        kernels = collect(_AccKernel, acc_kernels)
        n_emitted = 0
        # No primary emission ran, so there is no per-kernel reason to carry.
        primary_reasons = Symbol[]
    else
        resid = [j for j in eachindex(cg.covered) if !cg.covered[j]]
        kernels = _AccKernel[acc_kernels[j] for j in resid]
        n_emitted = count(cg.covered)
        # Re-indexed onto `kernels`, which is what every consumer below indexes.
        primary_reasons = Symbol[cg.reasons[j] for j in resid]
    end
    cgf = cg === nothing ? nothing : cg.f
    cgtabs = cg === nothing ? nothing : cg.tabs
    # Dual overflow tier: retry the residual kernels under the dual budget. Its
    # RGF is only ever CALLED with non-Float64 arguments, so nothing here adds
    # Float64 compile latency — only the (cheap) AST emission runs at build.
    # Gated on the primary tier too: with codegen off the build must stay a pure
    # pre-codegen one, which is the tier's differential oracle.
    dg = (_codegen_disabled() || _dual_codegen_disabled() || isempty(kernels)) ?
         nothing :
         _build_codegen_rhs(kernels; budget=_dual_codegen_node_budget(),
                            tally=:dual_codegen, shared_cache=shared_cache, nst=nst)
    if dg === nothing
        _refuse_interpreted_kernels(kernels, collect(Int, 1:length(kernels)),
                                    primary_reasons, isempty(primary_reasons))
        return _KernelSection(cgf, cgtabs, n_emitted, kernels,
                              nothing, nothing, 0, collect(Int, 1:length(kernels)),
                              false, _sec_tcache(cg), _sec_tcache(nothing),
                              _cg_section_tiles(cg, n_emitted))
    end
    # Float64 overflow routing (ess-f64ofl): armed whenever the overflow
    # function exists and the plan has not turned the routing off. A build with
    # either codegen tier off reaches the branch above instead, so both remain
    # full oracles for their tiers.
    f64cg = _f64_overflow_codegen_enabled()
    f64cg && _tally_cascade!(:f64_overflow_armed)
    dual_resid = Int[j for j in eachindex(dg.covered) if !dg.covered[j]]
    _refuse_interpreted_kernels(kernels, dual_resid, dg.reasons, false)
    return _KernelSection(cgf, cgtabs, n_emitted, kernels,
                          dg.f, dg.tabs, count(dg.covered), dual_resid, f64cg,
                          _sec_tcache(cg), _sec_tcache(dg),
                          _cg_section_tiles(cg, n_emitted))
end

_cg_section_tiles(::Nothing, ::Int) = 1
_cg_section_tiles(cg::_CGBuilt, n_emitted::Int) =
    _section_tiles(cg.ncells, n_emitted, cg.outs_disjoint)
