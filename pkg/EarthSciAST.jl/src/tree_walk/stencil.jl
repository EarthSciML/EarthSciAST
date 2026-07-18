# ========================================================================
# tree_walk/stencil.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4c: the symbolic stencil compiler (ess-perf) — one spine
# template per structural group, with per-lane recipe evaluation.
# ========================================================================

# ============================================================
# 4c. Symbolic stencil compiler (ess-perf: one template per structural group)
# ============================================================
#
# The per-cell array path (§4b) runs `_sub_preserving` → `_resolve_indices` →
# `_compile` once for EVERY output cell, then `_vectorize_cell_entries` collapses
# the structurally-identical per-cell `_Node` trees into `_VecKernel` templates.
# For a stencil that is ~82% wasted work (measured): the tree SHAPE ("spine") is
# identical across cells — only the state-gather slot indices (and per-cell const /
# ghost leaves) differ. This pass builds the spine ONCE, symbolically, keeping
# each loop-var-dependent gather as a LANE placeholder, then derives every cell's
# leaf values by evaluating the gather index expressions per lane. The result is
# the SAME set of `_VecKernel`s the per-cell path would produce — byte-identical
# structure + slots — at O(spine + Σcells·gathers) instead of O(cells·spine).
#
# Applicability is intentionally narrow. `_stencilize` keeps ONLY the whitelisted
# elementwise ops + `index(state/const/pgather, …)` gathers + `fn` leaves + bare
# loop-index literals; ANY loop-var-dependent construct outside that set
# (`arrayop`/`aggregate`/`makearray`/`integral`/`index`-of-those/`table_lookup`/…)
# throws `_StencilFallback` and the caller runs the unchanged per-cell path. So the
# fast path is provably identical WHERE it applies and simply absent elsewhere.
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
#     `_resolve_indices` returns;
#   • `_lower_template` mirrors `_merge_nodes` arm-for-arm (all-equal→scalar,
#     else→gather/constvec; interp const-fold via the SAME `_merge_fn_node`);
#   • cells are grouped by ghost pattern — the ONLY structural variable among
#     whitelisted cells (in-bounds STATE 'S' vs ghost LITERAL 'L') — reproducing
#     the `_struct_sig` partition; iteration + first-seen order are preserved so
#     lane↔out-slot pairing is identical.
# `ESS_STENCIL_DISABLE=1` forces the fallback (used by the differential test that
# asserts both paths build identical kernels).

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
# that IS an expansion root, it compiles that subtree ONCE per (use site, region
# class) into a `_SubVariant` and splices a SUB-KERNEL CALL sentinel into the
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

# Per-equation compile-once context. `sites` maps each expansion root (an
# `OpExpr` in the obs-inlined RHS, by identity) to its originating apply node
# (documentary — the template name for diagnostics). `variants` memoizes
# compiled bodies by `(root identity, body branch key)`; `gmemo` is the shared
# `_refs_idxset` guard memo; `bio` a scratch buffer for body branch keys. The
# compile inputs (`var_map`, `param_sym_set`, `reg_funcs`) ride along because
# variant compilation happens mid-`_stencilize`, where they are out of scope.
struct _TemplateCtx
    sites::IdDict{OpExpr,OpExpr}
    variants::Dict{Tuple{UInt64,String},_SubVariant}
    gmemo::IdDict{OpExpr,Bool}
    bio::IOBuffer
    var_map::Dict{String,Int}
    param_sym_set::Any
    reg_funcs::Any
    # Index-bound bodies for expansion roots that are ARRAY PRODUCERS (an
    # aggregate reached through `index(makearray → root, k…)` — the ESD stencil
    # shape): the producer's `expr_body` with its output indices substituted by
    # the k-args, built ONCE per (root, k-arg identity tuple) and shared across
    # branches. The bound body is then the compile-once boundary exactly as a
    # scalar-position root is. Keyed by root identity; each entry holds the
    # k-arg objects it was bound against (branch-invariant in practice, so the
    # inner vector stays length 1) plus the shared bound body.
    bound_bodies::IdDict{OpExpr,Vector{Tuple{Vector{ASTExpr},ASTExpr}}}
end
_TemplateCtx(sites::IdDict{OpExpr,OpExpr}, var_map::Dict{String,Int},
             param_sym_set, reg_funcs) =
    _TemplateCtx(sites, Dict{Tuple{UInt64,String},_SubVariant}(),
                 IdDict{OpExpr,Bool}(), IOBuffer(), var_map, param_sym_set, reg_funcs,
                 IdDict{OpExpr,Vector{Tuple{Vector{ASTExpr},ASTExpr}}}())

# Does `expr` reference any of the output loop indices in `idxset`? EXHAUSTIVE
# over every `ASTExpr`-typed field of `OpExpr` via the shared `child_exprs`
# traversal (`foreach_subexpr`, expression.jl) — args / expr_body / lower /
# upper / values / filter / key / table_axes / ranges bounds — so a loop index
# buried in an aggregate body, a reduction bound, or a table-axis map routes
# that op to the fallback and is NEVER mis-seen as loop-invariant (a false
# negative would return an unsubstituted loop var to resolve → a hard build
# error instead of a fallback). Cold path — called once per branch template,
# not per cell (the per-cell guard is the memoized `_refs_idxset`).
function _refs_loop_var(e::ASTExpr, idxset::Set{String})
    found = false
    foreach_subexpr(e) do x
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
    # (sentinel j ↔ subcalls[j]), and the per-equation template context (`nothing`
    # on every reference-free build and on the symbolic `_VecKernel` path, which
    # always receives the fused expanded body).
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
    vkey = (objectid(node), bodykey)
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
function _branch_key!(io::IOBuffer, e, idxset::Set{String}, idx_env, const_arrays,
                      memo::IdDict{OpExpr,Bool})
    e isa OpExpr || return
    _refs_idxset(e, idxset, memo) || return
    if e.op == "index" && !isempty(e.args)
        fa = e.args[1]
        if fa isa OpExpr && (fa.op == "makearray" || _is_aggregate_op(fa.op))
            _branch_key_indexed!(io, fa::OpExpr, e.args[2:end], idxset, idx_env, const_arrays, memo)
            return
        end
    end
    for a in e.args
        _branch_key!(io, a, idxset, idx_env, const_arrays, memo)
    end
    e.expr_body !== nothing && _branch_key!(io, e.expr_body, idxset, idx_env, const_arrays, memo)
    if e.values !== nothing
        for v in e.values
            _branch_key!(io, v, idxset, idx_env, const_arrays, memo)
        end
    end
end
function _branch_key_indexed!(io::IOBuffer, producer::OpExpr, kargs::Vector{ASTExpr},
                              idxset::Set{String}, idx_env, const_arrays,
                              memo::IdDict{OpExpr,Bool})
    if producer.op == "makearray"
        kvals = Int[_eval_const_int(a, idx_env, const_arrays) for a in kargs]
        r, _ = _select_region(producer, kvals)
        print(io, 'M', r, ';')
        r == 0 && return
        values = producer.values === nothing ? ASTExpr[] : producer.values
        sel = values[r]
        if _is_array_producer(sel)
            _branch_key_indexed!(io, sel::OpExpr, kargs, idxset, idx_env, const_arrays, memo)
        else
            _branch_key!(io, sel, idxset, idx_env, const_arrays, memo)
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
    _branch_key!(io, body, idxset, idx_env, const_arrays, memo)
    for d in n:-1:1
        nm = oi[d]
        old = saved[d]
        old === nothing ? delete!(idx_env, nm) : (idx_env[nm] = old)
        added[d] && delete!(idxset, nm)
    end
end

# Extend `var_map` with the lane sentinels → a negative slot marker. `_compile`
# maps `VarExpr(lane_name(k))` to `_NK_STATE(idx = -k)`, which `_lower_template`
# decodes back to `recipes[k]`. Built ONCE per equation (not per cell).
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
# `_lower_to_access`. `_lower_template` (the symbolic `_VecKernel` path) never
# sees one — that path always receives the fused expanded body — and guards the
# range as an internal error rather than mis-indexing `recipes`.
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
                    "[1, $(pg.dims[d])] on dim $(d)"))
            inds[d] = v
        end
        return LinearIndices(Tuple(pg.dims))[inds...]
    end
end

# Ghost pattern of the STATE lanes — the ONLY structural variable among
# whitelisted cells (in-bounds STATE 'S' vs ghost LITERAL 'L'). Two cells share a
# `_VecKernel` iff this key is equal (and the invariant spine is identical, which
# holds by construction). Encoded as a `String` for a cheap, hashable group key.
function _ghost_key(lane_vals::Vector{Any}, state_ks::Vector{Int})
    isempty(state_ks) && return ""
    io = IOBuffer()
    @inbounds for k in state_ks
        print(io, (lane_vals[k]::Int) == 0 ? '1' : '0')
    end
    return String(take!(io))
end

# Same ghost key from the STATE-lane slots ALREADY isolated into a Vector{Int}
# (the affine sweep evaluates only those — `_ghost_key` never reads a non-state
# lane), so `_cell_ckey!` needs no `Vector{Any}` and no boxing.
function _ghost_key_states(state_vals::Vector{Int})
    isempty(state_vals) && return ""
    io = IOBuffer()
    @inbounds for v in state_vals
        print(io, v == 0 ? '1' : '0')
    end
    return String(take!(io))
end

# Lower the sentinel template `_Node` to a `_VecNode` for ONE structural group,
# reading each lane's per-cell values from `cell_lanes` (`cell_lanes[j][k]` is
# recipe `k`'s value for the group's lane `j`). Mirrors `_merge_nodes` exactly:
# same all-equal → scalar / else → gather-or-constvec decisions, same interp fold.
function _lower_template(n::_Node, recipes::Vector{_LaneRecipe},
                         cell_lanes::Vector{Vector{Any}}, len::Int)::_VecNode
    k = n.kind
    if k === _NK_STATE
        if n.idx < 0
            r = -n.idx
            # Sub-kernel call sentinels never reach the symbolic `_VecKernel`
            # path (it always receives the fused expanded body); reaching one
            # here is an internal invariant violation, never wire-visible.
            r >= _SUBCALL_SENT_BASE && throw(TreeWalkError("E_TREEWALK_INTERNAL",
                "symbolic stencil: sub-kernel call sentinel in a _VecKernel template"))
            rec = recipes[r]
            if rec.kind == LANE_STATE
                # Ghost-ness is uniform within the group (it defines the group).
                if (cell_lanes[1][r]::Int) == 0
                    return _mkvnode(kind=_VK_LITERAL, literal=0.0, buf=Vector{Float64}(undef, len))
                end
                slots = Int[cell_lanes[j][r]::Int for j in 1:len]
                s1 = slots[1]
                if all(==(s1), slots)
                    return _mkvnode(kind=_VK_STATE, idx=s1, buf=Vector{Float64}(undef, len))
                end
                return _mkvnode(kind=_VK_GATHER, slots=slots, buf=Vector{Float64}(undef, len))
            elseif rec.kind == LANE_PGATHER
                slots = Int[cell_lanes[j][r]::Int for j in 1:len]
                return _mkvnode(kind=_VK_PGATHER, payload=(rec.arr::_PGatherArray).flat,
                                slots=slots, buf=Vector{Float64}(undef, len))
            else  # LANE_CONST / LANE_LOOPLIT → per-lane float
                vals = Float64[cell_lanes[j][r]::Float64 for j in 1:len]
                v1 = vals[1]
                if all(x -> isequal(x, v1), vals)
                    return _mkvnode(kind=_VK_LITERAL, literal=v1, buf=Vector{Float64}(undef, len))
                end
                return _mkvnode(kind=_VK_CONSTVEC, vals=vals)
            end
        end
        return _mkvnode(kind=_VK_STATE, idx=n.idx, buf=Vector{Float64}(undef, len))
    elseif k === _NK_LITERAL
        return _mkvnode(kind=_VK_LITERAL, literal=n.literal, buf=Vector{Float64}(undef, len))
    elseif k === _NK_PARAM
        return _mkvnode(kind=_VK_PARAM, sym=n.sym, buf=Vector{Float64}(undef, len))
    elseif k === _NK_TIME
        return _mkvnode(kind=_VK_TIME, buf=Vector{Float64}(undef, len))
    elseif k === _NK_PARAM_GATHER
        # Invariant forcing gather (constant index) — one lin offset broadcast.
        return _mkvnode(kind=_VK_PGATHER, payload=n.payload,
                        slots=fill(n.idx, len), buf=Vector{Float64}(undef, len))
    elseif k === _NK_CONTRACTION
        # Contractions take the per-cell path (einsum), never the symbolic one —
        # `_stencilize` rejects every contraction-bearing construct with a
        # `_StencilFallback`, so this arm is an INTERNAL invariant violation
        # (`E_TREEWALK_INTERNAL` is compiler-internal, never wire-visible: no
        # conforming document can reach it).
        throw(TreeWalkError("E_TREEWALK_INTERNAL",
            "symbolic stencil: unexpected contraction node in template"))
    else  # _NK_OP / fn
        ch = _VecNode[_lower_template(c, recipes, cell_lanes, len) for c in n.children]
        if n.op === :fn
            return _merge_fn_node(n.payload, ch, len, length(ch))
        end
        # Lane-invariant subtree → one scalar eval per RHS call instead of one per lane
        # (vectorize.jl). Built from the LOWERED children, never from this template node,
        # whose LITERAL/STATE leaves are recipe placeholders rather than lane values.
        hoisted = _maybe_hoist_invariant(n.op, n.payload, ch, len)
        hoisted === nothing || return hoisted
        return _mkvnode(kind=_VK_OP, op=n.op, payload=n.payload, children=ch,
                        buf=Vector{Float64}(undef, len))
    end
end

# One branch's spine entry: the compiled sentinel template, its lane recipes,
# the recipe indices that are STATE gathers (the ghost-key columns), and the
# sub-kernel call sites its spine references (empty on every reference-free
# build and on the whole symbolic path).
const _StencilBranch = Tuple{_Node,Vector{_LaneRecipe},Vector{Int},Vector{_SubCallSite}}

# The collected state of one equation's symbolic-stencil sweep: the per-branch
# spine templates, the structural groups (first-seen order preserved for
# deterministic kernel ordering), and the per-cell du-slot / cell-name streams
# in iteration order (for the duplicate-derivative check the commit step runs).
struct _StencilGroups
    branch_cache::Dict{String,_StencilBranch}
    order::Vector{String}                                    # first-seen group keys
    groups::Dict{String,Tuple{Vector{Int},Vector{Vector{Any}},String}}
    du_ordered::Vector{Int}
    cn_ordered::Vector{String}
end

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

# The group-collection sweep: iterate every output cell, build each new branch's
# spine template once, evaluate the lane recipes per cell, and group cells by
# `bkey|gkey` (branch × ghost pattern — the only per-cell structural variables).
# The `_StencilFallback` rewind is LOCALIZED here: any fallback inside the sweep
# returns `nothing` (nothing observable has happened yet — `covered` is not
# touched until the commit step); a real TreeWalkError propagates, exactly as it
# would from the per-cell path.
function _collect_stencil_groups(body::ASTExpr, idx_names::Vector{String},
                                 range_iters, lhs_var::String,
                                 lhs_idx_args::Vector{ASTExpr},
                                 ctx_proto::_StencilCtx, var_map::Dict{String,Int},
                                 param_sym_set, reg_funcs)::Union{_StencilGroups,Nothing}
    st = _StencilGroups(Dict{String,_StencilBranch}(), String[],
                        Dict{String,Tuple{Vector{Int},Vector{Vector{Any}},String}}(),
                        Int[], String[])
    idx_env = ctx_proto.idx_env
    const_arrays = ctx_proto.const_arrays
    bio = IOBuffer()
    # Per-node variable-set cache for the branch-key guard, built once and reused
    # across every cell (the spine is structurally identical cell to cell).
    bmemo = IdDict{OpExpr,Bool}()
    try
        for idx_tuple in Iterators.product(range_iters...)
            empty!(idx_env)
            @inbounds for d in 1:length(idx_names)
                idx_env[idx_names[d]] = idx_tuple[d]
            end
            # LHS index args are simple loop-var arithmetic; evaluate with an empty
            # const-array env to match the per-cell fallback path (the
            # `_is_arrayop_D_lhs` branch of `_build_evaluator_impl`) exactly.
            du_inds = Int[_eval_const_int(a, idx_env) for a in lhs_idx_args]
            cname = _cell_key(lhs_var, du_inds)
            du_slot = get(var_map, cname, 0)
            du_slot == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", cname))

            _branch_key!(bio, body, ctx_proto.idxset, idx_env, const_arrays, bmemo)
            bkey = String(take!(bio))
            entry = get(st.branch_cache, bkey, nothing)
            if entry === nothing
                entry = _build_branch_template(body, ctx_proto, var_map,
                                               param_sym_set, reg_funcs)
                st.branch_cache[bkey] = entry
            end
            _tmpl, recipes, state_ks, _subcalls = entry

            lane_vals = Vector{Any}(undef, length(recipes))
            @inbounds for k in eachindex(recipes)
                lane_vals[k] = _eval_recipe(recipes[k], idx_env, var_map, const_arrays)
            end
            ckey = string(bkey, '|', _ghost_key(lane_vals, state_ks))
            slots, cells, _bk = get!(st.groups, ckey) do
                push!(st.order, ckey)
                (Int[], Vector{Any}[], bkey)
            end
            push!(slots, du_slot)
            push!(cells, lane_vals)
            push!(st.du_ordered, du_slot)
            push!(st.cn_ordered, cname)
        end
    catch err
        if err isa _StencilFallback
            get(ENV, "ESS_STENCIL_DEBUG", "") == "1" &&
                @info "symbolic stencil fallback" reason = err.reason
            return nothing   # covered is untouched — the per-cell path takes over
        end
        rethrow()
    end
    return st
end

# The commit step: mark `covered` (duplicate detection in iteration order,
# matching the per-cell path's incremental check), then lower one `_VecKernel`
# per structural group, in first-seen group order.
function _commit_stencil_kernels(st::_StencilGroups, covered::BitVector)::Vector{_VecKernel}
    for i in eachindex(st.du_ordered)
        s = st.du_ordered[i]
        covered[s] &&
            throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", st.cn_ordered[i]))
        covered[s] = true
    end
    kernels = _VecKernel[]
    for ckey in st.order
        slots, cells, bkey = st.groups[ckey]
        tmpl, recipes, _, _ = st.branch_cache[bkey]
        push!(kernels, _VecKernel(slots, _lower_template(tmpl, recipes, cells, length(slots)),
                                  length(slots)))
    end
    return kernels
end

# Try to compile a no-contraction array equation via the symbolic stencil path.
# Returns the `Vector{_VecKernel}` on success (marking `covered` for every cell it
# owns), or `nothing` to signal the caller to run the unchanged per-cell fallback.
# On `nothing`, `covered` is guaranteed untouched. Three steps: guard + inline
# observeds (here), the group-collection sweep (`_collect_stencil_groups`, which
# owns the `_StencilFallback` rewind), and the covered-marking / kernel-lowering
# commit (`_commit_stencil_kernels`).
function _try_symbolic_stencil(rhs_body::ASTExpr, idx_names::Vector{String},
                               range_iters, lhs_body::OpExpr,
                               resolved_obs::Dict{String,ASTExpr},
                               array_var_info, var_map::Dict{String,Int},
                               const_arrays::AbstractDict, pgather::AbstractDict,
                               param_sym_set, reg_funcs, covered::BitVector)
    # Malformed LHS → fall back so the per-cell loop raises the exact
    # `E_TREEWALK_ARRAYOP_MALFORMED_LHS` diagnostic (never a raw TypeError here).
    (lhs_body.op == "D" && !isempty(lhs_body.args) &&
     lhs_body.args[1] isa OpExpr && (lhs_body.args[1]::OpExpr).op == "index" &&
     !isempty((lhs_body.args[1]::OpExpr).args) &&
     (lhs_body.args[1]::OpExpr).args[1] isa VarExpr) || return nothing

    # Inline observed variables once. Their RHS are loop-index-independent, so a
    # single substitution equals the per-cell `sub(sub(body, idx), obs)` order.
    body = isempty(resolved_obs) ? rhs_body : _sub_preserving(rhs_body, resolved_obs)

    # LHS write target: `D(index(var, k…))` — var + index-arg exprs shared by all
    # cells (evaluated per cell against the sweep's `idx_env`).
    inner = lhs_body.args[1]::OpExpr
    lhs_var = (inner.args[1]::VarExpr).name
    lhs_idx_args = inner.args[2:end]

    # Prototype walk context: `recipes` is replaced per branch by
    # `_build_branch_template`; `idx_env` is the sweep's (reused) cell env.
    ctx_proto = _StencilCtx(Set{String}(idx_names), _LaneRecipe[],
                            Dict{String,Int}(), array_var_info, const_arrays,
                            pgather)
    st = _collect_stencil_groups(body, idx_names, range_iters, lhs_var,
                                 lhs_idx_args, ctx_proto, var_map,
                                 param_sym_set, reg_funcs)
    st === nothing && return nothing   # fallback — covered untouched
    return _commit_stencil_kernels(st, covered)
end
