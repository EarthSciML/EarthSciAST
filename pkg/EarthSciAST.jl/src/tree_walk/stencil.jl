# ========================================================================
# tree_walk/stencil.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4c: the symbolic STENCILIZER — one sentinel spine
# template per structural group, with per-lane recipe evaluation. This is the
# front half of the affine box processor (stencil_affine.jl): `_stencilize`
# turns a rule body into a compiled `_Node` spine whose loop-var-dependent
# leaves are LANE sentinels, and `_eval_recipe` resolves each lane at any cell.
# The box processor derives per-box access descriptors from those recipes.
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
# elementwise ops + `index(state/const/pgather, …)` gathers + bare
# loop-index literals; ANY loop-var-dependent construct outside that set
# (`faq`/`makearray`/`integral`/`index`-of-those/…)
# declines (`_Decline`) and the caller runs the unchanged per-cell path. So the
# fast path is provably identical WHERE it applies and simply absent elsewhere.
# ONE refinement keeps the failure mode SUBTERM-granular instead of
# whole-equation: a construct that would throw but is BUILD-TIME EVALUABLE
# (free references only loop indices / literals / const arrays) becomes a
# `LANE_EXPRTBL` lane materialized as a per-box value table — see the
# SUBTREE-TABLE RESCUE section below. Everything else still throws.
#
# With this tier off (`compiler=:interpreter`) an array equation takes the
# per-cell SCALAR reference instead: compiled cell nodes on `rhs_list`,
# evaluated by `_eval_node` — the differential oracle.

@enum _LaneKind LANE_STATE LANE_CONST LANE_PGATHER LANE_LOOPLIT LANE_EXPRTBL

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
    affine::Union{Nothing, Tuple{Int, Vector{Int}}}
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

_stencil_disabled() = !_compiler_plan_now().stencil

# The per-build observed-inlining store. `obs_memo` is the shared
# `_sub_preserving` memo for the per-equation observed inlining
# (`_try_affine_stencil`): the bindings (`resolved_obs`) are one fixed Dict per
# build, so sharing the memo is sound by `_sub_preserving`'s own contract.
# `obs_bindings` guards that contract: a different bindings object gets a
# fresh memo instead of a wrong reuse. With the affine tier off
# (`compiler = :interpreter`) no store is created.
struct _XEqStore
    obs_memo::IdDict{OpExpr, ASTExpr}          # a shared `_SubMemo`
    obs_bindings::Base.RefValue{Any}          # the bindings object it was built against
end
_XEqStore() = _XEqStore(IdDict{OpExpr, ASTExpr}(), Base.RefValue{Any}(nothing))

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
    return IdDict{OpExpr, ASTExpr}()
end

# Select the `makearray` region covering `kvals` — LAST covering region wins,
# matching `_resolve_index_of_makearray`. Returns `(region_index_or_0, region)`.
function _select_region(m::OpExpr, kvals::Vector{Int})
    regions = m.regions === nothing ? Vector{Vector{Vector{Any}}}() : m.regions
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
# tree_walk/setup_sweep.jl): the output loop-index names, the lane-recipe
# accumulator (appended in traversal order — recipe k IS lane sentinel k), the
# REPRESENTATIVE cell's index environment (consulted ONLY to pick
# `index(makearray)` regions — every cell sharing a branch resolves to the same
# regions), and the three read-only variable registries the gather recipes
# consult. All six are invariant across one walk (only `recipes` is mutated, by
# push!). Build-time-only path — one small struct per branch is fine.
struct _StencilCtx
    idxset::Set{String}
    recipes::Vector{_LaneRecipe}
    idx_env::Dict{String, Int}
    array_var_info::Any
    const_arrays::AbstractDict
    pgather::AbstractDict
    # Identity memo for `_stencilize`: a shared makearray body is a DAG (esm-spec
    # §9.7.3 inlining has no `let` node, but the in-memory graph shares subtrees by
    # object identity), and `_stencilize` is a pure function of the input node plus
    # the structural ctx, so memoizing by node identity keeps the sentinel spine a
    # DAG instead of re-inflating it to a tree. Reset
    # per `_build_branch_template` because it references that call's lane recipes.
    smemo::IdDict{OpExpr, ASTExpr}
    # Memoized per-node "refers to a loop index" flag for the guard
    # (`_refs_idxset`), so `_stencilize`'s per-node check is an O(1) memo hit
    # rather than an O(subtree) re-walk.
    vsmemo::IdDict{OpExpr, Bool}
end
_StencilCtx(idxset, recipes, idx_env, array_var_info, const_arrays, pgather) =
    _StencilCtx(
    idxset, recipes, idx_env, array_var_info, const_arrays, pgather,
    IdDict{OpExpr, ASTExpr}(), IdDict{OpExpr, Bool}()
)

# `_stencilize` transforms `expr` into the sentinel spine and appends a
# `_LaneRecipe` (to `ctx.recipes`) for every loop-var-dependent leaf.
# Loop-INVARIANT subtrees are returned verbatim (resolved/compiled once, shared).
# Declines (`_Decline`) on any loop-var-dependent construct not modelled here.
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
    # Memoized guard: does the subtree read a loop index? A subtree that does
    # not is loop-invariant and is returned as it is.
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
_stencilize_op(e::OpExpr, ctx::_StencilCtx) = _stencilize_op_core(e, ctx)
function _stencilize_op_core(e::OpExpr, ctx::_StencilCtx)
    op = e.op
    if op == "index"
        return _stencilize_index(e, ctx)
    elseif _tpl_is_call(e)
        # A template call (call.jl) is elementwise in its arguments: they are
        # read in this spine, the body is a function of them compiled apart.
        nb = Dict{String, ASTExpr}()
        for k in sort!(collect(keys(e.bindings)))
            nb[k] = _stencilize(e.bindings[k], ctx)
        end
        return reconstruct(e; bindings = nb)
    elseif op in _STENCIL_ELEMENTWISE_OPS
        # Pure elementwise op — must carry no sub-expression structure (a defensive
        # guard: elementwise ops never legitimately do; if one does, fall back).
        (
            e.expr_body === nothing && e.values === nothing && e.ranges === nothing &&
                e.output_idx === nothing && e.filter === nothing && e.lower === nothing &&
                e.upper === nothing && e.key === nothing
        ) ||
            _decline(:unsupported_op, "elementwise op '$op' carries structural fields")
        new_args = ASTExpr[_stencilize(a, ctx) for a in e.args]
        return reconstruct(e; args = new_args)
    end
    # SUBTERM-GRANULAR fallback (subtree-table rescue): before declining the
    # WHOLE equation over this one construct, try to isolate it as a
    # build-time-evaluable lane (see `_try_exprtbl_lane` below). It runs only
    # where the walk would otherwise throw, so it never changes how an equation
    # the walk models lowers.
    lane = _try_exprtbl_lane(e, ctx)
    lane === nothing || return lane
    # A SHORT scalar contraction (an `faq` with no output index) in expression
    # position is the gather `index(faq, k…)` with no subscripts, so it unrolls
    # exactly as `_stencilize_indexed` unrolls a contracting producer: the term
    # list, order and fold the per-cell reference builds for it
    # (`_resolve_index_of_faq` with no index arguments). The column mean of a
    # flattened model, `c·(Σ_k u[i,j,k]/L − u[i,j,k])` in a makearray region
    # value summed with other terms, reaches the tier this way; the reduction
    # hoist (hoist.jl) does not look inside a region value. Below the
    # contraction loop's floor only, as for a top-level contraction
    # (`_long_contraction`): a longer one is left to the tiers that keep it a
    # loop, and refused by name where none does.
    _is_short_scalar_contraction(e) && return _stencilize_indexed(e, ASTExpr[], ctx)
    return _decline(:unsupported_op, "loop-index-dependent op '$op'")
end

# ─────────────────────────────────────────────────────────────────────────────
# SUBTREE-TABLE RESCUE (subterm-granular fallback). Without it ONE
# unsupported loop-var-dependent construct anywhere in a rule body declines the
# ENTIRE equation to per-cell scalarization — O(#cells) IR and build time. The
# escape hatch the
# box processor already carries for LEAVES — a non-uniform state/const/pgather
# lane materializes a per-box table instead of declining
# (`_materialize_state_tbl` / `_materialize_const_box` /
# `_materialize_pgather_tbl`, stencil_affine.jl) — generalizes to SUBTREES:
# when the offending subtree is BUILD-TIME EVALUABLE (its free references are
# only loop indices, literals, and const arrays — NO state, NO `t`, NO scalar
# params, NO live forcing, NO non-const-materialized observeds), it becomes a
# `LANE_EXPRTBL` lane whose per-box lowering is a dense VALUE table
# (`_materialize_const_box`'s exhaustive per-cell evaluation, all-equal fold
# included), and the rest of the equation stays on the affine path.
#
# Evaluation reuses the compile-once machinery
# (`_cell_evaluator` + `_CellEval`, tree_walk/cellwise.jl) — the
# existing evaluator for "a scalar expression at a loop-index environment over
# const arrays": the subtree is resolved+compiled ONCE with the loop indices
# bound as Float64 parameters, and each cell only rebinds them. `_eval_node`
# computes every leaf in Float64, so a loop index bound as a Float64 param
# equals that index folded to a Float64 literal (the `_try_field_ic_fastpath`
# identity argument) — the table entries are bit-for-bit what the per-cell
# reference computes for the same subtree.
#
# `compiler = :interpreter`, which turns the whole affine tier off, is the
# differential oracle (test/stencil_subtree_tbl_test.jl).

# One rescued subtree: the expression, the loop-index binding ORDER (sorted —
# deterministic, and consistent between compile and per-cell rebinding), and
# the compiled `_CellEval` (attached by `_attach_exprtbl_evals!` when the
# recipe vector is finalized). Mutable so the
# attach mutates the spec shared by every recipe vector that references it
# (a variant's recipes are appended to parents by reference).
mutable struct _ExprTblSpec
    expr::ASTExpr
    idx_names::Vector{String}
    ce::Any                       # _CellEval once attached; nothing before
end

# Is `e` evaluable at build time from loop indices + literals + const arrays
# ALONE? A conservative free-reference check: every VarExpr must be a bound
# name (a loop index, or a binder introduced by an enclosing aggregate-like
# node — `ranges` keys / `output_idx` strings) or a const-array name. This
# rejects state (array_var_info names), scalar params, live forcing (pgather),
# non-inlined observeds, and — explicitly, since `_compile` maps the NAME "t"
# to `_NK_TIME` and `_CellEval` evaluates at t=0.0, which would be SILENTLY
# wrong — anything called "t". Over-acceptance is safe: the compile attempt in
# `_cell_evaluator` is wrapped in try/catch and any failure
# restores the original whole-equation decline. Field coverage mirrors
# `_scan_refs_idxset` (args / lower / upper / expr_body / filter / key /
# values / ranges bounds), so nothing an expression can carry
# slips through unchecked; `bindings` (pre-lowered template sugar) is
# conservatively rejected outright. Cold path — once per offending subtree
# per branch template, never per cell.
function _exprtbl_evaluable(
        e::ASTExpr, bound::Set{String},
        const_arrays::AbstractDict
    )::Bool
    (e isa NumExpr || e isa IntExpr) && return true
    if e isa VarExpr
        nm = (e::VarExpr).name
        nm == "t" && return false
        return nm in bound || haskey(const_arrays, nm)
    end
    o = e::OpExpr
    o.bindings === nothing || return false
    # Binders this node introduces (checked against "t" too — a binder named
    # "t" could shadow the time guard above).
    binders = String[]
    if o.ranges !== nothing
        for (k, rv) in o.ranges
            nm = String(k)
            nm == "t" && return false
            push!(binders, nm)
            if rv isa AbstractVector
                for x in rv
                    # Range BOUNDS evaluate in the OUTER scope.
                    x isa ASTExpr && !_exprtbl_evaluable(x, bound, const_arrays) &&
                        return false
                end
            end
        end
    end
    if o.output_idx !== nothing
        for s in o.output_idx
            s isa AbstractString || continue
            String(s) == "t" && return false
            push!(binders, String(s))
        end
    end
    inner = isempty(binders) ? bound : union(bound, binders)
    chk(x) = x === nothing || _exprtbl_evaluable(x, inner, const_arrays)
    for a in _operands(o)
        chk(a) || return false
    end
    (
        chk(o.lower) && chk(o.upper) && chk(o.expr_body) && chk(o.filter) &&
            chk(o.key)
    ) || return false
    if o.values !== nothing
        for v in o.values
            chk(v) || return false
        end
    end
    return true
end

# The rescue proper: emit a `LANE_EXPRTBL` recipe for a loop-var-dependent
# subtree the stencil vocabulary cannot model, or `nothing` to throw. Array
# producers are excluded (this is a scalar position; an array-valued subtree
# here is ill-formed and keeps its error).
# TALLY: one `:affine_subtree_tbl` increment PER RESCUED SUBTREE LANE PER
# BRANCH TEMPLATE (bounded by structural groups — grid-independent; the smemo
# in `_stencilize` dedupes a shared subtree within one walk), NOT per
# equation; it increments even when the equation later declines for another
# construct, so it counts rescue FIRINGS, not final cascade routing (that is
# `:affine` / `:percell_acc`).
function _try_exprtbl_lane(e::OpExpr, ctx::_StencilCtx)
    _is_array_producer(e) && return nothing
    _exprtbl_evaluable(e, ctx.idxset, ctx.const_arrays) || return nothing
    names = sort!(collect(ctx.idxset))
    push!(
        ctx.recipes, _LaneRecipe(
            LANE_EXPRTBL, "", ASTExpr[], Int[], Int[],
            _ExprTblSpec(e, names, nothing), ""
        )
    )
    _tally_cascade!(:affine_subtree_tbl)
    return VarExpr(_lane_name(length(ctx.recipes)))
end

# Attach the compiled evaluator to every not-yet-attached `LANE_EXPRTBL`
# recipe — called from the two places recipe vectors are finalized
# (`_build_branch_template` and the variant compile in `_stencilize_shared`).
# Loop indices bind as parameters; scalar
# params are deliberately ABSENT (`_EMPTY_PARAMS`) — the evaluability contract
# is loop indices + literals + const arrays only. A compile failure (an op
# `_compile` cannot evaluate, an unresolvable gather, a loop index named "t")
# throws the whole-equation `_Decline` the rescue displaced — the
# original decline, one hop later.
function _attach_exprtbl_evals!(
        rs::Vector{_LaneRecipe},
        const_arrays::AbstractDict
    )
    for r in rs
        r.kind == LANE_EXPRTBL || continue
        spec = r.arr::_ExprTblSpec
        spec.ce === nothing || continue
        ce = _cell_evaluator(
            spec.expr, spec.idx_names, const_arrays, _EMPTY_PARAMS; index_outputs = true
        )
        ce === nothing && _decline(
            :subtree_table_declined,
            "op '" * (spec.expr isa OpExpr ? (spec.expr::OpExpr).op : string(typeof(spec.expr))) * "'"
        )
        spec.ce = ce
    end
    return rs
end

# `index(<producer|var>, k…)`. Var gathers (state / pgather / const) become lane
# recipes; `index(makearray|aggregate, …)` is unwrapped symbolically (region
# selected via `ctx.idx_env`, aggregate output indices bound to the — still
# symbolic — `k` argument expressions). Mirrors the `_resolve_indices` `index`
# branch and its `_resolve_index_of_{makearray,faq}` helpers; anything not
# modelled falls back.
function _stencilize_index(e::OpExpr, ctx::_StencilCtx)
    isempty(e.args) && _decline(:malformed_index)
    first_arg = e.args[1]
    idx_args = e.args[2:end]
    if first_arg isa OpExpr && (_is_faq_op(first_arg.op) || first_arg.op == "makearray")
        return _stencilize_indexed(first_arg::OpExpr, idx_args, ctx)
    end
    # A lane resolves its subscripts per cell through `_eval_const_int`, so
    # every subscript must be an integer function of the loop indices and
    # build-time tables. A subscript that is not (a gather through an array
    # producer, a parameter, a state) is no lane: a const read whose whole
    # subtree is build-time data becomes a value-table lane, and anything else
    # declines the equation to the tiers that gather at run time.
    if !all(a -> _lane_subscript_static(a, ctx.idxset, ctx.const_arrays), idx_args)
        if first_arg isa OpExpr && (first_arg::OpExpr).op == "const" ||
                first_arg isa VarExpr && haskey(ctx.const_arrays, first_arg.name)
            lane = _try_exprtbl_lane(e, ctx)
            lane === nothing || return lane
        end
        _decline(:subscript_not_static, "a subscript of '$(first_arg isa VarExpr ? first_arg.name : "?")'")
    end
    if first_arg isa VarExpr && haskey(ctx.array_var_info, first_arg.name)
        lo, hi = ctx.array_var_info[first_arg.name]
        length(idx_args) == length(lo) ||
            _decline(:subscript_rank_mismatch, "state array '$(first_arg.name)'")
        push!(
            ctx.recipes, _LaneRecipe(
                LANE_STATE, first_arg.name, idx_args,
                copy(lo), copy(hi), nothing, ""
            )
        )
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    if first_arg isa VarExpr && haskey(ctx.pgather, first_arg.name)
        pg = ctx.pgather[first_arg.name]::_PGatherArray
        length(idx_args) == length(pg.dims) ||
            _decline(:subscript_rank_mismatch, "parameter array '$(first_arg.name)'")
        push!(
            ctx.recipes, _LaneRecipe(
                LANE_PGATHER, first_arg.name, idx_args,
                Int[], Int[], pg, ""
            )
        )
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    if first_arg isa VarExpr && haskey(ctx.const_arrays, first_arg.name)
        arr = ctx.const_arrays[first_arg.name]
        length(idx_args) == ndims(arr) ||
            _decline(:subscript_rank_mismatch, "const array '$(first_arg.name)'")
        push!(
            ctx.recipes, _LaneRecipe(
                LANE_CONST, first_arg.name, idx_args,
                Int[], Int[], arr, ""
            )
        )
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    # An INLINE `const` array literal, `index({op:const, value:[…]}, k…)`, is a
    # const-array lane like a registered one: interned under the content-hashed
    # name the resolver gives it (`_intern_inline_const`), so this lane, the
    # per-cell resolve and the whole-array nest read one array under one name
    # and one boundary policy. A contraction's run-time fold reads it at the
    # contracted index this way.
    if first_arg isa OpExpr && (first_arg::OpExpr).op == "const" &&
            (first_arg::OpExpr).value isa AbstractVector
        arr, cname = _intern_inline_const(first_arg::OpExpr, ctx.const_arrays)
        haskey(ctx.const_arrays, cname) ||
            _decline(:unknown_array, "an inline const array outside a const registry")
        length(idx_args) == ndims(arr) ||
            _decline(:subscript_rank_mismatch, "an inline const array")
        push!(
            ctx.recipes, _LaneRecipe(
                LANE_CONST, cname, idx_args,
                Int[], Int[], arr, ""
            )
        )
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    # COMBINATION producer: `index(a ⊕ b, k…)` where ⊕ is elementwise. Push the
    # index through to each array-valued operand — `index(a,k…) ⊕ index(b,k…)` —
    # and re-stencilize. This mirrors the branch `_resolve_indices` already
    # carries (resolve.jl, the §4.3.4 name-aligned note) for the SAME motivating
    # shape, `divh = D(Mx,lon) + D(My,lat)` inlining to `+(makearray, makearray)`.
    # The two single-node producers are handled above; the resolver closes this
    # combination case and the affine build did not, so an equation whose RHS
    # ADDS two lowered stencils — reseact's air-mass continuity,
    # `D(m)/dt = -(divh_fix + D(Mz,lev))` — declined here and fell back to the
    # per-cell tier, one kernel per cell, O(#cells) IR. Distribution is sound for
    # any `_is_scalar_op` (registry categories applicable elementwise).
    if first_arg isa OpExpr && _is_scalar_op((first_arg::OpExpr).op)
        fa = first_arg::OpExpr
        # `_index_pushdown_arrayish` (build_helpers.jl) is the resolver's operand
        # test, shared verbatim: it looks THROUGH nested elementwise ops, so a
        # folded elementwise array observed (`index(1 + cos(pi*zc), j)`) pushes
        # down here too rather than declining to the per-cell tier.
        _leaf_is_array(n) = haskey(ctx.array_var_info, n) || haskey(ctx.pgather, n) ||
            (
            haskey(ctx.const_arrays, n) &&
                !_is_scalar_const_field(ctx.const_arrays[n])
        )
        _amemo = IdDict{OpExpr, Bool}()
        _arrayish(a) = _index_pushdown_arrayish(a, _leaf_is_array, _amemo)
        if _anyof(_arrayish, fa.args)
            pushed = ASTExpr[
                _arrayish(a) ? OpExpr("index", ASTExpr[a, idx_args...]) : a
                    for a in fa.args
            ]
            return _stencilize(reconstruct(fa; args = pushed), ctx)
        end
    end
    # Name the producer: "some var is not an array" is not actionable, and the
    # thing that failed to resolve is exactly what you need to see.
    return _decline(
        :unknown_array,
        first_arg isa VarExpr ? "'$(first_arg.name)'" :
            first_arg isa OpExpr ?
            "producer op '$((first_arg::OpExpr).op)' :: " *
            first(sprint(show, first_arg), 160) :
            "non-var $(typeof(first_arg))"
    )
end

# Whether `_eval_const_int` evaluates subscript `e` at a cell from the loop
# indices (`idxset`) and build-time tables alone: integer literals, loop
# names, the integer ops it implements, and gathers from a const array (by
# name or inline) at such subscripts. Anything else (an array producer, a
# name that is not a loop index) leaves `_eval_const_int` without a value.
const _LANE_SUBSCRIPT_OPS = Set(keys(_SUBSCRIPT_OPS))
function _lane_subscript_static(
        e::ASTExpr, idxset::Set{String},
        const_arrays::AbstractDict
    )::Bool
    e isa IntExpr && return true
    e isa NumExpr && return isinteger((e::NumExpr).value)
    e isa VarExpr && return (e::VarExpr).name in idxset
    e isa OpExpr || return false
    o = e::OpExpr
    if o.op == "index"
        isempty(o.args) && return false
        h = o.args[1]
        (
            h isa VarExpr && haskey(const_arrays, (h::VarExpr).name) ||
                h isa OpExpr && (h::OpExpr).op == "const" && (h::OpExpr).value isa AbstractVector
        ) ||
            return false
        for k in 2:length(o.args)
            _lane_subscript_static(o.args[k], idxset, const_arrays) || return false
        end
        return true
    elseif o.op == "const"
        return o.value isa Real && !(o.value isa Bool)
    elseif o.op in _LANE_SUBSCRIPT_OPS
        return _allof(a -> _lane_subscript_static(a, idxset, const_arrays), o.args)
    end
    return false
end

# Symbolically index an array producer at `kargs`. For a `makearray`, select the
# covering region via `ctx.idx_env` and recurse into its value (a full-rank
# producer, or a scalar value used directly). For a non-contracting `faq`,
# bind its output indices to `kargs` and stencilize the body. Contraction /
# joins / filters / reduced-rank region values are NOT modelled — fall back.
function _stencilize_indexed(producer::OpExpr, kargs::Vector{ASTExpr}, ctx::_StencilCtx)
    if producer.op == "makearray"
        kvals = Int[_eval_const_int(a, ctx.idx_env, ctx.const_arrays) for a in kargs]
        r, region = _select_region(producer, kvals)
        r == 0 && return NumExpr(0.0)   # no region covers → makearray default
        sel = _bind_makearray_loop(producer, producer.values[r], kargs)
        if _is_array_producer(sel)
            re = sel::OpExpr
            rank = _producer_rank(re)
            rank == length(kargs) && return _stencilize_indexed(re, kargs, ctx)
            # §9.6.8 REDUCED-RANK region value: the value array covers the
            # region's NON-SINGLETON axes (a face/strip region pins the others
            # to a single line), so the value is indexed at the non-singleton
            # k-args only — mirroring `_resolve_index_of_makearray` exactly.
            # The pinned axes need no verification: region coverage already
            # fixed their k-values to the singleton bound.
            ns = region === nothing ? Int[] :
                _region_value_axes(rank, length(kargs), d -> region[d][1] == region[d][2])
            rank == length(ns) ||
                _decline(
                :region_value_shape,
                "region $r value op '$(re.op)' rank $rank vs $(length(ns)) " *
                    "non-singleton of $(length(kargs)) index args" *
                    (re.op == "makearray" ? "" : ", output_idx $(re.output_idx)")
            )
            return _stencilize_indexed(re, kargs[ns], ctx)
        end
        return _stencilize(sel, ctx)
    end
    # aggregate / faq
    (producer.join_gates === nothing && producer.filter === nothing) ||
        _decline(
        producer.join_gates === nothing ? :filtered_reduction : :gated_reduction,
        "a gathered reduction"
    )
    oi_raw = producer.output_idx === nothing ? Any[] : producer.output_idx
    oi = String[String(s) for s in oi_raw if s isa AbstractString]
    length(oi) == length(kargs) ||
        _decline(:gathered_reduction_shape, "$(length(oi)) output indices, $(length(kargs)) subscripts")
    ranges = _ranges_dict(producer)
    body = producer.expr_body
    body === nothing && _decline(:gathered_reduction_shape, "no body")
    cnames = _contracted_index_names(ranges, oi)
    if !isempty(cnames)
        # CONSTANT-bound contraction: unroll into the same ⊕-combined term list
        # the per-cell reference builds (`_resolve_index_of_faq` →
        # `_foreach_aggregate_term` + `_combine_with_reducer`), so the fold
        # SHAPE, term order, and reducer chaining are byte-identical — the box
        # processor then lowers the unrolled body like any elementwise tree.
        # Output-index binding happens after the unroll here (the reference
        # binds first); leaf substitutions on disjoint name sets commute, so
        # the trees are identical. A non-constant bound could vary the term
        # set across the box (it may reference an output index), so only fully
        # constant dense ranges are modelled — same gate as the branch-key
        # walk (`_branch_key_indexed!`), which keeps key and spine in
        # lockstep. NOTE: the per-term `_sub_preserving` detaches nested
        # expansion roots from `tctx.sites` (they re-fuse, costing only
        # compile sharing, never correctness) — same behavior as the
        # top-level `_unrolled_contraction_body` path.
        citers = Vector{Int}[]
        for n in cnames
            raw = ranges[n]
            (raw isa AbstractVector && _is_const_int_range(raw)) ||
                _decline(:ragged_contraction, "contracted index '$n' of a gathered reduction")
            push!(citers, collect(_expand_int_range(raw)))
        end
        oplus, zerobar = _aggregate_oplus_identity(producer.semiring, producer.reduce)
        terms = ASTExpr[]
        _foreach_aggregate_term(
            body, cnames, citers, nothing, nothing,
            zerobar
        ) do term
            push!(terms, term)
        end
        body = _combine_with_reducer(oplus, zerobar, terms)
        _tally_cascade!(:stencil_indexed_contraction_unroll)
    end
    idx_exprs = Dict{String, ASTExpr}(oi[d] => kargs[d] for d in 1:length(oi))
    sub_body = _sub_preserving(body, idx_exprs)
    return _stencilize(sub_body, ctx)
end

# Does `e` reference any loop index in `idxset`? EXHAUSTIVE over every
# expression-bearing field of `OpExpr` (args / expr_body / lower / upper /
# filter / key / values / ranges bounds, the `child_exprs` field set), so a loop
# index buried in an aggregate body or a reduction bound routes that op to the
# fallback and is never mis-seen as loop-invariant. Memoized by node identity:
# `idxset` is fixed per build, so the answer is a pure function of the node, and
# a shared subtree is scanned once. Short-circuits on the first hit.
_child_refs_idxset(x::VarExpr, idxset::Set{String}, ::IdDict{OpExpr, Bool}) = x.name in idxset
_child_refs_idxset(::NumExpr, ::Set{String}, ::IdDict{OpExpr, Bool}) = false
_child_refs_idxset(::IntExpr, ::Set{String}, ::IdDict{OpExpr, Bool}) = false
_child_refs_idxset(x::OpExpr, idxset::Set{String}, memo::IdDict{OpExpr, Bool}) =
    _refs_idxset(x, idxset, memo)
function _refs_idxset(e::OpExpr, idxset::Set{String}, memo::IdDict{OpExpr, Bool})
    cached = get(memo, e, nothing)
    cached === nothing || return cached
    r = _scan_refs_idxset(e, idxset, memo)
    memo[e] = r
    return r
end
# Same field set / order as `child_exprs`, but returns as soon as any child refers
# to a loop index (no Set, no `child_exprs` vector, no closure).
function _scan_refs_idxset(e::OpExpr, idxset::Set{String}, memo::IdDict{OpExpr, Bool})
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

# The visited set of one `_branch_key!` walk. Each walk takes a new token and a
# node counts as visited when its entry holds the current token, so the table
# keeps its size across walks (emptying an `IdDict` shrinks it back to its
# smallest size, and the next walk would regrow and rehash it), and starting a
# walk allocates one small object. Which nodes a walk enters, and in which
# order, does not depend on the reuse.
#
# A walk nested inside another (a producer's body gathered under its own
# bindings) needs a set of its own while the outer walk is still live:
# `_seen_nested!` hands out the one set kept for that depth, restarted, so the
# nested walks at a depth reuse one table across bindings, cells and
# contracted-index tuples.
mutable struct _SeenSet
    d::IdDict{OpExpr, Any}
    tok::Base.RefValue{Nothing}
    nested::Union{Nothing, _SeenSet}
end
_SeenSet() = _SeenSet(IdDict{OpExpr, Any}(), Ref(nothing), nothing)
_seen_restart!(s::_SeenSet) = (s.tok = Ref(nothing); s)
function _seen_nested!(s::_SeenSet)
    c = s.nested
    c === nothing && (c = s.nested = _SeenSet())
    return _seen_restart!(c)
end
# Whether `e` was visited in this walk; marks it visited if not.
@inline function _seen_visit!(s::_SeenSet, e::OpExpr)
    tok = s.tok
    get(s.d, e, nothing) === tok && return true
    s.d[e] = tok
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
# IDENTITY-DEDUPED traversal: `seen` (fresh per top-level call, i.e.
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
function _branch_key!(
        io::IOBuffer, e, idxset::Set{String}, idx_env, const_arrays,
        memo::IdDict{OpExpr, Bool},
        seen::_SeenSet = _SeenSet(),
        segs::Dict{Any, Int} = Dict{Any, Int}()
    )
    e isa OpExpr || return
    _refs_idxset(e, idxset, memo) || return
    _seen_visit!(seen, e) && return
    if e.op == "index" && !isempty(e.args)
        fa = e.args[1]
        if fa isa OpExpr && (fa.op == "makearray" || _is_faq_op(fa.op))
            _branch_key_indexed!(io, fa::OpExpr, e.args[2:end], idxset, idx_env, const_arrays, memo, seen, segs)
            return
        end
        # `index(a ⊕ b, k…)`: `_stencilize_index` pushes the gather into the
        # operands, so a producer among them selects its region at `k…`, and
        # the key must see that selection where the spine makes it.
        if fa isa OpExpr && _is_scalar_op((fa::OpExpr).op) &&
                _reaches_indexable_producer(fa::OpExpr)
            _branch_key_pushdown!(
                io, fa::OpExpr, e.args[2:end], idxset, idx_env,
                const_arrays, memo, seen, segs
            )
            for k in 2:length(e.args)
                _branch_key!(io, e.args[k], idxset, idx_env, const_arrays, memo, seen, segs)
            end
            return
        end
    end
    # A short scalar contraction is unrolled by the spine (`_stencilize_op_core`),
    # its contracted indices bound term by term: key it the same way, so a
    # region select at a contracted index is keyed at each of its values.
    if _is_short_scalar_contraction(e)
        _branch_key_indexed!(io, e, ASTExpr[], idxset, idx_env, const_arrays, memo, seen, segs)
        return
    end
    for a in e.args
        _branch_key!(io, a, idxset, idx_env, const_arrays, memo, seen, segs)
    end
    e.expr_body !== nothing && _branch_key!(io, e.expr_body, idxset, idx_env, const_arrays, memo, seen, segs)
    # A template call's arguments are read in this spine (call.jl).
    if e.bindings !== nothing
        for k in sort!(collect(keys(e.bindings)))
            _branch_key!(io, e.bindings[k], idxset, idx_env, const_arrays, memo, seen, segs)
        end
    end
    return if e.values !== nothing
        for v in e.values
            _branch_key!(io, v, idxset, idx_env, const_arrays, memo, seen, segs)
        end
    end
end

# An `faq` with no output index, no filter and no join (a scalar reduction)
# whose ranges are all constant and dense, with fewer terms than the
# contraction loop's floor: the one the affine spine unrolls.
function _is_short_scalar_contraction(e::OpExpr)
    (
        _is_faq_op(e.op) && e.expr_body !== nothing && e.join_gates === nothing &&
            e.filter === nothing && !_is_array_producer(e)
    ) || return false
    n = 1
    for v in values(_ranges_dict(e))
        (v isa AbstractVector && _is_const_int_range(v)) || return false
        n *= length(_expand_int_range(v))
    end
    return n < _contraction_loop_min()
end

# Whether an elementwise operand tree holds an array producer that a gather
# pushed through it (`_stencilize_index`) would index.
function _reaches_indexable_producer(e::OpExpr)
    (e.op == "makearray" || _is_array_producer(e)) && return true
    _is_scalar_op(e.op) || return false
    return _anyof(a -> a isa OpExpr && _reaches_indexable_producer(a::OpExpr), e.args)
end

# The key of `index(fa, kargs…)` for an elementwise `fa`: each producer operand
# keyed as gathered at `kargs`, nested elementwise operands followed, and every
# other operand keyed as it stands.
function _branch_key_pushdown!(
        io::IOBuffer, fa::OpExpr, kargs::Vector{ASTExpr},
        idxset::Set{String}, idx_env, const_arrays,
        memo::IdDict{OpExpr, Bool}, seen::_SeenSet,
        segs::Dict{Any, Int}
    )
    for a in fa.args
        a isa OpExpr || continue
        ao = a::OpExpr
        if ao.op == "makearray" || _is_array_producer(ao)
            _branch_key_indexed!(io, ao, kargs, idxset, idx_env, const_arrays, memo, seen, segs)
        elseif _is_scalar_op(ao.op)
            _branch_key_pushdown!(io, ao, kargs, idxset, idx_env, const_arrays, memo, seen, segs)
        else
            _branch_key!(io, ao, idxset, idx_env, const_arrays, memo, seen, segs)
        end
    end
    return
end

function _branch_key_indexed!(
        io::IOBuffer, producer::OpExpr, kargs::Vector{ASTExpr},
        idxset::Set{String}, idx_env, const_arrays,
        memo::IdDict{OpExpr, Bool}, seen::_SeenSet,
        segs::Dict{Any, Int}
    )
    if producer.op == "makearray"
        kvals = Int[_eval_const_int(a, idx_env, const_arrays) for a in kargs]
        r, region = _select_region(producer, kvals)
        print(io, 'M', r, ';')
        r == 0 && return
        sel = _bind_makearray_loop(producer, producer.values[r], kargs)
        if _is_array_producer(sel)
            re = sel::OpExpr
            # §9.6.8 reduced-rank region value: key it at the region's
            # NON-SINGLETON k-args — the same slicing `_stencilize_indexed`
            # applies, so key and spine traversals stay in lockstep. A shape
            # neither models throws a `_Decline` in the spine build, so
            # returning here (key incomplete) can never pair with an accepted
            # spine.
            ka = kargs
            rank = _producer_rank(re)
            if rank != length(kargs)
                region === nothing && return
                ns = _region_value_axes(rank, length(kargs), d -> region[d][1] == region[d][2])
                rank == length(ns) || return
                ka = kargs[ns]
            end
            _branch_key_indexed!(io, re, ka, idxset, idx_env, const_arrays, memo, seen, segs)
        else
            _branch_key!(io, sel, idxset, idx_env, const_arrays, memo, seen, segs)
        end
        return
    end
    # aggregate / faq: recurse the body with the output indices bound in the
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
    # CONTRACTED indices are binders here too. Binding only `output_idx` left a
    # reduction index FREE, and the first site in the body needing its value — an
    # `index(makearray, …, gk)` region select — threw `E_TREEWALK_UNBOUND_LOOP_VAR`
    # out of the whole build instead of out of this tier. The motivating body is a
    # mass-weighted column integral,
    #     pbl_sum_X[gi,gj] = Σ_gk dp[gi,gj,gk] · pbl_f[gi,gj,gk] · X[gi,gj,gk]
    # whose `pbl_f` is a region-split layer-overlap expression, so `gk` reaches a
    # makearray select in every term. Only an INLINING build gets here at all
    # (`compiler=:interpreter`, or an observed excluded from materialization —
    # both emitters materialize by default): materializing the
    # observed gives the reduction its own fill equation, where the contraction
    # is top-level and never enters a branch-key walk.
    #
    # The contraction is part of the cell's branch structure — two `gk` may select
    # DIFFERENT regions — so the key covers every contracted value, in the same
    # deterministic order the unroll accumulates them. `seen` is per-value: a node
    # shared across terms must be re-keyed at each `gk` rather than suppressed
    # after the first. Key EQUALITY CLASSES still hold, because the traversal
    # remains a deterministic function of the body DAG plus the bindings.
    ranges = _ranges_dict(producer)
    cnames = _contracted_index_names(ranges, oi)
    citers = Vector{Vector{Int}}(undef, length(cnames))
    for d in eachindex(cnames)
        raw = ranges[cnames[d]]
        # Decline the tier rather than invent a key, for either shape we cannot
        # enumerate here: an unresolved `IndexSetRef` (not a dense bound vector at
        # all), or a ragged / expression-valued bound, which has no value without
        # the enclosing per-cell environment.
        raw isa AbstractVector && _is_const_int_range(raw) ||
            _decline(:ragged_contraction, "contracted index '$(cnames[d])' of a gathered reduction")
        citers[d] = collect(_expand_int_range(raw))
    end
    # ONE SEGMENT PER BINDING. Each gather walks the body afresh under its own
    # bindings (below), so a producer gathered again at the same subscripts, in
    # the same environment, prints a back-reference to the segment it printed
    # the first time instead of walking the body again: a nest of templates
    # gathered through each other costs a walk per DISTINCT binding, not per
    # path. Equal keys still mean equal selections: a back-reference names a
    # segment printed earlier in the same key, at the same place in the walk.
    skey = (objectid(producer), kvals, sort!(collect(idx_env); by = first))
    sid = get(segs, skey, 0)
    if sid != 0
        print(io, 'R', sid, ';')
        return
    end
    sub = IOBuffer()
    n = length(oi)
    saved = Vector{Union{Nothing, Int}}(undef, n)
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
    nc = length(cnames)
    csaved = Vector{Union{Nothing, Int}}(undef, nc)
    cadded = falses(nc)
    for d in 1:nc
        nm = cnames[d]
        csaved[d] = get(idx_env, nm, nothing)
        if !(nm in idxset)
            push!(idxset, nm)
            cadded[d] = true
        end
    end
    if nc == 0
        # The output indices are binders too, and the same two caches go stale
        # under them. `memo` was filled under the idxset WITHOUT this producer's
        # output names: a body read before as "references no loop index" (it
        # names only `i`, which was not yet a loop index) would be PRUNED here,
        # so a region select inside it would never reach the key. That is the
        # lifted equation `faq(index(makearray(…), i), i)`: gathered at `_lp0`,
        # its makearray picks a region per cell, but every cell keyed equal and
        # took the first cell's template, values and all, silently. So a name
        # this producer adds gets a fresh memo. `seen` is per binding for the
        # same reason as below: a node shared with another gather of this
        # producer, at other subscripts, must be keyed again at these.
        bmemo = any(added) ? IdDict{OpExpr, Bool}() : memo
        _branch_key!(
            sub, body, idxset, idx_env, const_arrays, bmemo,
            _seen_nested!(seen), segs
        )
    else
        # FRESH `_refs_idxset` memo. That memo caches, per node, whether the node
        # references `idxset` — and `idxset` just GREW by the contracted names. An
        # entry cached under the smaller set says `false` for a subtree that does
        # reference `gk`, and `_branch_key!` uses it to PRUNE: the key would then
        # omit exactly the region selections that vary with `gk`, so two cells with
        # different branch structure would key equal and merge into one affine
        # kernel — wrong, and silently. Rebuilding costs a walk on a path that only
        # inlining builds reach.
        cmemo = IdDict{OpExpr, Bool}()
        for tup in Iterators.product(citers...)
            for d in 1:nc
                idx_env[cnames[d]] = tup[d]
            end
            print(sub, 'C')
            _branch_key!(
                sub, body, idxset, idx_env, const_arrays, cmemo,
                _seen_nested!(seen), segs
            )
        end
    end
    for d in nc:-1:1
        nm = cnames[d]
        old = csaved[d]
        old === nothing ? delete!(idx_env, nm) : (idx_env[nm] = old)
        cadded[d] && delete!(idxset, nm)
    end
    for d in n:-1:1
        nm = oi[d]
        old = saved[d]
        old === nothing ? delete!(idx_env, nm) : (idx_env[nm] = old)
        added[d] && delete!(idxset, nm)
    end
    segs[skey] = length(segs) + 1
    print(io, 'S', length(segs), '{')
    write(io, take!(sub))
    return print(io, '}')
end

# Lane sentinels: lane k maps to the slot `-k`, decoded by `_lower_to_access`.
function _ext_var_map(var_map::AbstractDict{String, Int}, recipes::Vector{_LaneRecipe})
    isempty(recipes) && return var_map
    ext = Dict{String, Int}()
    for k in eachindex(recipes)
        ext[_lane_name(k)] = -k
    end
    return _VarMapOverlay(ext, var_map)
end

# Evaluate one lane recipe for the current cell (`idx_env`). Byte-for-byte the
# `_resolve_indices` outcome for that leaf: a STATE slot (≥1), 0 for a ghost cell,
# a linear PGATHER offset, or a folded const / loop-index literal.
function _eval_recipe(
        rec::_LaneRecipe, idx_env::Dict{String, Int},
        var_map::AbstractDict{String, Int}, const_arrays::AbstractDict
    )
    if rec.kind == LANE_LOOPLIT
        return Float64(idx_env[rec.loop_name])
    end
    if rec.kind == LANE_EXPRTBL
        # Rescued build-time-evaluable subtree: rebind the loop indices on the
        # compile-once evaluator (`_CellEval` binds them as Float64 params —
        # bit-identical to the per-cell path's literal fold, see the rescue
        # header above). `ce::Any` costs a dynamic dispatch, but this runs only
        # inside `_materialize_const_box`'s O(box cells) sweep — the same cost
        # class as the state/pgather table materializers — never per eval.
        spec = rec.arr::_ExprTblSpec
        ce = spec.ce
        ce === nothing && _decline(:subtree_table_declined, "evaluated before its evaluator was attached")
        cell = Vector{Int}(undef, length(spec.idx_names))
        @inbounds for d in eachindex(spec.idx_names)
            cell[d] = idx_env[spec.idx_names[d]]
        end
        return (ce(cell))::Float64
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
            inds[d] = _resolve_const_index(
                arr, rec.var_name, d,
                _eval_const_int(rec.idx_args[d], idx_env, const_arrays),
                size(arr, d)
            )
        end
        return Float64(arr[inds...])
    else  # LANE_PGATHER
        pg = rec.arr::_PGatherArray
        inds = Vector{Int}(undef, n)
        @inbounds for d in 1:n
            v = _eval_const_int(rec.idx_args[d], idx_env, const_arrays)
            (1 <= v <= pg.dims[d]) ||
                throw(
                TreeWalkError(
                    "E_TREEWALK_PGATHER_OOB",
                    "forcing array '$(rec.var_name)' index $(v) out of range " *
                        "[1, $(pg.dims[d])] on dim $(d)"
                )
            )
            inds[d] = v
        end
        return LinearIndices(Tuple(pg.dims))[inds...]
    end
end

# ---- Compiled lane evaluation (the per-box table materializers) ------------
# `_eval_recipe` reads the loop indices out of a `Dict` environment and walks the
# subscript trees through `_eval_const_int` for every cell. A table materializer
# evaluates one recipe at every cell of a box, so it compiles the recipe once:
# the subscripts become an `_IdxNode` tree over loop POSITIONS, a const gather
# holds its array's flat data, and a state slot comes from the layout block. The
# integer arithmetic is `_eval_const_int`'s, operation for operation. Anything
# the compiled form does not cover — an out-of-range const subscript (a boundary
# policy or an error), a missing cell, a value that does not convert — reports
# `ok = false` for that cell, which then takes `_eval_recipe` itself, so the
# table and every error are exactly the per-cell resolution's.

const _IX_LIT, _IX_LOOP, _IX_OP, _IX_GATHER = Int8.(1:4)

struct _IdxNode
    kind::Int8
    val::Int                    # literal, or loop position
    op::Symbol                  # `_IX_OP`: the subscript operator (`_SUBSCRIPT_OPS`)
    args::Vector{_IdxNode}
    flat::Vector{Float64}       # gather: the const array's data, column-major
    dims::Vector{Int}
    _IdxNode(kind, val, op, args, flat, dims) = _new_typed(_IdxNode, kind, val, op, args, flat, dims)
end
_def_new_typed(_IdxNode)
_IdxNode(kind::Int8, val::Int, args::Vector{_IdxNode} = _IdxNode[]) =
    _IdxNode(kind, val, Symbol(""), args, Float64[], Int[])
_IdxNode(op::Symbol, args::Vector{_IdxNode}) =
    _IdxNode(_IX_OP, 0, op, args, Float64[], Int[])

# The `_IdxNode` form of an index expression, or `nothing` when some part of it
# is outside what `_ix_eval` models (the caller keeps `_eval_const_int`).
# An operator compiles when it is a subscript operator applied at an arity it
# admits (`_SUBSCRIPT_OPS`); a wrong arity is left to `_eval_const_int` to refuse.
function _ix_compile(e::ASTExpr, idx_names::Vector{String}, const_arrays::AbstractDict)
    if e isa IntExpr
        return _IdxNode(_IX_LIT, Int(e.value))
    elseif e isa NumExpr
        v = e.value
        (isinteger(v) && -9.0e18 <= v <= 9.0e18) || return nothing
        return _IdxNode(_IX_LIT, Int(v))
    elseif e isa VarExpr
        pos = findfirst(==(e.name), idx_names)
        return pos === nothing ? nothing : _IdxNode(_IX_LOOP, pos)
    elseif e isa OpExpr
        op = e.op
        c = e.args
        if op == "index"
            (length(c) >= 2 && c[1] isa VarExpr) || return nothing
            arr = get(const_arrays, (c[1]::VarExpr).name, nothing)
            data = arr isa BoundedConstArray ? arr.data : arr
            (data isa Array{Float64} && ndims(data) == length(c) - 1) || return nothing
            xs = _IdxNode[]
            for a in @view c[2:end]
                x = _ix_compile(a, idx_names, const_arrays)
                x === nothing && return nothing
                push!(xs, x)
            end
            return _IdxNode(_IX_GATHER, 0, Symbol(""), xs, vec(data), collect(Int, size(data)))
        end
        ar = get(_SUBSCRIPT_OPS, op, nothing)
        (ar !== nothing && length(c) in ar) || return nothing
        xs = _IdxNode[]
        for a in c
            x = _ix_compile(a, idx_names, const_arrays)
            x === nothing && return nothing
            push!(xs, x)
        end
        return _IdxNode(Symbol(op), xs)
    end
    return nothing
end

# `(value, ok)`: `_eval_const_int` of the compiled expression at loop values
# `loop`, or `ok = false` where that call would throw or apply a boundary policy.
function _ix_eval(n::_IdxNode, loop::Vector{Int})::Tuple{Int, Bool}
    k = n.kind
    k === _IX_LIT && return (n.val, true)
    k === _IX_LOOP && return (@inbounds(loop[n.val]), true)
    a = n.args
    if k === _IX_GATHER
        lin = 0
        stride = 1
        for d in eachindex(a)
            v, ok = _ix_eval(a[d], loop)
            (ok && 1 <= v <= n.dims[d]) || return (0, false)
            lin += (v - 1) * stride
            stride *= n.dims[d]
        end
        x = round(@inbounds(n.flat[lin + 1]))
        (isfinite(x) && -9.0e18 <= x <= 9.0e18) || return (0, false)
        return (Int(x), true)
    end
    # An operator: the shared integer meaning (`_subscript_eval_op`). A failure
    # (an out-of-range gather below, a zero divisor, an inexact quotient)
    # reports `ok = false`, and the caller's `_eval_const_int` raises it.
    ok = Ref(true)
    ev(x::_IdxNode) = (r = _ix_eval(x, loop); r[2] || (ok[] = false); r[1])
    quot(x::_IdxNode) = (x.kind === _IX_OP && x.op === :/) ? x.args : nothing
    op = n.op
    if op === :/ || op === :mod || ((op === :floor || op === :ceil) && quot(a[1]) !== nothing)
        q = op === :/ || op === :mod ? a : quot(a[1])
        x = ev(q[1]); y = ev(q[2])
        (ok[] && y != 0) || return (0, false)
        (op === :/ && rem(x, y) != 0) && return (0, false)
        v = op === :/ ? div(x, y) : op === :mod ? mod(x, y) :
            _subscript_rounded_quotient(op, x, y)
        return (v, true)
    end
    v = _subscript_eval_op(op, a, ev, quot)
    return ok[] ? (v::Int, true) : (0, false)
end

"""
    _LaneEval

A recipe compiled for evaluation at many cells (see the section header):
`_lane_eval(le, loop)` is `(value, ok)`, with `value` what `_eval_recipe`
returns at that cell whenever `ok`.
"""
struct _LaneEval{M}
    kind::_LaneKind
    args::Vector{_IdxNode}
    lo::Vector{Int}
    hi::Vector{Int}
    affine::Union{Nothing, Tuple{Int, Vector{Int}}}
    blk::Union{Nothing, _ArrayBlock}     # LANE_STATE with no affine map
    var_map::M
    var_name::String
    flat::Vector{Float64}               # LANE_CONST data / LANE_PGATHER extents
    dims::Vector{Int}
    loop_pos::Int                       # LANE_LOOPLIT
    cell::Vector{Int}
end

# `nothing` when the recipe (or one of its subscripts) has no compiled form.
#
# `ixmemo`, when given, holds the compiled form of every subscript expression
# already compiled under the same `idx_names` and `const_arrays` (one that has
# none is compiled again when asked). An `_IdxNode` is immutable and `_ix_eval` reads it
# without writing, so evaluators share one; the lanes of every branch template
# of an equation subscript with the same expression objects, which this
# compiles once per equation rather than once per template and lane.
function _lane_evaluator(
        rec::_LaneRecipe, idx_names::Vector{String}, var_map,
        const_arrays::AbstractDict,
        ixmemo::Union{Nothing, IdDict{OpExpr, Any}} = nothing
    )
    if rec.kind == LANE_LOOPLIT
        pos = findfirst(==(rec.loop_name), idx_names)
        pos === nothing && return nothing
        return _LaneEval(
            rec.kind, _IdxNode[], rec.lo, rec.hi, nothing, nothing, var_map,
            rec.var_name, Float64[], Int[], pos, Int[]
        )
    end
    rec.kind == LANE_EXPRTBL && return nothing
    args = _IdxNode[]
    for a in rec.idx_args
        x = ixmemo === nothing || !(a isa OpExpr) ? nothing : get(ixmemo, a, nothing)
        if x === nothing
            x = _ix_compile(a, idx_names, const_arrays)
            x === nothing && return nothing
            ixmemo === nothing || !(a isa OpExpr) || (ixmemo[a] = x)
        end
        push!(args, x::_IdxNode)
    end
    n = length(args)
    flat = Float64[]
    dims = Int[]
    blk = nothing
    if rec.kind == LANE_STATE
        rec.affine === nothing && (blk = _vm_block(var_map, rec.var_name))
    elseif rec.kind == LANE_CONST
        data = rec.arr isa BoundedConstArray ? rec.arr.data : rec.arr
        (data isa Array{Float64} && ndims(data) == n) || return nothing
        flat = vec(data)
        dims = collect(Int, size(data))
    else  # LANE_PGATHER
        pg = rec.arr::_PGatherArray
        length(pg.dims) == n || return nothing
        dims = collect(Int, pg.dims)
    end
    return _LaneEval(
        rec.kind, args, rec.lo, rec.hi, rec.affine, blk, var_map,
        rec.var_name, flat, dims, 0, Vector{Int}(undef, n)
    )
end

function _lane_eval(le::_LaneEval, loop::Vector{Int})
    k = le.kind
    k == LANE_LOOPLIT && return (Float64(@inbounds(loop[le.loop_pos])), true)
    args = le.args
    n = length(args)
    if k == LANE_STATE
        return _lane_eval_state(le, loop)
    elseif k == LANE_CONST
        lin = 0
        stride = 1
        @inbounds for d in 1:n
            v, ok = _ix_eval(args[d], loop)
            (ok && 1 <= v <= le.dims[d]) || return (0.0, false)
            lin += (v - 1) * stride
            stride *= le.dims[d]
        end
        return (@inbounds(le.flat[lin + 1]), true)
    else  # LANE_PGATHER
        lin = 0
        stride = 1
        @inbounds for d in 1:n
            v, ok = _ix_eval(args[d], loop)
            (ok && 1 <= v <= le.dims[d]) || return (0, false)
            lin += (v - 1) * stride
            stride *= le.dims[d]
        end
        return (lin + 1, true)
    end
end

# `_lane_eval` of a LANE_STATE evaluator: the slot (0 for a ghost) as an `Int`,
# so a caller that knows the kind gets a concrete result type.
function _lane_eval_state(le::_LaneEval, loop::Vector{Int})::Tuple{Int, Bool}
    args = le.args
    aff = le.affine
    ghost = false
    slot = aff === nothing ? 0 : aff[1]
    @inbounds for d in 1:length(args)
        v, ok = _ix_eval(args[d], loop)
        ok || return (0, false)
        (v < le.lo[d] || v > le.hi[d]) && (ghost = true)
        aff === nothing ? (le.cell[d] = v) : (slot += v * aff[2][d])
    end
    ghost && return (0, true)
    aff === nothing || return (slot, true)
    s = le.blk === nothing ? _vm_slot(le.var_map, le.var_name, le.cell) :
        _block_slot(le.blk, le.cell)
    return (s, s != 0)
end

# One branch's spine entry: the compiled sentinel template, its lane recipes,
# and the recipe indices that are STATE gathers (the ghost-key columns).
struct _StencilBranch
    tmpl::_Node
    recipes::Vector{_LaneRecipe}
    state_lanes::Vector{Int}
end

# A state var's affine slot map over its `[lo, hi]` box (cell indices → slot:
# `slot = base + Σ_d inds_d·strides_d`, stride 0 along a one-cell axis), so a
# gather resolves arithmetically; `nothing` when the map is not affine there,
# and `_eval_recipe` keeps the exact string lookup. A layout's block is the map
# by definition (`_affine_block`); a map with no block for the var (a plain
# `Dict`, a range view, or a block that does not cover the box) is probed at
# ~2^D + D cells and corner-verified.
function _derive_var_affine(
        var_name::String, lo::Vector{Int}, hi::Vector{Int},
        var_map::AbstractDict{String, Int}
    )
    n = length(lo)
    (n == 0 || length(hi) != n) && return nothing
    blk = _affine_block(var_map, var_name)
    if blk !== nothing && length(blk.lo) == n &&
            all(d -> blk.lo[d] <= lo[d] && hi[d] <= blk.hi[d], 1:n)
        strides = Int[hi[d] > lo[d] ? blk.strides[d] : 0 for d in 1:n]
        base = blk.base
        @inbounds for d in 1:n
            base += (lo[d] - blk.lo[d]) * blk.strides[d] - lo[d] * strides[d]
        end
        return (base, strides)
    end
    return _probe_var_affine(var_name, lo, hi, var_map)
end

function _probe_var_affine(
        var_name::String, lo::Vector{Int}, hi::Vector{Int},
        var_map::AbstractDict{String, Int}
    )
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

# Build one branch's spine template. Sentinels pass through resolve untouched
# and compile to `_NK_STATE(idx = -k)` via the extended var-map; a real
# TreeWalkError here also fires in the fallback path, so it propagates rather
# than falling back.
function _build_branch_template(
        body::ASTExpr, ctx_proto::_StencilCtx,
        var_map::AbstractDict{String, Int},
        param_sym_set
    )::_StencilBranch
    _count!(:branch_templates)
    rs = _LaneRecipe[]
    # A fresh spine memo (its entries name this template's lane recipes), but
    # the prototype's loop-index memo: whether a node reads a loop index is a
    # function of the node and `idxset` alone, and every template of the
    # equation walks the same body under the same `idxset`, so the answers one
    # template computes hold for the next. The per-cell branch-key walk
    # (`_cell_bkey!`) fills and reads the same memo.
    ctx = _StencilCtx(
        ctx_proto.idxset, rs, ctx_proto.idx_env,
        ctx_proto.array_var_info, ctx_proto.const_arrays,
        ctx_proto.pgather, IdDict{OpExpr, ASTExpr}(), ctx_proto.vsmemo
    )
    spine = _stencilize(body, ctx)
    # Attach each state gather's affine slot map (cold, once per branch) so the hot
    # per-cell `_eval_recipe` avoids the `_cell_key` String + index Vector.
    # Cache by var name: every LANE_STATE recipe for the same var shares one affine
    # map (its lo/hi are the var's array_var_info bounds), so derive it ONCE per var
    # rather than once per recipe (the derivation's `_cell_key` probes were the top
    # allocator otherwise).
    aff_cache = Dict{String, Union{Nothing, Tuple{Int, Vector{Int}}}}()
    @inbounds for k in eachindex(rs)
        r = rs[k]
        r.kind == LANE_STATE || continue
        aff = get!(
            () -> _derive_var_affine(r.var_name, r.lo, r.hi, var_map),
            aff_cache, r.var_name
        )
        aff === nothing && continue
        rs[k] = _LaneRecipe(
            r.kind, r.var_name, r.idx_args, r.lo, r.hi,
            r.arr, r.loop_name, aff
        )
    end
    # Rescued-subtree lanes: compile each spec's `_CellEval` now (once per
    # branch template, cold; a compile failure restores the whole-equation
    # decline).
    _attach_exprtbl_evals!(rs, ctx.const_arrays)
    vm_ext = _ext_var_map(var_map, rs)
    # Identity memo so `_resolve_indices` + `_compile` carry the DAG that
    # `_stencilize` now preserves straight through to the compiled `_Node`
    # template instead of re-inflating it (the `_BuildMemo` contract: forwarding it
    # only removes duplicate work, never changes a result).
    bmemo = _BuildMemo()
    tmpl = _compile(
        _resolve_indices(
            spine, ctx.array_var_info, vm_ext,
            ctx.const_arrays, ctx.pgather, bmemo
        ),
        vm_ext, param_sym_set, bmemo
    )
    return _StencilBranch(
        tmpl, rs, Int[k for k in eachindex(rs) if rs[k].kind == LANE_STATE]
    )
end
