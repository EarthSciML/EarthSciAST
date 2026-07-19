# ========================================================================
# tree_walk/stencil_affine.jl — part of the tree-walk evaluator (ess-affine).
# Included by src/tree_walk.jl AFTER stencil.jl; see that file for the layout.
#
# The POLYHEDRAL affine build: turn a lowered `makearray` rule body into a small
# set of `_AccKernel`s (access_kernel.jl) in O(#structural groups), NOT O(#cells).
# This is the replacement for the per-cell / per-branch symbolic-stencil path
# (stencil.jl), whose cost is O(#cells × body) and made the monotone-PPM build
# take tens of minutes (see esd-ess-build-oom-memoless-substitution).
#
# HOW IT WILL WORK (the box processor, built incrementally):
#   1. Reuse `_build_branch_template` (stencil.jl) to compile ONE sentinel spine
#      per structural signature — a `_Node` tree whose loop-var-dependent gather
#      leaves are `_NK_STATE(idx = -k)` placeholders (lane k ↔ `recipes[k]`).
#   2. Decompose the index space into BOXES on which the region selection, the
#      ghost pattern, and every gather's affine Δ are CONSTANT. Cut points per
#      loop dim come from region + ghost boundaries (an O(N) per-dim line sweep);
#      the product of per-dim intervals is the candidate box set.
#   3. Per box: evaluate the lane recipes at the box's REPRESENTATIVE cell to get
#      each gather's slot / const value / ghost flag, and DERIVE its access
#      descriptor by finite differences (Δ = slot(rep) − oln(rep) for state; per-
#      dim strides from unit-step differences for a const on its own grid). VERIFY
#      the derivation is uniform across the box CORNERS; if not, fall back.
#   4. Lower the sentinel spine to an access spine with `_lower_to_access` (below)
#      and emit one `_AccKernel` with the box's `_CellSet`.
#
# `_lower_to_access` is the analog of `_lower_template` (stencil.jl): same tree
# shape, but each `_NK_STATE(idx=-k)` lane leaf becomes either a literal (ghost /
# invariant-folded lane) or an `_NK_ACCESS` into a per-kernel descriptor table,
# and each invariant fixed-slot leaf (`_NK_STATE idx≥0`, `_NK_PARAM_GATHER`)
# becomes a fixed-read descriptor. Because the spine's OP structure is the exact
# `_compile` output (only leaves are swapped), the arithmetic — operand order,
# associativity, n-ary grouping — is byte-for-byte the per-cell path's, which is
# what makes the emitted kernel bit-identical.
# ========================================================================

# Per-lane lowering decision, computed by the box processor from the recipe
# values at the box's representative cell: a lane is either a constant (a ghost
# gather → 0.0, or a value that is invariant across the box) or an access
# descriptor resolved per cell at runtime.
abstract type _LaneRepl end
struct _LitRepl <: _LaneRepl
    v::Float64
end
struct _AccRepl <: _LaneRepl
    desc::_AccDesc
end

# Lower a compiled sentinel template `tmpl` to an access spine, appending each
# access leaf's descriptor to `acc` (the kernel's descriptor table, `_NK_ACCESS.idx`
# indexes it). `lane_repl[k]` is the lowering decision for lane sentinel k
# (`_NK_STATE(idx = -k)`). Non-lane leaves:
#   * `_NK_STATE(idx ≥ 0)`     invariant fixed state slot  → `_AccStateFixed`
#   * `_NK_PARAM_GATHER`       invariant forcing gather    → `_AccArrFixed`
#   * `_NK_LITERAL/PARAM/TIME`  pass through (the access evaluator handles them)
#   * `_NK_OP :fn` (interp)     op node carrying its `(fname, spec)` payload
# Anything not modelled (a contraction node) throws `_StencilFallback` so the
# caller runs the per-cell path — never a wrong kernel.
#
# IDENTITY-MEMOIZED (ESS-0hh): the compiled template is a DAG (`_stencilize` /
# `_compile` preserve sharing via their identity memos), and the lowering is a
# pure function of the node under one call's fixed `lane_repl`/`subcalls`, so
# a shared template node lowers to ONE shared access node — the per-path
# rebuild re-inflated the spine into an exponentially large tree AND pushed a
# duplicate `acc` descriptor per PATH to each access leaf. With the memo a
# shared leaf pushes its descriptor once and every parent references that
# entry; evaluation reads `acc[idx]` by index, so values are unchanged, and
# `_build_acc_cse` counts path multiplicities exactly, so CSE slot decisions
# are unchanged too. On a tree (no shared nodes) the memo never hits —
# byte-identical output, `acc` table included. The memo is per top-level
# call; `_lower_subcall` re-enters through this entry so a variant body gets
# its own memo for its own `lane_repl`.
function _lower_to_access(tmpl::_Node, lane_repl::Vector{<:_LaneRepl},
                          acc::Vector{_AccDesc},
                          subcalls::Vector{_SubCallSite}=_SubCallSite[])::_Node
    return _lower_to_access(tmpl, lane_repl, acc, subcalls, IdDict{_Node,_Node}())
end
function _lower_to_access(tmpl::_Node, lane_repl::Vector{<:_LaneRepl},
                          acc::Vector{_AccDesc}, subcalls::Vector{_SubCallSite},
                          memo::IdDict{_Node,_Node})::_Node
    cached = get(memo, tmpl, nothing)
    cached === nothing || return cached
    result = _lower_to_access_node(tmpl, lane_repl, acc, subcalls, memo)
    memo[tmpl] = result
    return result
end
function _lower_to_access_node(tmpl::_Node, lane_repl::Vector{<:_LaneRepl},
                               acc::Vector{_AccDesc}, subcalls::Vector{_SubCallSite},
                               memo::IdDict{_Node,_Node})::_Node
    k = tmpl.kind
    if k === _NK_STATE
        if tmpl.idx < 0
            r = -tmpl.idx
            r >= _SUBCALL_SENT_BASE &&
                return _lower_subcall(subcalls[r - _SUBCALL_SENT_BASE], lane_repl)
            rep = lane_repl[r]
            if rep isa _LitRepl
                return _alit(rep.v)
            else
                push!(acc, (rep::_AccRepl).desc)
                return _acc(length(acc))
            end
        else
            push!(acc, _AccStateFixed(tmpl.idx))
            return _acc(length(acc))
        end
    elseif k === _NK_LITERAL || k === _NK_PARAM || k === _NK_TIME
        return tmpl                    # evaluator reads these kinds directly
    elseif k === _NK_PARAM_GATHER
        push!(acc, _AccArrFixed(tmpl.payload::Vector{Float64}, tmpl.idx))
        return _acc(length(acc))
    elseif k === _NK_CONTRACTION
        throw(_StencilFallback("affine lowering: contraction node in template"))
    elseif k === _NK_OP
        # `payload` is carried through: `nothing` for every arithmetic op, and the
        # concrete `(fname, spec)` tuple for an interp `:fn` — the access evaluator's
        # `:fn` arm reads it exactly as `_eval_node_op` does. The fn's scalar query
        # args are ordinary children, lowered like any lane subtree.
        ch = _Node[_lower_to_access(c, lane_repl, acc, subcalls, memo)
                   for c in tmpl.children]
        return _mknode(kind=_NK_OP, op=tmpl.op, children=ch, payload=tmpl.payload)
    end
    throw(_StencilFallback("affine lowering: unhandled node kind $(Int(k))"))
end

# Lower one sub-kernel call site (compile-once template tier): slice the body's
# re-based lane lowerings out of the enclosing `lane_repl`, and get-or-build the
# variant's shared access form for that descriptor content. Two boxes (or two
# parent kernels) whose body lanes lower identically share ONE `_AccKernel`
# object — descriptor content, not box identity, is the key, mirroring the
# enclosing `spine_cache`. The body's own nested sites recurse with LOCAL
# numbering (the variant's recipes/subcalls are self-contained).
function _lower_subcall(site::_SubCallSite, lane_repl::Vector{<:_LaneRepl})::_Node
    variant, base = site
    seg = _LaneRepl[lane_repl[base + k] for k in eachindex(variant.recipes)]
    skey = _lane_repl_key(seg)
    sub = get!(variant.acc_cache, skey) do
        a = _AccDesc[]
        raw = _lower_to_access(variant.tmpl, seg, a, variant.subcalls)
        sp, cse = _build_acc_cse(raw, a)
        _AccKernel(_contig_cells(0), sp, a, _FixedBound(0), 0.0, cse,
                   _collect_subkernels(sp, cse))
    end
    return _mknode(kind=_NK_SUBCALL, payload=sub)
end

# Distinct sub-kernels reachable from a lowered spine + its CSE recipes
# (transitively, nested-first) — the runner prologue fills each one's invariant
# tier once per call. Dedup by payload identity: a shared body appears once.
function _collect_subkernels(spine::_Node, cse::_AccCSE)::Vector{_AccKernel}
    out = _AccKernel[]
    seen = IdDict{Any,Bool}()
    _collect_subkernels!(out, seen, spine)
    for r in cse.recipes
        _collect_subkernels!(out, seen, r)
    end
    for r in cse.inv_recipes
        _collect_subkernels!(out, seen, r)
    end
    return out
end
function _collect_subkernels!(out::Vector{_AccKernel}, seen::IdDict{Any,Bool}, n::_Node)
    if n.kind === _NK_SUBCALL
        S = n.payload::_AccKernel
        haskey(seen, S) && return
        seen[S] = true
        # `S.subs` already holds ITS transitive sub-kernels (built inside-out by
        # `_lower_subcall`), so splice those first — nested-first order.
        for T in S.subs
            if !haskey(seen, T)
                seen[T] = true
                push!(out, T)
            end
        end
        push!(out, S)
        return
    end
    for c in n.children
        _collect_subkernels!(out, seen, c)
    end
end

# ========================================================================
# THE BOX PROCESSOR — a rule body → Vector{_AccKernel} in O(#structural groups).
# ========================================================================
# The DEFAULT array-kernel build. Returns kernels or `nothing` (fall back to the
# existing symbolic-stencil / per-cell chain, `covered` untouched).
# `ESS_STENCIL_DISABLE=1` forces the per-cell reference — the differential-test
# escape hatch and the sole remaining switch (the old opt-in `ESS_AFFINE` was
# retired when the affine path became the default).

# Reusable caches for the per-cell signature (branch template memo + branch-key
# guard memo + a scratch IOBuffer), shared across the whole equation's sweep.
mutable struct _AffineSig
    branch_cache::Dict{String,_StencilBranch}
    bmemo::IdDict{OpExpr,Bool}
    bio::IOBuffer
    state_scratch::Vector{Int}   # reused per `_cell_ckey!` for the state-lane slots
end
_AffineSig() = _AffineSig(Dict{String,_StencilBranch}(), IdDict{OpExpr,Bool}(), IOBuffer(), Int[])

@inline _set_env!(env, idx_names, loop) =
    (for d in eachindex(idx_names); env[idx_names[d]] = loop[d]; end; env)
@inline _box_oln(base, strides, loop, D) =
    (o = base; @inbounds for d in 1:D; o += loop[d]*strides[d]; end; o)

# Output slot of a cell via the ACTUAL state layout (var_map) — the ground truth
# the affine map is verified against. `lhs_idx_args` map loop indices → the LHS
# array subscripts (usually identity `D(q[i,j,k])`).
function _oln_via_varmap(lhs_var, lhs_idx_args, idx_env, var_map)
    du_inds = Int[_eval_const_int(a, idx_env) for a in lhs_idx_args]
    slot = get(var_map, _cell_key(lhs_var, du_inds), 0)
    slot == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", _cell_key(lhs_var, du_inds)))
    return slot
end

# Derive + VERIFY the affine map (loop indices → output slot): `oln = base +
# Σ_d loop_d·strides[d]`. Strides come from unit steps off the range origin; the
# map is then checked at every domain corner against var_map. A non-affine layout
# (irregular / holey grid) fails here → whole-equation fallback.
function _derive_output_affine(lhs_var, lhs_idx_args, idx_names, ranges, var_map)
    D = length(idx_names)
    env = Dict{String,Int}()
    rep = Int[first(ranges[d]) for d in 1:D]
    oln_rep = _oln_via_varmap(lhs_var, lhs_idx_args, _set_env!(env, idx_names, rep), var_map)
    strides = zeros(Int, D)
    for d in 1:D
        if length(ranges[d]) >= 2
            l2 = copy(rep); l2[d] += 1
            strides[d] = _oln_via_varmap(lhs_var, lhs_idx_args,
                             _set_env!(env, idx_names, l2), var_map) - oln_rep
        end
    end
    base = oln_rep - _box_oln(0, strides, rep, D)
    for corner in Iterators.product(((first(ranges[d]), last(ranges[d])) for d in 1:D)...)
        cl = collect(Int, corner)
        want = _box_oln(base, strides, cl, D)
        got = _oln_via_varmap(lhs_var, lhs_idx_args, _set_env!(env, idx_names, cl), var_map)
        want == got || throw(_StencilFallback("output layout non-affine"))
    end
    return base, strides
end

# The linear index a LANE_CONST recipe reads (into the column-major flat array),
# mirroring `_eval_recipe`'s LANE_CONST index resolution exactly so
# `flat[_recipe_const_lin(...)] == _eval_recipe(...)`.
function _recipe_const_lin(rec::_LaneRecipe, idx_env, const_arrays)
    arr = rec.arr
    n = length(rec.idx_args)
    inds = Vector{Int}(undef, n)
    @inbounds for d in 1:n
        inds[d] = _resolve_const_index(arr, rec.var_name, d,
                      _eval_const_int(rec.idx_args[d], idx_env, const_arrays), size(arr, d))
    end
    return LinearIndices(size(arr))[inds...]
end

# Per-cell signature `bkey | gather_key` (region selection × gather pattern) plus
# the branch it resolves to. Builds/caches ONE sentinel template per region
# signature (the expensive step, bounded by #groups); cheap recipe evals give the
# gather key.
#
# The gather key has TWO strengths, selected by `okey`:
#   * `okey === nothing` — the historical ghost-bit key (in-bounds vs ghost per
#     state lane). Used by `_process_affine_box!`, which only needs bkey+branch.
#   * `okey = (base, strides)` (the VERIFIED output affine map) — each state
#     lane's Δ = slot − oln (or 'G' for a ghost) enters the key, so a PERIODIC
#     WRAP — where the slot legally jumps by ±N·stride with no region or ghost
#     transition — produces a signature change and therefore a CUT, giving the
#     wrap its own box exactly as the polyhedral design intends. Δ subsumes the
#     ghost bit (a ghost is 'G', any in-bounds lane its Δ).
# Const lanes with a declared BOUNDARY POLICY (BoundedConstArray) additionally
# key their per-dim fold class (in-range / clamp-low / clamp-high / wrap count),
# so a clamp/wrap transition of a const gather also produces a cut — within each
# resulting segment the resolved const index is affine again.
# Region signature (`bkey`) + its cached branch template — the part
# `_process_affine_box!` needs. Split out of `_cell_ckey!` (perf) so the per-box
# call skips the scan-only gather-delta key it would otherwise BUILD AND DISCARD
# (the state-recipe evals of lines below + a second `String`).
function _cell_bkey!(sig::_AffineSig, loop, idx_names, body, ctx_proto,
                     var_map, param_sym_set, reg_funcs)
    env = ctx_proto.idx_env
    empty!(env)
    _set_env!(env, idx_names, loop)
    _branch_key!(sig.bio, body, ctx_proto.idxset, env, ctx_proto.const_arrays, sig.bmemo)
    bkey = String(take!(sig.bio))
    branch = get(sig.branch_cache, bkey, nothing)
    if branch === nothing
        branch = _build_branch_template(body, ctx_proto, var_map, param_sym_set, reg_funcs)
        sig.branch_cache[bkey] = branch
    end
    return bkey, branch
end
function _cell_ckey!(sig::_AffineSig, loop, idx_names, body, ctx_proto,
                     var_map, param_sym_set, reg_funcs,
                     okey::Union{Nothing,Tuple{Int,Vector{Int}}}=nothing)
    bkey, branch = _cell_bkey!(sig, loop, idx_names, body, ctx_proto,
                               var_map, param_sym_set, reg_funcs)
    env = ctx_proto.idx_env    # left populated with `loop` by _cell_bkey! (branch_key restores its temp binds)
    _tmpl, recipes, state_ks, _subcalls = branch
    # Only the STATE lanes feed the gather key; evaluate just those into a reused
    # Vector{Int} (no Vector{Any}, no boxing, and no wasted non-state recipe evals).
    state_vals = sig.state_scratch
    resize!(state_vals, length(state_ks))
    @inbounds for i in eachindex(state_ks)
        state_vals[i] = _eval_recipe(recipes[state_ks[i]], env, var_map,
                                     ctx_proto.const_arrays)::Int
    end
    io = sig.bio                       # empty again after the take! above
    print(io, bkey, '|')
    if okey === nothing
        @inbounds for v in state_vals
            print(io, v == 0 ? '1' : '0')
        end
    else
        base, strides = okey
        oln = _box_oln(base, strides, loop, length(idx_names))
        @inbounds for v in state_vals
            v == 0 ? print(io, "G,") : print(io, v - oln, ',')
        end
    end
    _const_fold_key!(io, recipes, env, ctx_proto.const_arrays)
    return bkey, String(take!(io)), branch
end

# Append each policy-bearing const lane's per-dim boundary-fold class to the
# signature: '.' in-range, 'l'/'h' clamp-low/high, 'w<k>' the periodic wrap
# count (`fld(raw-1, n)` — the multiple of n the fold subtracts, so two cells
# share a class iff the resolved index is the SAME affine function of the raw
# one), 'E' an out-of-range index on an :error dim (the derive step then throws
# the exact per-cell `E_TREEWALK_CONSTARRAY_OOB`). Plain const arrays (no
# declared policy) contribute nothing: in-range indices have one class, and an
# out-of-range one throws identically on every path.
function _const_fold_key!(io::IOBuffer, recipes::Vector{_LaneRecipe}, env,
                          const_arrays)
    for rec in recipes
        rec.kind == LANE_CONST || continue
        arr = rec.arr
        arr isa BoundedConstArray || continue
        print(io, '|')
        for d in 1:length(rec.idx_args)
            v = _eval_const_int(rec.idx_args[d], env, const_arrays)
            n = size(arr, d)
            if 1 <= v <= n
                print(io, '.')
            else
                pol = _const_dim_boundary(arr, d)
                if pol === :clamp
                    print(io, v < 1 ? 'l' : 'h')
                elseif pol === :periodic
                    print(io, 'w', fld(v - 1, n))
                else
                    print(io, 'E')
                end
            end
        end
    end
    return io
end

# Probe values for a range: low / mid / high (deduplicated).
function _probe_values(rng::UnitRange{Int})
    lo, hi = first(rng), last(rng)
    unique(Int[lo, (lo + hi) ÷ 2, hi])
end

# Structural cut candidates: a per-cell signature changes at a makearray REGION
# boundary (`_select_region`), and — unlike a ghost transition — that boundary can
# sit anywhere in the range, including mid-domain, so the edge-inward scan cannot
# be relied on to reach it. Harvest every region boundary from the body up front
# (O(#regions), grid-independent) so it is probed explicitly. A boundary is mapped
# to an output dim only when its makearray is indexed by a BARE loop var there
# (the region-tiling case, e.g. PPM's seven columns and any hemisphere split);
# anything fancier is left to the edge scan + per-box corner verification.
function _collect_makearray_bounds!(cands::Vector{Set{Int}}, mk::OpExpr,
                                    kargs::Vector{ASTExpr}, idx_names::Vector{String})
    regions = mk.regions
    if regions !== nothing
        for (j, ka) in enumerate(kargs)
            ka isa VarExpr || continue
            d = findfirst(==(ka.name), idx_names)
            d === nothing && continue
            for region in regions
                j <= length(region) && length(region[j]) >= 2 || continue
                push!(cands[d], region[j][1]); push!(cands[d], region[j][2] + 1)
            end
        end
    end
    # A region's value may itself be a makearray; it inherits the same k-args.
    if mk.values !== nothing
        for v in mk.values
            v isa OpExpr && v.op == "makearray" &&
                _collect_makearray_bounds!(cands, v, kargs, idx_names)
        end
    end
end
function _region_cut_candidates(body, idx_names::Vector{String})
    cands = [Set{Int}() for _ in idx_names]
    # Identity-deduped (ESS-0hh): a Set-collector over the region bounds is
    # path-multiplicity-insensitive, so entering each distinct node once
    # collects exactly the same candidate sets — O(nodes) on a structurally-
    # shared body instead of once per path.
    seen = IdDict{OpExpr,Nothing}()
    walk(n) = begin
        n isa OpExpr || return
        haskey(seen, n) && return
        seen[n] = nothing
        if n.op == "index" && !isempty(n.args) &&
           n.args[1] isa OpExpr && (n.args[1]::OpExpr).op == "makearray"
            _collect_makearray_bounds!(cands, n.args[1]::OpExpr,
                                       ASTExpr[a for a in n.args[2:end]], idx_names)
        end
        for a in n.args; walk(a); end
        n.expr_body !== nothing && walk(n.expr_body)
        n.values !== nothing && (for v in n.values; walk(v); end)
    end
    walk(body)
    return cands
end

# How many consecutive identical per-cell signatures certify that the interior of
# a dimension has stabilized. A finite-volume stencil operator's region + ghost
# transitions all lie within its half-width of an END (wrap columns, one-sided
# boundary rows, ghost gathers), so once this many cells in a row share a
# signature we are safely past every boundary layer. 8 covers the widest operator
# on the grid (monotone PPM's 7-cell support → ≤3-cell boundary layers) with
# generous margin; a hypothetical wider layer that slipped past would only produce
# a box that spans a cut, which per-box corner verification catches → fallback.
const _AFFINE_STABLE_GUARD = 8

# Δ-keyed cut cap, per dim. State-Δ keying (see `_cell_ckey!`) exists to give
# wrap/fold transitions their own boxes — a handful of segments, bounded by the
# operator's half-width at each end. A GENUINELY UNSTRUCTURED gather (a slot
# indirect through a connectivity permutation) changes Δ at every cell; carving a
# box per cell would trade the O(#groups) build for O(#cells) kernels. So when a
# dim's Δ-keyed scan opens more segments than this cap, that dim's cuts are
# recomputed with the BASE key (region × ghost × const-fold) and the non-uniform
# lane is left for the box processor's indirect-table derivation
# (`_derive_lane_repl`), which materializes a per-box slot table instead.
const _AFFINE_MAX_DELTA_SEGS = 16

# Cut START indices per loop dim. For each dim, hold the OTHER dims at every
# low/mid/high probe and record where the per-cell signature changes — but scan
# INWARD FROM BOTH ENDS rather than across the whole range, stopping once the
# signature has been stable for `_AFFINE_STABLE_GUARD` cells. Because a stencil
# operator's transitions are all within its half-width of an end, this finds every
# real cut in O(boundary width) instead of O(N_d) — the difference between an
# N-independent build and one that re-walks the body ~N times per dim (fatal at
# millions of cells). The interior between the two converged fronts is a single
# uniform segment. Mid-domain makearray REGION boundaries — which need not lie near
# an end — are harvested structurally up front (`_region_cut_candidates`) and
# probed explicitly, so they are never missed. Anything neither scan nor candidate
# reaches is still caught by per-box corner verification (→ fallback), exactly as
# the old full sweep's misses were: correctness never depends on cut completeness,
# only speed.
#
# `okey` is the verified output affine map; the first scan of each dim keys state
# lanes by their Δ (wrap boxes), falling back to the base key when the Δ-keyed
# segment count exceeds `_AFFINE_MAX_DELTA_SEGS` (unstructured gather → the
# indirect-table derivation owns it instead).
function _affine_cut_points(sig::_AffineSig, body, idx_names, ranges, ctx_proto,
                            var_map, param_sym_set, reg_funcs,
                            okey::Union{Nothing,Tuple{Int,Vector{Int}}}=nothing)
    D = length(idx_names)
    cuts = Vector{Vector{Int}}(undef, D)
    region_cands = _region_cut_candidates(body, idx_names)
    for d in 1:D
        starts = _scan_dim_cuts(sig, body, idx_names, ranges, ctx_proto, var_map,
                                param_sym_set, reg_funcs, region_cands, d, okey)
        if okey !== nothing && length(starts) > _AFFINE_MAX_DELTA_SEGS
            starts = _scan_dim_cuts(sig, body, idx_names, ranges, ctx_proto, var_map,
                                    param_sym_set, reg_funcs, region_cands, d, nothing)
        end
        cuts[d] = sort!(collect(starts))
    end
    return cuts
end

# One dim's edge-inward signature scan (see `_affine_cut_points`). Returns the
# set of segment-start indices for dim `d` under the signature strength `okey`.
function _scan_dim_cuts(sig::_AffineSig, body, idx_names, ranges, ctx_proto,
                        var_map, param_sym_set, reg_funcs, region_cands, d::Int,
                        okey::Union{Nothing,Tuple{Int,Vector{Int}}})
    D = length(idx_names)
    rng = ranges[d]; lo, hi = first(rng), last(rng)
    starts = Set{Int}(); push!(starts, lo)
    otherdims = Int[dd for dd in 1:D if dd != d]
    probesets = isempty(otherdims) ? [()] :
        collect(Iterators.product((_probe_values(ranges[dd]) for dd in otherdims)...))
    loop = Vector{Int}(undef, D)
    ck(iv) = (loop[d] = iv;
              (_cell_ckey!(sig, loop, idx_names, body, ctx_proto,
                           var_map, param_sym_set, reg_funcs, okey))[2])
    # Region boundaries in this dim, kept only where they open a real segment
    # (lo < C ≤ hi). Each is confirmed below by comparing C-1 to C.
    cand_d = sort!(Int[c for c in region_cands[d] if lo < c <= hi])
    # Bound each front at the midpoint so a small range is covered once, not
    # twice (the two scans meet at `mid`, overlapping on that single cell so
    # the mid/mid+1 pair is still compared). For a large range each front
    # stabilizes long before `mid`, so the deep interior is never scanned.
    mid = (lo + hi) ÷ 2
    for probe in probesets
        for (ii, dd) in enumerate(otherdims); loop[dd] = probe[ii]; end
        # Over-cap early exit for a Δ-keyed scan: an unstructured gather changes
        # Δ at EVERY cell, so without this the fronts would never stabilize and
        # the scan would walk the whole range before the caller's cap fallback.
        overcap() = okey !== nothing && length(starts) > _AFFINE_MAX_DELTA_SEGS
        # Scan up from the low end: a change at `iv` opens a segment there.
        prev = nothing; stable = 0; iv = lo
        while iv <= mid
            cur = ck(iv)
            if prev !== nothing
                if cur != prev
                    push!(starts, iv); stable = 0
                    overcap() && break
                else; stable += 1; stable >= _AFFINE_STABLE_GUARD && break; end
            end
            prev = cur; iv += 1
        end
        # Scan down from the high end: a change between `iv` and `iv+1` opens a
        # segment at `iv+1`.
        prev = nothing; stable = 0; iv = hi
        while iv >= mid && !overcap()
            cur = ck(iv)
            if prev !== nothing
                if cur != prev
                    push!(starts, iv + 1); stable = 0
                    overcap() && break
                else; stable += 1; stable >= _AFFINE_STABLE_GUARD && break; end
            end
            prev = cur; iv -= 1
        end
        # Mid-domain region boundaries the edge scans cannot reach: confirm each
        # candidate is a genuine transition (C-1 vs C) before opening a segment.
        for C in cand_d
            ck(C - 1) != ck(C) && push!(starts, C)
        end
        # A Δ-keyed scan past the cap is abandoned early — the caller redoes the
        # dim with the base key, so finishing the sweep would be wasted work.
        okey !== nothing && length(starts) > _AFFINE_MAX_DELTA_SEGS && break
    end
    return starts
end

# Turn per-dim cut starts into segment ranges covering `rng`.
function _segments(starts::Vector{Int}, rng::UnitRange{Int})
    segs = UnitRange{Int}[]
    for i in eachindex(starts)
        e = i < length(starts) ? starts[i+1] - 1 : last(rng)
        push!(segs, starts[i]:e)
    end
    return segs
end

# Serialize a lane-lowering vector into a memo key (so boxes with identical
# descriptors share ONE spine + descriptor table object). Keyed by CONTENT for the
# kinds the box processor actually emits into a lane_repl (STATE_AFFINE, LOOP_IDX,
# CONST_BOX); any other kind falls back to identity keying — safe (it can only
# OVER-split, never merge two genuinely different descriptors).
# ISBITS key (perf): a uniform `Tuple{UInt8,UInt64,Int,Int,Int,Int}` — `(tag, id,
# a, b, c, d)` — instead of an allocated `String`. The leading `tag` disambiguates
# the kinds (so e.g. a STATE_AFFINE and a LOOP_IDX with equal payload never
# collide, exactly as the old "SA"/"LI" prefixes did), and the fixed shape means
# `_acc_vn_key`'s per-ACCESS-node CSE key and `_lane_repl_key`'s per-lane key hash
# with no per-node string materialization. Equality classes are identical to the
# old strings: two descriptors map to the same tuple iff they mapped to the same
# string.
function _desc_key(d::_AccDesc)
    k = d.kind
    k === _AK_STATE_AFFINE && return (0x1, UInt64(0), d.delta, 0, 0, 0)
    k === _AK_LOOP_IDX     && return (0x2, UInt64(0), d.dim, 0, 0, 0)
    k === _AK_CONST_BOX    && return (0x3, objectid(d.arr), d.s1, d.s2, d.s3, d.off)
    k === _AK_FORCING_BOX  && return (0x4, objectid(d.arr), d.s1, d.s2, d.s3, d.off)
    k === _AK_STATE_TBL_BOX && return (0x5, objectid(d.conn), d.s1, d.s2, d.s3, d.off)
    return (0xff, objectid(d), 0, 0, 0, 0)
end
function _lane_repl_key(lane_repl)
    io = IOBuffer()
    for r in lane_repl
        if r isa _LitRepl
            print(io, 'L', r.v, ';')
        else
            t = _desc_key((r::_AccRepl).desc)
            print(io, 'A', t[1], ',', t[2], ',', t[3], ',', t[4], ',', t[5], ',', t[6], ';')
        end
    end
    return String(take!(io))
end

# Box-local DENSE addressing for a materialized per-box table: strides over the
# box dims (fastest-first, matching `Iterators.product` fill order) and the
# offset that maps the cell multi-index `midx` to `off + Σ(midx_d-1)·s_d`.
function _box_local_addr(box, D)
    s = zeros(Int, 3)
    acc = 1
    for d in 1:D
        s[d] = acc
        acc *= length(box[d])
    end
    off = 1
    for d in 1:D
        off -= (first(box[d]) - 1) * s[d]
    end
    return s, off, acc            # acc == number of cells in the box
end

# Materialize a NON-AFFINE state lane as a per-box slot table (Stage 2 of the
# array-IR unification): one `_eval_recipe` per box cell — the SAME resolution
# the per-cell fallback would run — stored densely in box-local layout, with 0
# marking a ghost (fetched as the ghost literal 0.0). This is what an
# unstructured gather (slot indirect through a connectivity const) lowers to;
# it is bit-identical by construction and O(box) — the same order as the
# connectivity input, and strictly smaller than the per-cell fallback's
# per-lane slot vectors.
function _materialize_state_tbl(rec::_LaneRecipe, idx_names, box, D,
                                var_map, const_arrays)
    s, off, len = _box_local_addr(box, D)
    tbl = Vector{Int}(undef, len)
    env = Dict{String,Int}()
    j = 0
    for loop in Iterators.product((box[d] for d in 1:D)...)
        j += 1
        tbl[j] = _eval_recipe(rec, _set_env!(env, idx_names, collect(Int, loop)),
                              var_map, const_arrays)::Int
    end
    return _AccRepl(_AccStateTblBox(tbl, s[1], s[2], s[3], off))
end

# Materialize a NON-AFFINE const lane as a dense per-box VALUE table, addressed
# box-locally through the existing `_AccConstBox` descriptor. The values are
# `_eval_recipe`'s per-cell outputs (boundary folds included), so a fetch is
# bit-identical to the per-cell resolve.
function _materialize_const_box(rec::_LaneRecipe, idx_names, box, D,
                                var_map, const_arrays)
    s, off, len = _box_local_addr(box, D)
    vals = Vector{Float64}(undef, len)
    env = Dict{String,Int}()
    j = 0
    for loop in Iterators.product((box[d] for d in 1:D)...)
        j += 1
        vals[j] = _eval_recipe(rec, _set_env!(env, idx_names, collect(Int, loop)),
                               var_map, const_arrays)::Float64
    end
    return _AccRepl(_AccConstBox(vals, s[1], s[2], s[3], off))
end

# Derive one lane's lowering for a box and VERIFY it is uniform across the box
# corners (state Δ constant, ghost uniform, const/forcing index affine). A
# non-uniform STATE lane (an unstructured/indirect gather, or a fold pattern
# past the Δ-cut cap) and a non-affine CONST index MATERIALIZE per-box tables
# instead of declining — see `_materialize_state_tbl` / `_materialize_const_box`.
# A non-affine live-forcing (pgather) index still throws `_StencilFallback`
# (per-cell fallback): a forcing gather must stay an index into the aliased live
# buffer, and no table kind models that today. A live forcing lane otherwise
# lowers to `_AccForcingBox` over the aliased buffer (never folded to a literal,
# so it stays refresh-live).
function _derive_lane_repl(rec::_LaneRecipe, idx_names, rep, corners, thin,
                           oln_rep, base, strides, D, var_map, const_arrays,
                           flat_cache, box)
    env = Dict{String,Int}()
    ev(loop) = _eval_recipe(rec, _set_env!(env, idx_names, loop), var_map, const_arrays)
    if rec.kind == LANE_STATE
        slot_rep = ev(rep)
        if slot_rep == 0                              # ghost → literal 0.0
            for cn in corners
                ev(cn) == 0 ||
                    return _materialize_state_tbl(rec, idx_names, box, D,
                                                  var_map, const_arrays)
            end
            return _LitRepl(0.0)
        end
        Δ = slot_rep - oln_rep
        for cn in corners
            sc = ev(cn)
            (sc != 0 && sc - _box_oln(base, strides, cn, D) == Δ) ||
                return _materialize_state_tbl(rec, idx_names, box, D,
                                              var_map, const_arrays)
        end
        return _AccRepl(_AccStateAffine(Δ))
    elseif rec.kind == LANE_LOOPLIT
        dim = findfirst(==(rec.loop_name), idx_names)
        dim === nothing && throw(_StencilFallback("loop-lit name not an output index"))
        return thin[dim] ? _LitRepl(Float64(rep[dim])) : _AccRepl(_AccLoopIdx(dim))
    elseif rec.kind == LANE_CONST
        val_rep = ev(rep)
        allinv = true
        for cn in corners
            if ev(cn) != val_rep; allinv = false; break; end
        end
        allinv && return _LitRepl(Float64(val_rep))
        arr_flat = get!(flat_cache, rec.arr) do; Float64.(vec(rec.arr)); end
        lenv = Dict{String,Int}()
        clin(loop) = _recipe_const_lin(rec, _set_env!(lenv, idx_names, loop), const_arrays)
        lin_rep = clin(rep)
        s = zeros(Int, 3)
        for d in 1:D
            if !thin[d]
                l2 = copy(rep); l2[d] += 1
                s[d] = clin(l2) - lin_rep
            end
        end
        off = lin_rep - sum((rep[d]-1)*s[d] for d in 1:D)
        for cn in corners
            (off + sum((cn[d]-1)*s[d] for d in 1:D)) == clin(cn) ||
                return _materialize_const_box(rec, idx_names, box, D,
                                              var_map, const_arrays)
        end
        return _AccRepl(_AccConstBox(arr_flat, s[1], s[2], s[3], off))
    else  # LANE_PGATHER — LIVE forcing gather
        # `_eval_recipe` returns the flat LINEAR INDEX into the forcing buffer (its
        # own grid), so this is the LANE_CONST derivation applied to the INDEX, not
        # the value: finite-difference across unit loop steps for the affine strides,
        # then VERIFY at every corner. Two differences from LANE_CONST: (1) never
        # fold to a literal even when the index is constant — the buffer contents are
        # refreshed in place, so the read must stay live; (2) pass `pg.flat`
        # (the aliased live buffer) straight through, NEVER a copy.
        pg = rec.arr::_PGatherArray
        lin_rep = ev(rep)
        s = zeros(Int, 3)
        for d in 1:D
            if !thin[d]
                l2 = copy(rep); l2[d] += 1
                s[d] = ev(l2) - lin_rep
            end
        end
        off = lin_rep - sum((rep[d]-1)*s[d] for d in 1:D)
        for cn in corners
            (off + sum((cn[d]-1)*s[d] for d in 1:D)) == ev(cn) ||
                throw(_StencilFallback("pgather index non-affine in box"))
        end
        return _AccRepl(_AccForcingBox(pg.flat, s[1], s[2], s[3], off))
    end
end

# All 2^D corners of a box, as loop tuples.
function _box_corners(box)
    D = length(box)
    Vector{Int}[collect(Int, tup) for tup in
        Iterators.product(((first(box[d]), last(box[d])) for d in 1:D)...)]
end

# Emit one `_AccKernel` for a box: derive + verify every lane, then lower the
# (memoized) sentinel template to a shared access spine.
function _process_affine_box!(kernels, spine_cache, flat_cache, box, idx_names,
                              body, ctx_proto, var_map, const_arrays,
                              param_sym_set, reg_funcs, base, strides,
                              lhs_var, lhs_idx_args, sig::_AffineSig)
    D = length(box)
    rep = Int[first(box[d]) for d in 1:D]
    thin = Bool[length(box[d]) == 1 for d in 1:D]
    corners = _box_corners(box)
    bkey, branch = _cell_bkey!(sig, rep, idx_names, body, ctx_proto,
                               var_map, param_sym_set, reg_funcs)
    tmpl, recipes, _state_ks, subcalls = branch

    # verify the output slot map on this box against var_map (catches a bad omap)
    denv = Dict{String,Int}()
    for cn in corners
        _box_oln(base, strides, cn, D) ==
            _oln_via_varmap(lhs_var, lhs_idx_args, _set_env!(denv, idx_names, cn), var_map) ||
            throw(_StencilFallback("box output slot ≠ var_map"))
    end
    oln_rep = _box_oln(base, strides, rep, D)

    lane_repl = Vector{_LaneRepl}(undef, length(recipes))
    for k in eachindex(recipes)
        lane_repl[k] = _derive_lane_repl(recipes[k], idx_names, rep, corners, thin,
                                         oln_rep, base, strides, D, var_map,
                                         const_arrays, flat_cache, box)
    end

    spine, acc, cse, subs = get!(spine_cache, string(bkey, '#', _lane_repl_key(lane_repl))) do
        a = _AccDesc[]
        raw = _lower_to_access(tmpl, lane_repl, a, subcalls)
        cs_spine, cse = _build_acc_cse(raw, a)   # per-cell CSE (shared subtrees → scratch)
        (cs_spine, a, cse, _collect_subkernels(cs_spine, cse))
    end
    cs = _CellSet(collect(Int, strides), UnitRange{Int}[box[d] for d in 1:D], base)
    push!(kernels, _AccKernel(cs, spine, acc, _FixedBound(0), 0.0, cse, subs))
end

# Mark every output slot a box owns (cheap O(box cells) bit-ops — the sole
# remaining O(#cells) step, no tree-walk), detecting duplicate derivatives.
function _mark_box_covered!(covered, box, base, strides, D, lhs_var, lhs_idx_args, idx_names)
    env = Dict{String,Int}()
    @inbounds for loop in Iterators.product((box[d] for d in 1:D)...)
        o = _box_oln(base, strides, loop, D)
        if covered[o]
            du_inds = Int[_eval_const_int(a, _set_env!(env, idx_names, collect(Int, loop))) for a in lhs_idx_args]
            throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", _cell_key(lhs_var, du_inds)))
        end
        covered[o] = true
    end
end

# Compile a no-contraction array equation via the affine polyhedral build.
# Same inputs as `_try_symbolic_stencil`; returns `Vector{_AccKernel}` or nothing.
function _try_affine_stencil(rhs_body::ASTExpr, idx_names::Vector{String},
                             range_iters, lhs_body::OpExpr,
                             resolved_obs::Dict{String,ASTExpr},
                             array_var_info, var_map::Dict{String,Int},
                             const_arrays::AbstractDict, pgather::AbstractDict,
                             param_sym_set, reg_funcs, covered::BitVector;
                             template_sites::Union{Nothing,IdDict{OpExpr,OpExpr}}=nothing)
    (lhs_body.op == "D" && !isempty(lhs_body.args) &&
     lhs_body.args[1] isa OpExpr && (lhs_body.args[1]::OpExpr).op == "index" &&
     !isempty((lhs_body.args[1]::OpExpr).args) &&
     (lhs_body.args[1]::OpExpr).args[1] isa VarExpr) || return nothing

    D = length(idx_names)
    (1 <= D <= 3) || return nothing               # multi-index capped at 3 (latlon3d)
    ranges = UnitRange{Int}[]
    for r in range_iters
        (length(r) >= 1 && collect(r) == collect(first(r):last(r))) || return nothing
        push!(ranges, first(r):last(r))
    end

    # Observed inlining, with the substitution memo EXPOSED when the compile-once
    # tier is active: `_sub_preserving` reconstructs every ancestor of a bound
    # variable, so a template expansion root that contains an observed reference
    # comes out as a NEW object — the memo maps old → new, and translating the
    # site table through it keeps those roots recognized. A root the memo never
    # visited (identity preserved, or from another equation) maps to itself. A
    # root that some earlier rewrite already detached from the table simply
    # compiles fused — slower, never wrong.
    body = rhs_body
    sites = template_sites
    if !isempty(resolved_obs)
        memo = _SubMemo()
        body = _sub_preserving(rhs_body, resolved_obs, memo)
        if sites !== nothing
            translated = IdDict{OpExpr,OpExpr}()
            for (root, ap) in sites
                nr = get(memo, root, root)
                nr isa OpExpr && (translated[nr] = ap)
            end
            sites = translated
        end
    end
    inner = lhs_body.args[1]::OpExpr
    lhs_var = (inner.args[1]::VarExpr).name
    lhs_idx_args = inner.args[2:end]
    length(lhs_idx_args) == D || return nothing

    if get(ENV, "ESS_STENCIL_DEBUG", "") == "1" && sites !== nothing
        # IDENTITY-MEMOIZED walk (`foreach_subexpr_once`) — NOTE the metric
        # changed with it (ESS-0hh): `reachable-in-body` used to count PATHS to
        # each site root and now counts DISTINCT reachable roots. Distinct is
        # the meaningful diagnostic — the compile-once tier compiles each root
        # once regardless of in-degree, and `sites` is keyed by identity — and
        # the per-path count made this debug print itself exponential on the
        # obs-inlined body, which is a compact DAG by construction
        # (`_sub_preserving`): enabling debugging must never hang the build.
        hit = 0
        foreach_subexpr_once(body) do x
            x isa OpExpr && haskey(sites, x) && (hit += 1)
            nothing
        end
        println(stderr, "[compile-once] sites=", length(sites),
                " reachable-in-body=", hit)
        flush(stderr)
    end
    tctx = sites === nothing ? nothing :
           _TemplateCtx(sites, var_map, param_sym_set, reg_funcs)
    ctx_proto = _StencilCtx(Set{String}(idx_names), _LaneRecipe[], Dict{String,Int}(),
                            array_var_info, const_arrays, pgather, tctx)
    sig = _AffineSig()
    try
        base, strides = _derive_output_affine(lhs_var, lhs_idx_args, idx_names, ranges, var_map)
        cuts = _affine_cut_points(sig, body, idx_names, ranges, ctx_proto,
                                  var_map, param_sym_set, reg_funcs,
                                  (base, strides))
        segs = [_segments(cuts[d], ranges[d]) for d in 1:D]
        kernels = _AccKernel[]
        spine_cache = Dict{String,Tuple{_Node,Vector{_AccDesc},_AccCSE,Vector{_AccKernel}}}()
        flat_cache = IdDict{Any,Vector{Float64}}()
        boxes = Vector{UnitRange{Int}}[]
        for segtuple in Iterators.product(segs...)
            box = UnitRange{Int}[segtuple[d] for d in 1:D]
            _process_affine_box!(kernels, spine_cache, flat_cache, box, idx_names,
                                 body, ctx_proto, var_map, const_arrays,
                                 param_sym_set, reg_funcs, base, strides,
                                 lhs_var, lhs_idx_args, sig)
            push!(boxes, box)
        end
        # Only after every box is verified: mark covered (untouched on fallback).
        for box in boxes
            _mark_box_covered!(covered, box, base, strides, D, lhs_var, lhs_idx_args, idx_names)
        end
        return kernels
    catch err
        if err isa _StencilFallback
            get(ENV, "ESS_STENCIL_DEBUG", "") == "1" &&
                @info "affine stencil fallback" reason = err.reason
            return nothing
        end
        rethrow()
    end
end
