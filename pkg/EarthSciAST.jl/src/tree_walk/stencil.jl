# ========================================================================
# tree_walk/stencil.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4c: the symbolic STENCILIZER — one sentinel spine
# template per structural group, with per-lane recipe evaluation. This is the
# front half of the affine box processor (stencil_affine.jl): `_stencilize`
# turns a rule body into a compiled `_Node` spine whose loop-var-dependent
# leaves are LANE sentinels, and `_eval_recipe` resolves each lane at any cell.
# The box processor derives per-box access descriptors from those recipes.
# (The `_VecKernel` lowering that once consumed these templates was deleted
# when the access-kernel IR became the only array runtime.)
# ============================================================
#
# Identity by construction, not by luck:
#   • the spine template is produced by the SAME `_resolve_indices` + `_compile`
#     run on a tree that differs from the per-cell tree ONLY in that gather leaves
#     are sentinel `VarExpr`s (mapped to a negative `_NK_STATE.idx` marker) instead
#     of resolved slots — leaf identity never changes an op's shape, so the
#     compiled ops are the same;
#   • per-lane leaf evaluation (`_eval_recipe`) reuses the EXACT resolve helpers
#     (`_eval_const_int`, `_cell_key`, `_resolve_const_index`, the ghost bounds
#     test), so a lane's slot / ghost / const value is bit-for-bit what
#     `_resolve_indices` returns.
#
# Applicability is intentionally narrow. `_stencilize` keeps ONLY the whitelisted
# elementwise ops + `index(state/const/pgather, …)` gathers + `fn` leaves + bare
# loop-index literals; ANY loop-var-dependent construct outside that set
# (`arrayop`/`aggregate`/`makearray`/`integral`/`index`-of-those/`table_lookup`/…)
# throws `_StencilFallback` and the caller runs the unchanged per-cell path. So the
# fast path is provably identical WHERE it applies and simply absent elsewhere.
#
# `ESS_STENCIL_DISABLE=1` forces the per-cell SCALAR reference (compiled cell
# nodes on `rhs_list`, evaluated by `_eval_node`) — the differential oracle.

struct _StencilFallback <: Exception
    reason::String
end

@enum _LaneKind LANE_STATE LANE_CONST LANE_PGATHER LANE_LOOPLIT

# One loop-var-dependent leaf, evaluated per output cell to a slot / value.
struct _LaneRecipe
    kind::_LaneKind
    var_name::String        # array / const / pgather variable name
    idx_args::Vector{ASTExpr}  # index-argument expressions (per-cell `_eval_const_int`)
    lo::Vector{Int}         # array_var_info bounds (LANE_STATE ghost test)
    hi::Vector{Int}
    arr::Any                # const-array values (LANE_CONST) / _PGatherArray (LANE_PGATHER)
    loop_name::String       # loop index name (LANE_LOOPLIT)
    # LANE_STATE only: the state var's affine slot map `(base, strides)` derived +
    # corner-verified against var_map at build time, so `_eval_recipe` resolves the
    # slot as `base + Σ inds_d·strides_d` — no per-cell index Vector, no formatted
    # `_cell_key` String. `nothing` for a non-affine (or non-state) layout, which
    # keeps the exact string lookup.
    affine::Union{Nothing,Tuple{Int,Vector{Int}}}
end
_LaneRecipe(kind, var_name, idx_args, lo, hi, arr, loop_name) =
    _LaneRecipe(kind, var_name, idx_args, lo, hi, arr, loop_name, nothing)

# Whitelisted pure-elementwise ops: every op `_eval_node_op` evaluates by
# recursing its `args` with no `expr_body`/`ranges`/`values` sub-structure. An op
# outside this set (and not `index`/`fn`) that depends on a loop var forces the
# per-cell fallback. Membership is declared per-op in src/op_registry.jl (flag
# `:stencil_elementwise`, mirroring `_eval_node_op`) and pinned by
# op_registry_test.jl; drift only costs a missed fast path — never correctness,
# since an unknown op simply falls back.
const _STENCIL_ELEMENTWISE_OPS = _ops_with(:stencil_elementwise)

# A NUL byte can never appear in a real variable / cell name, so a lane sentinel
# name never collides with a state cell, param, or observed variable.
const _LANE_PREFIX = "\0lane\0"
_lane_name(k::Int) = string(_LANE_PREFIX, k)

_stencil_disabled() = get(ENV, "ESS_STENCIL_DISABLE", "") == "1"

# ─────────────────────────────────────────────────────────────────────────────
# COMPILE-ONCE TEMPLATE TIER (esm-spec §9.6.4 Option B; RFC
# out-of-line-expression-templates §5/§7.7 — "7+7+7 replaces 7×7×7").
#
# The build expands surviving `apply_expression_template` references at the impl
# entry (`_expand_model_refs!` with site recording), so every phase and every
# fallback path sees exactly the fused expanded tree it always saw. The ONLY
# consumer of the recorded sites is this tier: when `_stencilize` reaches a node
# that IS an expansion root, it compiles that subtree ONCE per (root structure,
# loop-index set, region class) — per BUILD via the `_XEqStore` hoist (A3), so
# equations sharing a root reuse one `_SubVariant` — and splices a SUB-KERNEL
# CALL sentinel into the
# parent spine instead of re-walking the body per branch. The variant's lane
# recipes are appended to the parent's recipe vector at a per-branch base
# ("lane re-basing"), so ghost keys, per-cell recipe evaluation, and the affine
# box processor's per-box lane derivation + corner verification all see body
# lanes as ordinary lanes — grouping and box cuts are exactly the fused ones.
#
# Sub-kernel call sentinels ride the same negative-`_NK_STATE` channel as lane
# sentinels, offset by `_SUBCALL_SENT_BASE` so the two ranges can never collide
# (a spine would need a billion lanes first). The variant's spine uses LOCAL
# lane numbering 1..K; the `(variant, base)` site entry re-bases it per branch.
const _SUBCALL_PREFIX = "\0sub\0"
_subcall_name(j::Int) = string(_SUBCALL_PREFIX, j)
const _SUBCALL_SENT_BASE = 1_000_000_000

# One compiled template-body variant: the sentinel spine compiled from the
# expansion root under one region class, its LOCAL lane recipes (indices 1..K
# within `recipes`), its own nested sub-call sites (bases local to `recipes`),
# and the per-(body lane-repl) cache of access-lowered forms (`_AccKernel`s,
# built lazily by `_lower_to_access` and shared across boxes and kernels).
struct _SubVariant
    tmpl::_Node
    recipes::Vector{_LaneRecipe}
    subcalls::Vector{Tuple{_SubVariant,Int}}
    acc_cache::Dict{String,Any}
end
const _SubCallSite = Tuple{_SubVariant,Int}   # (variant, lane base in enclosing recipes)

# ─────────────────────────────────────────────────────────────────────────────
# CROSS-EQUATION VARIANT MEMOIZATION (perf plan A3). A `_SubVariant` is a pure
# function of (root STRUCTURE, loop-index-name set, region-class branch key)
# plus BUILD-level context: `var_map` / `param_sym_set` / `reg_funcs` /
# `array_var_info` / `const_arrays` / `pgather` are the same objects for every
# equation of one `build_evaluator` call (threaded unchanged from
# `_build_compile_evaluator` through `_compile_derivative_equations`), and
# `_branch_key!` carries ALL `idx_env` dependence (that is what already lets
# one root share a variant across branches within an equation). After A1
# interning, `objectid(root)` IS a structural key — so the variant cache (and
# the bound-body cache, the same purity argument via `_sub_preserving`) can be
# hoisted to ONE per-build store, and the same PPM body stops recompiling for
# every equation that instantiates it (D(m,t)/D(mq,t)/D(dev,t); one rule × N
# species in the chem assembly). The only remaining per-EQUATION input a
# variant bakes in is the loop-index-name set (it decides LANE_LOOPLIT leaves
# and every `_refs_idxset` invariance cut), so it enters the key (`idxkey`).
#
# `obs_memo` is the shared `_sub_preserving` memo for the per-equation observed
# inlining (`_try_affine_stencil`): the bindings (`resolved_obs`) are one fixed
# Dict per build, so sharing the memo is sound by `_sub_preserving`'s own
# contract — and it is what KEEPS cross-equation root identity: without it,
# each equation's obs-inline manufactures a fresh copy of every root that
# contains an observed reference, and the structural key never hits.
# `obs_bindings` guards that contract: a different bindings object (defensive —
# no current caller does this) gets a fresh memo instead of a wrong reuse.
#
# Sharing a variant across equations reuses the SAME mechanism as sharing
# across branches: `variant.recipes` are appended at each use's own per-branch
# base (lane re-basing, `_stencilize_shared`), and the per-(lane-repl) access
# forms in `variant.acc_cache` are keyed by descriptor CONTENT
# (`_lane_repl_key`), so a cache hit from another equation is byte-identical
# to the variant that equation would have compiled itself.
#
# KILL SWITCH: `ESS_XEQ_VARIANT_DISABLE=1` restores the per-equation caches
# (no store is created; every `_TemplateCtx` gets fresh dicts and every
# obs-inline a fresh memo — the pre-A3 build exactly).
_xeq_disabled() = get(ENV, "ESS_XEQ_VARIANT_DISABLE", "") == "1"

struct _XEqStore
    variants::Dict{Tuple{UInt64,String,String},_SubVariant}
    bound_bodies::IdDict{OpExpr,Vector{Tuple{Vector{ASTExpr},ASTExpr}}}
    obs_memo::IdDict{OpExpr,ASTExpr}          # a shared `_SubMemo`
    obs_bindings::Base.RefValue{Any}          # the bindings object it was built against
end
_XEqStore() = _XEqStore(Dict{Tuple{UInt64,String,String},_SubVariant}(),
                        IdDict{OpExpr,Vector{Tuple{Vector{ASTExpr},ASTExpr}}}(),
                        IdDict{OpExpr,ASTExpr}(), Base.RefValue{Any}(nothing))

# The shared obs-inline memo, valid only for ONE bindings object per build
# (pinned on first use). A different bindings object returns a fresh memo —
# correctness over sharing.
function _xeq_obs_memo(store::_XEqStore, bindings)
    ob = store.obs_bindings[]
    if ob === nothing
        store.obs_bindings[] = bindings
        return store.obs_memo
    end
    ob === bindings && return store.obs_memo
    return IdDict{OpExpr,ASTExpr}()
end

# Canonical key for an equation's loop-index-name set (order-insensitive: the
# stencilize walk consults MEMBERSHIP only; recipes/idx_args reference names).
_idxset_key(idx_names::Vector{String}) = join(sort(idx_names), '\0')

# Per-equation compile-once context. `sites` maps each expansion root (an
# `OpExpr` in the obs-inlined RHS, by identity) to its originating apply node
# (documentary — the template name for diagnostics). `variants` memoizes
# compiled bodies by `(root identity, loop-index-set key, body branch key)` —
# PER BUILD when an `_XEqStore` is threaded in (the A3 hoist; `variants` /
# `bound_bodies` then alias the store's dicts), per equation otherwise
# (`ESS_XEQ_VARIANT_DISABLE=1`, or a caller without a store). `gmemo` is the
# shared `_refs_idxset` guard memo (per-equation: its answers depend on this
# equation's idxset); `bio` a scratch buffer for body branch keys. The compile
# inputs (`var_map`, `param_sym_set`, `reg_funcs`) ride along because variant
# compilation happens mid-`_stencilize`, where they are out of scope; they are
# build-level constants (see the A3 note above), which is what makes the
# hoisted cache sound.
struct _TemplateCtx
    sites::IdDict{OpExpr,OpExpr}
    variants::Dict{Tuple{UInt64,String,String},_SubVariant}
    gmemo::IdDict{OpExpr,Bool}
    bio::IOBuffer
    var_map::Dict{String,Int}
    param_sym_set::Any
    reg_funcs::Any
    # Index-bound bodies for expansion roots that are ARRAY PRODUCERS (an
    # aggregate reached through `index(makearray → root, k…)` — the ESD stencil
    # shape): the producer's `expr_body` with its output indices substituted by
    # the k-args, built ONCE per (root, k-arg identity tuple) and shared across
    # branches — and, via the store, across equations (the bound body is a pure
    # function of producer + k-arg structure, and sharing it is what lets the
    # bound-site variant key hit across equations: the shared bound body IS the
    # vkey root). Each entry holds the k-arg objects it was bound against
    # (branch-invariant in practice, so the inner vector stays length 1) plus
    # the shared bound body.
    bound_bodies::IdDict{OpExpr,Vector{Tuple{Vector{ASTExpr},ASTExpr}}}
    # This equation's loop-index-set key — the per-equation component of vkey.
    idxkey::String
end
function _TemplateCtx(sites::IdDict{OpExpr,OpExpr}, var_map::Dict{String,Int},
                      param_sym_set, reg_funcs;
                      idxkey::String="", store::Union{Nothing,_XEqStore}=nothing)
    variants = store === nothing ? Dict{Tuple{UInt64,String,String},_SubVariant}() :
               store.variants
    bound = store === nothing ?
            IdDict{OpExpr,Vector{Tuple{Vector{ASTExpr},ASTExpr}}}() :
            store.bound_bodies
    return _TemplateCtx(sites, variants, IdDict{OpExpr,Bool}(), IOBuffer(),
                        var_map, param_sym_set, reg_funcs, bound, idxkey)
end

# Does `expr` reference any of the output loop indices in `idxset`? EXHAUSTIVE
# over every `ASTExpr`-typed field of `OpExpr` via the shared `child_exprs`
# traversal (`foreach_subexpr`, expression.jl) — args / expr_body / lower /
# upper / values / filter / key / table_axes / ranges bounds — so a loop index
# buried in an aggregate body, a reduction bound, or a table-axis map routes
# that op to the fallback and is NEVER mis-seen as loop-invariant (a false
# negative would return an unsubstituted loop var to resolve → a hard build
# error instead of a fallback). Cold path — called once per branch template,
# not per cell (the per-cell guard is the memoized `_refs_idxset`).
# IDENTITY-MEMOIZED (`foreach_subexpr_once`): a pure existence predicate is
# path-multiplicity-insensitive, and the branch-template expressions scanned
# here share subtrees by reference (`_sub_preserving`) — the per-path walk was
# exponential on a doubling chain (ESS-0hh). The memo is per call, which is
# per QUERY: `idxset` is fixed within a call, so a node's answer cannot change.
function _refs_loop_var(e::ASTExpr, idxset::Set{String})
    found = false
    foreach_subexpr_once(e) do x
        found || (x isa VarExpr && x.name in idxset && (found = true))
        nothing
    end
    return found
end

# Select the `makearray` region covering `kvals` — LAST covering region wins,
# matching `_resolve_index_of_makearray`. Returns `(region_index_or_0, region)`.
function _select_region(m::OpExpr, kvals::Vector{Int})
    regions = m.regions === nothing ? Vector{Vector{Vector{Int}}}() : m.regions
    ndim = length(kvals)
    r = 0
    reg = nothing
    for (ri, region) in enumerate(regions)
        length(region) == ndim || continue
        inr = true
        @inbounds for d in 1:ndim
            (kvals[d] >= region[d][1] && kvals[d] <= region[d][2]) || (inr = false; break)
        end
        inr && (r = ri; reg = region)
    end
    return r, reg
end

# Loop-invariant context for the `_stencilize` walk (the `_GeoCtx` precedent,
# tree_walk/geometry_setup.jl): the output loop-index names, the lane-recipe
# accumulator (appended in traversal order — recipe k IS lane sentinel k), the
# REPRESENTATIVE cell's index environment (consulted ONLY to pick
# `index(makearray)` regions — every cell sharing a branch resolves to the same
# regions), and the three read-only variable registries the gather recipes
# consult. All six are invariant across one walk (only `recipes` is mutated, by
# push!); previously they were threaded as positional args with `_, _, _, _`
# leaf placeholders. Build-time-only path — one small struct per branch is fine.
struct _StencilCtx
    idxset::Set{String}
    recipes::Vector{_LaneRecipe}
    idx_env::Dict{String,Int}
    array_var_info::Any
    const_arrays::AbstractDict
    pgather::AbstractDict
    # Identity memo for `_stencilize`: a shared makearray body is a DAG (esm-spec
    # §9.7.3 inlining has no `let` node, but the in-memory graph shares subtrees by
    # object identity), and `_stencilize` is a pure function of the input node plus
    # the structural ctx, so memoizing by node identity keeps the sentinel spine a
    # DAG instead of re-inflating it to a tree (~2M nodes for a PPM operator). Reset
    # per `_build_branch_template` because it references that call's lane recipes.
    smemo::IdDict{OpExpr,ASTExpr}
    # Memoized per-node "refers to a loop index" flag for the guard, so
    # `_stencilize`'s per-node check is an O(1) memo hit rather than an O(subtree)
    # re-walk (`_refs_loop_var`) plus a boxed-capture closure at every node — and a
    # Bool per node instead of a Set{String}.
    vsmemo::IdDict{OpExpr,Bool}
    # Compile-once template tier: the sub-kernel call sites this walk emitted
    # (sentinel j ↔ subcalls[j]), and the per-equation template context
    # (`nothing` on every reference-free build).
    subcalls::Vector{_SubCallSite}
    tctx::Union{Nothing,_TemplateCtx}
end
_StencilCtx(idxset, recipes, idx_env, array_var_info, const_arrays, pgather) =
    _StencilCtx(idxset, recipes, idx_env, array_var_info, const_arrays, pgather,
                IdDict{OpExpr,ASTExpr}(), IdDict{OpExpr,Bool}(),
                _SubCallSite[], nothing)
_StencilCtx(idxset, recipes, idx_env, array_var_info, const_arrays, pgather,
            tctx::Union{Nothing,_TemplateCtx}) =
    _StencilCtx(idxset, recipes, idx_env, array_var_info, const_arrays, pgather,
                IdDict{OpExpr,ASTExpr}(), IdDict{OpExpr,Bool}(),
                _SubCallSite[], tctx)

# `_stencilize` transforms `expr` into the sentinel spine and appends a
# `_LaneRecipe` (to `ctx.recipes`) for every loop-var-dependent leaf.
# Loop-INVARIANT subtrees are returned verbatim (resolved/compiled once, shared).
# Throws `_StencilFallback` on any loop-var-dependent construct not modelled here.
_stencilize(e::NumExpr, ::_StencilCtx) = e
_stencilize(e::IntExpr, ::_StencilCtx) = e
function _stencilize(e::VarExpr, ctx::_StencilCtx)
    if e.name in ctx.idxset
        push!(ctx.recipes, _LaneRecipe(LANE_LOOPLIT, "", ASTExpr[], Int[], Int[], nothing, e.name))
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    return e
end
function _stencilize(e::OpExpr, ctx::_StencilCtx)
    # Memoized guard (byte-for-byte the `_refs_loop_var` decision): probe the cached
    # variable set instead of re-walking the subtree + allocating a closure per node.
    _refs_idxset(e, ctx.idxset, ctx.vsmemo) || return e
    # A shared subtree stencilizes identically every time it is reached (same
    # sentinel spine, same lane recipes), so dedupe by identity: the first visit
    # pushes the recipes and the rest reuse the cached spine node + lane indices.
    # This is what keeps the spine a DAG; it only removes duplicate work, never
    # changes a value (the lane VALUES are recipe-evaluated identically per cell).
    cached = get(ctx.smemo, e, nothing)
    cached === nothing || return cached
    out = _stencilize_op(e, ctx)
    ctx.smemo[e] = out
    return out
end
function _stencilize_op(e::OpExpr, ctx::_StencilCtx)
    # Compile-once template tier: a node that IS an expansion root becomes a
    # sub-kernel call instead of being fused into this spine. Checked here (after
    # the loop-var guard and the smemo probe in `_stencilize`) so an invariant
    # root still hoists whole, and a root reached twice through a shared observed
    # subtree reuses its cached sentinel exactly like any shared subtree.
    tctx = ctx.tctx
    if tctx !== nothing && haskey(tctx.sites, e)
        return _stencilize_site(e, ctx, tctx)
    end
    return _stencilize_op_core(e, ctx)
end
function _stencilize_op_core(e::OpExpr, ctx::_StencilCtx)
    op = e.op
    if op == "index"
        return _stencilize_index(e, ctx)
    elseif op == "fn"
        # Closed function: recurse into the (scalar) query args; the const-array
        # table/axis args are loop-invariant and returned verbatim by recursion.
        new_args = ASTExpr[_stencilize(a, ctx) for a in e.args]
        return reconstruct(e; args=new_args)
    elseif op in _STENCIL_ELEMENTWISE_OPS
        # Pure elementwise op — must carry no sub-expression structure (a defensive
        # guard: elementwise ops never legitimately do; if one does, fall back).
        (e.expr_body === nothing && e.values === nothing && e.ranges === nothing &&
         e.output_idx === nothing && e.filter === nothing && e.lower === nothing &&
         e.upper === nothing && e.table_axes === nothing && e.key === nothing) ||
            throw(_StencilFallback("elementwise op '$op' carries structural fields"))
        new_args = ASTExpr[_stencilize(a, ctx) for a in e.args]
        return reconstruct(e; args=new_args)
    end
    throw(_StencilFallback("unsupported loop-var-dependent op '$op'"))
end

# Compile a template expansion root ONCE per (use site, region class) and emit a
# sub-kernel call sentinel. The region class is the root's own branch key under
# the current representative cell (`ctx.idx_env`) — exactly the segment this
# subtree contributes to the fused branch key — so two branches whose body takes
# the same region selections share one compiled `_SubVariant`. The variant's
# recipes are appended to the parent's vector at `base` (lane re-basing): the
# body's leaves are derived, ghost-keyed, and corner-verified per cell/box by the
# UNCHANGED machinery, in the same traversal order the fused walk would produce,
# so grouping is identical by construction.
_stencilize_site(root::OpExpr, ctx::_StencilCtx, tctx::_TemplateCtx) =
    _stencilize_shared(root, ctx, tctx, true)

# The common boundary compiler for both site shapes: `node` is either an
# expansion root hit directly in scalar position (`bypass=true` — its own walk
# must not re-enter the site check) or an index-bound producer body
# (`bypass=false` — the bound body is a fresh object, never in `sites`).
function _stencilize_shared(node::OpExpr, ctx::_StencilCtx, tctx::_TemplateCtx,
                            bypass::Bool)
    _branch_key!(tctx.bio, node, ctx.idxset, ctx.idx_env, ctx.const_arrays, tctx.gmemo)
    bodykey = String(take!(tctx.bio))
    # (root identity ≡ structure after A1 interning, loop-index-set key, region
    # class): the full variant key — shared per BUILD when the A3 store is
    # threaded in, per equation otherwise. See the _XEqStore purity note above.
    vkey = (objectid(node), tctx.idxkey, bodykey)
    variant = get(tctx.variants, vkey, nothing)
    if variant === nothing
        _BENCH_ON[] && (_BENCH_BODY_VARIANTS[] += 1)
        rs = _LaneRecipe[]
        # `tctx = nothing` for the body walk: compile-once boundaries are the
        # OUTERMOST expansion roots only (the RFC's "7 lon bodies"). A NESTED
        # root — ESD's stencils are deeply factored into limiter/edge-interpolant
        # helper templates — compiles FUSED into its enclosing variant: measured
        # on the ESD PPM stack, per-nested-root boundaries exploded 8,297 tiny
        # variants (vs ~40 outer bodies) whose bookkeeping and per-call
        # indirection cost more than the sharing saved. Nested region selections
        # still reach the variant key through `_branch_key!`, which descends
        # everything identically.
        subctx = _StencilCtx(ctx.idxset, rs, ctx.idx_env, ctx.array_var_info,
                             ctx.const_arrays, ctx.pgather,
                             IdDict{OpExpr,ASTExpr}(), tctx.gmemo,
                             _SubCallSite[], nothing)
        spine = bypass ? _stencilize_op_core(node, subctx) : _stencilize(node, subctx)
        vm_ext = _ext_var_map(tctx.var_map, rs, subctx.subcalls)
        bmemo = _BuildMemo()
        tmpl = _compile(_resolve_indices(spine, ctx.array_var_info, vm_ext,
                                         ctx.const_arrays, ctx.pgather, bmemo),
                        vm_ext, tctx.param_sym_set, tctx.reg_funcs, bmemo)
        variant = _SubVariant(tmpl, rs, subctx.subcalls, Dict{String,Any}())
        tctx.variants[vkey] = variant
    end
    base = length(ctx.recipes)
    append!(ctx.recipes, variant.recipes)
    push!(ctx.subcalls, (variant, base))
    return VarExpr(_subcall_name(length(ctx.subcalls)))
end

# An array-producer expansion root reached through `index(makearray → root, k…)`
# (the ESD stencil shape): bind the producer's output indices to the k-args ONCE
# per (root, k-arg identity) — the shared bound body — then compile-once on it.
function _stencilize_bound_site(producer::OpExpr, oi::Vector{String},
                                kargs::Vector{ASTExpr}, body::ASTExpr,
                                ctx::_StencilCtx, tctx::_TemplateCtx)
    entries = get!(tctx.bound_bodies, producer) do
        Tuple{Vector{ASTExpr},ASTExpr}[]
    end
    sub_body = nothing
    for (ka, sb) in entries
        if length(ka) == length(kargs) &&
           all(i -> ka[i] === kargs[i], eachindex(kargs))
            sub_body = sb
            break
        end
    end
    if sub_body === nothing
        idx_exprs = Dict{String,ASTExpr}(oi[d] => kargs[d] for d in 1:length(oi))
        sub_body = _sub_preserving(body, idx_exprs)
        push!(entries, (ASTExpr[a for a in kargs], sub_body))
    end
    sub_body isa OpExpr || return _stencilize(sub_body, ctx)   # degenerate body
    # An index-bound body that never touches a loop index is invariant — return
    # it whole, exactly as the fused walk's guard would (compiled once, shared).
    _refs_idxset(sub_body, ctx.idxset, ctx.vsmemo) || return sub_body
    return _stencilize_shared(sub_body, ctx, tctx, false)
end

# `index(<producer|var>, k…)`. Var gathers (state / pgather / const) become lane
# recipes; `index(makearray|aggregate, …)` is unwrapped symbolically (region
# selected via `ctx.idx_env`, aggregate output indices bound to the — still
# symbolic — `k` argument expressions). Mirrors the `_resolve_indices` `index`
# branch and its `_resolve_index_of_{makearray,arrayop}` helpers; anything not
# modelled falls back.
function _stencilize_index(e::OpExpr, ctx::_StencilCtx)
    isempty(e.args) && throw(_StencilFallback("empty index op"))
    first_arg = e.args[1]
    idx_args = e.args[2:end]
    if first_arg isa OpExpr && (_is_aggregate_op(first_arg.op) || first_arg.op == "makearray")
        return _stencilize_indexed(first_arg::OpExpr, idx_args, ctx)
    end
    if first_arg isa VarExpr && haskey(ctx.array_var_info, first_arg.name)
        lo, hi = ctx.array_var_info[first_arg.name]
        length(idx_args) == length(lo) ||
            throw(_StencilFallback("index ndim mismatch on '$(first_arg.name)'"))
        push!(ctx.recipes, _LaneRecipe(LANE_STATE, first_arg.name, idx_args,
                                       copy(lo), copy(hi), nothing, ""))
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    if first_arg isa VarExpr && haskey(ctx.pgather, first_arg.name)
        pg = ctx.pgather[first_arg.name]::_PGatherArray
        length(idx_args) == length(pg.dims) ||
            throw(_StencilFallback("pgather ndim mismatch on '$(first_arg.name)'"))
        push!(ctx.recipes, _LaneRecipe(LANE_PGATHER, first_arg.name, idx_args,
                                       Int[], Int[], pg, ""))
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    if first_arg isa VarExpr && haskey(ctx.const_arrays, first_arg.name)
        arr = ctx.const_arrays[first_arg.name]
        length(idx_args) == ndims(arr) ||
            throw(_StencilFallback("const-array ndim mismatch on '$(first_arg.name)'"))
        push!(ctx.recipes, _LaneRecipe(LANE_CONST, first_arg.name, idx_args,
                                       Int[], Int[], arr, ""))
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    throw(_StencilFallback("index into non-array/unknown var (loop-var-dependent)"))
end

# Symbolically index an array producer at `kargs`. For a `makearray`, select the
# covering region via `ctx.idx_env` and recurse into its value (a full-rank
# producer, or a scalar value used directly). For a non-contracting `aggregate`,
# bind its output indices to `kargs` and stencilize the body. Contraction /
# joins / filters / reduced-rank region values are NOT modelled — fall back.
function _stencilize_indexed(producer::OpExpr, kargs::Vector{ASTExpr}, ctx::_StencilCtx)
    if producer.op == "makearray"
        kvals = Int[_eval_const_int(a, ctx.idx_env, ctx.const_arrays) for a in kargs]
        r, _ = _select_region(producer, kvals)
        r == 0 && return NumExpr(0.0)   # no region covers → makearray default
        values = producer.values === nothing ? ASTExpr[] : producer.values
        sel = values[r]
        if _is_array_producer(sel)
            re = sel::OpExpr
            rank = re.op == "makearray" ?
                ((re.regions === nothing || isempty(re.regions)) ? 0 : length(re.regions[1])) :
                count(s -> s isa AbstractString, re.output_idx)
            rank == length(kargs) ||
                throw(_StencilFallback("makearray reduced-rank region value"))
            return _stencilize_indexed(re, kargs, ctx)
        end
        return _stencilize(sel, ctx)
    end
    # aggregate / arrayop
    (producer.join_gates === nothing && producer.filter === nothing) ||
        throw(_StencilFallback("index(aggregate) with join/filter"))
    oi_raw = producer.output_idx === nothing ? Any[] : producer.output_idx
    oi = String[String(s) for s in oi_raw if s isa AbstractString]
    length(oi) == length(kargs) ||
        throw(_StencilFallback("index(aggregate) output_idx/arg mismatch"))
    ranges = producer.ranges === nothing ? Dict{String,Any}() : producer.ranges
    all(n -> n in oi, keys(ranges)) ||
        throw(_StencilFallback("index(aggregate) with contracted index"))
    body = producer.expr_body
    body === nothing && throw(_StencilFallback("index(aggregate) with no body"))
    # Compile-once template tier: an expansion-root producer becomes a shared
    # sub-kernel over its index-bound body instead of being re-substituted and
    # re-fused into every branch spine.
    tctx = ctx.tctx
    if tctx !== nothing && haskey(tctx.sites, producer)
        return _stencilize_bound_site(producer, oi, kargs, body, ctx, tctx)
    end
    idx_exprs = Dict{String,ASTExpr}(oi[d] => kargs[d] for d in 1:length(oi))
    sub_body = _sub_preserving(body, idx_exprs)
    return _stencilize(sub_body, ctx)
end

# Memoized set of every variable name appearing anywhere in `e`, drawing
# children from the SAME shared `child_exprs` traversal `_refs_loop_var` uses
# (args / expr_body / lower / upper / filter / key / values / table_axes /
# ranges) so `_refs_idxset` below is exactly equivalent to a fresh
# `_refs_loop_var` call. Built lazily, once per node, and reused across every
# cell — turning the per-cell branch-key guard from an O(subtree) re-walk into
# an O(|idxset|) probe of the cached set. (Hand-rolled memoized recursion, not
# `foreach_subexpr`: the per-OpExpr `memo` shares interior sets, which a flat
# whole-subtree visitor cannot.)
# `_refs_loop_var(e, idxset)` without re-walking `e` — and without the
# `IdDict{OpExpr,Set{String}}` of every variable name it used to memoize (a Set per
# node was the largest remaining build churn). The guard only asks a BOOLEAN — does
# `e` reference any loop index in `idxset`? — so memoize THAT by node identity.
# Short-circuits on the first hit; `idxset` is fixed per build, so the answer is a
# pure function of the node. Byte-for-byte the same guard decision.
_child_refs_idxset(x::VarExpr, idxset::Set{String}, ::IdDict{OpExpr,Bool}) = x.name in idxset
_child_refs_idxset(::NumExpr, ::Set{String}, ::IdDict{OpExpr,Bool}) = false
_child_refs_idxset(::IntExpr, ::Set{String}, ::IdDict{OpExpr,Bool}) = false
_child_refs_idxset(x::OpExpr, idxset::Set{String}, memo::IdDict{OpExpr,Bool}) =
    _refs_idxset(x, idxset, memo)
function _refs_idxset(e::OpExpr, idxset::Set{String}, memo::IdDict{OpExpr,Bool})
    cached = get(memo, e, nothing)
    cached === nothing || return cached
    r = _scan_refs_idxset(e, idxset, memo)
    memo[e] = r
    return r
end
# Same field set / order as `child_exprs`, but returns as soon as any child refers
# to a loop index (no Set, no `child_exprs` vector, no closure).
function _scan_refs_idxset(e::OpExpr, idxset::Set{String}, memo::IdDict{OpExpr,Bool})
    for a in e.args
        _child_refs_idxset(a, idxset, memo) && return true
    end
    for fld in (e.lower, e.upper, e.expr_body, e.filter, e.key)
        if fld !== nothing && _child_refs_idxset(fld, idxset, memo)
            return true
        end
    end
    if e.values !== nothing
        for v in e.values
            _child_refs_idxset(v, idxset, memo) && return true
        end
    end
    if e.table_axes !== nothing
        for (_, v) in e.table_axes
            _child_refs_idxset(v, idxset, memo) && return true
        end
    end
    if e.ranges !== nothing
        for (_, rv) in e.ranges
            if rv isa AbstractVector
                for x in rv
                    x isa ASTExpr && _child_refs_idxset(x, idxset, memo) && return true
                end
            end
        end
    end
    if e.bindings !== nothing
        for (_, bv) in e.bindings
            _child_refs_idxset(bv, idxset, memo) && return true
        end
    end
    return false
end

# Per-cell branch signature: the `index(makearray)` region selections a cell
# takes, in traversal order. Cells with equal signatures resolve to the same
# spine template (the ONLY per-cell structural branch is makearray region choice;
# gather ghosts are handled separately). Mirrors `_stencilize`'s traversal — same
# invariant short-circuit, same region selection, same aggregate output-index
# substitution — so a shared signature guarantees a shared template. `memo` caches
# per-node variable sets across cells so the invariant guard costs O(|idxset|).
#
# IDENTITY-DEDUPED traversal (ESS-0hh): `seen` (fresh per top-level call, i.e.
# per cell/site keying) enters each distinct `OpExpr` once, so keying a
# structurally-shared spine (the obs-inlined body is a compact DAG by
# `_sub_preserving` construction) is O(distinct nodes), not once per PATH.
# The emitted STRING changes with this (a shared `index(makearray)` site
# prints its `M<r>;` segment once instead of once per path), but the string
# is ONLY ever compared to other strings produced by this same function over
# the SAME body object under the SAME loop-index set (`branch_cache` within
# one equation; template-variant keys per build, where the vkey pins the root
# object and idxkey pins the index set), and key-EQUALITY classes are
# preserved exactly: the
# traversal — which sites are visited, in which order, and what each prints —
# is a deterministic function of the fixed body DAG plus the per-cell region
# selections, so two cells produce equal deduped keys iff they select equal
# regions at every reachable site iff their per-path keys were equal.
function _branch_key!(io::IOBuffer, e, idxset::Set{String}, idx_env, const_arrays,
                      memo::IdDict{OpExpr,Bool},
                      seen::IdDict{OpExpr,Nothing}=IdDict{OpExpr,Nothing}())
    e isa OpExpr || return
    _refs_idxset(e, idxset, memo) || return
    haskey(seen, e) && return
    seen[e] = nothing
    if e.op == "index" && !isempty(e.args)
        fa = e.args[1]
        if fa isa OpExpr && (fa.op == "makearray" || _is_aggregate_op(fa.op))
            _branch_key_indexed!(io, fa::OpExpr, e.args[2:end], idxset, idx_env, const_arrays, memo, seen)
            return
        end
    end
    for a in e.args
        _branch_key!(io, a, idxset, idx_env, const_arrays, memo, seen)
    end
    e.expr_body !== nothing && _branch_key!(io, e.expr_body, idxset, idx_env, const_arrays, memo, seen)
    if e.values !== nothing
        for v in e.values
            _branch_key!(io, v, idxset, idx_env, const_arrays, memo, seen)
        end
    end
end
function _branch_key_indexed!(io::IOBuffer, producer::OpExpr, kargs::Vector{ASTExpr},
                              idxset::Set{String}, idx_env, const_arrays,
                              memo::IdDict{OpExpr,Bool}, seen::IdDict{OpExpr,Nothing})
    if producer.op == "makearray"
        kvals = Int[_eval_const_int(a, idx_env, const_arrays) for a in kargs]
        r, _ = _select_region(producer, kvals)
        print(io, 'M', r, ';')
        r == 0 && return
        values = producer.values === nothing ? ASTExpr[] : producer.values
        sel = values[r]
        if _is_array_producer(sel)
            _branch_key_indexed!(io, sel::OpExpr, kargs, idxset, idx_env, const_arrays, memo, seen)
        else
            _branch_key!(io, sel, idxset, idx_env, const_arrays, memo, seen)
        end
        return
    end
    # aggregate / arrayop: recurse the body with the output indices bound in the
    # SAME env/idxset (restored on the way out) — never a per-cell `_sub_preserving`
    # (which would re-clone the whole stencil spine on every cell) and never a
    # per-cell `copy` of the env/idxset (which fed the build's GC). The body's own
    # `index(makearray)` k-args reference these output indices, so they resolve to
    # the same values a substitution would.
    oi_raw = producer.output_idx === nothing ? Any[] : producer.output_idx
    oi = String[String(s) for s in oi_raw if s isa AbstractString]
    body = producer.expr_body
    (body === nothing || length(oi) != length(kargs)) && return
    kvals = Int[_eval_const_int(a, idx_env, const_arrays) for a in kargs]
    n = length(oi)
    saved = Vector{Union{Nothing,Int}}(undef, n)
    added = falses(n)
    for d in 1:n
        nm = oi[d]
        saved[d] = get(idx_env, nm, nothing)
        idx_env[nm] = kvals[d]
        if !(nm in idxset)
            push!(idxset, nm)
            added[d] = true
        end
    end
    _branch_key!(io, body, idxset, idx_env, const_arrays, memo, seen)
    for d in n:-1:1
        nm = oi[d]
        old = saved[d]
        old === nothing ? delete!(idx_env, nm) : (idx_env[nm] = old)
        added[d] && delete!(idxset, nm)
    end
end

# Extend `var_map` with the lane sentinels → a negative slot marker. `_compile`
# maps `VarExpr(lane_name(k))` to `_NK_STATE(idx = -k)`, which the box
# processor's `_lower_to_access` decodes back to `recipes[k]`. Built ONCE per
# equation (not per cell).
function _lane_var_map(var_map::Dict{String,Int}, recipes::Vector{_LaneRecipe})
    isempty(recipes) && return var_map
    ext = copy(var_map)
    for k in eachindex(recipes)
        ext[_lane_name(k)] = -k
    end
    return ext
end

# Lane sentinels plus sub-kernel call sentinels (compile-once tier): call site j
# maps to the disjoint negative range `-(_SUBCALL_SENT_BASE + j)`, decoded by
# `_lower_to_access`.
function _ext_var_map(var_map::Dict{String,Int}, recipes::Vector{_LaneRecipe},
                      subcalls::Vector{_SubCallSite})
    (isempty(recipes) && isempty(subcalls)) && return var_map
    ext = copy(var_map)
    for k in eachindex(recipes)
        ext[_lane_name(k)] = -k
    end
    for j in eachindex(subcalls)
        ext[_subcall_name(j)] = -(_SUBCALL_SENT_BASE + j)
    end
    return ext
end

# Evaluate one lane recipe for the current cell (`idx_env`). Byte-for-byte the
# `_resolve_indices` outcome for that leaf: a STATE slot (≥1), 0 for a ghost cell,
# a linear PGATHER offset, or a folded const / loop-index literal.
function _eval_recipe(rec::_LaneRecipe, idx_env::Dict{String,Int},
                      var_map::Dict{String,Int}, const_arrays::AbstractDict)
    if rec.kind == LANE_LOOPLIT
        return Float64(idx_env[rec.loop_name])
    end
    n = length(rec.idx_args)
    if rec.kind == LANE_STATE
        aff = rec.affine
        if aff !== nothing
            # Arithmetic slot (build-time corner-verified to equal the string
            # lookup): no index Vector, no `_cell_key` String. Same dims evaluated
            # and same ghost decision as below, so the result is byte-identical.
            base, strides = aff
            slot = base
            ghost = false
            @inbounds for d in 1:n
                v = _eval_const_int(rec.idx_args[d], idx_env, const_arrays)
                (v < rec.lo[d] || v > rec.hi[d]) && (ghost = true)
                slot += v * strides[d]
            end
            return ghost ? 0 : slot
        end
        inds = Vector{Int}(undef, n)
        ghost = false
        @inbounds for d in 1:n
            v = _eval_const_int(rec.idx_args[d], idx_env, const_arrays)
            inds[d] = v
            (v < rec.lo[d] || v > rec.hi[d]) && (ghost = true)
        end
        ghost && return 0
        cname = _cell_key(rec.var_name, inds)
        slot = get(var_map, cname, 0)
        slot == 0 && throw(TreeWalkError("E_TREEWALK_MISSING_CELL", cname))
        return slot
    elseif rec.kind == LANE_CONST
        arr = rec.arr
        inds = Vector{Int}(undef, n)
        @inbounds for d in 1:n
            inds[d] = _resolve_const_index(arr, rec.var_name, d,
                          _eval_const_int(rec.idx_args[d], idx_env, const_arrays),
                          size(arr, d))
        end
        return Float64(arr[inds...])
    else  # LANE_PGATHER
        pg = rec.arr::_PGatherArray
        inds = Vector{Int}(undef, n)
        @inbounds for d in 1:n
            v = _eval_const_int(rec.idx_args[d], idx_env, const_arrays)
            (1 <= v <= pg.dims[d]) ||
                throw(TreeWalkError("E_TREEWALK_PGATHER_OOB",
                    "forcing array '$(rec.var_name)' index $(v) out of range " *
                    "[1, $(pg.dims[d])] on dim $(d)" *
                    (get(ENV, "ESS_PGATHER_OOB_DEBUG", "") == "1" ?
                     " idx_args=$(repr(rec.idx_args)) idx_env=$(idx_env)" : "")))
            inds[d] = v
        end
        return LinearIndices(Tuple(pg.dims))[inds...]
    end
end

# Ghost pattern of the STATE lanes, from slots ALREADY isolated into a
# Vector{Int} (the affine sweep evaluates only those), encoded as a `String`
# for a cheap, hashable signature component (`_cell_ckey!`'s base key).
function _ghost_key_states(state_vals::Vector{Int})
    isempty(state_vals) && return ""
    io = IOBuffer()
    @inbounds for v in state_vals
        print(io, v == 0 ? '1' : '0')
    end
    return String(take!(io))
end

# One branch's spine entry: the compiled sentinel template, its lane recipes,
# the recipe indices that are STATE gathers (the ghost-key columns), and the
# sub-kernel call sites its spine references (empty on every reference-free
# build and on the whole symbolic path).
const _StencilBranch = Tuple{_Node,Vector{_LaneRecipe},Vector{Int},Vector{_SubCallSite}}

# Build one branch's spine template. Sentinels pass through resolve untouched
# and compile to `_NK_STATE(idx = -k)` via the extended var-map; a real
# TreeWalkError here also fires in the fallback path, so it propagates rather
# than falling back.
# Derive + corner-verify a state var's affine slot map (cell indices → var_map
# slot: `slot = base + Σ_d inds_d·strides_d`) so a gather resolves arithmetically.
# Returns `nothing` if any probe cell is absent or the layout is not affine on the
# var's `[lo,hi]` box — in which case `_eval_recipe` keeps the exact string lookup.
# ~2^D + D probes, once per var per branch template (cold); the payoff is per-cell.
function _derive_var_affine(var_name::String, lo::Vector{Int}, hi::Vector{Int},
                            var_map::Dict{String,Int})
    n = length(lo)
    (n == 0 || length(hi) != n) && return nothing
    base0 = get(var_map, _cell_key(var_name, lo), 0)
    base0 == 0 && return nothing
    strides = zeros(Int, n)
    probe = copy(lo)
    for d in 1:n
        hi[d] > lo[d] || continue           # single-cell dim → stride 0
        probe[d] = lo[d] + 1
        s = get(var_map, _cell_key(var_name, probe), 0)
        probe[d] = lo[d]
        s == 0 && return nothing
        strides[d] = s - base0
    end
    base = base0
    @inbounds for d in 1:n
        base -= lo[d] * strides[d]
    end
    for corner in Iterators.product(((lo[d], hi[d]) for d in 1:n)...)
        cl = collect(Int, corner)
        want = base
        @inbounds for d in 1:n
            want += cl[d] * strides[d]
        end
        got = get(var_map, _cell_key(var_name, cl), 0)
        (got == 0 || got != want) && return nothing
    end
    return (base, strides)
end

function _build_branch_template(body::ASTExpr, ctx_proto::_StencilCtx,
                                var_map::Dict{String,Int},
                                param_sym_set, reg_funcs)::_StencilBranch
    _BENCH_ON[] && (_BENCH_BRANCH_TEMPLATES[] += 1)   # §12 spine-template counter (off by default)
    rs = _LaneRecipe[]
    ctx = _StencilCtx(ctx_proto.idxset, rs, ctx_proto.idx_env,
                      ctx_proto.array_var_info, ctx_proto.const_arrays,
                      ctx_proto.pgather, ctx_proto.tctx)
    spine = _stencilize(body, ctx)
    # Attach each state gather's affine slot map (cold, once per branch) so the hot
    # per-cell `_eval_recipe` avoids the `_cell_key` String + index Vector.
    # Cache by var name: every LANE_STATE recipe for the same var shares one affine
    # map (its lo/hi are the var's array_var_info bounds), so derive it ONCE per var
    # rather than once per recipe (the derivation's `_cell_key` probes were the top
    # allocator otherwise).
    aff_cache = Dict{String,Union{Nothing,Tuple{Int,Vector{Int}}}}()
    @inbounds for k in eachindex(rs)
        r = rs[k]
        r.kind == LANE_STATE || continue
        aff = get!(() -> _derive_var_affine(r.var_name, r.lo, r.hi, var_map),
                   aff_cache, r.var_name)
        aff === nothing && continue
        rs[k] = _LaneRecipe(r.kind, r.var_name, r.idx_args, r.lo, r.hi,
                            r.arr, r.loop_name, aff)
    end
    vm_ext = _ext_var_map(var_map, rs, ctx.subcalls)
    # Identity memo so `_resolve_indices` + `_compile` carry the DAG that
    # `_stencilize` now preserves straight through to the compiled `_Node`
    # template instead of re-inflating it (the `_BuildMemo` contract: forwarding it
    # only removes duplicate work, never changes a result).
    bmemo = _BuildMemo()
    tmpl = _compile(_resolve_indices(spine, ctx.array_var_info, vm_ext,
                                     ctx.const_arrays, ctx.pgather, bmemo),
                    vm_ext, param_sym_set, reg_funcs, bmemo)
    return (tmpl, rs, Int[k for k in eachindex(rs) if rs[k].kind == LANE_STATE],
            ctx.subcalls)
end

