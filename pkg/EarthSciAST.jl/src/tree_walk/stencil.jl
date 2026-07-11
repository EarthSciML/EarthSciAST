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
    idx_args::Vector{Expr}  # index-argument expressions (per-cell `_eval_const_int`)
    lo::Vector{Int}         # array_var_info bounds (LANE_STATE ghost test)
    hi::Vector{Int}
    arr::Any                # const-array values (LANE_CONST) / _PGatherArray (LANE_PGATHER)
    loop_name::String       # loop index name (LANE_LOOPLIT)
end

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

# Does `expr` reference any of the output loop indices in `idxset`? EXHAUSTIVE
# over every `Expr`-typed field of `OpExpr` via the shared `child_exprs`
# traversal (`foreach_subexpr`, expression.jl) — args / expr_body / lower /
# upper / values / filter / key / table_axes / ranges bounds — so a loop index
# buried in an aggregate body, a reduction bound, or a table-axis map routes
# that op to the fallback and is NEVER mis-seen as loop-invariant (a false
# negative would return an unsubstituted loop var to resolve → a hard build
# error instead of a fallback). Cold path — called once per branch template,
# not per cell (the per-cell guard is the memoized `_refs_idxset`).
function _refs_loop_var(e::Expr, idxset::Set{String})
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
end

# `_stencilize` transforms `expr` into the sentinel spine and appends a
# `_LaneRecipe` (to `ctx.recipes`) for every loop-var-dependent leaf.
# Loop-INVARIANT subtrees are returned verbatim (resolved/compiled once, shared).
# Throws `_StencilFallback` on any loop-var-dependent construct not modelled here.
_stencilize(e::NumExpr, ::_StencilCtx) = e
_stencilize(e::IntExpr, ::_StencilCtx) = e
function _stencilize(e::VarExpr, ctx::_StencilCtx)
    if e.name in ctx.idxset
        push!(ctx.recipes, _LaneRecipe(LANE_LOOPLIT, "", Expr[], Int[], Int[], nothing, e.name))
        return VarExpr(_lane_name(length(ctx.recipes)))
    end
    return e
end
function _stencilize(e::OpExpr, ctx::_StencilCtx)
    _refs_loop_var(e, ctx.idxset) || return e
    op = e.op
    if op == "index"
        return _stencilize_index(e, ctx)
    elseif op == "fn"
        # Closed function: recurse into the (scalar) query args; the const-array
        # table/axis args are loop-invariant and returned verbatim by recursion.
        new_args = Expr[_stencilize(a, ctx) for a in e.args]
        return reconstruct(e; args=new_args)
    elseif op in _STENCIL_ELEMENTWISE_OPS
        # Pure elementwise op — must carry no sub-expression structure (a defensive
        # guard: elementwise ops never legitimately do; if one does, fall back).
        (e.expr_body === nothing && e.values === nothing && e.ranges === nothing &&
         e.output_idx === nothing && e.filter === nothing && e.lower === nothing &&
         e.upper === nothing && e.table_axes === nothing && e.key === nothing) ||
            throw(_StencilFallback("elementwise op '$op' carries structural fields"))
        new_args = Expr[_stencilize(a, ctx) for a in e.args]
        return reconstruct(e; args=new_args)
    end
    throw(_StencilFallback("unsupported loop-var-dependent op '$op'"))
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
function _stencilize_indexed(producer::OpExpr, kargs::Vector{Expr}, ctx::_StencilCtx)
    if producer.op == "makearray"
        kvals = Int[_eval_const_int(a, ctx.idx_env, ctx.const_arrays) for a in kargs]
        r, _ = _select_region(producer, kvals)
        r == 0 && return NumExpr(0.0)   # no region covers → makearray default
        values = producer.values === nothing ? Expr[] : producer.values
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
    idx_exprs = Dict{String,Expr}(oi[d] => kargs[d] for d in 1:length(oi))
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
_accum_vars!(::Set{String}, ::NumExpr, ::IdDict{OpExpr,Set{String}}) = nothing
_accum_vars!(::Set{String}, ::IntExpr, ::IdDict{OpExpr,Set{String}}) = nothing
_accum_vars!(s::Set{String}, e::VarExpr, ::IdDict{OpExpr,Set{String}}) = (push!(s, e.name); nothing)
_accum_vars!(s::Set{String}, e::OpExpr, memo::IdDict{OpExpr,Set{String}}) =
    (union!(s, _stencil_var_set(e, memo)); nothing)
function _stencil_var_set(e::OpExpr, memo::IdDict{OpExpr,Set{String}})
    cached = get(memo, e, nothing)
    cached === nothing || return cached
    s = Set{String}()
    for c in child_exprs(e)
        _accum_vars!(s, c, memo)
    end
    memo[e] = s
    return s
end

# `_refs_loop_var(e, idxset)` without re-walking `e`: probe the small `idxset`
# against `e`'s memoized variable set. Byte-for-byte the same guard decision.
@inline function _refs_idxset(e::OpExpr, idxset::Set{String}, memo::IdDict{OpExpr,Set{String}})
    vs = _stencil_var_set(e, memo)
    for v in idxset
        v in vs && return true
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
                      memo::IdDict{OpExpr,Set{String}})
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
function _branch_key_indexed!(io::IOBuffer, producer::OpExpr, kargs::Vector{Expr},
                              idxset::Set{String}, idx_env, const_arrays,
                              memo::IdDict{OpExpr,Set{String}})
    if producer.op == "makearray"
        kvals = Int[_eval_const_int(a, idx_env, const_arrays) for a in kargs]
        r, _ = _select_region(producer, kvals)
        print(io, 'M', r, ';')
        r == 0 && return
        values = producer.values === nothing ? Expr[] : producer.values
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
                return _mkvnode(kind=_VK_PGATHER, handler=(rec.arr::_PGatherArray).flat,
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
        return _mkvnode(kind=_VK_PGATHER, handler=n.handler,
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
            return _merge_fn_node(n.handler, ch, len, length(ch))
        end
        return _mkvnode(kind=_VK_OP, op=n.op, handler=n.handler, children=ch,
                        buf=Vector{Float64}(undef, len))
    end
end

# One branch's spine entry: the compiled sentinel template, its lane recipes,
# and the recipe indices that are STATE gathers (the ghost-key columns).
const _StencilBranch = Tuple{_Node,Vector{_LaneRecipe},Vector{Int}}

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
function _build_branch_template(body::Expr, ctx_proto::_StencilCtx,
                                var_map::Dict{String,Int},
                                param_sym_set, reg_funcs)::_StencilBranch
    rs = _LaneRecipe[]
    ctx = _StencilCtx(ctx_proto.idxset, rs, ctx_proto.idx_env,
                      ctx_proto.array_var_info, ctx_proto.const_arrays,
                      ctx_proto.pgather)
    spine = _stencilize(body, ctx)
    vm_ext = _lane_var_map(var_map, rs)
    tmpl = _compile(_resolve_indices(spine, ctx.array_var_info, vm_ext,
                                     ctx.const_arrays, ctx.pgather),
                    vm_ext, param_sym_set, reg_funcs)
    return (tmpl, rs, Int[k for k in eachindex(rs) if rs[k].kind == LANE_STATE])
end

# The group-collection sweep: iterate every output cell, build each new branch's
# spine template once, evaluate the lane recipes per cell, and group cells by
# `bkey|gkey` (branch × ghost pattern — the only per-cell structural variables).
# The `_StencilFallback` rewind is LOCALIZED here: any fallback inside the sweep
# returns `nothing` (nothing observable has happened yet — `covered` is not
# touched until the commit step); a real TreeWalkError propagates, exactly as it
# would from the per-cell path.
function _collect_stencil_groups(body::Expr, idx_names::Vector{String},
                                 range_iters, lhs_var::String,
                                 lhs_idx_args::Vector{Expr},
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
    bmemo = IdDict{OpExpr,Set{String}}()
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
            _tmpl, recipes, state_ks = entry

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
        tmpl, recipes, _ = st.branch_cache[bkey]
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
function _try_symbolic_stencil(rhs_body::Expr, idx_names::Vector{String},
                               range_iters, lhs_body::OpExpr,
                               resolved_obs::Dict{String,Expr},
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
