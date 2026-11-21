# ========================================================================
# tree_walk/codegen_kernel.jl — the Julia CODEGEN tier for access kernels.
#
# The scalar access-kernel runner (`_run_acc_kernel!`, access_kernel.jl) walks
# the spine `_Node` tree once per cell: one dynamic kind/op dispatch per node
# per cell per RHS call. This tier removes that interpretation entirely where
# it can: at `_build_evaluator` time each `_AccKernel` is EMITTED as Julia
# source — the kernel's exact per-box loop nest with the spine as a
# straight-line expression using direct indexing (`u[oln + Δ]`, literal
# strides/offsets baked in) — and every emitted kernel is fused into ONE
# function compiled once via RuntimeGeneratedFunctions.jl.
#
# BIT-EXACTNESS IS THE CONTRACT. The emitter mirrors `_eval_acc` /
# `_eval_acc_op` (and through them `_eval_node_op`) operation for operation:
#   * same operand order and the same LEFT-nested fold for n-ary `+`/`*`/
#     `min`/`max` (`((c1 ⊕ c2) ⊕ c3)…`), the same 0̄-seeded fold for
#     `_NK_CONTRACTION`/`_NK_AREDUCE` (`((0̄ ⊕ c1) ⊕ c2)…`);
#   * NO `@simd`, NO `@fastmath`, NO `muladd`, NO reassociation of any kind
#     (`@inbounds` only — indices were validated at build);
#   * LAZY guard semantics preserved verbatim: `ifelse` emits a ternary (only
#     the taken branch evaluates), `and`/`or` emit `&&`/`||` chains with the
#     interpreter's exact `== 0`/`!= 0` tests and `1.0`/`0.0` results;
#   * leaves keep their native types (a literal stays `Float64`, so `x ^ 2.0`
#     lands on `Dual^Float64` under AD exactly as the walker's leaf discipline
#     guarantees); CSE slot values convert to `T` exactly where the
#     interpreter's `buf[i] = …` store does.
#
# ELTYPE-GENERIC: the emitted function derives `T = _rhs_value_type(u, p, t)`
# exactly as the interpreter does, so the SAME generated code integrates at
# Float64 and differentiates under ForwardDiff `Dual` (state or parameters).
#
# FALLBACK CONTRACT: anything the emitter cannot model — an unknown node kind
# or descriptor, a foreign CSE scratch (except the build's own shared
# scalar-prelude cache, which is emitted as the interpreter's `_cse_read`; see
# the tier note below), an oversized spine —
# declines THAT kernel silently (`_Decline`); the kernel keeps the
# per-cell interpreter (`_run_acc_kernel!`, eltype-generic). Declines are
# counted per reason in the build's cascade tally (`:codegen_kernel` /
# `:codegen_decline_<reason>`, `_tally_cascade!`).
#
# GENERATED CODE NEVER TOUCHES INTERPRETER STATE: CSE/invariant slots become
# SSA-style locals, never writes into the kernel's `_AccScratch` buffers — so
# an emitted kernel and an interpreted one coexist within one RHS call.
#
# With the tier off (`compiler=:interpreter`) the generated function stands
# down and every kernel runs the per-cell interpreter: that is the differential
# oracle, slower but bit-identical by the emitter's contract.
# Budget: ESS_CODEGEN_NODE_BUDGET overrides the emitted-node cap (default
# 64_000_000 across all kernels of one build) that backstops a runaway build.
# ========================================================================

_codegen_disabled() = !_compiler_plan_now().codegen
# CUMULATIVE emitted-node budget across all kernels in one build call — a
# build-latency backstop, NOT a per-function compile bound (the intra-kernel
# split handles that: every generated function stays under
# `_codegen_fn_node_cap` regardless of a kernel's total size). The default is
# high enough that realistic models always emit fully; it only backstops a
# runaway. It is a REFUSAL BOUNDARY under `native`: a kernel past it is a
# refused rule, never a quiet demotion to the per-cell runner. Override with
# ESS_CODEGEN_NODE_BUDGET.
_codegen_node_budget() = _tuning_now().node_budget

# Emitted-node size of a tree: a node shared by several parents is counted
# once per parent, as the emitter writes it once per use.
_cg_node_tree_size(n::_Node) = _node_tree_size(n)

# ---- Shared-prelude (xcse) cache reads ---------------------------------------
# The cross-kernel CSE pass (xcse.jl) rewrites kernel invariant-tier defs into
# bare `_NK_CACHED` reads of the build's SCALAR prelude cache — a `_CSECache`
# payload that is no kernel's scratch. The emitter emits the read as the very
# call the interpreter makes
# (`_cse_read(cache, idx, T)` — eltype-generic, so the Float64 AND the Dual
# specialization of the generated code read the same buffer the interpreter
# would: `f64` at Float64, the lazily-allocated `alt::Vector{T}` otherwise).
#
# FILL-ORDERING SOUNDNESS. Acceptance is gated on IDENTITY with the one cache
# the build threads in (`shared_cache` below): `_make_rhs` fills every prelude
# tier (const/time/dynamic) into that exact cache — for the SAME value type `T`
# the kernel section is about to run at — before `kernel_section(du,u,p,t,T)`
# is called, in the same `f!` body (acc_merge.jl). The generated function is
# only ever invoked from inside that section, so every accepted read lands on
# a slot filled this call. Call sites
# that cannot pin that ordering (the materialized-observed fill sections in
# build_observed_fills.jl, hand-built test sections) pass `shared_cache = nothing` and
# decline the read — as does ANY payload that is not that one cache object.
#
# Build tally: `:cg_foreign_scratch_emit` — one bump per kernel that COMPILED
# carrying at least one shared-prelude read (a kernel that later declines for
# another reason is not counted).

# A kernel the emitter cannot model declines through `_Decline` (compiler.jl);
# the per-kernel transaction in `_build_codegen_rhs` catches it and the kernel
# keeps its per-cell runner.

# What a kernel's loop nest does with each cell's value.
abstract type _CGStore end

# The plain store: the value goes into `du` at the cell's output slot.
struct _CGStoreDu <: _CGStore end

# A fused scan's consumer as the nest emits it (`_cg_consumer`, scan_fused.jl):
# kernel `K`, whose descriptor `ix` reads the scan's value at its cell plus
# `delta`, with `invsyms` its invariant locals; `store` writes `K`'s own output.
struct _CGConsumer
    K::_AccKernel
    ix::Int
    delta::Int
    store::Bool
    invsyms::Vector{Symbol}
end

# A fused prefix scan's store (scan_fused.jl): the value is folded into the
# accumulator local `acc` with `op`; `[a, b)` is the ordinal range of the one
# lane the nest runs, `inclusive` says whether the fold precedes the store, and
# `cons` is the consumer taken in, if any.
struct _CGStoreScan <: _CGStore
    acc::Symbol
    a::Symbol
    b::Symbol
    op::Symbol
    inclusive::Bool
    cons::Union{Nothing, _CGConsumer}
end

# ---- Emission state ----------------------------------------------------------
# Runtime objects the generated code needs (const arrays, slot tables, outs
# vectors), GROUPED BY CONCRETE TYPE into homogeneous containers. The generated
# code indexes a concrete-element container — `_cggrpG[pos]` — so its element
# type infers in O(1); the runtime `tabs` argument is a small tuple of those
# containers, one per distinct type. A per-object heterogeneous N-tuple instead
# would have a TYPE that alone makes inference super-linear in the number of
# tabs. `types[g]` is group g's element type, `objs[g]` its objects (deduped by
# identity via `id` → (group, position)).
struct _CGTabs
    types::Vector{DataType}
    objs::Vector{Vector{Any}}
    id::IdDict{Any, Tuple{Int, Int}}
end
_CGTabs() = _CGTabs(DataType[], Vector{Any}[], IdDict{Any, Tuple{Int, Int}}())

# The shared invariant prologue (see `_cg_inv!`): its statements; the
# invariant-slot local names per kernel object, with the kernels in
# registration order for a declined kernel's rollback; the geometry local the
# prologue already holds for a (field, value) pair (`geo`) and the invariant
# local already holding an emitted invariant expression (`inv`); and the keys
# of both in the order they were added, with the statement count at that
# point (`log`), so a declined kernel's entries roll back with its statements.
struct _CGPrologue
    stmts::Vector{Any}
    invdone::IdDict{Any, Vector{Symbol}}
    invlog::Vector{Any}
    geo::Dict{Any, Symbol}
    inv::Dict{Any, Symbol}
    log::Vector{Tuple{Int, Bool, Any}}
end
_CGPrologue() = _CGPrologue(
    Any[], IdDict{Any, Vector{Symbol}}(), Any[],
    Dict{Any, Symbol}(), Dict{Any, Symbol}(), Tuple{Int, Bool, Any}[]
)

# Two-buffer addressing (`_ObsSplitVec`, obs_buffers.jl): the state length of
# the slot space the section runs on, or 0 for one plain vector. With `nst > 0`
# each state read is emitted against the buffer its slots live in
# (`_cg_side`); `olnext` holds the output-slot extent of every kernel whose
# loop nest binds `oln` (an affine read's slots are `oln + delta`), and
# `sidememo` the slot extent of each slot table already scanned.
struct _CGSlotSpace
    nst::Int
    olnext::IdDict{Any, Tuple{Int, Int}}
    sidememo::IdDict{Any, Tuple{Int, Int}}
end
_CGSlotSpace(nst::Int) = _CGSlotSpace(
    nst, IdDict{Any, Tuple{Int, Int}}(), IdDict{Any, Tuple{Int, Int}}()
)

# Where the nest being emitted puts what it hoists, and how it reads slot
# tables; each is set and restored around a nested emission.
#   `sink`: the statement list the `local` that reads each geometry integer
#   goes into (the current kernel's block, or the invariant prologue), and
#   `memo` names one local per geometry field within that list.
#   `tblread`: set when a fetch reads the state through a slot table
#   (`_cg_tabh!`); the loop nests read and clear it to keep such a loop scalar
#   (`_cg_tblread!`).
#   `tblaffine`, `tblcbs`: slot-table reads and their two emitted versions
#   (`_cg_tbl_versions`): `tblaffine` emits every `_AK_STATE_TBL_BOX` read as
#   its run form, and `tblcbs` collects the run-mode locals the version guard
#   tests.
mutable struct _CGNest
    sink::Vector{Any}
    memo::IdDict{Any, Symbol}
    tblread::Bool
    tblaffine::Bool
    tblcbs::Vector{Symbol}
end
_CGNest() = _CGNest(Any[], IdDict{Any, Symbol}(), false, false, Symbol[])

# How far a generated function's emission state reached before one kernel (or
# row group) began: its prologue, its invariant registrations, its split
# helpers, its node count and shared-prelude read count.
struct _CGMark
    nprologue::Int
    ninvlog::Int
    nhelpers::Int
    nodes::Int
    fscratch::Int
end

# One kernel's emission transaction (`_cg_transaction`): the mark it rolls back
# to when the kernel declines, and its helper dedup scope. Identical spilled
# bodies (same code — the momentum spine bears LAZY nodes, so scalar CSE was
# skipped and its redundant sub-expressions reach codegen un-shared) collapse
# to ONE compiled `@noinline`, still called per occurrence: body string → the
# helper name it was first minted as. The scope is one kernel, so a declined
# kernel's rolled-back helpers are never referenced (distinct kernels are
# distinct equations). Emitters that are not kernel transactions share the
# function's first scope.
struct _CGKernelTx
    mark::_CGMark
    helper_dedup::Dict{String, Symbol}
end

# ---- Emission context (one per generated function) --------------------------
mutable struct _CGFunction
    tabs::_CGTabs
    # Run-time geometry (see "Geometry as data" below): the integers the emitted
    # loops read instead of literals, one tab object for the whole function.
    geo::Vector{Int}
    prologue::_CGPrologue
    # Intra-kernel split: top-level `@noinline` helper defs a
    # large kernel's body was partitioned into. Spliced ahead of the chunk
    # sub-functions so both call them by name; each captures nothing (params
    # only), so the RHS stays allocation-free.
    helpers::Vector{Any}
    nodes::Int                   # emitted-node tally (budget enforcement)
    budget::Int
    nname::Int                   # unique-name counter
    # Shared-prelude cache reads: the ONE `_CSECache` whose
    # `_NK_CACHED` reads may be emitted (`nothing` ⇒ decline), and a
    # per-build count of reads emitted (tally bookkeeping in the build loop).
    shared_cache::Union{Nothing, _CSECache}
    fscratch::Int
    space::_CGSlotSpace
    nest::_CGNest
    tx::_CGKernelTx
    # The template call targets emitted so far (`_cg_call_fn!`): target →
    # (name, position in `helpers`, definition). An entry whose definition a
    # declined kernel's rollback cut from `helpers` is stale.
    callfns::IdDict{Any, Tuple{Symbol, Int, Expr}}
    # Per emitted call function: its count tables and the table of each count
    # (`_cg_site_count_tables`).
    callcounts::IdDict{Any, Tuple{Vector{Tuple{Int, Int, Int}}, Vector{Int}}}
    # The size each INLINED helper (a call function) adds where it is
    # called: its body's emitted size with the inlined calls in it counted
    # whole (`_cg_inl_size`). LLVM compiles that body at every call, so the
    # inline decisions and the per-function node counts count it there.
    inlsize::Dict{Symbol, Int}
    # A content number per read table (`_cg_tbl_content`): equal for two
    # tables with equal entries, by object and by content.
    tblid::IdDict{Any, Int}
    tblcontent::Dict{Any, Int}
    # Per emitted call function: the literal tables its body reads (a
    # `_ConstGatherArray`, its own or a nested call's), in the order of its
    # trailing parameters; a call site passes each (`_cg_emit_call`).
    callconsts::IdDict{Any, Vector{Any}}
end
_CGFunction(budget::Int, shared_cache::Union{Nothing, _CSECache} = nothing; nst::Int = 0) =
    _CGFunction(
    _CGTabs(), Int[], _CGPrologue(), Any[], 0, budget, 0, shared_cache, 0,
    _CGSlotSpace(nst), _CGNest(), _CGKernelTx(_CGMark(0, 0, 0, 0, 0), Dict{String, Symbol}()),
    IdDict{Any, Tuple{Symbol, Int, Expr}}(),
    IdDict{Any, Tuple{Vector{Tuple{Int, Int, Int}}, Vector{Int}}}(), Dict{Symbol, Int}(),
    IdDict{Any, Int}(), Dict{Any, Int}(), IdDict{Any, Vector{Any}}()
)

# The emitted size of `ex` as LLVM sees it: a call of an inlined helper counts
# that helper's body (`ctx.inlsize`), not one node.
function _cg_inl_size(ctx::_CGFunction, ex)
    ex isa Expr || return 1
    n = 1
    if ex.head === :call && !isempty(ex.args) && ex.args[1] isa Symbol
        n += get(ctx.inlsize, ex.args[1]::Symbol, 0)
    end
    for a in ex.args
        n += _cg_inl_size(ctx, a)
    end
    return n
end

_cg_name(ctx::_CGFunction, base::String) = Symbol("_cg", base, ctx.nname += 1)

# The local that holds group `g`'s homogeneous tab container (`_cggrpG`).
_cg_grp_sym(g::Int) = Symbol("_cggrp", g)

@inline function _cg_budget!(ctx::_CGFunction)
    ctx.nodes += 1
    ctx.nodes > ctx.budget && _decline(:budget)
    return nothing
end

# Register a runtime object; returns the indexing expression `_cggrpG[pos]` into
# its by-type container. Deduped by identity; a new object is
# appended to the container for its concrete type (a new group if that type is
# unseen). The returned `_cggrpG[pos]` reads a CONCRETE-element container, so its
# element type infers in O(1) — the whole point of grouping.
function _cg_tab!(tabs::_CGTabs, obj)
    got = get(tabs.id, obj, nothing)
    got !== nothing && return :($(_cg_grp_sym(got[1]))[$(got[2])])
    T = typeof(obj)
    g = findfirst(==(T), tabs.types)
    if g === nothing
        push!(tabs.types, T); push!(tabs.objs, Any[])
        g = length(tabs.types)
    end
    push!(tabs.objs[g], obj)
    pos = length(tabs.objs[g])
    tabs.id[obj] = (g, pos)
    return :($(_cg_grp_sym(g))[$pos])
end
_cg_tab!(ctx::_CGFunction, obj) = _cg_tab!(ctx.tabs, obj)

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
#
# `key` (optional) names the geometry FIELD the value came from, by the
# identity of the object that holds it, so two reads of one descriptor share one
# local — keeping identical code identical for the split helpers' dedup — while
# two fields that merely hold equal values at this N stay distinct.
function _cg_geo!(ctx::_CGFunction, v::Int, key = nothing, unit::Bool = false)
    (unit && -1 <= v <= 1) && return v
    if key !== nothing
        got = get(ctx.nest.memo, key, nothing)
        got === nothing || return got
    end
    # In the invariant prologue, one local per fixed read: the invariants of
    # different kernels that read the same cell then emit the same expression,
    # which `_cg_inv!` shares.
    pkey = ctx.nest.sink === ctx.prologue.stmts ? _cg_fixed_read(key, v) : nothing
    if pkey !== nothing
        got = get(ctx.prologue.geo, pkey, nothing)
        got === nothing || return got
    end
    push!(ctx.geo, v)
    s = _cg_name(ctx, "G")
    push!(ctx.nest.sink, :(local $s = $(_cg_tab!(ctx, ctx.geo))[$(length(ctx.geo))]))
    key === nothing || (ctx.nest.memo[key] = s)
    if pkey !== nothing
        ctx.prologue.geo[pkey] = s
        push!(ctx.prologue.log, (length(ctx.prologue.stmts), false, pkey))
    end
    return s
end

# A table a loop body indexes, as a local read once ahead of the loops (in the
# geometry sink) rather than `_cggrpG[pos]` at every use: a store to `du` may
# alias the container's memory as far as the compiler knows, so the in-loop
# form reloads the table's address on every iteration.
function _cg_tabh!(ctx::_CGFunction, obj)
    ref = _cg_tab!(ctx, obj)
    key = (:tab, obj)
    got = get(ctx.nest.memo, key, nothing)
    got === nothing || return got
    s = _cg_name(ctx, "tb")
    push!(ctx.nest.sink, :(local $s = $ref))
    ctx.nest.memo[key] = s
    return s
end

# A gather of the state through a slot table, once its table is a local
# (`_cg_tabh!`), invites the loop vectorizer to turn every neighbour read into
# a vector gather, which is several times slower here than the scalar loop. A
# fetch that emits one sets `ctx.nest.tblread`; `_cg_tblread!` returns the loop
# annotation that keeps the loop scalar (or nothing) and clears the flag.
# Leaving a loop scalar never changes a value.
function _cg_tblread!(ctx::_CGFunction)
    r = ctx.nest.tblread
    ctx.nest.tblread = false
    return r ? Any[_cg_novec()] : Any[]
end

# Run `f()` with geometry locals going to `sink` (and a fresh memo, since a
# memoized local exists only in the list it was defined in).
function _cg_with_geosink(f, ctx::_CGFunction, sink::Vector{Any})
    sink0, memo0 = ctx.nest.sink, ctx.nest.memo
    ctx.nest.sink = sink
    ctx.nest.memo = IdDict{Any, Symbol}()
    try
        return f()
    finally
        ctx.nest.sink = sink0
        ctx.nest.memo = memo0
    end
end

# ---- Per-kernel-evaluation context ------------------------------------------
# The cell coordinates as EXPRESSIONS (a loop-variable Symbol or an Int
# literal), plus the CSE slot → local-name maps for the kernel currently being
# emitted. `cellsyms` holds the per-cell CSE locals; `invsyms` is
# kernel-scoped (filled once per call by the prologue, as `_fill_invariant!`
# does).
# `subst` is a scan consumer's body (scan_fused.jl): `nothing`, or
# `Dict(ix => v)` — this kernel's descriptor `ix` reads as the local `v`.
struct _CGKernCtx
    K::_AccKernel
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
    subst::Union{Nothing, Dict{Int, Any}}
end
_CGKernCtx(K, oln, mi1, mi2, mi3, cellsyms, invsyms, mix = Any[]) =
    _CGKernCtx(K, oln, mi1, mi2, mi3, cellsyms, invsyms, mix, nothing)

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
    return _CGKernCtx(
        kc.K, kc.oln, mi1, mi2, mi3, kc.cellsyms,
        kc.invsyms, mix, kc.subst
    )
end

# Integer index expression `off + Σ_d (mi_d - 1)·s_d`, folding literal-1 mi
# and zero strides (exact Int arithmetic — folding cannot change the index).
# `sx` carries the strides of dims 4, 5, … (`_AccDesc.sx`). The strides and the
# offset are run-time geometry (`_cg_geo!`), keyed under `key`.
_cg_gkey(key, f) = key === nothing ? nothing : (key, f)
function _cg_boxaddr(
        ctx::_CGFunction, kc::_CGKernCtx, s1::Int, s2::Int, s3::Int, off::Int,
        sx::Vector{Int} = _AK_NO_CONN, key = nothing
    )
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

# What a fixed read of value `v` under geometry key `key` reads, for the
# invariant prologue to hold one local per read (`_cg_geo!`), or `nothing`
# when the key is not a fixed descriptor's. A state slot names its cell, a
# forcing index its element of that buffer, except where a tile build moved a
# slot onto its own layout: a slot of a cell the tile does not store is
# clamped into its variable's block, where it may meet another's, so the read
# is named by the cell it had before (`_range_fixed_ident`).
function _cg_fixed_read(key, v::Int)
    (key isa Tuple && length(key) == 2 && last(key) === :idx) || return nothing
    k1 = first(key)
    (k1 isa Tuple && length(k1) == 2 && first(k1) isa Vector{_AccDesc}) || return nothing
    acc, i = k1
    a = acc[i]
    if a.kind === _AK_STATE_FIXED
        return (:state, _range_fixed_ident(_range_spec_now(), acc, i), v)
    elseif a.kind === _AK_ARR_FIXED
        return (:arr, objectid(a.arr), v)
    end
    return nothing
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
struct _ObsShift{T, O} <: AbstractVector{T}
    o::O
    n::Int
end
_ObsShift(o::AbstractVector{T}, n::Int) where {T} = _ObsShift{T, typeof(o)}(o, n)
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

# Whether a box's extent along `d` is emitted as the literal 1 of a boundary
# slab. In a tile that shares its code it is run-time data, as every other
# extent is: the tile may own none of the slab's cells.
_cg_slab_literal(cs::_CellSet, d::Int) =
    _cellset_slab(cs, d) && !_range_shared_code(_range_spec_now())

# The output-slot extent of a kernel's cells (`(1, 0)` for none).
function _cg_oln_extent(cs::_CellSet)
    any(isempty, cs.ranges) && return (1, 0)
    _is_outs(cs) && return extrema(cs.outs)
    lo = hi = cs.base
    for d in eachindex(cs.strides)
        a = cs.strides[d] * first(cs.ranges[d])
        b = cs.strides[d] * last(cs.ranges[d])
        lo += min(a, b)
        hi += max(a, b)
    end
    return (lo, hi)
end
function _cg_oln_extent(Ks::AbstractVector{_AccKernel})
    lo, hi = typemax(Int), typemin(Int)
    for K in Ks
        a, b = _cg_oln_extent(K.cells)
        a > b && continue
        lo = min(lo, a); hi = max(hi, b)
    end
    return lo > hi ? (1, 0) : (lo, hi)
end

# Record that `K`'s loop nest binds `oln` over its own cells.
function _cg_note_nest!(ctx::_CGFunction, K::_AccKernel)
    ctx.space.nst > 0 && !haskey(ctx.space.olnext, K) && (ctx.space.olnext[K] = _cg_oln_extent(K.cells))
    return nothing
end

# The slot extent of a slot table, ghost (0) entries left out.
function _cg_table_extent(ctx::_CGFunction, conn)
    got = get(ctx.space.sidememo, conn, nothing)
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
    ctx.space.sidememo[conn] = ext
    return ext
end

# The buffer descriptor `a` reads in kernel context `kc`. A state-lane
# descriptor of a tile that shares its code names a slot of the variable it
# reads (`idx`, `_range_real_repls!`), whose buffer is the one every read of it
# addresses, whatever cells the tile's box runs.
function _cg_side(ctx::_CGFunction, kc::_CGKernCtx, a::_AccDesc)
    ctx.space.nst > 0 || return :x
    k = a.kind
    if k === _AK_STATE_AFFINE
        kc.oln isa Symbol || return :x
        e = get(ctx.space.olnext, kc.K, nothing)
        e === nothing && return :x
        a.idx > 0 && return _cg_slot_side(ctx.space.nst, a.idx, a.idx)
        return _cg_slot_side(ctx.space.nst, e[1] + a.delta, e[2] + a.delta)
    elseif k === _AK_STATE_FIXED
        return _cg_slot_side(ctx.space.nst, a.idx, a.idx)
    elseif k === _AK_STATE_TBL_BOX && a.idx > 0
        return _cg_slot_side(ctx.space.nst, a.idx, a.idx)
    elseif k === _AK_STATE_TBL_BOX
        lo, hi = _cg_table_extent(ctx, a.conn)
        return _cg_slot_side(ctx.space.nst, lo, hi)
    end
    return :x
end

# A state read of slot expression `i` from the buffer `side` names.
_cg_uread(side::Symbol, i) =
    side === :s ? :(_cg_bufS(u)[$i]) : side === :o ? :(_cg_oview(u)[$i]) : :(u[$i])

# ---- One access descriptor → one indexing expression (mirrors `_fetch`) -----
# `key` identifies the descriptor (its table and position) for `_cg_geo!`.
function _cg_fetch(ctx::_CGFunction, kc::_CGKernCtx, a::_AccDesc, key = nothing)
    k = a.kind
    if k === _AK_STATE_AFFINE
        return _cg_uread(
            _cg_side(ctx, kc, a),
            _cg_offset(kc.oln, _cg_geo!(ctx, a.delta, _cg_gkey(key, :delta), true))
        )
    elseif k === _AK_CONST_BOX || k === _AK_FORCING_BOX
        # FORCING_BOX's arr is the aliased LIVE buffer — passing the reference
        # through `tabs` keeps every in-place refresh visible.
        return :(
            $(_cg_tab!(ctx, a.arr))[
                $(
                    _cg_boxaddr(
                        ctx, kc, a.s1, a.s2, a.s3, a.off,
                        a.sx, key
                    )
                ),
            ]
        )
    elseif k === _AK_STATE_FIXED
        return _cg_uread(_cg_side(ctx, kc, a), _cg_geo!(ctx, a.idx, _cg_gkey(key, :idx)))
    elseif k === _AK_LOOP_IDX
        return :(Float64($(_cg_mi(kc, a.dim))))
    elseif k === _AK_ARR_FIXED
        return :($(_cg_tab!(ctx, a.arr))[$(_cg_geo!(ctx, a.idx, _cg_gkey(key, :idx)))])
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
            ctx.nest.tblaffine && return _cg_uread(side, :($cb + $addr))
            push!(ctx.nest.tblcbs, cb)
        end
        tb = _cg_tabh!(ctx, _cg_run_tbl(a.conn, _cg_affine_conn(a.conn)))
        ctx.nest.tblread = true
        # Exactly `_fetch`'s ghost test: slot 0 ⇒ the ghost literal 0.0.
        return :(
            $cb == -2 ? $(_cg_uread(side, :($tb[$addr]))) :
                $cb >= 0 ? $(_cg_uread(side, :($cb + $addr))) :
                let $s = $tb[$addr]
                    $s == 0 ? 0.0 : $(_cg_uread(side, s))
            end
        )
    elseif k === _AK_ARR_TBL_BOX
        addr = _cg_boxaddr(ctx, kc, a.s1, a.s2, a.s3, a.off, a.sx, key)
        ctx.nest.tblread = true
        return :($(_cg_tabh!(ctx, a.arr))[$(_cg_tabh!(ctx, a.conn))[$addr]])
    end
    return _decline(:unsupported_desc)
end

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
function _cg_emit(ctx::_CGFunction, kc::_CGKernCtx, nd::_Node)
    _cg_budget!(ctx)
    k = nd.kind
    if k === _NK_ACCESS
        sb = kc.subst
        if sb !== nothing
            v = get(sb, nd.idx, nothing)
            v === nothing || return v
        end
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
        elseif pl === cse.inv_scratch && nd.idx <= length(kc.invsyms)
            return kc.invsyms[nd.idx]
        elseif pl === ctx.shared_cache && pl isa _CSECache
            # Shared scalar-prelude slot (xcse.jl rewrite). Emit the
            # interpreter's exact read — `_cse_read` selects `f64` at Float64
            # and the `alt::Vector{T}` buffer under any other `T`, both filled
            # by `_make_rhs`'s prelude tiers (at this same `T`) before the
            # kernel section runs; see the fill-ordering note at the tier docs
            # above.
            ctx.fscratch += 1
            return :(_cse_read($(_cg_tab!(ctx, pl)), $(nd.idx), _cgT))
        end
        _decline(:foreign_scratch)
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
        fnsym = _reducer_fnsym(op)
        return _cg_foldl(fnsym, exprs)
    elseif k === _NK_CALL
        return _cg_emit_call(ctx, kc, nd)
    elseif k === _NK_OP
        return _cg_emit_op(ctx, kc, nd)
    end
    return _decline(:unknown_kind, string(k))
end

# Affine reduction (`_NK_AREDUCE`) — `_eval_acc_areduce` as a loop nest: one
# accumulator seeded from the node's 0̄ (a `Float64`, as the interpreter seeds
# it), the contracted dims bound to loop counters (the first dim innermost),
# and `s = s ⊕ body` in the innermost loop. The body is emitted once, so the
# kernel's code does not grow with the contraction length.
function _cg_emit_areduce(ctx::_CGFunction, kc::_CGKernCtx, nd::_Node)
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
# the scan consumers (scan_fused.jl).
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
function _cg_emit_recipes!(stmts::Vector{Any}, ctx::_CGFunction, kc::_CGKernCtx)
    for r in kc.K.cse.recipes
        e = _cg_bound_body!(ctx, _cg_emit(ctx, kc, r))
        s = _cg_name(ctx, "q")
        push!(stmts, :(local $s = $e))
        push!(kc.cellsyms, s)
    end
    return stmts
end

# ---- Template calls (`_NK_CALL`, call.jl) ---------------------------------------
# A call target is emitted ONCE per generated function, as a function of its
# arguments, and every call site calls it: the number of functions is the
# number of targets (template instances), whatever the number of uses. The
# body is the interpreter's (`_eval_node` over the target's `_Node`), emitted
# through the same operator arms, so values are bit-identical; the arguments
# are emitted in the caller's context and evaluated before the body, as the
# interpreter evaluates them. A call in a conditional arm sits inside that arm's
# expression, so it runs only when the arm is taken.

struct _CGCallCtx
    args::Vector{Symbol}
    arrs::Vector{Symbol}
    # The comparison counts over a const array argument (`_cg_count_runtime`):
    # each distinct (array slot, lo, hi) is a table the call site passes
    # (`ctabs`, parameters `ctsyms`, each with a flag `ctoks`); `ctocc` lists
    # the table of every count emitted, for the tallies.
    ctabs::Vector{Tuple{Int, Int, Int}}
    ctsyms::Vector{Symbol}
    ctoks::Vector{Symbol}
    ctocc::Vector{Int}
    loops::IdDict{Any, Symbol}   # loop counters, and sub-trees computed once ahead ("A repeated sub-tree")
    spans::IdDict{Any, Tuple{Int, Int}}
    share::Any                   # a `_CGShareKeys` (array_contraction.jl, included later)
    # The literal tables the body reads, each a trailing parameter
    # (`consts[k]` is parameter `constsyms[k]`): a call function is a helper
    # outside the generated function's scope under the split transport, so it
    # reads a table through a parameter, never through the function's tabs.
    consts::Vector{Any}
    constsyms::Vector{Symbol}
end
_CGCallCtx(args, arrs) = _CGCallCtx(
    args, arrs, Tuple{Int, Int, Int}[], Symbol[], Symbol[], Int[],
    IdDict{Any, Symbol}(), IdDict{Any, Tuple{Int, Int}}(), _CGShareKeys(), Any[], Symbol[]
)

# The parameter that holds the literal table `cg` in the body being emitted
# (`_cg_const_gather` reads the table through it).
function _cg_cga(::_CGFunction, kc::_CGCallCtx, cg)
    k = findfirst(x -> x === cg, kc.consts)
    k === nothing || return kc.constsyms[k]
    push!(kc.consts, cg)
    push!(kc.constsyms, Symbol("_cgK", length(kc.consts)))
    return kc.constsyms[end]
end

function _cg_emit(ctx::_CGFunction, kc::_CGCallCtx, nd::_Node)
    _cg_budget!(ctx)
    shared = get(kc.loops, nd, nothing)
    shared === nothing || return shared
    k = nd.kind
    k === _NK_LITERAL && return nd.literal
    k === _NK_ARG && return kc.args[nd.idx]
    k === _NK_OP && return _cg_emit_op(ctx, kc, nd)
    k === _NK_CALL && return _cg_emit_call(ctx, kc, nd)
    k === _NK_ARG_GATHER && return _cg_arg_gather(ctx, kc, nd)
    # A read of a literal table in the body (an inline `const`, or a
    # reference to a template that is one, frames.jl `_tpl_const_table`): the
    # build-time array, read through a trailing parameter of the call
    # function (`_cg_cga`), which each call site passes (`_cg_emit_call`).
    k === _NK_CONST_GATHER && return _cg_call_const_gather(ctx, kc, nd)
    if k === _NK_CONTRACTION_LOOP
        spec = nd.payload::_ContractLoop
        rng = spec.lo:spec.step:spec.hi
        return _cg_contraction_loop(
            ctx, kc, nd, spec.lo, spec.step, spec.hi;
            span = isempty(rng) ? nothing : extrema((first(rng), last(rng)))
        )
    end
    if k === _NK_LOOPVAR
        s = get(kc.loops, nd.payload, nothing)
        s === nothing && _decline(:loopvar_out_of_scope)
        return :(Float64($s))
    end
    return _decline(:unknown_kind, string(nd.kind))
end
# A body is a DAG (an interpolation reads its bracket index many times): each
# region computes its repeated sub-trees once, as the scalar spine does.
_cg_emit_region(ctx::_CGFunction, kc::_CGCallCtx, nd::_Node) = _cg_emit_shared(ctx, kc, nd)
function _cg_share_leaf(K, kc::_CGCallCtx, nd::_Node)
    k = nd.kind
    (k === _NK_LITERAL || k === _NK_ARG) && return 0
    k === _NK_ARG_GATHER && return _cg_share_obj!(K, nd.payload)
    return _cg_share_inner(K, nd)
end

# The call of `nd` from emission context `kc`: the scalar arguments, then each
# array argument's gather payload (a run-time value, from this function's tabs).
function _cg_emit_call(ctx::_CGFunction, kc, nd::_Node)
    site = nd.payload::_CallSite
    tg = site.target
    f = _cg_call_fn!(ctx, tg)
    args = Any[_cg_emit(ctx, kc, c) for c in nd.children]
    for a in site.arrays
        if a.data isa _FwdArr
            # Passed on from the calling body: its own array parameter.
            push!(args, (kc::_CGCallCtx).arrs[(a.data::_FwdArr).j])
            continue
        end
        kc isa _CGCallCtx && _decline(:call_array_forward)
        push!(args, _cg_tab!(ctx, a.data))
    end
    # The count tables the body searches, built from this site's arrays (none
    # for a forwarded array: the body then counts entry by entry).
    for (tab, ok) in _cg_site_count_tables(ctx, site, :count_fold)
        if kc isa _CGCallCtx
            push!(args, GlobalRef(@__MODULE__, :_CG_NO_COUNT_TABLE), false)
        else
            push!(args, _cg_tab!(ctx, tab), ok)
        end
    end
    # The literal tables the body reads: from this function's tabs, or, in a
    # calling body, through that body's own parameter for it.
    for cg in get(ctx.callconsts, tg, Any[])
        push!(args, kc isa _CGCallCtx ? _cg_cga(ctx, kc, cg) : _cg_tab!(ctx, cg))
    end
    # An inlined body is compiled here too: it counts toward this function.
    ctx.nodes += get(ctx.inlsize, f, 0)
    return Expr(:call, f, :u, :p, :t, args...)
end

# `_NK_ARG_GATHER` in a call function: the walker's read
# (`_eval_state_gather_at` / `_eval_const_gather_at`) of the array parameter,
# whose bounds and strides are read from it at run time. A state gather tests
# each subscript before the next is evaluated, as the walker does.
function _cg_arg_gather(ctx::_CGFunction, kc::_CGCallCtx, nd::_Node)
    ref = nd.payload::_ArgGatherRef
    A = kc.arrs[ref.j]
    kind = ref.target.arrkinds[ref.j]
    ch = nd.children
    subs = Symbol[_cg_name(ctx, "ags") for _ in ch]
    if kind === :block
        # A block array: its layout is the target's, its base the argument.
        sg = ref.target.blocks[ref.j]::_StateGather
        bs = kc.args[ref.target.baseidx[ref.j]]
        off = _cg_foldl(:+, Any[:(unsafe_trunc(Int, $bs)), (:(($(subs[d]) - $(sg.lo[d])) * $(sg.strides[d])) for d in eachindex(ch))...])
        inner = :(@inbounds u[$off])
        for d in reverse(eachindex(ch))
            se = d == 1 ? _cg_emit(ctx, kc, ch[d]) : _cg_emit_region(ctx, kc, ch[d])
            inner = Expr(
                :let, Expr(:block, :($(subs[d]) = round(Int, $se))),
                Expr(:block, :(($(sg.lo[d]) <= $(subs[d]) <= $(sg.hi[d])) ? $inner : zero(eltype(u))))
            )
        end
        return inner
    end
    if kind === :state
        off = _cg_foldl(:+, Any[0, (:(($(subs[d]) - $A.lo[$d]) * $A.strides[$d]) for d in eachindex(ch))...])
        inner = :(@inbounds u[_sg_slot($A, $off)])
        for d in reverse(eachindex(ch))
            se = d == 1 ? _cg_emit(ctx, kc, ch[d]) : _cg_emit_region(ctx, kc, ch[d])
            inner = Expr(
                :let, Expr(:block, :($(subs[d]) = round(Int, $se))),
                Expr(:block, :(($A.lo[$d] <= $(subs[d]) <= $A.hi[$d]) ? $inner : zero(eltype(u))))
            )
        end
        return inner
    end
    binds = Any[]
    dims = ref.target.arrdims[ref.j]
    for d in eachindex(ch)
        se = d == 1 ? _cg_emit(ctx, kc, ch[d]) : _cg_emit_region(ctx, kc, ch[d])
        # A subscript whose every value is an integer on the axis (the
        # array's dimensions are part of the target) reads its element
        # directly: `round` and the boundary policy both return it unchanged.
        span = _cg_int_span(kc, ch[d])
        inside = span !== nothing && d <= length(dims) && 1 <= span[1] && span[2] <= dims[d]
        inside && _tally_cascade!(:gather_in_range)
        push!(
            binds, inside ? :($(subs[d]) = unsafe_trunc(Int, $se)) :
                :($(subs[d]) = _const_gather_sub($A, $d, round(Int, $se)))
        )
    end
    off = _cg_foldl(:+, Any[1, (:(($(subs[d]) - 1) * $A.strides[$d]) for d in eachindex(ch))...])
    return Expr(:let, Expr(:block, binds...), Expr(:block, :(@inbounds $A.flat[$off])))
end

# A literal table read in a body (`_NK_CONST_GATHER`): read through the
# body's parameter for it (`_cg_cga`), as a const array argument is read
# (`_cg_arg_gather`): strides from the passed array, each subscript through the
# walker's `_const_gather_sub` unless it is provably on its axis.
function _cg_call_const_gather(ctx::_CGFunction, kc::_CGCallCtx, nd::_Node)
    cg = nd.payload::_ConstGatherArray
    A = _cg_cga(ctx, kc, cg)
    ch = nd.children
    subs = Symbol[_cg_name(ctx, "cks") for _ in ch]
    binds = Any[]
    for d in eachindex(ch)
        se = d == 1 ? _cg_emit(ctx, kc, ch[d]) : _cg_emit_region(ctx, kc, ch[d])
        span = _cg_int_span(kc, ch[d])
        inside = span !== nothing && d <= length(cg.dims) && 1 <= span[1] && span[2] <= cg.dims[d]
        inside && _tally_cascade!(:gather_in_range)
        push!(
            binds, inside ? :($(subs[d]) = unsafe_trunc(Int, $se)) :
                :($(subs[d]) = _const_gather_sub($A, $d, round(Int, $se)))
        )
    end
    off = _cg_foldl(:+, Any[1, (:(($(subs[d]) - 1) * $A.strides[$d]) for d in eachindex(ch))...])
    return Expr(:let, Expr(:block, binds...), Expr(:block, :(@inbounds $A.flat[$off])))
end

# The emitted function of target `tg` (minted on first use in `ctx`).
function _cg_call_fn!(ctx::_CGFunction, tg::_CallTarget)
    got = get(ctx.callfns, tg, nothing)
    if got !== nothing
        name, at, def = got
        if at <= length(ctx.helpers) && ctx.helpers[at] === def
            _tally_cascade!(:cg_call_shared)
            return name
        end
    end
    argsyms = Symbol[Symbol("_cga", i) for i in eachindex(tg.slots)]
    arrsyms = Symbol[Symbol("_cgA", j) for j in eachindex(tg.arrslots)]
    # A block array is no parameter: its base is a scalar argument.
    arrparams = Symbol[arrsyms[j] for j in eachindex(tg.arrslots) if tg.passed[j] != 0]
    kc = _CGCallCtx(argsyms, arrsyms)
    body = _cg_emit_region(ctx, kc, tg.body)
    ln = LineNumberNode(0, Symbol("ess-template-call"))
    # Its emitted size with the inlined calls in it counted whole: a body
    # that is large once its calls are inlined is called, not inlined.
    sz = _cg_inl_size(ctx, body)
    small = sz <= _CG_INSTANCE_INLINE_MAX_NODES
    small && _count!(:cg_call_fn_inlined)
    stmts = Any[
        Expr(:meta, small ? :inline : :no_constprop),
        Expr(:macrocall, Symbol("@inbounds"), ln, :(return $body)),
    ]
    # In the helper namespace (`_cgh…`): never taken for a local to pass along
    # (`_cg_is_passable`).
    name = _cg_name(ctx, "htc")
    small && (ctx.inlsize[name] = sz)
    fdef = Expr(
        :function,
        Expr(:call, name, :u, :p, :t, argsyms..., arrparams..., Iterators.flatten(zip(kc.ctsyms, kc.ctoks))..., kc.constsyms...),
        Expr(:block, stmts...)
    )
    def = Expr(:macrocall, Symbol(small ? "@inline" : "@noinline"), ln, fdef)
    push!(ctx.helpers, def)
    ctx.callfns[tg] = (name, length(ctx.helpers), def)
    ctx.callcounts[tg] = (copy(kc.ctabs), copy(kc.ctocc))
    ctx.callconsts[tg] = copy(kc.consts)
    _tally_cascade!(:cg_call_fn)
    return name
end

const _CG_NO_COUNT_TABLE = Float64[]

# The count tables call site `site` passes to its target's function, in the
# order of the target's parameters (`ctx.callcounts`): per table `(entries,
# ok)`, `ok` false when this site's array cannot give the entries (its range
# leaves the array under a throwing boundary policy), where the body counts
# entry by entry. Each emitted count is tallied as the const-array count is
# (`tally` prefix `:count_fold`: `_search` over ascending entries, `_sorted`
# over a sorted copy; `:count_fold_setup` in setup geometry).
function _cg_site_count_tables(ctx::_CGFunction, site::_CallSite, tally::Symbol)
    got = get(ctx.callcounts, site.target, nothing)
    got === nothing && return Tuple{Vector{Float64}, Bool}[]
    ctabs, occ = got
    out = Tuple{Vector{Float64}, Bool, Bool}[]
    ct = _call_table()
    for (j, lo, hi) in ctabs
        a = site.arrays[site.target.passed[j]]
        if a.data isa _FwdArr
            push!(out, (Float64[], false, false))
            continue
        end
        build() = (
            f = _count_const_axis_of(a.data::_ConstGatherArray, lo:hi);
            f === nothing ? (Float64[], false, false) : (f[1], true, f[2])
        )
        # One object per table for the build, so a geometry kernel's sources
        # (`_geo_shape_key`) and its emission name the same array.
        push!(out, ct === nothing ? build() : get!(build, (ct::_CallTable).ctabs, (objectid(a.data), lo, hi)))
    end
    tally === :none || for k in occ
        _, ok, asc = out[k]
        ok || continue
        _tally_cascade!(tally === :count_fold ? (asc ? :count_fold_search : :count_fold_sorted) : tally)
    end
    return Tuple{Vector{Float64}, Bool}[(t, ok) for (t, ok, _) in out]
end

# The comparison count (`_cg_count_loop`) over a const ARRAY ARGUMENT read at
# the counter, with step 1: a binary search over the table of the array's
# entries over the range that the call site passes (`_cg_site_count_tables`,
# the const-array count's table, `_count_const_axis`), or, when the site
# could not build it, the comparison per entry. Both are the count, so the
# bits are the fold's whichever runs.
function _cg_count_runtime(ctx::_CGFunction, kc::_CGCallCtx, a::_Node, spec, test, neg, rel, xv, xe, kv_loop)
    (a.kind === _NK_ARG_GATHER && length(a.children) == 1) || return nothing
    s = a.children[1]
    (s.kind === _NK_LOOPVAR && s.payload === spec.ref) || return nothing
    ref = a.payload::_ArgGatherRef
    ref.target.arrkinds[ref.j] === :const || return nothing
    spec.step == 1 || return nothing
    key = (ref.j, spec.lo, spec.hi)
    k = findfirst(==(key), kc.ctabs)
    if k === nothing
        push!(kc.ctabs, key)
        push!(kc.ctsyms, Symbol("_cgCT", length(kc.ctabs)))
        push!(kc.ctoks, Symbol("_cgCTok", length(kc.ctabs)))
        k = length(kc.ctabs)
    end
    push!(kc.ctocc, k)
    tv, okv = kc.ctsyms[k], kc.ctoks[k]
    nrng = length(spec.lo:spec.hi)
    search = _cg_count_search(ctx, test, rel, neg, nrng, tv)
    linear = kv_loop()
    return quote
        let
            local $xv = $xe
            if $okv
                $search
            else
                $linear
            end
        end
    end
end

# The binary search for the count over the table `tv` (ascending entries),
# shared by the const-array count and the array-argument count.
function _cg_count_search(ctx::_CGFunction, test, rel, neg, nrng, tv)
    cv, hv, mv = _cg_name(ctx, "cn"), _cg_name(ctx, "ch"), _cg_name(ctx, "cm")
    return if rel === :<= || rel === :<
        quote
            local $cv = 0
            local $hv = length($tv)
            while $cv < $hv
                local $mv = ($cv + $hv + 1) >>> 1
                if $(test(:(@inbounds $tv[$mv])))
                    $cv = $mv
                else
                    $hv = $mv - 1
                end
            end
            Float64($(neg ? :($nrng - $cv) : cv))
        end
    else
        quote
            local $cv = 1
            local $hv = length($tv) + 1
            while $cv < $hv
                local $mv = ($cv + $hv) >>> 1
                if $(test(:(@inbounds $tv[$mv])))
                    $hv = $mv
                else
                    $cv = $mv + 1
                end
            end
            Float64($(neg ? :($nrng - (length($tv) + 1 - $cv)) : :(length($tv) + 1 - $cv)))
        end
    end
end

# Emitted-node size up to which a template call function is inlined at its calls.
# Measured on a 6-tracer, 400-cell flux template (test fixture, by-value
# section): out of line, the per-cell call made the right-hand side 4x slower.
const _CG_INSTANCE_INLINE_MAX_NODES = 2000

# ---- Op application -----------------------------------------------------------
#
# `_op_expr` is the expression form of the generated ladder (`_op_ladder`,
# tree_walk/op_ladder.jl): the same registry shapes, the same fold association,
# the same short-circuit set, the same `1.0`/`0.0` truth values, so emitted code
# computes what the walkers compute. `operands` holds one expression per operand,
# with every conditionally evaluated operand (`_op_arg_conditional`) already
# wrapped as a region of its own by the caller.
function _op_expr(s::_OpSpec, operands::Vector{Any})
    sh = s.shape
    n = length(operands)
    if sh === :fold
        n == 1 && return operands[1]
        return _cg_foldl(_op_fnsym(s), operands)
    elseif sh === :minmax
        return _cg_foldl(_op_fnsym(s), operands)
    elseif sh === :minus
        n == 1 && return :(-$(operands[1]))
        return :($(operands[1]) - $(operands[2]))
    elseif sh === :negate
        return :(-$(operands[1]))
    elseif sh === :binary
        return Expr(:call, _op_fnsym(s), operands[1], operands[2])
    elseif sh === :compare
        return :($(Expr(:call, _op_fnsym(s), operands[1], operands[2])) ? 1.0 : 0.0)
    elseif sh === :and || sh === :or
        cond = _cg_chain(sh === :and ? :&& : :||, Any[:($o != 0) for o in operands])
        return :($cond ? 1.0 : 0.0)
    elseif sh === :not
        return :($(operands[1]) == 0 ? 1.0 : 0.0)
    elseif sh === :select
        return :($(operands[1]) != 0 ? $(operands[2]) : $(operands[3]))
    elseif sh === :unary
        return Expr(:call, _op_fnsym(s), operands[1])
    elseif sh === :atan
        n == 1 && return :(atan($(operands[1])))
        return :(atan($(operands[1]), $(operands[2])))
    elseif sh === :constant
        return s.value::Float64
    elseif sh === :passthrough
        return operands[1]
    end
    error("_op_expr: no template for shape $sh")
end

# `kc` is left unannotated here and on `_cg_emit_fn`: the op ladder reads nothing
# off the evaluation context but the recursion, so the scalar-spine emitter
# (array_contraction.jl) shares it. An op outside the registry's shaped rows, or
# an operand count outside its arity, declines.
function _cg_emit_op(ctx::_CGFunction, kc, nd::_Node)
    op = nd.op
    ch = nd.children
    s = get(_OP_SYM_INDEX, op, nothing)
    (s === nothing || s.shape === nothing || !(length(ch) in s.arity)) &&
        _decline(:unsupported_op, String(op))
    operands = Any[
        _op_arg_conditional(op, j) ? _cg_emit_region(ctx, kc, c) : _cg_emit(ctx, kc, c)
            for (j, c) in enumerate(ch)
    ]
    return _op_expr(s, operands)
end

# ---- Invariant tier → prologue locals (mirrors `_fill_invariant!`) ----------
# Emitted once per kernel OBJECT. The dummy cell
# context (oln=1, midx=(1,1,1)) is `_fill_invariant!`'s — invariant
# recipes contain no cell-varying access, so it is never consulted, but a
# hand-built kernel that violates that reproduces the interpreter's reads.
function _cg_inv!(ctx::_CGFunction, K::_AccKernel)
    syms = get(ctx.prologue.invdone, K, nothing)
    syms === nothing || return syms
    syms = Symbol[]
    kc = _CGKernCtx(K, 1, 1, 1, 1, Symbol[], syms)
    ctx.prologue.invdone[K] = syms
    push!(ctx.prologue.invlog, K)
    # Geometry an invariant recipe reads (a fixed slot) is read into the
    # prologue too, just ahead of the statement that uses it.
    # An invariant whose emitted expression is one the prologue already holds
    # reuses that local: both read the same inputs (fixed slots, tabs,
    # parameters, earlier invariants) through the same operations before any
    # kernel runs, so they hold the same value. The box kernels a region-split
    # rule lowers repeat the same invariants box after box.
    _cg_with_geosink(ctx, ctx.prologue.stmts) do
        for r in K.cse.inv_recipes
            e = _cg_bound_body!(ctx, _cg_emit(ctx, kc, r))
            got = get(ctx.prologue.inv, e, nothing)
            if got !== nothing
                push!(syms, got)
                continue
            end
            s = _cg_name(ctx, "v")
            push!(ctx.prologue.stmts, :(local $s = $e))
            push!(syms, s)
            ctx.prologue.inv[e] = s
            push!(ctx.prologue.log, (length(ctx.prologue.stmts), true, e))
        end
    end
    return syms
end

# Drop the shared-prologue entries whose statements a declined kernel's
# rollback just cut (`resize!(ctx.prologue.stmts, n)`).
function _cg_prolog_rollback!(ctx::_CGFunction, n::Int)
    while !isempty(ctx.prologue.log) && ctx.prologue.log[end][1] > n
        _, isinv, k = pop!(ctx.prologue.log)
        delete!(isinv ? ctx.prologue.inv : ctx.prologue.geo, k)
    end
    return nothing
end

# ---- One kernel → its loop nest (mirrors `_run_acc_kernel!`) ----------------
# CHUNK-PARAMETERIZED (threaded cell axis, see "Threaded cell axis for the
# codegen tier" below): every loop nest iterates the cell ordinals `[a, b)` of
# ITS OWN cell set for chunk `_cgci` of `_cgnc`, where `(a, b)` is the shared
# static partition (`_chunk_ordinals`, access_kernel.jl — one arithmetic, not
# re-derived). The serial call is the `(1, 1)` instance: `a == 0, b == ncells`
# is the full loops, with the inner-loop body instruction-identical
# (outs/contig/rank-1 boxes differ only in loop-bound arithmetic; rank-2/3
# boxes add two per-ROW range clamps that select the full range at `(1, 1)`).
# Partition and iteration order are pure functions of `(ncells, nchunks)`, and
# a cell computes the same instruction sequence on the same inputs whichever
# chunk it lands in, so any chunking reproduces the serial values BIT FOR BIT
# as long as no two cells share a `du` slot (checked at build — see
# `_cg_covered_outs_disjoint`).
function _cg_emit_kernel!(ctx::_CGFunction, K::_AccKernel)
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
function _cg_tbl_versions(emit, ctx::_CGFunction)
    cbs0 = ctx.nest.tblcbs
    ctx.nest.tblcbs = Symbol[]
    try
        nestG = emit()
        isempty(ctx.nest.tblcbs) && return nestG
        cond = nothing
        for cb in unique(ctx.nest.tblcbs)
            c = :($cb >= 0)
            cond = cond === nothing ? c : :($cond && $c)
        end
        ctx.nest.tblaffine = true
        nestA = try
            emit()
        finally
            ctx.nest.tblaffine = false
        end
        return :(
            if $cond
                $nestA
            else
                $nestG
            end
        )
    finally
        ctx.nest.tblcbs = cbs0
    end
end

# A fused scan's consumer cell (scan_fused.jl): kernel `cons.K`'s body at the
# state slot `oln - delta`, with its scanned-observed read as the local `xv`,
# stored into the state part of `du`.
function _cg_scan_consumer_cell(ctx::_CGFunction, cons, oln::Symbol, xv::Symbol)
    Kc = cons.K
    oc = _cg_name(ctx, "oc")
    d = _cg_geo!(ctx, cons.delta, (Kc, :scan_consumer_delta))
    kc = _CGKernCtx(Kc, oc, 1, 1, 1, Symbol[], cons.invsyms, Any[], Dict{Int, Any}(cons.ix => xv))
    stmts = Any[:(local $oc = $oln - $d)]
    _cg_emit_recipes!(stmts, ctx, kc)
    val = _cg_bound_body!(ctx, _cg_emit(ctx, kc, Kc.spine))
    push!(stmts, :(_cg_bufS(du)[$oc] = $val))
    return stmts
end

# A table read a cell makes more than once, read once. The access CSE gives a
# slot to repeated OPERATORS, never to a bare read, and the kernel-class merge
# gives every member read its own descriptor; a read through a table costs
# some seventy emitted nodes (its address, the ghost test and the
# loop-version ladder). Reads made by the caller of a template call are one
# argument per read occurrence (call.jl), so a merged stencil cell reads the
# same table at the same address many times (two face fluxes of a cell read
# the same neighbours). Descriptors whose keys are equal (`_cg_read_key`: equal
# tables at the same address) are the same read of the same cell; each such read is made once into a local at the top of the cell,
# and every use reads the local (`kc.subst`). A read inside an affine
# reduction is addressed by the reduction's counters, not the cell's, so a
# descriptor read there is left alone. A read is pure and cannot fail (the
# table covers every cell of the box), so making it once ahead of its uses
# gives every use the same value.
const _CG_SHARED_READ_KINDS = (_AK_STATE_TBL_BOX, _AK_ARR_TBL_BOX, _AK_CONST_BOX, _AK_FORCING_BOX)

# The content number of table `v` in this function (one per distinct entry
# list; each object hashed once).
function _cg_tbl_content(ctx::_CGFunction, v)
    v isa Vector || return objectid(v)
    got = get(ctx.tblid, v, 0)
    got == 0 || return got
    c = get!(ctx.tblcontent, v, length(ctx.tblcontent) + 1)
    ctx.tblid[v] = c
    return c
end

# Two descriptors with equal keys read the same value at every cell: the kind,
# the address (strides, offset), the table by CONTENT (a merge makes one table
# object per member read, so equal reads hold equal tables, not one table), and
# a live buffer by identity.
function _cg_read_key(ctx::_CGFunction, a::_AccDesc)
    k = a.kind
    tbl = k === _AK_STATE_TBL_BOX || k === _AK_ARR_TBL_BOX ? _cg_tbl_content(ctx, a.conn) : 0
    arr = k === _AK_CONST_BOX ? _cg_tbl_content(ctx, a.arr) :
        (k === _AK_ARR_TBL_BOX || k === _AK_FORCING_BOX) ? objectid(a.arr) : UInt(0)
    return (k, tbl, arr, a.s1, a.s2, a.s3, a.off, Tuple(a.sx))
end
function _cg_shared_reads!(stmts::Vector{Any}, ctx::_CGFunction, kc::_CGKernCtx)
    K = kc.K
    acc = K.acc
    uses = Dict{Any, Int}()
    firstidx = Dict{Any, Int}()
    inred = Set{Int}()
    seen = IdDict{_Node, Nothing}()
    function walk(n::_Node, red::Bool)
        k = n.kind
        if k === _NK_ACCESS
            if red
                push!(inred, n.idx)
            elseif acc[n.idx].kind in _CG_SHARED_READ_KINDS
                key = _cg_read_key(ctx, acc[n.idx])
                uses[key] = get(uses, key, 0) + 1
                get!(firstidx, key, n.idx)
            end
            return
        end
        (haskey(seen, n) && !red) && return
        red || (seen[n] = nothing)
        r = red || k === _NK_AREDUCE
        for c in n.children
            walk(c, r)
        end
        return
    end
    walk(K.spine, false)
    for r in K.cse.recipes
        walk(r, false)
    end
    any(>(1), values(uses)) || return kc
    sub = kc.subst === nothing ? Dict{Int, Any}() : copy(kc.subst)
    bykey = Dict{Any, Any}()
    for i in eachindex(acc)
        acc[i].kind in _CG_SHARED_READ_KINDS || continue
        i in inred && continue
        haskey(sub, i) && continue
        key = _cg_read_key(ctx, acc[i])
        get(uses, key, 0) > 1 || continue
        v = get(bykey, key, nothing)
        if v === nothing
            r = _cg_name(ctx, "rd")
            push!(stmts, :(local $r = $(_cg_fetch(ctx, kc, acc[firstidx[key]], (acc, firstidx[key])))))
            v = bykey[key] = r
        end
        sub[i] = v
    end
    return _CGKernCtx(kc.K, kc.oln, kc.mi1, kc.mi2, kc.mi3, kc.cellsyms, kc.invsyms, kc.mix, sub)
end

# One cell's statements: the CSE recipes as locals (converted to T exactly
# where the interpreter's scratch store converts), then the spine stored into
# `du[oln]`, or, inside a fused scan's nest (`sm`, a `_CGStoreScan`), folded
# into the lane's running value.
function _cg_cell_stmts(ctx::_CGFunction, K::_AccKernel, sm::_CGStore, kc::_CGKernCtx)
    stmts = Any[]
    kc = _cg_shared_reads!(stmts, ctx, kc)
    _cg_emit_recipes!(stmts, ctx, kc)
    val = _cg_bound_body!(ctx, _cg_emit(ctx, kc, K.spine))
    if sm isa _CGStoreDu
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

# Box geometry as the emitted loops read it. Every bound, base and stride is
# run-time geometry (`_cg_geo!`), except the extent of a boundary slab's thin
# axis (`_cellset_slab`), and the count of a box that is a slab on every axis:
# it is one cell at every N, and a literal extent lets the compiler drop that
# axis's loop, where a run-time one leaves a loop set up (and vectorized) for a
# single cell per row. The slab's index stays data, so the far edge's is one
# function too.
_cg_box_geo!(ctx::_CGFunction, cs::_CellSet, v, f, unit::Bool = false) =
    _cg_geo!(ctx, v, (cs, f), unit)

# Axis `d` of box `cs`: `(first, last, length)` as emitted.
function _cg_box_axis!(ctx::_CGFunction, cs::_CellSet, d::Int)
    lo = _cg_box_geo!(ctx, cs, first(cs.ranges[d]), (d, :first))
    _cg_slab_literal(cs, d) && return (lo, lo, 1)
    n = length(cs.ranges[d])
    return (
        lo, _cg_box_geo!(ctx, cs, last(cs.ranges[d]), (d, :last)),
        _cg_box_geo!(ctx, cs, n, (d, :len)),
    )
end

# A nest's chunk header: the statements that bind this chunk's half-open,
# 0-based range `[a, b)` of the cell-ordinal axis (`_chunk_ordinals`), and the
# names of `a` and `b`. A fused scan's nest runs the one lane its caller bound.
function _cg_nest_header!(ctx::_CGFunction, cs::_CellSet, sm::_CGStore)
    ncells = _cellset_ncells(cs)
    tv = _cg_name(ctx, "ab")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    sm isa _CGStoreScan && return Any[], sm.a, sm.b
    # (A tile that shares its code counts every box at run time: it runs no
    # cell of a box it does not own.)
    corner = !isempty(cs.strides) && all(d -> _cellset_slab(cs, d), eachindex(cs.strides)) &&
        !_range_shared_code(_range_spec_now())
    hdr = Any[
        :(local $tv = _chunk_ordinals($(corner ? 1 : _cg_box_geo!(ctx, cs, ncells, :n)), _cgci, _cgnc)),
        :(local $av = $tv[1]),
        :(local $bv = $tv[2]),
    ]
    return hdr, av, bv
end

# ---- Loop-position decoding ---------------------------------------------------
# A flat 0-based loop position held in the local `r` is decoded into one
# position per axis, the first axis varying fastest: along an axis of extent
# `len` the digit is `r % len`, and `r` divided by `len` goes on to the next
# axis. `_cg_decode_digit!` appends one axis's statements to `stmts`: the
# digit bound to the local `qv` first when one is given, then `use(q)`, the
# statements that read the digit `q` (that local, or the expression
# `r % len`), then the division.
function _cg_decode_digit!(
        use, stmts::Vector{Any}, r::Symbol, len;
        qv::Union{Nothing, Symbol} = nothing
    )
    q = :($r % $len)
    if qv !== nothing
        push!(stmts, :(local $qv = $q))
        q = qv
    end
    append!(stmts, use(q))
    push!(stmts, :($r = div($r, $len)))
    return stmts
end

# The index digit `q` names on an axis that starts at `lo` and steps by `st`
# (`nothing` for a unit step written as none).
_cg_axis_index(lo, q, st) = st === nothing ? :($lo + $q) : :($lo + $q * $st)

# A listed-slots kernel: the chunk's ordinals index the out-slot table.
function _cg_emit_outs_nest!(ctx::_CGFunction, K::_AccKernel, sm::_CGStore, invsyms, hdr, av, bv)
    outs = _cg_tab!(ctx, K.cells.outs)
    c = _cg_name(ctx, "c")
    oln = _cg_name(ctx, "o")
    kc = _CGKernCtx(K, oln, c, 1, 1, Symbol[], invsyms)
    ctx.nest.tblread = false
    body = _cg_cell_stmts(ctx, K, sm, kc)
    tv1 = _cg_tblread!(ctx)
    return quote
        $(hdr...)
        for $c in ($av + 1):$bv
            local $oln = $outs[$c]
            $(body...)
            $(tv1...)
        end
    end
end

# One kernel's loop nest over its chunk of cells, each cell's value going to
# the store `sm`. A fused scan's store keeps the kernel's own axes
# (leading-axis fusion would change the lane's cell order).
function _cg_emit_kernel_nest!(
        ctx::_CGFunction, K::_AccKernel, invsyms::Vector{Symbol}, sm::_CGStore = _CGStoreDu()
    )
    sm isa _CGStoreDu && (K = _cg_fuse_leading(K))
    _cg_note_nest!(ctx, K)
    cs = K.cells
    hdr, av, bv = _cg_nest_header!(ctx, cs, sm)
    _is_outs(cs) && return _cg_emit_outs_nest!(ctx, K, sm, invsyms, hdr, av, bv)
    _is_cellless(cs) && error("_cg_emit_kernel_nest!: a kernel with no cells has no loop nest")
    # Strided Cartesian box, rank ≤ 3, in `_run_box_kernel!`'s exact iteration
    # order (k-outer, i-inner). The flat cell ordinal `o`
    # of `(i, j, k)` is `(i-i0) + ni·((j-j0) + nj·(k-k0))` — exactly the serial
    # enumeration position — and a chunk `[a, b)` is walked as whole i-ROWS
    # with the FIRST and LAST row's i-range clamped to the chunk boundary
    # (the decode is hoisted to the row level so the inner loop stays a plain
    # counted loop).
    nd = length(cs.strides)
    nd <= 3 || return _cg_emit_box_rank_n(ctx, K, cs, sm, hdr, av, bv)
    st = Any[_cg_geo!(ctx, cs.strides[d], (cs, d, :stride), true) for d in 1:nd]
    iv = _cg_name(ctx, "i")
    jv = nd >= 2 ? _cg_name(ctx, "j") : 1
    kv = nd >= 3 ? _cg_name(ctx, "k") : 1
    oln = _cg_name(ctx, "o")
    olnexpr = :($(_cg_box_geo!(ctx, cs, cs.base, :base)) + $iv * $(st[1]))
    nd >= 2 && (olnexpr = :($olnexpr + $jv * $(st[2])))
    nd >= 3 && (olnexpr = :($olnexpr + $kv * $(st[3])))
    kc = _CGKernCtx(K, oln, iv, jv, kv, Symbol[], invsyms)
    ctx.nest.tblread = false
    body = _cg_cell_stmts(ctx, K, sm, kc)
    # The innermost loop's own annotation: kept scalar when it gathers through
    # a slot table (`_cg_tblread!`).
    tv1 = _cg_tblread!(ctx)
    i0, i1, ni = _cg_box_axis!(ctx, cs, 1)
    if nd == 1 && sm isa _CGStoreDu
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
    j0, j1, _ = _cg_box_axis!(ctx, cs, 2)
    # A row of a rank-2/3 box whose cell value is one affine reduction runs the
    # reduction interchanged, as the rank-1 case above does (Float64 only).
    rowinter = sm isa _CGStoreDu ?
        _cg_areduce_interchanged(ctx, K, kc, iv, oln, olnexpr, :($ilo:$ihi)) : nothing
    rowloop = quote
        for $iv in $ilo:$ihi
            local $oln = $olnexpr
            $(body...)
            $(tv1...)
        end
    end
    rowinter === nothing ||
        (
        rowloop = quote
            if _cgT === Float64 && eltype(du) === Float64
                $rowinter
            else
                $rowloop
            end
        end
    )
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
                    $rowloop
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
    nj = _cg_box_axis!(ctx, cs, 2)[3]; k0 = _cg_box_axis!(ctx, cs, 3)[1]
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
                    $rowloop
                    $(nv...)
                end
                $(nv...)
            end
        end
    end
end

# ---- Leading-axis fusion -----------------------------------------------------
# A box whose first axis spans whole rows of everything it addresses — the
# output, and every box-addressed read — walks its first two axes as one: a row
# of the fused box is `len1·len2` cells long where it was `len1`, which is the
# difference between a vectorized loop and a loop of short rows (a column field
# whose first axes are a small horizontal grid). Cell `(i, j, …)` becomes
# `(i + (j - j0)·len1, …)`; each address and output slot is the same integer
# sum it was, so every cell computes the same operations on the same operands.
# Applies when every address is affine in the first two axes with the second
# stride `len1` times the first — the output's (`strides`) and each
# box-addressed descriptor's (`s1`, `s2`) — and nothing reads the loop indices
# themselves (`_AK_LOOP_IDX` on those axes) or a per-lane `fn` table.
function _cg_fuse_leading(K::_AccKernel)
    cs = K.cells
    (_is_outs(cs) || _is_cellless(cs)) && return K
    # Whether a box spans whole rows depends on the cells a tile owns, so a
    # tile that shares its code never fuses.
    _range_shared_code(_range_spec_now()) && return K
    nd = length(cs.strides)
    nd >= 2 || return K
    len1 = length(cs.ranges[1])
    (len1 >= 1 && cs.strides[2] == len1 * cs.strides[1]) || return K
    _cellset_slab(cs, 1) && return K
    for a in K.acc
        k = a.kind
        if _ak_box_addressed(k)
            a.s2 == len1 * a.s1 || return K
        elseif k === _AK_LOOP_IDX
            a.dim <= 2 && return K
        end
    end
    j0 = first(cs.ranges[2])
    shift(s1, s2, s3, sx) = (
        s1, s3, isempty(sx) ? 0 : sx[1],
        length(sx) > 1 ? Vector{Int}(sx[2:end]) : _AK_NO_CONN,
    )
    acc = _AccDesc[]
    for a in K.acc
        k = a.kind
        if _ak_box_addressed(k)
            n1, n2, n3, nx = shift(a.s1, a.s2, a.s3, a.sx)
            push!(acc, _acc_with_box(a; s1 = n1, s2 = n2, s3 = n3, off = a.off + (j0 - 1) * a.s2, sx = nx))
        elseif k === _AK_LOOP_IDX
            push!(acc, _acc_with_box(a; dim = a.dim - 1))
        else
            push!(acc, a)
        end
    end
    memo = IdDict{_Node, _Node}()
    function remap(n::_Node)
        return get!(memo, n) do
            ch = _Node[remap(c) for c in n.children]
            pl = n.payload
            if n.kind === _NK_AREDUCE
                sp = pl::_AReduceSpec
                pl = _AReduceSpec(Int[d - 1 for d in sp.dims], sp.ranges)
            end
            _Node(n.kind, n.op, n.literal, n.idx, n.sym, pl, ch)
        end
    end
    spine = remap(K.spine)
    cse = _AccCSE(
        _Node[remap(r) for r in K.cse.recipes], K.cse.scratch,
        _Node[remap(r) for r in K.cse.inv_recipes], K.cse.inv_scratch
    )
    r1 = first(cs.ranges[1])
    ranges = vcat(
        UnitRange{Int}[r1:(r1 + len1 * length(cs.ranges[2]) - 1)],
        cs.ranges[3:end]
    )
    strides = Int[cs.strides[1]; cs.strides[3:end]]
    slab = length(cs.slab) >= 2 ? Bool[false; cs.slab[3:end]] : Bool[]
    cells = _CellSet(strides, ranges, cs.base + j0 * cs.strides[2], Int[], slab)
    return _cg_fuse_leading(_AccKernel(cells, spine, acc, cse))
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
    # Rows by their end points: every empty range is `==` every other.
    return (
        nd, cs.base, Tuple(cs.strides),
        Tuple((first(cs.ranges[d]), last(cs.ranges[d])) for d in 2:nd),
        Tuple(_cellset_slab(cs, d) for d in 2:nd),
    )
end

# Groups of kernel indices to row-fuse (two or more members, leading-axis
# ranges pairwise disjoint, ordered along that axis), keyed by the index of
# the group's first kernel in build order.
function _cg_rowfuse_groups(kernels::AbstractVector{_AccKernel})
    out = Dict{Int, Vector{Int}}()
    # Which boxes share their rows is read from the rows a tile runs, so a
    # tile that shares its code emits every box as its own nest.
    _range_shared_code(_range_spec_now()) && return out
    byrow = Dict{Any, Vector{Int}}()
    for (j, K) in enumerate(kernels)
        key = _cg_rowfuse_key(K)
        key === nothing || push!(get!(byrow, key, Int[]), j)
    end
    for js in values(byrow)
        length(js) >= 2 || continue
        ord = sort(js; by = j -> first(kernels[j].cells.ranges[1]))
        ok = _allof(
            m -> last(kernels[ord[m - 1]].cells.ranges[1]) <
                first(kernels[ord[m]].cells.ranges[1]), 2:length(ord)
        )
        ok && (out[minimum(js)] = ord)
    end
    return out
end

function _cg_emit_rowgroup!(ctx::_CGFunction, Ks::Vector{_AccKernel})
    invs = Vector{Vector{Symbol}}()
    for K in Ks
        push!(invs, _cg_inv!(ctx, K))
    end
    geo = Any[]
    nest = _cg_with_geosink(ctx, geo) do
        _cg_tbl_versions(() -> _cg_emit_rowgroup_nest!(ctx, Ks, invs), ctx)
    end
    return Expr(:block, geo..., nest)
end

function _cg_emit_rowgroup_nest!(
        ctx::_CGFunction, Ks::Vector{_AccKernel},
        invs::Vector{Vector{Symbol}}
    )
    cs1 = Ks[1].cells
    nd = length(cs1.strides)
    # The same geometry rules as `_cg_emit_kernel_nest!` (`_cg_box_axis!`).
    axis(cs, d) = _cg_box_axis!(ctx, cs, d)
    st = Any[_cg_geo!(ctx, cs1.strides[d], (cs1, d, :stride), true) for d in 1:nd]
    base = _cg_geo!(ctx, cs1.base, (cs1, :base))
    jv = _cg_name(ctx, "j")
    kv = nd >= 3 ? _cg_name(ctx, "k") : 1
    j0, j1, nj = axis(cs1, 2)
    k0, _, nk = nd >= 3 ? axis(cs1, 3) : (1, 1, 1)
    olnof(iv) = (
        e = :($base + $iv * $(st[1]) + $jv * $(st[2]));
        nd >= 3 ? :($e + $kv * $(st[3])) : e
    )
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
        kc = _CGKernCtx(K, oln, iv, jv, kv, Symbol[], invs[m])
        ctx.nest.tblread = false
        rec = _cg_emit_recipes!(Any[], ctx, kc)
        val = _cg_bound_body!(ctx, _cg_emit(ctx, kc, K.spine))
        tv1 = _cg_tblread!(ctx)
        i0, i1, _ = axis(K.cells, 1)
        push!(parts, (; iv, oln, rec, val, i0, i1, tv1))
    end
    segs = Any[
        seg(
            q.iv, q.i0, q.i1, q.oln,
            Any[q.rec..., :(du[$(q.oln)] = $(q.val)), q.tv1...]
        )
            for q in parts
    ]
    fis = _cg_row_fission(ctx, Ks, parts)
    if fis !== nothing
        holes, stages, iF, oF = fis
        fsegs = Any[
            seg(q.iv, q.i0, q.i1, q.oln, Any[:(du[$(q.oln)] = $(holes[m]))])
                for (m, q) in enumerate(parts)
        ]
        # A stage reads and writes only its own cell's `du` slot, so its
        # iterations are independent; `julia.ivdep` says so to the loop
        # vectorizer, which cannot prove it for a load and a store of one
        # array. It licenses no reassociation (that is `julia.simdloop`).
        for F in stages
            push!(
                fsegs, seg(
                    iF, parts[1].i0, parts[end].i1, oF,
                    Any[:(du[$oF] = $F), Expr(:loopinfo, Symbol("julia.ivdep"))]
                )
            )
        end
        # The split form stores each segment's hole value in `du` and reads it
        # back, which is exact only when that value already has `du`'s element
        # type: it does when `u`, `du` and the value type agree (the hole reads
        # `u`), and every other call takes the one-pass form.
        segs = Any[
            quote
                if eltype(u) === _cgT && eltype(du) === _cgT
                    $(fsegs...)
                else
                    $(segs...)
                end
            end,
        ]
        _tally_cascade!(:cg_row_fission)
    end
    tv = _cg_name(ctx, "ab")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    hdr = Any[
        :(local $tv = _chunk_ordinals($nj * $nk, _cgci, _cgnc)),
        :(local $av = $tv[1]),
        :(local $bv = $tv[2]),
    ]
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
_cg_areduce_interchanged(
    ctx::_CGFunction, K::_AccKernel, kc::_CGKernCtx,
    iv::Symbol, oln::Symbol, olnexpr, i0, av, bv
) =
    _cg_areduce_interchanged(ctx, K, kc, iv, oln, olnexpr, :(($i0 + $av):($i0 + $bv - 1)))
# The same nest over one row `rng` of the leading cell axis, for a box of rank 2
# or 3 whose rows the caller walks.
function _cg_areduce_interchanged(
        ctx::_CGFunction, K::_AccKernel, kc::_CGKernCtx,
        iv::Symbol, oln::Symbol, olnexpr, rng
    )
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
        for $iv in $rng
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
        for $iv in $rng
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
    # Each read counts once per path that reaches it, as the emitted nest
    # performs it once per use.
    order, pos = _dag_postorder(body, _dag_children, _dag_every)
    paths, _ = _dag_path_counts(order, pos, _dag_children, _dag_every, _dag_strict)
    for (p, n) in enumerate(order)
        n.kind === _NK_ACCESS || continue
        a = K.acc[n.idx]
        _ak_box_addressed(a.kind) || continue
        so = stride(a, 1)
        sk = stride(a, rdim)
        near(so) && !near(sk) && (gain += paths[p])
        near(sk) && !near(so) && (gain -= paths[p])
    end
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
function _cg_row_fission(ctx::_CGFunction, Ks::Vector{_AccKernel}, parts)
    length(Ks) >= 2 || return nothing
    # The split is chosen from the members' geometry, which differs from tile
    # to tile, so a tile that shares its code keeps the one-pass form.
    _range_shared_code(_range_spec_now()) && return nothing
    all(q -> isempty(q.rec), parts) || return nothing
    for m in 2:length(Ks)
        last(Ks[m - 1].cells.ranges[1]) + 1 == first(Ks[m].cells.ranges[1]) || return nothing
    end
    gval = Dict{Symbol, Int}()
    for st in ctx.nest.sink
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
    lazy(e) = e isa Expr && (
        e.head in (:if, :&&, :||, :let, :block) ||
            _anyof(lazy, e.args)
    )
    _anyof(q -> lazy(q.val), parts) && return nothing
    cs = Any[canon(q.val, q) for q in parts]
    # The hole: descend while the members differ in exactly one child.
    function walk(es, at)
        e1 = es[1]
        all(e -> isequal(e, e1), es) && return nothing
        if e1 isa Expr && all(
                e -> e isa Expr && e.head === e1.head &&
                    length(e.args) == length(e1.args), es
            )
            diffs = [
                i for i in eachindex(e1.args)
                    if !all(e -> isequal(e.args[i], e1.args[i]), es)
            ]
            length(diffs) == 1 &&
                return walk(Any[e.args[diffs[1]] for e in es], (at..., diffs[1]))
        end
        return at
    end
    path = walk(cs, ())
    (path === nothing || isempty(path)) && return nothing
    sub(e, pth) = isempty(pth) ? e : sub(e.args[pth[1]], pth[2:end])
    reads_u(e) = e isa Expr && (_cg_is_uread(e) || _anyof(reads_u, e.args))
    holes = Any[sub(q.val, path) for q in parts]
    _allof(reads_u, holes) || return nothing
    _anyof(h -> h isa Expr && _cg_expr_size(h) >= 4, holes) || return nothing
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
    e.head === :ref && (
    e.args[1] === :u ||
        (
        e.args[1] isa Expr && e.args[1].head === :call &&
            e.args[1].args[1] in (:_cg_bufS, :_cg_oview)
    )
)

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
function _cg_emit_box_rank_n(
        ctx::_CGFunction, K::_AccKernel, cs::_CellSet, sm::_CGStore, hdr, av, bv
    )
    nd = length(cs.strides)
    st = Any[_cg_geo!(ctx, cs.strides[d], (cs, d, :stride), true) for d in 1:nd]
    ax = [_cg_box_axis!(ctx, cs, d) for d in 1:nd]
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
    rowexpr = _cg_box_geo!(ctx, cs, cs.base, :base)
    for d in 2:nd
        rowexpr = :($rowexpr + $(ovs[d]) * $(st[d]))
    end
    kc = _CGKernCtx(
        K, oln, ovs[1], ovs[2], ovs[3], Symbol[], _cg_inv!(ctx, K),
        Any[ovs[d] for d in 4:nd]
    )
    ctx.nest.tblread = false
    body = _cg_cell_stmts(ctx, K, sm, kc)
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

# The `let` bindings a generated section runs its kernels under: on a
# two-buffer slot space, `du` as the buffer all of `Ks`' cells write.
function _cg_section_bindings(nst::Int, Ks::AbstractVector{_AccKernel})
    b = Expr(:block)
    if nst > 0
        side = _cg_slot_side(nst, _cg_oln_extent(Ks)...)
        side === :x || push!(b.args, :(du = _cg_dview(du, Val($(QuoteNode(side))))))
    end
    return b
end

# ---- Build the fused generated RHS section ----------------------------------
struct _CGBuilt{F, TB}
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
    # The section's work estimate in emitted-node evaluations
    # (`_acc_kernel_work` per cell, summed over the covered kernels' cells),
    # what the threading verdict holds against the work floor.
    work::Int
    # Whether a covered kernel is one affine reduction, which the emitter may
    # interchange into a read-modify-write of each `du` slot per reduced term
    # (`_cg_areduce_interchanged`); see `_THREAD_MIN_RMW_CELLS`.
    rmw::Bool
end

# Build-time SECTION-chunking safety check: are the emitted kernels' output
# slots globally pairwise-distinct ACROSS the whole generated function? Only
# then may one chunk run ALL kernels' cell sub-ranges without a barrier —
# two chunks could otherwise read-modify-write one `du` slot from different
# kernels (indirect-out / scatter merges CAN alias across kernels; the
# `_KernelSection` derivative-section comment says they don't for state
# equations, but this VERIFIES rather than trusts, and materialized-observed
# sections go through the same builder). Returns `(total cells, disjoint)`.
function _cg_covered_outs_disjoint(
        acc_kernels::AbstractVector{_AccKernel},
        covered::Vector{Bool}
    )
    ncells = 0
    work = 0
    rmw = false
    for (j, K) in enumerate(acc_kernels)
        covered[j] || continue
        nc = _cellset_ncells(K.cells)
        ncells += nc
        rmw |= K.spine.kind === _NK_AREDUCE
        work = Base.Checked.checked_add(
            work,
            Base.Checked.checked_mul(nc, _acc_kernel_work(K))
        )
    end
    return ncells, _cellsets_outs_unique(
            K.cells for (j, K) in enumerate(acc_kernels)
            if covered[j]
        ), work, rmw
end

# One cell's work in a kernel, in node evaluations: every node of the spine and
# of the per-cell CSE recipes counts one, a loop's body counts once per
# iteration (an affine reduction's or a contraction loop's range).
# The loop-invariant recipes run once per call and do not count. A rough cost,
# used only to decide whether a section is worth a thread dispatch.
function _acc_kernel_work(K::_AccKernel)
    w = _acc_node_work(K.spine, K)
    for r in K.cse.recipes
        w += _acc_node_work(r, K)
    end
    return max(w, 1)
end
_acc_node_work(root::_Node, K::_AccKernel) =
    _node_fold(root, Int) do nd, kids
    return 1 + sum(kids; init = 0) * _node_loop_reach(nd)
end

# The iterations a looping node runs its body for (1 for any other node).
function _node_loop_reach(nd::_Node)
    pl = nd.payload
    if nd.kind === _NK_AREDUCE && pl isa _AReduceSpec
        r = 1
        for rg in pl.ranges
            r = Base.Checked.checked_mul(r, max(length(rg), 1))
        end
        return r
    elseif nd.kind === _NK_CONTRACTION_LOOP && pl isa _ContractLoop
        return max(length(pl.lo:pl.step:pl.hi), 1)
    elseif nd.kind === _NK_RAGGED_LOOP && pl isa _RaggedLoop
        return pl.reach
    end
    return 1
end

# A scalar spine's work in node evaluations, loops counted per iteration.
_node_work(root::_Node) =
    _node_fold((nd, kids) -> 1 + sum(kids; init = 0) * _node_loop_reach(nd), root, Int)

# Per-generated-FUNCTION emitted-node cap. The node budget above bounds total
# AST size; this bounds the size of any ONE compiled function, because LLVM's
# first-call compile memory is super-linear in single-function size. Loop nests
# are packed into `@noinline`
# sub-functions up to this cap so LLVM compiles bounded pieces. Override with
# ESS_CODEGEN_FN_NODE_CAP; 0 disables splitting (one function, one flat body).
# Every supported Julia can split (`_cg_split_transport` picks the transport),
# so an oversized body is compiled rather than declined, on every version.
_codegen_fn_node_cap() = _tuning_now().fn_node_cap

# Whether this Julia can carry an emitted sub-function as an INNER DEFINITION —
# a `function` written inside the emitted body. Julia < 1.12 cannot, and takes
# the by-value transport instead (`_cg_carry_by_value`); the split itself is
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
_cg_split_supported() = VERSION >= v"1.12"

# The name a by-value build gives the tuple of emitted sub-functions.
const _CG_FNS = :_cgfns

# TRANSPORT for the emitted sub-functions. There are two, and they run the same
# code — they differ only in how a sub-function reaches the body that calls it.
# Emission always writes INNER DEFINITIONS; `_cg_split_transport` then picks the
# transport for the finished generated function, and rewrites it into the
# by-value form when that is the one picked.
#
#   INNER DEFINITION: the sub-function is an `@noinline function` written inside
#     the generated body and called by name. Only one generated function per
#     section, which is the cheaper build for a small body, but it only works
#     where RGF's rewrite of an inner definition into an opaque closure is typed
#     — see `_cg_split_supported` — and the whole body, every sub-function in
#     it, goes through type inference as ONE unit.
#
#   BY VALUE: each sub-function is compiled on its own, as a `_CGSubFn` (a
#     generated function of this module, not an RGF — see there for why), and
#     handed to the body at run time in a tuple, appended to the `tabs`
#     argument; a call site is `_cgfns[k](…)` at a LITERAL `k`, so the callee is
#     a concrete callable the compiler resolves statically — no closure is
#     constructed, and nothing is boxed. The tuple is the last argument of every
#     sub-function, so nesting works to any depth.
#
# Which one a build takes (`_cg_carry_by_value`):
#   - Julia < 1.12: by value, always (the inner definition boxes there).
#   - `ESS_CODEGEN_SPLIT_TRANSPORT=value` / `=definition` forces one; that is
#     the override, and what makes either path testable on any body.
#   - Otherwise by size: by value when the generated function, inner
#     definitions included, exceeds `_CG_BY_VALUE_MIN_NODES` emitted expression
#     nodes (`_cg_expr_size`). Separate generated functions are inferred and
#     optimised one at a time, so first-call compile memory and time follow the
#     largest piece rather than the whole body; under the threshold the single
#     generated function is kept, as it always was.
#
# The by-value transport is also what lets `compiler=:native` split a body on
# EVERY supported Julia. `native` is the tier that has to be universally
# available — no heavy external dependency, and no version where an oversized
# kernel has nowhere to go but the per-cell interpreter, which under the strict
# compiler is a refusal. Both transports run the SAME partitioned expression, so
# a build is value-identical either way.

# Emitted-node size of a generated function (inner definitions included) above
# which its sub-functions are carried by value. A count of expression nodes, so
# a build's transport is a function of the document alone. Chosen from first-call
# measurements: every split section of the test suite sits well under it, and
# the reseact transport section sits well over it. A `Ref`, read into each
# build's `_Tuning`, so a test can lower it to reach the size-based choice on a
# small body.
const _CG_BY_VALUE_MIN_NODES = Ref(100_000)

_cg_split_transport_override() = _tuning_now().split_transport

# The transport the Julia version or the override fixes regardless of size:
# `true` (by value), `false` (inner definitions), or `nothing` (decide by size).
function _cg_fixed_transport()
    _cg_split_supported() || return true
    o = _cg_split_transport_override()
    o == "value" && return true
    o == "definition" && return false
    return nothing
end

# Whether a generated function of `nodes` emitted nodes carries its
# sub-functions by value (see the TRANSPORT note above).
function _cg_carry_by_value(nodes::Integer)
    fixed = _cg_fixed_transport()
    return fixed === nothing ? nodes > _tuning_now().by_value_min_nodes : fixed
end

# The same choice for the generated function `ex`. Its size is counted only
# when nothing else decides, and only until it passes the threshold.
function _cg_carry_by_value(ex::Expr)
    fixed = _cg_fixed_transport()
    fixed === nothing || return fixed
    lim = _tuning_now().by_value_min_nodes
    return _cg_expr_size_upto(ex, lim) > lim
end

# `_cg_expr_size(ex)`, or any count above `lim` once the walk passes it.
function _cg_expr_size_upto(ex, lim::Int, n::Int = 0)
    n += 1
    ex isa Expr || return n
    for a in ex.args
        n > lim && return n
        n = _cg_expr_size_upto(a, lim, n)
    end
    return n
end

# `(name, params, body)` of an emitted inner definition — `@noinline function
# name(params…) … end`, every parameter a plain name — or `nothing`.
function _cg_inner_def(s)
    s isa Expr || return nothing
    if s.head === :macrocall && length(s.args) == 3 &&
            (s.args[1] === Symbol("@noinline") || s.args[1] === Symbol("@inline"))
        s = s.args[3]
    end
    (s isa Expr && s.head === :function && length(s.args) == 2) || return nothing
    sig = s.args[1]
    (sig isa Expr && sig.head === :call && !isempty(sig.args)) || return nothing
    fname = sig.args[1]
    fname isa Symbol || return nothing
    params = sig.args[2:end]
    all(a -> a isa Symbol, params) || return nothing
    return (fname, Symbol[a for a in params], s.args[2])
end

# Rewrite every call `name(args…)` of an inner definition in `idx` to the
# by-value call `_cgfns[k](args…, _cgfns)`. `left` counts the names in `idx` met
# anywhere other than a call head, which the rewrite cannot carry.
function _cg_calls_by_value(
        ex, idx::Dict{Symbol, Int}, left::Base.RefValue{Int},
        embed::Union{Nothing, Dict{Symbol, Any}} = nothing
    )
    if ex isa Symbol
        haskey(idx, ex) && (left[] += 1)
        return ex
    end
    ex isa Expr || return ex
    if ex.head === :call && !isempty(ex.args)
        f = ex.args[1]
        if f isa Symbol && haskey(idx, f)
            args = Any[_cg_calls_by_value(a, idx, left, embed) for a in @view(ex.args[2:end])]
            # A template call function is called as itself, embedded (see
            # `_cg_embed_call_fns`), with no sub-function tuple.
            embed !== nothing && haskey(embed, f) &&
                return Expr(:call, embed[f], args..., nothing)
            return Expr(:call, Expr(:ref, _CG_FNS, idx[f]), args..., _CG_FNS)
        end
    end
    return Expr(ex.head, Any[_cg_calls_by_value(a, idx, left, embed) for a in ex.args]...)
end

# The template call functions among `defs` as by-value instances, by name,
# each built after the call functions it calls (by height) and calling them as
# embedded instances. A call function's definition then reads nothing of its
# section (no position in the section's sub-function tuple), so one template
# instance has one content id, and Julia compiles it once per process however
# many sections call it.
function _cg_embed_call_fns(defs, idx::Dict{Symbol, Int}, heights::Vector{Int})
    embed = Dict{Symbol, Any}()
    order = sort!([k for k in eachindex(defs) if heights[k] > 0]; by = k -> heights[k])
    for k in order
        name, params, fb = defs[k]
        left = Ref(0)
        def = Expr(:function, Expr(:tuple, params..., _CG_FNS), _cg_calls_by_value(fb, idx, left, embed))
        embed[name] = only(_cg_subfns(Expr[def], Int[heights[k]]))
    end
    return embed
end

# Choose the transport of a finished generated function `ex`, `function (…,
# tabs, …) … end` whose body holds its sub-functions as top-level inner
# definitions and whose `tabs` argument packs `ngrp` tab groups. Returns `(ex,
# nothing)` to keep the inner definitions, or `(ex′, fns)`: `ex′` reads the
# sub-function tuple from `tabs[ngrp + 1]` and calls `_cgfns[k]`, and `fns` are
# the sub-functions' own definitions, in that tuple's order (`_cg_pack_fns`).
# `by_value` fixes the choice instead (a second generated function that shares
# the first one's `tabs`, and so must take the transport the first one took).
function _cg_split_transport(ex::Expr, ngrp::Int; by_value::Union{Nothing, Bool} = nothing)
    body = ex.args[2]::Expr
    defs = Tuple{Symbol, Vector{Symbol}, Any}[]
    rest = Any[]
    idx = Dict{Symbol, Int}()
    for s in body.args
        d = _cg_inner_def(s)
        if d === nothing
            push!(rest, s)
        else
            push!(defs, d)
            idx[d[1]] = length(defs)
        end
    end
    isempty(defs) && return (ex, nothing)
    # A template call function (`_cg_call_fn!`) is always carried by value: an
    # inner definition is a closure of the generated function, which
    # RuntimeGeneratedFunctions cannot run while the package precompiles, and
    # a call target is meant to be one static function.
    something(by_value, _cg_carry_by_value(ex) || any(d -> _cg_is_call_fn(d[1]), defs)) ||
        return (ex, nothing)
    heights = _cg_call_heights(defs)
    embed = all(iszero, heights) ? nothing : _cg_embed_call_fns(defs, idx, heights)
    left = Ref(0)
    fns = Expr[
        Expr(:function, Expr(:tuple, params..., _CG_FNS), _cg_calls_by_value(fb, idx, left, embed))
            for (_, params, fb) in defs
    ]
    stmts = Any[:(local $(_CG_FNS) = tabs[$(ngrp + 1)])]
    for s in rest
        push!(stmts, _cg_calls_by_value(s, idx, left, embed))
    end
    # The emitter only ever calls a sub-function; a bare reference would point
    # at a definition the by-value form does not have.
    left[] == 0 || error("codegen: an emitted sub-function is referenced other than by a call")
    _tally_cascade!(:cg_split_by_value)
    # The heights travel with the definitions only when a call function is
    # among them (`_cg_pack_fns`).
    return (Expr(:function, ex.args[1], Expr(:block, stmts...)), all(iszero, heights) ? fns : (fns, heights))
end

_cg_is_call_fn(name::Symbol) = startswith(String(name), "_cghtc")

# A by-value sub-function: a callable whose call is a generated function of this
# module, keyed by the CONTENT of its definition — `ID` is a digest of the
# serialized `function (params…) body end` expression (`_cg_subfn_id`), so one
# `ID` names one body, in every session, and a literal's type is part of the
# content (`x^2` and `x^2.0` are different sub-functions).
#
# Why not a `RuntimeGeneratedFunction`. Every RGF of this module is called
# through the one method RGF defines for it, so an RGF calling another RGF is,
# to inference, that method calling itself; inference treats it as recursion
# and widens the callee's signature, and the call is made through the generic
# boxed calling convention — every argument heap-allocated, on every call. A
# sub-function called through its own method is an ordinary static call.
#
# Where the generator finds the body. The instance holds its definition (`def`),
# and the generator, which sees only the type, reads it from
# `_CG_SUBFN_TABLE` — `ID` to a weak reference to that same `Expr`. Every way an
# instance comes to exist puts its definition there first: built
# (`_cg_subfns`), deserialized on another process (the `deserialize` method
# below), or deep-copied (which returns the instance itself). So while an
# instance can be called, the entry is live.
#
# Why that read is safe inside a generator, which may run during inference, on
# any thread, any number of times. It takes no lock: the table is an immutable
# snapshot that a registration replaces whole (copy, add, publish atomically),
# so a reader sees one consistent `Dict` and never waits on a writer. And it is
# pure in effect: an `ID` only ever maps to its own content, so every run of the
# generator — in this session, or one whose result was cached in a precompile
# image — produces the same body for the same `ID`. The one way a lookup can
# fail is a call made with no instance alive, which cannot be a real call.
struct _CGSubFn{ID}
    def::Expr
end

# A template call function (`_cg_call_fn!`) by value. Call functions call each
# other (a template body calls the templates it references), and instance
# functions call them; through the one generated method of `_CGSubFn` every
# such call would be that method calling itself with another type parameter,
# which inference widens (boxed arguments, dynamic dispatch). So a call
# function is a `_CGSubFnH{H, ID}`, `H` its HEIGHT (1 + the largest height of
# the call functions it calls), and each height has a generated method of its
# own: along any call chain the heights strictly fall, so no method calls
# itself. Heights past `_CG_MAX_CALL_HEIGHT` share its method (correct, slower).
struct _CGSubFnH{H, ID}
    def::Expr
end
const _CG_MAX_CALL_HEIGHT = 32

mutable struct _CGSubFnTable
    @atomic defs::Dict{UInt128, WeakRef}
end
const _CG_SUBFN_TABLE = _CGSubFnTable(Dict{UInt128, WeakRef}())
# Serializes registrations against each other; never taken by a reader.
const _CG_SUBFN_LOCK = ReentrantLock()

# The content address of a sub-function definition: the first 128 bits of the
# SHA-256 of its serialization, which records every literal's type and value
# and every name by its text, so it is the same in every session.
function _cg_subfn_id(def::Expr)
    io = IOBuffer()
    Serialization.serialize(io, def)
    d = SHA.sha256(take!(io))
    id = UInt128(0)
    for i in 1:16
        id = (id << 8) | d[i]
    end
    return id
end

# Register `defs` under `ids`; return, per entry, the `Expr` an instance must
# hold — the one already registered for that `ID` when it is still alive (so
# every instance of one `ID` keeps the same entry alive), else its own. Dead
# entries are dropped while the snapshot is copied.
function _cg_subfn_register!(ids::Vector{UInt128}, defs::Vector{Expr})
    return lock(_CG_SUBFN_LOCK) do
        old = @atomic :acquire _CG_SUBFN_TABLE.defs
        new = Dict{UInt128, WeakRef}()
        sizehint!(new, length(old) + length(ids))
        for (k, w) in old
            w.value === nothing || (new[k] = w)
        end
        live = Vector{Expr}(undef, length(ids))
        for i in eachindex(ids)
            w = get(new, ids[i], nothing)
            v = w === nothing ? nothing : w.value
            if v === nothing
                new[ids[i]] = WeakRef(defs[i])
                live[i] = defs[i]
            else
                live[i] = v::Expr
            end
        end
        @atomic :release _CG_SUBFN_TABLE.defs = new
        live
    end
end

# The sub-functions of one build, as the tuple a body indexes. `heights[i] > 0`
# makes entry `i` a call function of that height (`_CGSubFnH`).
function _cg_subfns(defs::Vector{Expr}, heights::Vector{Int} = zeros(Int, length(defs)))
    ids = UInt128[_cg_subfn_id(d) for d in defs]
    live = _cg_subfn_register!(ids, defs)
    return Tuple(
        heights[i] > 0 ?
            _CGSubFnH{min(heights[i], _CG_MAX_CALL_HEIGHT), ids[i]}(live[i]) :
            _CGSubFn{ids[i]}(live[i])
            for i in eachindex(ids)
    )
end

# The height of each inner definition in `defs` (`(name, params, body)`, as
# `_cg_inner_def` gives them) that is a call function, 0 for the others: 1 +
# the largest height of the call functions its body calls.
function _cg_call_heights(defs)
    idx = Dict{Symbol, Int}(d[1] => k for (k, d) in enumerate(defs))
    h = zeros(Int, length(defs))
    function height(k)
        h[k] != 0 && return h[k]
        h[k] = 1                       # a cycle cannot occur (the template graph is a DAG)
        best = 0
        callees = _cg_collect_syms!(Set{Symbol}(), defs[k][3])
        for c in callees
            j = get(idx, c, 0)
            (j != 0 && _cg_is_call_fn(c)) && (best = max(best, height(j)))
        end
        h[k] = best + 1
        return h[k]
    end
    for k in eachindex(defs)
        _cg_is_call_fn(defs[k][1]) && height(k)
    end
    return h
end

# The registered definition of `id`, or `nothing`. Lock-free (see `_CGSubFn`).
function _cg_subfn_def(id::UInt128)
    w = get(@atomic(:acquire, _CG_SUBFN_TABLE.defs), id, nothing)
    return w === nothing ? nothing : w.value
end

# Another process's instance arrives with its definition and registers it here.
function Serialization.deserialize(
        s::Serialization.AbstractSerializer, ::Type{_CGSubFn{ID}}
    ) where {ID}
    def = Serialization.deserialize(s)::Expr
    return _CGSubFn{ID}(only(_cg_subfn_register!(UInt128[ID], Expr[def])))
end
function Serialization.deserialize(
        s::Serialization.AbstractSerializer, ::Type{_CGSubFnH{H, ID}}
    ) where {H, ID}
    def = Serialization.deserialize(s)::Expr
    return _CGSubFnH{H, ID}(only(_cg_subfn_register!(UInt128[ID], Expr[def])))
end

# A deep copy is the instance itself, as for an RGF or any other function; the
# copy keeps the original's entry alive.
Base.deepcopy_internal(f::_CGSubFn, ::IdDict) = f
Base.deepcopy_internal(f::_CGSubFnH, ::IdDict) = f

# The method's own argument and parameter names are not ones the emitter mints
# (they hold a `#`), so no sub-function parameter or local can rebind them.
# The method body of by-value sub-function `id` called with `n` arguments.
function _cg_subfn_body(id, n::Int)
    var"##id" = id
    var"##n" = n
    def = _cg_subfn_def(var"##id")
    def === nothing && error("codegen: by-value sub-function $(var"##id") has no definition")
    params = (def::Expr).args[1].args
    length(params) == var"##n" ||
        error("codegen: by-value sub-function $(var"##id") takes $(length(params)) arguments, called with $(var"##n")")
    args = Symbol("##args")
    body = def.args[2]
    # A `meta` heading the definition's body (a template call function's
    # `inline` or `no_constprop`, `_cg_call_fn!`) must head the method's body to
    # take effect, so it moves up with `noinline`.
    metas = Any[]
    if body isa Expr && body.head === :block && !isempty(body.args) &&
            body.args[1] isa Expr && (body.args[1]::Expr).head === :meta
        push!(metas, body.args[1])
        body = Expr(:block, body.args[2:end]...)
    end
    # An inlinable call function carries `inline`; every other sub-function
    # is compiled on its own.
    any(m -> m.args == Any[:inline], metas) || pushfirst!(metas, Expr(:meta, :noinline))
    return Expr(
        :block,
        # Compiled on its own, as the inner definition it replaces would be.
        metas...,
        Any[:($(params[i]) = @inbounds $args[$i]) for i in 1:var"##n"]...,
        body,
    )
end

# Defined after `_cg_subfn_body`: a generator may call only what exists when
# it is defined.
@generated function (::_CGSubFn{var"##id"})(
        var"##args"::Vararg{Any, var"##n"}
    ) where {var"##id", var"##n"}
    return _cg_subfn_body(var"##id", var"##n")
end
for H in 1:_CG_MAX_CALL_HEIGHT
    @eval @generated function (::_CGSubFnH{$H, var"##id"})(
            var"##args"::Vararg{Any, var"##n"}
        ) where {var"##id", var"##n"}
        return _cg_subfn_body(var"##id", var"##n")
    end
end


# The runtime `tabs` tuple, plus — in the by-value transport — the sub-function
# tuple as one more element: a heterogeneous tuple of concrete callables, so a
# call site reading it at a LITERAL index resolves its callee statically.
_cg_pack_fns(tabpack::Tuple, ::Nothing) = tabpack
_cg_pack_fns(tabpack::Tuple, fns::Vector{Expr}) = (tabpack..., _cg_subfns(fns))
_cg_pack_fns(tabpack::Tuple, fh::Tuple{Vector{Expr}, Vector{Int}}) =
    (tabpack..., _cg_subfns(fh[1], fh[2]))

"""
    _cg_finish(ctx, args, stmts...; pre = (), by_value = nothing) -> (f, fns)

The one epilogue of every generated function: hoist each tab group to its
`_cggrpG` local, bind the value type `_cgT`, splice `pre`, the split helpers
(`ctx.helpers`) and `stmts`, return `nothing`; then give the split helpers the
transport this Julia supports (`_cg_split_transport`, `by_value` forcing one)
and build the `RuntimeGeneratedFunction` over the signature `args`. `fns` goes
to `_cg_tabpack`.
"""
function _cg_finish(ctx::_CGFunction, args::Tuple, stmts...; pre = (), by_value = nothing)
    ngrp = length(ctx.tabs.types)
    body = Expr(
        :block,
        Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]...,
        :(local _cgT = _rhs_value_type(u, p, t)),
        pre...,
        ctx.helpers...,
        stmts...,
        :(return nothing)
    )
    ex, fns = _cg_split_transport(Expr(:function, Expr(:tuple, args...), body), ngrp; by_value = by_value)
    return RuntimeGeneratedFunctions.RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex), fns
end

# The runtime `tabs` argument of a generated function: one HOMOGENEOUS container
# per group, converted to the group's concrete element type (`Vector{Vector{Int}}`,
# …), packed in a small tuple, plus the split helpers in the by-value transport.
function _cg_tabpack(ctx::_CGFunction, fns)
    tabs = ctx.tabs
    return _cg_pack_fns(ntuple(g -> Vector{tabs.types[g]}(tabs.objs[g]), length(tabs.types)), fns)
end

# The signature of a section's generated function.
const _CG_SECTION_ARGS = (:du, :u, :p, :t, :tabs, :_cgci, :_cgnc)

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
    return a isa Expr && a.head === :(=) ? a.args[1] : nothing
end

# ---- Intra-kernel body split -------------------------------------------------
# `_cg_emit` lowers one output cell to a SINGLE Julia expression, which for a
# spine-dominated kernel can be large enough that compiling it as one function
# exhausts memory (compile is superlinear in single-function size). The
# kernel-CLASS merge already made the cell body grid-INDEPENDENT (one body over
# a lane axis), so what remains is to cap the SINGLE-FUNCTION size: partition the emitted
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
_cg_expr_size(ex) = ex isa Expr ? 1 + sum(_cg_expr_size, ex.args; init = 0)::Int : 1

# True for a call to a split helper (`_cgh…(…)`) minted by `_cg_spill!` — an
# irreducible leaf of the partition (re-spilling it cannot shrink it).
function _cg_is_spill_call(ex)
    (ex isa Expr && ex.head === :call && !isempty(ex.args)) || return false
    f = ex.args[1]
    return f isa Symbol && startswith(String(f::Symbol), "_cgh")
end

# A head that introduces its own scope / bindings (an `_NK_AREDUCE` body is
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
# already the by-type container indices `_cggrpG[pos]`, so the
# helper's tab dependency is ONE argument per GROUP (a few concrete-typed
# containers) no matter how many distinct tabs it touches — this is what keeps
# the split's parameter/inference cost from exploding with the tab count.
function _cg_spill!(ctx::_CGFunction, sub)
    syms = Set{Symbol}()
    _cg_collect_syms!(syms, sub)                     # `_cggrpG` containers + coords + child calls
    bound = _cg_collect_bound!(Set{Symbol}(), sub)   # names the helper binds itself
    extra = sort!([s for s in syms if _cg_is_passable(s) && !(s in bound)]; by = string)
    params = Symbol[:u, :p, :t]
    append!(params, extra)
    # Helper dedup: an identical body (same code ⇒ same params, since params are
    # exactly the passable names it references) reuses the first helper minted for
    # it. Only the CALL is re-emitted; the compiled function is shared. Value-exact
    # and laziness-preserving — a call in place of the sub-expression evaluates
    # exactly when the sub-expression would.
    key = string(sub)
    let got = get(ctx.tx.helper_dedup, key, nothing)
        if got !== nothing
            _tally_cascade!(:cg_helper_deduped)
            return Expr(:call, got, params...)
        end
    end
    ln = LineNumberNode(0, Symbol("ess-iip-split"))
    stmts = Any[]
    (:_cgT in syms) && push!(stmts, :(local _cgT = _rhs_value_type(u, p, t)))
    push!(stmts, Expr(:macrocall, Symbol("@inbounds"), ln, :(return $sub)))
    fname = _cg_name(ctx, "h")
    fdef = Expr(:function, Expr(:call, fname, params...), Expr(:block, stmts...))
    push!(ctx.helpers, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
    ctx.tx.helper_dedup[key] = fname
    return Expr(:call, fname, params...)
end

# Partition `ex` so every generated function (this expression and every helper
# it spills) is ≤ `cap` nodes. Bottom-up: partition children first (each becomes
# ≤ cap), then, while this node's inlined size exceeds `cap`, spill its largest
# still-inline `Expr` child into a helper CALL (small). A node whose children are
# all spilled is `op(call, call, …)` — small — so the loop always terminates.
# Returns `(bounded_expr, size)`.
function _cg_partition!(ctx::_CGFunction, ex, cap::Int)
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
            # The CALLEE position of a call is not a value to hoist.
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
function _cg_bound_body!(ctx::_CGFunction, ex)
    cap = _codegen_fn_node_cap()
    cap <= 0 && return ex
    _cg_expr_size(ex) <= cap && return ex
    # Oversized: partition it. Which TRANSPORT carries the pieces depends on the
    # Julia and the body's size (`_cg_carry_by_value`), but every supported Julia has one, so an
    # oversized body is compiled rather than declined to the per-cell
    # interpreter — which under a strict compiler is a refusal, and would make
    # `native` unavailable on Julia < 1.12 for exactly the largest kernels.
    return _cg_partition!(ctx, ex, cap)[1]
end

_cg_mark(ctx::_CGFunction) = _CGMark(
    length(ctx.prologue.stmts), length(ctx.prologue.invlog), length(ctx.helpers), ctx.nodes, ctx.fscratch
)

# Take the function's emission state back to `m`: a declined kernel's partial
# prologue statements, its invariant registrations (a later kernel looking
# them up would otherwise reference rolled-back locals), its split
# helpers and its node count.
function _cg_rollback!(ctx::_CGFunction, m::_CGMark)
    pro = ctx.prologue
    resize!(pro.stmts, m.nprologue)
    _cg_prolog_rollback!(ctx, m.nprologue)
    for i in length(pro.invlog):-1:(m.ninvlog + 1)
        delete!(pro.invdone, pro.invlog[i])
    end
    resize!(pro.invlog, m.ninvlog)
    resize!(ctx.helpers, m.nhelpers)
    ctx.nodes = m.nodes
    ctx.fscratch = m.fscratch
    return nothing
end

# One kernel's emission as a transaction (`_CGKernelTx`): `emit()`'s loop nest
# with its emitted-node cost and whether it read the shared prelude, or — when
# it declines — the `_Decline`, with every piece of state it added taken back.
function _cg_transaction(emit, ctx::_CGFunction)
    tx = _CGKernelTx(_cg_mark(ctx), Dict{String, Symbol}())
    ctx.tx = tx
    m = tx.mark
    try
        lx = emit()
        return (lx, ctx.nodes - m.nodes, ctx.fscratch > m.fscratch)
    catch err
        err isa _Decline || rethrow()
        _cg_rollback!(ctx, m)
        return err::_Decline
    end
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
function _build_codegen_rhs(
        acc_kernels::AbstractVector{_AccKernel};
        budget::Int = _codegen_node_budget(),
        shared_cache::Union{Nothing, _CSECache} = nothing,
        nst::Int = 0
    )
    isempty(acc_kernels) && return nothing
    ctx = _CGFunction(budget, shared_cache; nst = nst)
    covered = fill(false, length(acc_kernels))
    reasons = fill(:none, length(acc_kernels))
    kloops = Tuple{Any, Int}[]         # (loop-nest expr, its emitted-node cost)
    # Row-fused groups (see `_cg_emit_rowgroup!`): a group is emitted at its
    # first member's position; if it declines, its members are emitted one by
    # one, exactly as without fusion.
    groups = _cg_rowfuse_groups(acc_kernels)
    ingroup = falses(length(acc_kernels))
    for (j, K) in enumerate(acc_kernels)
        if haskey(groups, j)
            js = groups[j]
            r = _cg_transaction(ctx) do
                _cg_emit_rowgroup!(ctx, _AccKernel[acc_kernels[m] for m in js])
            end
            if !(r isa _Decline)
                lx, cost, fscratch = r
                push!(kloops, (lx, cost))
                for m in js
                    covered[m] = true
                    ingroup[m] = true
                    _tally_cascade!(:codegen_kernel)
                end
                _tally_cascade!(:cg_rowfused_group)
                fscratch && _tally_cascade!(:cg_foreign_scratch_emit)
            end
        end
        ingroup[j] && continue
        r = _cg_transaction(() -> _cg_emit_kernel!(ctx, K), ctx)
        if r isa _Decline
            reasons[j] = r.reason
            _tally_cascade!(Symbol("codegen_decline_", r.reason))
        else
            lx, cost, fscratch = r
            push!(kloops, (lx, cost))
            covered[j] = true
            _tally_cascade!(:codegen_kernel)
            # Shared-prelude read observability: this kernel compiled carrying
            # at least one such read.
            fscratch && _tally_cascade!(:cg_foreign_scratch_emit)
        end
    end
    any(covered) || return nothing
    ln = LineNumberNode(0, Symbol("ess-codegen"))

    # Outer locals a chunk may need as arguments: the table locals and every
    # invariant-slot local defined in the prologue. `_cgT` is deliberately NOT
    # passed — it is the value TYPE (a runtime `DataType`), and passing it across
    # the call boundary loses the constant-propagation that keeps `convert(_cgT,
    # …)` type-stable, boxing every scalar. Each chunk recomputes `_cgT` locally
    # from (u, p, t) instead, so inference constant-propagates it.
    ngrp = length(ctx.tabs.types)
    outer_passed = Set{Symbol}()
    # The by-type tab containers (`_cggrpG`, one per distinct tab type — a handful,
    # not one per object) are the only tab locals now; every chunk / helper that
    # reads a tab references a container, so it receives that container.
    for g in 1:ngrp
        push!(outer_passed, _cg_grp_sym(g))
    end
    for stmt in ctx.prologue.stmts
        s = _cg_local_lhs(stmt)
        s === nothing || push!(outer_passed, s)
    end
    # The chunk index pair rides through like any other outer name: every
    # kernel loop nest references it (its `_chunk_ordinals` header), so the
    # sym-collection below forwards it into each `@noinline` sub-function.
    push!(outer_passed, :_cgci)
    push!(outer_passed, :_cgnc)

    # Partition the loop nests into chunks capped by emitted-node count. A
    # non-positive cap means "one chunk".
    cap = _codegen_fn_node_cap()
    chunks = Vector{Vector{Any}}()
    cur = Any[]; curcost = 0
    for (lx, cost0) in kloops
        cost = _cg_chunk_cost(ctx, lx, cost0)
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
    # A genuine split (several chunks) emits one sub-function per chunk, as an
    # inner `@noinline` definition called by name; `_cg_split_transport` below
    # decides whether it stays one or becomes its own generated function.
    fndefs = Any[]; callstmts = Any[]
    if length(chunks) == 1
        push!(
            callstmts,
            Expr(:macrocall, Symbol("@inbounds"), ln, Expr(:block, chunks[1]...))
        )
    else
        for (ci, chunk) in enumerate(chunks)
            used = Set{Symbol}()
            for lx in chunk
                _cg_collect_syms!(used, lx)
            end
            passed = sort!(collect(intersect(used, outer_passed)); by = string)
            fbody = Expr(
                :block,
                :(local _cgT = _rhs_value_type(u, p, t)),
                Expr(:macrocall, Symbol("@inbounds"), ln, Expr(:block, chunk...)),
                :(return nothing)
            )
            fname = Symbol("_cgchunk_", ci)
            fdef = Expr(
                :function, Expr(:call, fname, :du, :u, :p, :t, passed...),
                fbody
            )
            push!(fndefs, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
            push!(callstmts, Expr(:call, fname, :du, :u, :p, :t, passed...))
        end
    end

    # No `Base.Experimental.@aliasscope` here: on Julia 1.11 to 1.13 it tags
    # every load in the scope, not only `Const` ones, so it would let LLVM
    # move any load ahead of a store to the same element (JuliaLang/julia#63129),
    # and this section does store and read back (`du` accumulators, row
    # fission). No cell reads a slot any cell of the section writes, which is
    # what lets the threaded path run its chunks concurrently and what an
    # observed level's `(ue, ue)` call relies on.
    # On a two-buffer slot space `du` is rebound to the one buffer every cell
    # of the section writes (`_cg_dview`), when there is one.
    kernels = Expr(
        :let, _cg_section_bindings(nst, acc_kernels),
        Expr(
            :block,
            Expr(
                :macrocall, Symbol("@inbounds"), ln,
                Expr(:block, ctx.prologue.stmts...)
            ),
            callstmts...
        )
    )
    # The intra-kernel split helpers come FIRST so the
    # invariant prologue and every chunk sub-function can call them by name;
    # each is `@noinline`, params-only (captures nothing). By value, every
    # sub-function becomes its own generated function, arriving in a tuple
    # appended to `tabs` (`_cg_split_transport`).
    f, fns = _cg_finish(ctx, _CG_SECTION_ARGS, fndefs..., kernels)
    # Threaded cell axis: total covered cells + the global out-slot
    # disjointness verdict, both facts of the BUILD (the runtime chunk verdict
    # is `_sec_prep_threads!`'s).
    ncells, disjoint, work, rmw = _cg_covered_outs_disjoint(acc_kernels, covered)
    tabpack = _cg_tabpack(ctx, fns)
    return _CGBuilt(f, tabpack, covered, reasons, ncells, disjoint, work, rmw)
end

# A loop nest's weight toward the chunk cap: its emitter cost (spine nodes
# emitted), or its emitted expression size (inlined call functions counted
# whole, `_cg_inl_size`) over `_CG_EXPR_PER_NODE`, whichever is larger. The
# emitter charges one node per state read, but a read through a slot table is
# some seventy expression nodes (its loop-version ladder); a nest made mostly
# of such reads (a stencil whose neighbour reads are made by the caller of a
# template call) was charged a sixth of its size, so one chunk took five times
# the code of the others and LLVM's time and memory, superlinear in a
# function's size, went to that one function. Measured on reseact_s: ordinary
# nests are 4.9 expression nodes per emitted node, table-read nests 16 to 18.
const _CG_EXPR_PER_NODE = 5
_cg_chunk_cost(ctx::_CGFunction, lx, cost::Int) = max(cost, cld(_cg_inl_size(ctx, lx), _CG_EXPR_PER_NODE))

# ---- Threaded cell axis for the codegen tier ---------------------------------
# The verdict, the partition and the dispatch are threading.jl's (the safety
# argument lives there). A generated function runs chunk `c` of every emitted
# kernel back to back, `f(du, u, p, t, tabs, c, nchunks)`.
_sec_tcache(cg::_CGBuilt) = _SecTCache(cg.ncells, cg.outs_disjoint, cg.work, cg.rmw)

# A generated function's chunk: the static partition (`_chunk_ordinals`) is
# computed inside it, and each chunk re-runs the (pure) tab-hoist + invariant
# prologue on its own stack and walks its `[a, b)` slice of every kernel.
struct _CGChunk{F, TB}
    f::F
    tabs::TB
end
@inline (b::_CGChunk)(args, c::Int, nchunks::Int) =
    b.f(args[1], args[2], args[3], args[4], b.tabs, c, nchunks)

# Run one generated function through the section runner (threading.jl):
# chunked when the verdict allows, else serially in `ntiles` cell tiles.
@inline _run_cg_maybe_threaded!(f, tabs, du, u, p, t, tc::_SecTCache, ntiles::Int = 1) =
    _run_section!(tc, _CGChunk(f, tabs), (du, u, p, t), typemax(Int), ntiles)

# ---- The RHS's kernel section (wired into `_make_rhs`, rhs_assembly.jl) --------
# One concretely-typed callable holding the generated function (or `Nothing`)
# plus the residual kernels the emitter declined. The `F === Nothing` branch
# folds away per closure specialization. Emitted kernels write disjoint du
# slots from residual ones (each state slot has exactly one equation/cell), so
# running the generated section first is value-identical to the in-order
# kernel loop.
#
# The per-cell runner is the interpreter's: a section that runs any kernel on
# it holds a `_PerCellLicense` in `walk` (W), and one that runs none holds
# `nothing`. The constructor checks the two agree, so a strict plan, which has
# no license, cannot build a section that walks; with `W === Nothing` the
# runner's loops are not in the compiled call at all.
struct _KernelSection{F, TB, W}
    cgf::F
    cgtabs::TB
    n_emitted::Int                # kernels compiled into the generated function
    kernels::Vector{_AccKernel}   # residual kernels (interpreter runner)
    # Threaded cell axis: the lazily-decided chunk verdict of the generated
    # function, see `_SecTCache` above.
    tcache::_SecTCache
    # Serial cell tiling: the number of static chunks a serial call runs back
    # to back (1 = one pass per kernel). See `_section_tiles`.
    ntiles::Int
    walk::W
    function _KernelSection(
            cgf::F, cgtabs::TB, n_emitted::Int, kernels::Vector{_AccKernel},
            tcache::_SecTCache, ntiles::Int, walk::W
        ) where {F, TB, W <: Union{Nothing, _PerCellLicense}}
        isempty(kernels) == (W === Nothing) ||
            throw(
            ArgumentError(
                "a kernel section holds a per-cell license exactly " *
                    "when it runs a kernel on the per-cell runner"
            )
        )
        return new{F, TB, W}(cgf, cgtabs, n_emitted, kernels, tcache, ntiles, walk)
    end
end

# The per-cell runner over `kernels`, in order.
@inline function _walk_kernels!(::_PerCellLicense, du, u, p, t, kernels, ::Type{T}) where {T}
    @inbounds for j in eachindex(kernels)
        _run_acc_kernel!(du, u, p, t, kernels[j], T)
    end
    return nothing
end

# SERIAL TILING. The generated function runs chunk `c` of every emitted kernel
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

@inline function (s::_KernelSection{F, TB, W})(
        du, u, p, t,
        ::Type{T}
    ) where {F, TB, W, T}
    # The generated function, chunked when the section verdict allows
    # (threaded cell axis above), at every value type. Any serial verdict
    # (small, shared outs, one thread) runs it tiled serially.
    F !== Nothing && _run_cg_maybe_threaded!(s.cgf, s.cgtabs, du, u, p, t, s.tcache, s.ntiles)
    W === Nothing || _walk_kernels!(s.walk, du, u, p, t, s.kernels, T)
    return nothing
end

# Partition the kernels between the codegen tier and the per-cell runner. With
# the codegen tier off (or an empty emission) the section is the plain kernel
# loop.
# `shared_cache`: the build's scalar prelude `_CSECache`, passed ONLY by the
# `_make_rhs` call site (rhs_assembly.jl) — the one place where the section
# provably runs after that cache's prelude tiers were filled in the same `f!`
# call. Every other caller keeps the default `nothing`, which keeps the
# `:foreign_scratch` decline for shared-prelude reads.
# A kernel the emission declined runs on `_run_acc_kernel!` — the `_eval_acc`
# tree walk, once per output cell, on every right-hand-side call. That is the
# interpreter's runner, so the section needs a license for it; a strict
# compiler refuses at BUILD instead, naming the rule the cascade has open and
# the reason the emission gave.
function _kernel_walk_license(
        kernels::AbstractVector{_AccKernel},
        reasons::AbstractVector{Symbol}
    )
    return _percell_license(
        _current_rule_label("the assembled right-hand side"), _ -> begin
            why = :emission_produced_nothing
            for r in reasons
                r === :none && continue
                why = r
                break
            end
            "$(length(kernels)) access kernel" *
                (length(kernels) == 1 ? "" : "s") * " reached the end of the codegen " *
                "emission undeclared (deepest reason: $why), so they would run on the " *
                "per-cell tree-walk kernel runner on every right-hand-side call. Build " *
                "with compiler=:interpreter to run it, or grow the emitter to cover " *
                "this construct"
        end
    )
end

function _make_kernel_section(
        acc_kernels::AbstractVector{_AccKernel};
        shared_cache::Union{Nothing, _CSECache} = nothing,
        nst::Int = 0
    )
    cg = _codegen_disabled() ? nothing :
        _build_codegen_rhs(acc_kernels; shared_cache = shared_cache, nst = nst)
    if cg === nothing
        kernels = collect(_AccKernel, acc_kernels)
        n_emitted = 0
        reasons = Symbol[]
    else
        resid = [j for j in eachindex(cg.covered) if !cg.covered[j]]
        kernels = _AccKernel[acc_kernels[j] for j in resid]
        n_emitted = count(cg.covered)
        reasons = Symbol[cg.reasons[j] for j in resid]
    end
    walk = isempty(kernels) ? nothing : _kernel_walk_license(kernels, reasons)
    return _KernelSection(
        cg === nothing ? nothing : cg.f, cg === nothing ? nothing : cg.tabs,
        n_emitted, kernels, _sec_tcache(cg), _cg_section_tiles(cg, n_emitted), walk
    )
end

_cg_section_tiles(::Nothing, ::Int) = 1
_cg_section_tiles(cg::_CGBuilt, n_emitted::Int) =
    _section_tiles(cg.ncells, n_emitted, cg.outs_disjoint)
