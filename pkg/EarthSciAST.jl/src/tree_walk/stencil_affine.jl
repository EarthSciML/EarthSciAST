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
function _lower_to_access(tmpl::_Node, lane_repl::Vector{<:_LaneRepl},
                          acc::Vector{_AccDesc})::_Node
    k = tmpl.kind
    if k === _NK_STATE
        if tmpl.idx < 0
            rep = lane_repl[-tmpl.idx]
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
        ch = _Node[_lower_to_access(c, lane_repl, acc) for c in tmpl.children]
        return _mknode(kind=_NK_OP, op=tmpl.op, children=ch, payload=tmpl.payload)
    end
    throw(_StencilFallback("affine lowering: unhandled node kind $(Int(k))"))
end

# ========================================================================
# THE BOX PROCESSOR — a rule body → Vector{_AccKernel} in O(#structural groups).
# ========================================================================
# Opt-in via ESS_AFFINE=1 during rollout (a dev switch to differential-test the
# affine path against the per-cell reference before it becomes the default/only
# path — like ESS_STENCIL_DISABLE). Returns kernels or `nothing` (fall back to the
# existing symbolic-stencil / per-cell chain, `covered` untouched).

_affine_enabled() = get(ENV, "ESS_AFFINE", "") == "1"

# Reusable caches for the per-cell signature (branch template memo + branch-key
# guard memo + a scratch IOBuffer), shared across the whole equation's sweep.
mutable struct _AffineSig
    branch_cache::Dict{String,_StencilBranch}
    bmemo::IdDict{OpExpr,Set{String}}
    bio::IOBuffer
end
_AffineSig() = _AffineSig(Dict{String,_StencilBranch}(), IdDict{OpExpr,Set{String}}(), IOBuffer())

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

# Per-cell signature `bkey | ghost_key` (region selection × ghost pattern) plus the
# branch it resolves to. Builds/caches ONE sentinel template per region signature
# (the expensive step, bounded by #groups); cheap recipe evals give the ghost key.
function _cell_ckey!(sig::_AffineSig, loop, idx_names, body, ctx_proto,
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
    _tmpl, recipes, state_ks = branch
    lane_vals = Vector{Any}(undef, length(recipes))
    @inbounds for k in eachindex(recipes)
        lane_vals[k] = _eval_recipe(recipes[k], env, var_map, ctx_proto.const_arrays)
    end
    return bkey, string(bkey, '|', _ghost_key(lane_vals, state_ks)), branch
end

# Probe values for a range: low / mid / high (deduplicated).
function _probe_values(rng::UnitRange{Int})
    lo, hi = first(rng), last(rng)
    unique(Int[lo, (lo + hi) ÷ 2, hi])
end

# Cut START indices per loop dim: sweep each dim over its range while the OTHER
# dims are held at every low/mid/high combination, and record where the per-cell
# signature changes. Axis-aligned region + ghost boundaries fall on these cuts;
# any that a probe set misses is caught later by per-box corner verification
# (→ fallback), so correctness never depends on cut completeness, only speed.
function _affine_cut_points(sig::_AffineSig, body, idx_names, ranges, ctx_proto,
                            var_map, param_sym_set, reg_funcs)
    D = length(idx_names)
    cuts = Vector{Vector{Int}}(undef, D)
    for d in 1:D
        starts = Set{Int}(); push!(starts, first(ranges[d]))
        otherdims = Int[dd for dd in 1:D if dd != d]
        probesets = isempty(otherdims) ? [()] :
            collect(Iterators.product((_probe_values(ranges[dd]) for dd in otherdims)...))
        loop = Vector{Int}(undef, D)
        for probe in probesets
            for (ii, dd) in enumerate(otherdims); loop[dd] = probe[ii]; end
            prev = nothing
            for iv in ranges[d]
                loop[d] = iv
                _, ckey, _ = _cell_ckey!(sig, loop, idx_names, body, ctx_proto,
                                         var_map, param_sym_set, reg_funcs)
                prev !== nothing && ckey != prev && push!(starts, iv)
                prev = ckey
            end
        end
        cuts[d] = sort!(collect(starts))
    end
    return cuts
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
function _desc_key(d::_AccDesc)
    k = d.kind
    k === _AK_STATE_AFFINE && return "SA$(d.delta)"
    k === _AK_LOOP_IDX     && return "LI$(d.dim)"
    k === _AK_CONST_BOX    && return "CB$(objectid(d.arr)),$(d.s1),$(d.s2),$(d.s3),$(d.off)"
    k === _AK_FORCING_BOX  && return "FB$(objectid(d.arr)),$(d.s1),$(d.s2),$(d.s3),$(d.off)"
    return "?$(objectid(d))"
end
function _lane_repl_key(lane_repl)
    io = IOBuffer()
    for r in lane_repl
        r isa _LitRepl ? print(io, 'L', r.v, ';') :
                         print(io, 'A', _desc_key((r::_AccRepl).desc), ';')
    end
    return String(take!(io))
end

# Derive one lane's lowering for a box and VERIFY it is uniform across the box
# corners (state Δ constant, ghost uniform, const/forcing index affine). Any
# non-uniformity — an incomplete cut, a clamp, a non-affine gather — throws
# `_StencilFallback`. A live forcing (pgather) lane lowers to `_AccForcingBox`
# over the aliased buffer (never folded to a literal, so it stays refresh-live).
function _derive_lane_repl(rec::_LaneRecipe, idx_names, rep, corners, thin,
                           oln_rep, base, strides, D, var_map, const_arrays, flat_cache)
    env = Dict{String,Int}()
    ev(loop) = _eval_recipe(rec, _set_env!(env, idx_names, loop), var_map, const_arrays)
    if rec.kind == LANE_STATE
        slot_rep = ev(rep)
        if slot_rep == 0                              # ghost → literal 0.0
            for cn in corners
                ev(cn) == 0 || throw(_StencilFallback("ghost not uniform in box"))
            end
            return _LitRepl(0.0)
        end
        Δ = slot_rep - oln_rep
        for cn in corners
            sc = ev(cn)
            (sc != 0 && sc - _box_oln(base, strides, cn, D) == Δ) ||
                throw(_StencilFallback("state Δ not uniform in box"))
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
                throw(_StencilFallback("const index non-affine in box"))
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
    bkey, _ckey, branch = _cell_ckey!(sig, rep, idx_names, body, ctx_proto,
                                      var_map, param_sym_set, reg_funcs)
    tmpl, recipes, _state_ks = branch

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
                                         const_arrays, flat_cache)
    end

    spine, acc, cse = get!(spine_cache, string(bkey, '#', _lane_repl_key(lane_repl))) do
        a = _AccDesc[]
        raw = _lower_to_access(tmpl, lane_repl, a)
        cs_spine, cse = _build_acc_cse(raw, a)   # per-cell CSE (shared subtrees → scratch)
        (cs_spine, a, cse)
    end
    cs = _CellSet(collect(Int, strides), UnitRange{Int}[box[d] for d in 1:D], base)
    push!(kernels, _AccKernel(cs, spine, acc, _FixedBound(0), 0.0, cse))
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
                             param_sym_set, reg_funcs, covered::BitVector)
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

    body = isempty(resolved_obs) ? rhs_body : _sub_preserving(rhs_body, resolved_obs)
    inner = lhs_body.args[1]::OpExpr
    lhs_var = (inner.args[1]::VarExpr).name
    lhs_idx_args = inner.args[2:end]
    length(lhs_idx_args) == D || return nothing

    ctx_proto = _StencilCtx(Set{String}(idx_names), _LaneRecipe[], Dict{String,Int}(),
                            array_var_info, const_arrays, pgather)
    sig = _AffineSig()
    try
        base, strides = _derive_output_affine(lhs_var, lhs_idx_args, idx_names, ranges, var_map)
        cuts = _affine_cut_points(sig, body, idx_names, ranges, ctx_proto,
                                  var_map, param_sym_set, reg_funcs)
        segs = [_segments(cuts[d], ranges[d]) for d in 1:D]
        kernels = _AccKernel[]
        spine_cache = Dict{String,Tuple{_Node,Vector{_AccDesc},_AccCSE}}()
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
