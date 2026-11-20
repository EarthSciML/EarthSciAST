# ========================================================================
# tree_walk/stencil_affine.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl AFTER stencil.jl; see that file for the layout.
#
# The POLYHEDRAL affine build: turn a lowered `makearray` rule body into a small
# set of `_AccKernel`s (access_kernel.jl) in O(#structural groups), NOT O(#cells).
# The per-cell path costs O(#cells × body).
#
# HOW IT WORKS (the box processor):
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
# `_lower_to_access` keeps the spine's tree shape, but each `_NK_STATE(idx=-k)`
# lane leaf becomes either a literal (ghost / invariant-folded lane) or an
# `_NK_ACCESS` into a per-kernel descriptor table,
# and each invariant fixed-slot leaf (`_NK_STATE idx≥0`, `_NK_PARAM_GATHER`)
# becomes a fixed-read descriptor. Because the spine's OP structure is the exact
# `_compile` output (only leaves are swapped), the arithmetic — operand order,
# associativity, n-ary grouping — is the per-cell path's, which is what makes
# the emitted kernel bit-identical.
#
# The tier rests on two invariants: (1) within a box every cell selects the same
# makearray regions, which the cuts guarantee (it is not verified per box, so a
# missed region boundary is a wrong answer); (2) within a box every lane's
# lowering holds at every cell, which per-box verification guarantees (at the
# corners for a structurally affine subscript, at every cell otherwise).
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
# Anything not modelled (a contraction node) throws a `_Decline` so the
# caller runs the per-cell path — never a wrong kernel.
#
# IDENTITY-MEMOIZED: the compiled template is a DAG (`_stencilize` /
# `_compile` preserve sharing via their identity memos), and the lowering is a
# pure function of the node under one call's fixed `lane_repl`, so
# a shared template node lowers to ONE shared access node — the per-path
# rebuild re-inflated the spine into an exponentially large tree AND pushed a
# duplicate `acc` descriptor per PATH to each access leaf. With the memo a
# shared leaf pushes its descriptor once and every parent references that
# entry; evaluation reads `acc[idx]` by index, so values are unchanged, and
# `_build_acc_cse` counts path multiplicities exactly, so CSE slot decisions
# are unchanged too. On a tree (no shared nodes) the memo never hits —
# byte-identical output, `acc` table included. The memo is per top-level call.
function _lower_to_access(
        tmpl::_Node, lane_repl::Vector{<:_LaneRepl}, acc::Vector{_AccDesc}
    )::_Node
    return _lower_to_access(tmpl, lane_repl, acc, _NodeIdMap{_Node}())
end
function _lower_to_access(
        tmpl::_Node, lane_repl::Vector{<:_LaneRepl},
        acc::Vector{_AccDesc}, memo::_NodeIdMap{_Node}
    )::_Node
    cached = get(memo, tmpl, nothing)
    cached === nothing || return cached
    result = _lower_to_access_node(tmpl, lane_repl, acc, memo)
    memo[tmpl] = result
    return result
end
function _lower_to_access_node(
        tmpl::_Node, lane_repl::Vector{<:_LaneRepl},
        acc::Vector{_AccDesc}, memo::_NodeIdMap{_Node}
    )::_Node
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
        _decline(:unknown_kind, "a contraction node in a template")
    elseif k === _NK_OP
        # `payload` is carried through (`nothing` for every arithmetic op).
        ch = _Node[
            _lower_to_access(c, lane_repl, acc, memo)
                for c in tmpl.children
        ]
        return _mknode(kind = _NK_OP, op = tmpl.op, children = ch, payload = tmpl.payload)
    elseif k === _NK_CALL
        # A template call: its arguments lower into this spine; the target's
        # body is a function of them and is not lowered (call.jl).
        ch = _Node[
            _lower_to_access(c, lane_repl, acc, memo)
                for c in tmpl.children
        ]
        return _mknode(kind = _NK_CALL, op = tmpl.op, children = ch, payload = tmpl.payload)
    end
    return _decline(:unknown_kind, string(k))
end

# ========================================================================
# THE BOX PROCESSOR — a rule body → Vector{_AccKernel} in O(#structural groups).
# ========================================================================
# The DEFAULT array-kernel build. Returns kernels or `nothing` (fall back to the
# existing symbolic-stencil / per-cell chain, `covered` untouched).
# With this tier off the equation takes the per-cell reference, which is what
# the differential tests compare against.

# The scan key of a body whose every cell has the same branch and whose key is
# its state lanes' ghost pattern alone: no indexed array producer (so the branch
# key is constant), every lane subscript structurally affine (so the lane-affine
# key adds nothing), no boundary-policy const lane (so no fold class), and every
# state lane on an affine slot map. Each state subscript is then an exact
# integer affine function `c0 + Σ_d c[d]·loop[d]` of the cell, and the key is
# computed from those coefficients instead of walking the subscripts.
struct _FastKey
    id::Int                                 # the branch key's number
    lo::Vector{Vector{Int}}                 # per state lane, its subscripts' bounds
    hi::Vector{Vector{Int}}
    c0::Vector{Vector{Int}}                 # per state lane and subscript
    c::Vector{Vector{Vector{Int}}}          # per state lane, subscript and loop dim
    base::Vector{Int}                       # per state lane, its affine slot map
    strides::Vector{Vector{Int}}
end

# ---- Affine subscripts ----------------------------------------------------
# One model of an integer subscript that is AFFINE in the loop indices:
# `c0 + Σ_d c[d]·loop[d]`, computed by the same wrapping integer arithmetic
# `_eval_const_int` does. The recognizer admits integer literals, the loop
# names, `+`, `-` (one or two operands), `neg`, and `*` with at most one factor
# that names a loop index; anything else (a clamp `max(k-1,1)`, a fold, a
# `mod`, a gather through a const table, a division, a non-loop name, a
# non-integer or non-finite literal) is not affine. It is the licence for
# skipping a per-cell check (an affine subscript cannot deviate from its model
# at any cell), so it errs only towards "not affine", which costs a per-cell
# evaluation and never a wrong value.
#
# `single = true` also refuses any subexpression that moves with two different
# loop indices (the LHS reading, `_lhs_index_affine`, which allows one).
struct _AffineForm
    c0::Int
    c::Vector{Int}
end

# A subexpression names no loop index (it is a constant over the loop).
_names_no_loop(e::ASTExpr, idx_names) =
    e isa VarExpr ? !((e::VarExpr).name in idx_names) :
    e isa OpExpr ? _allof(a -> _names_no_loop(a, idx_names), _operands(e::OpExpr)) : true

function _affine_form(e::ASTExpr, idx_names::AbstractVector{String}; single::Bool = false)
    D = length(idx_names)
    if e isa IntExpr
        return _AffineForm(Int((e::IntExpr).value), zeros(Int, D))
    elseif e isa NumExpr
        v = (e::NumExpr).value
        (isfinite(v) && isinteger(v) && abs(v) < 9.0e18) || return nothing
        return _AffineForm(Int(v), zeros(Int, D))
    elseif e isa VarExpr
        d = findfirst(==((e::VarExpr).name), idx_names)
        d === nothing && return nothing
        c = zeros(Int, D); c[d] = 1
        return _AffineForm(0, c)
    end
    e isa OpExpr || return nothing
    o = e::OpExpr
    (
        o.ranges === nothing && o.output_idx === nothing && o.bindings === nothing &&
            o.expr_body === nothing && o.lower === nothing && o.upper === nothing &&
            o.filter === nothing && o.key === nothing && o.values === nothing
    ) || return nothing
    n = length(o.args)
    n >= 1 || return nothing
    op = o.op
    if op == "*"
        # At most one factor names a loop index; the product of the others
        # scales it.
        count(a -> !_names_no_loop(a, idx_names), o.args) <= 1 || return nothing
    elseif !(op == "+" || (op == "-" && n <= 2) || (op == "neg" && n == 1))
        return nothing
    end
    parts = Vector{_AffineForm}(undef, n)
    for j in 1:n
        r = _affine_form(o.args[j], idx_names; single = single)
        r === nothing && return nothing
        parts[j] = r
    end
    r = if op == "+"
        c0 = parts[1].c0; c = copy(parts[1].c)
        for j in 2:n
            c0 += parts[j].c0; c .+= parts[j].c
        end
        _AffineForm(c0, c)
    elseif n == 1                                   # `-` or `neg`
        _AffineForm(-parts[1].c0, -parts[1].c)
    elseif op == "-"
        _AffineForm(parts[1].c0 - parts[2].c0, parts[1].c .- parts[2].c)
    else                                            # `*`
        k = 1; var = nothing
        for (j, p) in enumerate(parts)
            if _names_no_loop(o.args[j], idx_names)
                k *= p.c0
            else
                var = p
            end
        end
        var === nothing ? _AffineForm(k, zeros(Int, D)) : _AffineForm(k * var.c0, k .* var.c)
    end
    (single && count(!iszero, r.c) > 1) && return nothing
    return r
end

# Whether a subscript is structurally affine in the loop indices `idx`.
_affine_idx_expr(e::ASTExpr, idx::AbstractVector{String}) = _affine_form(e, idx) !== nothing
_affine_idx_expr(e::ASTExpr, idx) = _affine_form(e, collect(String, idx)) !== nothing

# One lane read's guards, outermost first: each a condition node of the branch
# template and the truth value the read needs it to have.
const _GuardPath = Vector{Tuple{_Node, Bool}}

# A contraction the affine tier compiles as a loop rather than an unroll: its
# contracted index names (kept symbolic in the body, as extra loop dims), their
# ranges, the ⊕ and its 0̄. Every range is contiguous with unit step.
struct _AffineReduce
    names::Vector{String}
    ranges::Vector{UnitRange{Int}}
    op::Symbol
    zerobar::Float64
end

# One equation of the affine build (`_try_affine_stencil`): its fixed inputs,
# which every step of the cut scan and the box processor reads, and the caches
# those steps share. One object per call, so a cache can never be paired with
# another equation's inputs.
#
# Inputs: the loop dims `names` and their `ranges` (the output indices, then a
# kept contraction's), the output dims' own ranges `out_ranges`, the body with
# observeds inlined, the stencil walk context `ctx` (whose `idx_env` the keys
# fill and whose `vsmemo` the branch-key walk shares with `_stencilize`), the
# slot map, the constant arrays, the parameter names, the output variable and
# its subscripts, the verified output map `oln = base + Σ loop[d]·strides[d]`
# over every loop dim (stride 0 along a contracted one), the kept contraction
# (`reduce`) and a tile's view (`view`, `nothing` for the whole domain).
mutable struct _AffineEq{B, VM, CA, PS, V}
    names::Vector{String}
    ranges::Vector{UnitRange{Int}}
    out_ranges::Vector{UnitRange{Int}}
    body::B
    ctx::_StencilCtx
    var_map::VM
    const_arrays::CA
    param_sym_set::PS
    lhs_var::String
    lhs_idx_args::Vector{ASTExpr}
    base::Int
    strides::Vector{Int}
    reduce::Union{Nothing, _AffineReduce}
    view::V
    # Per branch key (the region signature `_cell_bkey!` prints): its branch
    # template; for every lane recipe, which of its index arguments are NOT
    # structurally affine in the loop indices and therefore have to be
    # differenced per keyed cell (classified once per branch, see
    # `_lane_nonaffine_args!`); its number, the first entry of a scan key
    # (`_cell_ckey!`); every lane's compiled evaluator for the box processor
    # (`_box_lane_evals!`) and the state lanes' share of them for the scan
    # (`_ckey_state_slots!`); and the guard paths each lane is read under
    # (`_lane_guard_paths`), built only when a lane is out of range somewhere.
    branch_cache::Dict{String, _StencilBranch}
    lane_ref::Dict{String, Vector{Vector{Bool}}}
    bkey_ids::Dict{String, Int}
    box_evals::Dict{String, Vector{Union{Nothing, _LaneEval}}}
    lane_evals::Dict{String, Any}
    lane_guards::Dict{String, Vector{Vector{_GuardPath}}}
    # Per body: whether it holds an indexed array producer (`makearray` or a
    # `faq`), the only nodes `_branch_key!` prints. A body without one has the
    # empty branch key at every cell.
    bkey_sites::IdDict{Any, Bool}
    # The equation's compiled output subscripts (`_lhs_ix_compile`), and each
    # subscript expression's compiled form (`_lane_evaluator`'s `ixmemo`).
    lhs_ix::Union{Nothing, Vector{Union{Nothing, _IdxNode}}}
    ix_memo::IdDict{OpExpr, Any}
    # The scan key in closed form (`_FastKey`), `false` where the body has none,
    # `nothing` until the first keyed cell decides.
    fast_key::Union{Nothing, Bool, _FastKey}
    # The boxes' lowered spines by branch key and lane lowering, and the
    # flattened constant arrays the lowerings read.
    spine_cache::Dict{String, Tuple{_Node, Vector{_AccDesc}, _AccCSE, Vector{_AccKernel}}}
    flat_cache::IdDict{Any, Vector{Float64}}
    # Scratch reused across keyed cells: the branch-key text, the state lanes'
    # slots, the backward probe, and the visited set `_branch_key!` clears.
    bio::IOBuffer
    state_scratch::Vector{Int}
    back_scratch::Vector{Int}
    bseen::_SeenSet
end
function _AffineEq(
        names, ranges, out_ranges, body, ctx, var_map, const_arrays, param_sym_set,
        lhs_var, lhs_idx_args, base, strides, reduce, view
    )
    return _AffineEq(
        names, ranges, out_ranges, body, ctx, var_map, const_arrays, param_sym_set,
        lhs_var, lhs_idx_args, base, strides, reduce, view,
        Dict{String, _StencilBranch}(), Dict{String, Vector{Vector{Bool}}}(),
        Dict{String, Int}(), Dict{String, Vector{Union{Nothing, _LaneEval}}}(),
        Dict{String, Any}(), Dict{String, Vector{Vector{_GuardPath}}}(),
        IdDict{Any, Bool}(), nothing, IdDict{OpExpr, Any}(), nothing,
        Dict{String, Tuple{_Node, Vector{_AccDesc}, _AccCSE, Vector{_AccKernel}}}(),
        IdDict{Any, Vector{Float64}}(), IOBuffer(), Int[], Int[], _SeenSet()
    )
end

# The body's `_FastKey`, or `false`. `branch` is its one branch, `id` that
# branch key's number.
function _fast_key_model(eq::_AffineEq, branch, id::Int)
    idx_names = eq.names
    idxset = eq.ctx.idxset
    get(eq.bkey_sites, eq.body, true) && return false
    recipes, state_ks = branch.recipes, branch.state_lanes
    for rec in recipes
        all(a -> _affine_idx_expr(a, idxset), rec.idx_args) || return false
        rec.kind == LANE_CONST && rec.arr isa BoundedConstArray && return false
    end
    los = Vector{Int}[]; his = Vector{Int}[]; c0s = Vector{Int}[]
    cs = Vector{Vector{Int}}[]; bases = Int[]; strs = Vector{Int}[]
    for k in state_ks
        rec = recipes[k]
        aff = rec.affine
        aff === nothing && return false
        n = length(rec.idx_args)
        (length(rec.lo) == n && length(rec.hi) == n && length(aff[2]) == n) || return false
        c0 = Int[]; c = Vector{Int}[]
        for a in rec.idx_args
            r = _affine_form(a, idx_names)
            r === nothing && return false
            push!(c0, r.c0); push!(c, r.c)
        end
        push!(los, rec.lo); push!(his, rec.hi); push!(c0s, c0); push!(cs, c)
        push!(bases, aff[1]); push!(strs, aff[2])
    end
    return _FastKey(id, los, his, c0s, cs, bases, strs)
end

# `_cell_ckey!`'s key from the closed form: the branch number, then per state
# lane 1 for a ghost and 0 otherwise, as `_eval_recipe`'s slot (0 for a ghost,
# else `base + Σ v·strides`) decides it.
function _fast_ckey!(key::Vector{Int}, fk::_FastKey, loop::Vector{Int})
    empty!(key)
    push!(key, fk.id)
    @inbounds for i in eachindex(fk.base)
        lo = fk.lo[i]; hi = fk.hi[i]; c0 = fk.c0[i]; c = fk.c[i]; st = fk.strides[i]
        ghost = false
        slot = fk.base[i]
        for m in eachindex(c0)
            cm = c[m]
            v = c0[m]
            for d in eachindex(cm)
                v += cm[d] * loop[d]
            end
            (v < lo[m] || v > hi[m]) && (ghost = true)
            slot += v * st[m]
        end
        push!(key, (ghost || slot == 0) ? 1 : 0)
    end
    return key
end

# Whether `e` reaches an `index` of a `makearray` or `faq` producer, through the
# same children `_branch_key!` descends into.
function _has_indexed_producer(e, seen::IdDict{OpExpr, Nothing} = IdDict{OpExpr, Nothing}())
    e isa OpExpr || return false
    haskey(seen, e) && return false
    seen[e] = nothing
    if e.op == "index" && !isempty(e.args)
        fa = e.args[1]
        fa isa OpExpr && (fa.op == "makearray" || _is_faq_op(fa.op)) && return true
        # A gather pushed through an elementwise producer (`index(a + b, i)`)
        # indexes the producers among its operands (`_branch_key_pushdown!`).
        fa isa OpExpr && _is_scalar_op(fa.op) && _reaches_indexable_producer(fa) &&
            return true
    end
    for a in _operands(e)
        _has_indexed_producer(a, seen) && return true
    end
    e.expr_body !== nothing && _has_indexed_producer(e.expr_body, seen) && return true
    if e.values !== nothing
        for v in e.values
            _has_indexed_producer(v, seen) && return true
        end
    end
    return false
end

# ── LANE-AFFINE SIGNATURE (the cut key measures the LANE, not the output) ─────
#
# A gather key that recorded, per STATE lane, `Δ = slot − oln` — the lane's
# slot relative to the OUTPUT cell's slot — would be the right key only for
# a gather from an array laid out exactly like the output: a Cartesian stencil
# neighbour. It is the WRONG key for a gather whose array has a DIFFERENT shape
# from the output's — a lower-rank geometry column (`coslat_e[j]` read from an
# (i,j,k) loop), a staggered face field (`Mx` on (NLON+1, NLAT, NLEV)), a 2-D
# surface field. Those slots are perfectly affine in the loop indices, but with
# their OWN strides, so `Δ` moves at every cell and the signature reads a
# transition where there is none. Two costs follow, both O(grid):
#
#   * the edge-inward cut scan never stabilises (the key changes at every cell),
#     so it walks the whole half-range of every axis instead of stopping after
#     `_AFFINE_STABLE_GUARD` cells — the scan becomes O(axis length);
#   * every scanned axis is cut into segments up to the `_AFFINE_MAX_DELTA_SEGS`
#     cap, so the box count grows with the grid and every per-box cost
#     (branch key, corner verification, lane derivation, spine memo key) is paid
#     once per box.
#
# So each lane is keyed by its SUBSCRIPTS' own local behaviour instead: a
# subscript that is STRUCTURALLY affine in the loop indices (`+ - neg *` over
# loop names and integer literals) can never open a cut and is skipped outright,
# and any other subscript contributes its per-dim BACKWARD DIFFERENCE
# `v(loop) − v(loop − e_d)`. That difference is constant wherever the subscript
# is affine — no cut, at any grid size — and changes exactly at the cell where a
# clamp / fold / wrap engages, which is exactly where the box processor's corner
# verification would fail. It is reference-free by construction: keying the
# deviation from an affine model derived at some probe cell silently poisons the
# scan whenever that probe sits on the clamped side of the transition being
# looked for. Ghost membership (a state slot resolving to 0) keeps its own bit.

# Classify (and cache) one branch's lane subscripts: `true` for an argument that
# is NOT structurally affine in the loop indices and therefore has to be
# differenced per keyed cell, `false` for one that can never open a cut. Once per
# branch; the classification is a property of the EXPRESSION, not of any cell,
# so no reference point is involved (an earlier version derived an affine model
# at a reference cell and keyed the deviation from it — which silently poisons
# the scan when the reference happens to sit on the clamped side of the very
# transition being looked for, and then keys a change at EVERY cell).
function _lane_nonaffine_args!(eq::_AffineEq, bkey::String, recipes::Vector{_LaneRecipe})
    idxset = eq.ctx.idxset
    cached = get(eq.lane_ref, bkey, nothing)
    cached === nothing || return cached
    ref = Vector{Vector{Bool}}(undef, length(recipes))
    for k in eachindex(recipes)
        rec = recipes[k]
        ref[k] = Bool[!_affine_idx_expr(a, idxset) for a in rec.idx_args]
    end
    eq.lane_ref[bkey] = ref
    return ref
end

@inline _set_env!(env, idx_names, loop) =
    (
    for d in eachindex(idx_names)
        env[idx_names[d]] = loop[d]
    end; env
)
@inline _box_oln(base, strides, loop, D) =
    (
    o = base; @inbounds for d in 1:D
        o += loop[d] * strides[d]
    end; o
)

# Output slot of a cell via the ACTUAL state layout (var_map) — the ground truth
# the affine map is verified against. `lhs_idx_args` map loop indices → the LHS
# array subscripts (usually identity `D(q[i,j,k])`).
function _oln_via_varmap(lhs_var, lhs_idx_args, idx_env, var_map)
    du_inds = Int[_eval_const_int(a, idx_env) for a in lhs_idx_args]
    slot = get(var_map, _cell_key(lhs_var, du_inds), 0)
    slot == 0 && throw(TreeWalkError("E_TREEWALK_UNKNOWN_STATE", _cell_key(lhs_var, du_inds)))
    return slot
end

# The affine map loop indices → output slot, `oln = base + Σ_d loop_d·strides[d]`,
# with stride 0 along a one-value range. Computed from the variable's layout
# block when every LHS subscript is affine in one loop index and every corner
# cell lies in the block (`_output_affine_from_block`); otherwise strides come
# from unit steps off the range origin and the map is checked at every corner
# against `var_map`, a non-affine layout declining the whole equation.
function _derive_output_affine(lhs_var, lhs_idx_args, idx_names, ranges, var_map)
    got = _output_affine_from_block(lhs_var, lhs_idx_args, idx_names, ranges, var_map)
    got === nothing || return got
    D = length(idx_names)
    env = Dict{String, Int}()
    rep = Int[first(ranges[d]) for d in 1:D]
    oln_rep = _oln_via_varmap(lhs_var, lhs_idx_args, _set_env!(env, idx_names, rep), var_map)
    strides = zeros(Int, D)
    for d in 1:D
        if length(ranges[d]) >= 2
            l2 = copy(rep); l2[d] += 1
            strides[d] = _oln_via_varmap(
                lhs_var, lhs_idx_args,
                _set_env!(env, idx_names, l2), var_map
            ) - oln_rep
        end
    end
    base = oln_rep - _box_oln(0, strides, rep, D)
    for corner in Iterators.product(((first(ranges[d]), last(ranges[d])) for d in 1:D)...)
        cl = collect(Int, corner)
        want = _box_oln(base, strides, cl, D)
        got = _oln_via_varmap(lhs_var, lhs_idx_args, _set_env!(env, idx_names, cl), var_map)
        want == got || _decline(:output_layout_not_affine, lhs_var)
    end
    return base, strides
end

# `_derive_output_affine`'s map from the block, or `nothing` when the block or
# the subscript forms do not give it.
function _output_affine_from_block(lhs_var, lhs_idx_args, idx_names, ranges, var_map)
    blk = _affine_block(var_map, lhs_var)
    (blk !== nothing && length(blk.lo) == length(lhs_idx_args)) || return nothing
    D = length(idx_names)
    forms = Tuple{Int, Int, Int}[]
    for a in lhs_idx_args
        f = a isa ASTExpr ? _lhs_index_affine(a, idx_names) : nothing
        f === nothing && return nothing
        push!(forms, f)
    end
    cell = Vector{Int}(undef, length(forms))
    for corner in Iterators.product(((first(ranges[d]), last(ranges[d])) for d in 1:D)...)
        _lhs_affine_cell!(cell, forms, corner)
        all(k -> blk.lo[k] <= cell[k] <= blk.hi[k], eachindex(cell)) || return nothing
    end
    full = zeros(Int, D)
    base = blk.base
    for (k, (pos, coef, c)) in enumerate(forms)
        base += (c - blk.lo[k]) * blk.strides[k]
        pos == 0 || (full[pos] += coef * blk.strides[k])
    end
    # A one-value range keeps stride 0, its contribution folded into `base`.
    strides = zeros(Int, D)
    for d in 1:D
        if length(ranges[d]) >= 2
            strides[d] = full[d]
        else
            base += first(ranges[d]) * full[d]
        end
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
        inds[d] = _resolve_const_index(
            arr, rec.var_name, d,
            _eval_const_int(rec.idx_args[d], idx_env, const_arrays), size(arr, d)
        )
    end
    return LinearIndices(size(arr))[inds...]
end

# Region signature (`bkey`) at cell `loop` + its cached branch template — the
# part `_process_affine_box!` needs, without the scan-only gather key
# (`_cell_ckey!`) and its state-recipe evals.
function _cell_bkey!(eq::_AffineEq, loop)
    ctx_proto = eq.ctx
    body = eq.body
    env = ctx_proto.idx_env
    empty!(env)
    _set_env!(env, eq.names, loop)
    if get!(() -> _has_indexed_producer(body), eq.bkey_sites, body)
        _seen_restart!(eq.bseen)
        # The loop-index memo is the one every branch template's `_stencilize`
        # reads (`ctx_proto.vsmemo`): both ask `_refs_idxset` of the same nodes
        # under the same `idxset`. A nested walk that grows `idxset` takes a
        # fresh memo of its own (`_branch_key_indexed!`) and restores the set
        # before returning, so this memo only ever holds answers for
        # `ctx_proto.idxset`.
        _branch_key!(
            eq.bio, body, ctx_proto.idxset, env, ctx_proto.const_arrays,
            ctx_proto.vsmemo, eq.bseen
        )
    end
    bkey = String(take!(eq.bio))
    branch = get(eq.branch_cache, bkey, nothing)
    if branch === nothing
        branch = _build_branch_template(body, ctx_proto, eq.var_map, eq.param_sym_set)
        eq.branch_cache[bkey] = branch
    end
    return bkey, branch
end
# The state lanes' slots at the keyed cell: each recipe's compiled evaluator
# where it answers (the same integer arithmetic and slot map as `_eval_recipe`),
# `_eval_recipe` itself otherwise, so every error is the per-cell resolution's.
function _ckey_state_slots!(
        state_vals::Vector{Int}, eq::_AffineEq, bkey::String,
        recipes, state_ks, loop, env
    )
    var_map = eq.var_map
    evs = get!(eq.lane_evals, bkey) do
        compiled = loop isa Vector{Int}
        # The state lanes' evaluators are the box processor's
        # (`_box_lane_evals!`, the branch key's recipes under the equation's
        # context): compiled once per branch key for the scan and the boxes both.
        all_evs = compiled ? _box_lane_evals!(eq, bkey) : nothing
        Union{Nothing, _LaneEval{typeof(var_map)}}[
            compiled ? all_evs[k] : nothing for k in state_ks
        ]
    end
    _ckey_fill_slots!(state_vals, evs, recipes, state_ks, loop, env, var_map, eq.const_arrays)
    return state_vals
end

function _ckey_fill_slots!(
        state_vals::Vector{Int}, evs::Vector{Union{Nothing, E}}, recipes,
        state_ks, loop, env, var_map, const_arrays
    ) where {E}
    @inbounds for i in eachindex(state_ks)
        le = evs[i]
        if le !== nothing
            v, ok = _lane_eval_state(le, loop)
            if ok
                state_vals[i] = v
                continue
            end
        end
        state_vals[i] = _eval_recipe(recipes[state_ks[i]], env, var_map, const_arrays)::Int
    end
    return state_vals
end

# Per-cell scan key: the branch key's number (region selection) followed by
# the gather key, at cell `loop`. Builds/caches ONE sentinel template per region
# signature (the expensive step, bounded by #groups); cheap recipe evals give the
# gather key.
#
# The gather key has TWO strengths, selected by `strong`:
#   * the ghost-bit key (in-bounds vs ghost per state lane), for the scans that
#     need only the branch;
#   * the lane-affine key (`strong`): the ghost bits, then each structurally
#     non-affine lane subscript's backward difference along every dim
#     (`_lane_nonaffine_args!`), so a clamp, fold or wrap of a gathered
#     subscript changes the key at the cell where it engages and therefore
#     opens a CUT there, giving it its own box.
# Const lanes with a declared BOUNDARY POLICY (BoundedConstArray) additionally
# key their per-dim fold class (in-range / clamp-low / clamp-high / wrap count),
# so a clamp/wrap transition of a const gather also produces a cut — within each
# resulting segment the resolved const index is affine again.
function _cell_ckey!(key::Vector{Int}, eq::_AffineEq, loop; strong::Bool = false)
    # The closed form gives the same key wherever it applies.
    fk = eq.fast_key
    fk isa _FastKey && loop isa Vector{Int} && return _fast_ckey!(key, fk, loop)
    bkey, branch = _cell_bkey!(eq, loop)
    idx_names = eq.names
    ranges = eq.ranges
    env = eq.ctx.idx_env    # left populated with `loop` by _cell_bkey! (branch_key restores its temp binds)
    recipes, state_ks = branch.recipes, branch.state_lanes
    # Only the STATE lanes feed the gather key; evaluate just those into a reused
    # Vector{Int} (no Vector{Any}, no boxing, and no wasted non-state recipe evals).
    state_vals = eq.state_scratch
    resize!(state_vals, length(state_ks))
    _ckey_state_slots!(state_vals, eq, bkey, recipes, state_ks, loop, env)
    # The key is a vector of integers. Its first entry numbers the branch key;
    # everything after it has a length and a layout fixed by the branch (its
    # lanes, their subscripts, its policy-bearing const lanes), so two cells'
    # keys are equal exactly when the branch and every entry agree.
    empty!(key)
    push!(key, get!(eq.bkey_ids, bkey, length(eq.bkey_ids) + 1))
    if !strong
        @inbounds for v in state_vals
            push!(key, v == 0 ? 1 : 0)
        end
    else
        # LANE-AFFINE key (see `_lane_nonaffine_args!`): the ghost pattern, then
        # every lane subscript's DEVIATION from its own affine model of the loop
        # indices. Zero wherever the lane is affine — at any grid size — so a
        # cross-shape gather (lower-rank geometry, staggered face, surface
        # field) stops manufacturing a cut at every cell.
        @inbounds for v in state_vals
            push!(key, v == 0 ? 1 : 0)
        end
        ref = _lane_nonaffine_args!(eq, bkey, recipes)
        D = length(idx_names)
        ca = eq.const_arrays
        back = eq.back_scratch
        resize!(back, D)
        @inbounds for k in eachindex(recipes)
            rk = ref[k]
            (isempty(rk) || !any(rk)) && continue
            rec = recipes[k]
            for m in eachindex(rk)
                rk[m] || continue                  # structurally affine: no cut, ever
                a = rec.idx_args[m]
                v = _eval_const_int(a, env, ca)
                # LOCAL BACKWARD DIFFERENCE per dim: constant wherever the
                # subscript is affine, and changing exactly at the cell where a
                # clamp / fold / wrap engages. Reference-free, so no probe point
                # can poison it. `loop − e_d` may leave the range; a subscript is
                # a total integer function of the loop, so evaluating there is
                # always safe (unlike a slot, which can be a ghost).
                for d in 1:D
                    @inbounds for dd in 1:D
                        back[dd] = loop[dd]
                    end
                    # CLAMPED to the dim's own range. A subscript is NOT a total
                    # function of an out-of-range loop point: an unstructured
                    # gather (`index(cells_on_cell, i, n)`) resolves through a
                    # const array and throws `E_TREEWALK_CONSTARRAY_OOB` at
                    # `i = lo − 1`. At `lo` the difference degenerates to 0 for
                    # every lane, which costs nothing: `lo` is a segment start
                    # unconditionally, and the scan compares `lo` only against
                    # `lo + 1`.
                    back[d] = max(first(ranges[d]), loop[d] - 1)
                    vb = _eval_const_int(a, _set_env!(env, idx_names, back), ca)
                    push!(key, v - vb)
                end
                _set_env!(env, idx_names, loop)    # restore for the next lane
            end
        end
    end
    _const_fold_key!(key, recipes, env, eq.const_arrays)
    fk === nothing && (eq.fast_key = _fast_key_model(eq, branch, key[1]))
    return key
end

# Append each policy-bearing const lane's per-dim boundary-fold class to the
# key, as two integers: (0, 0) in-range, (1, 0) / (2, 0) clamp-low/high,
# (3, k) the periodic wrap count k (`fld(raw-1, n)` — the multiple of n the fold
# subtracts, so two cells share a class iff the resolved index is the SAME
# affine function of the raw one), (4, 0) an out-of-range index on an :error
# dim (the derive step then throws the exact per-cell
# `E_TREEWALK_CONSTARRAY_OOB`). Plain const arrays (no declared policy)
# contribute nothing: in-range indices have one class, and an out-of-range one
# throws identically on every path.
function _const_fold_key!(
        key::Vector{Int}, recipes::Vector{_LaneRecipe}, env,
        const_arrays
    )
    for rec in recipes
        rec.kind == LANE_CONST || continue
        arr = rec.arr
        arr isa BoundedConstArray || continue
        for d in 1:length(rec.idx_args)
            v = _eval_const_int(rec.idx_args[d], env, const_arrays)
            n = size(arr, d)
            if 1 <= v <= n
                push!(key, 0); push!(key, 0)
            else
                pol = _const_dim_boundary(arr, d)
                if pol === :clamp
                    push!(key, v < 1 ? 1 : 2); push!(key, 0)
                elseif pol === :periodic
                    push!(key, 3); push!(key, fld(v - 1, n))
                else
                    push!(key, 4); push!(key, 0)
                end
            end
        end
    end
    return key
end

# Probe values for a range: low / mid / high (deduplicated).
function _probe_values(rng::UnitRange{Int})
    lo, hi = first(rng), last(rng)
    return unique(Int[lo, (lo + hi) ÷ 2, hi])
end

# Structural cut candidates: a per-cell signature changes at a makearray REGION
# boundary (`_select_region`), and — unlike a ghost transition — that boundary can
# sit anywhere in the range, including mid-domain, so the edge-inward scan cannot
# be relied on to reach it. Harvest every region boundary from the body up front
# (O(#regions), grid-independent) so it is probed explicitly.
#
# A box takes the template of its first cell (`_process_affine_box!`) and nothing
# checks the region selections of the rest of it, so a boundary the harvest and
# the edge scans both miss is a box spanning two regions that silently computes
# the first one's value everywhere. The harvest therefore follows each
# makearray subscript back to the loop indices, through every name that binds
# one, and answers for every subscript it meets:
#
#   * a loop index plus a constant, `i + c` — directly, or through the output
#     index of an `faq` gathered at one (`index(faq(index(makearray, i), i),
#     _lp0)`, the lifted form of a whole-array equation): the region bounds,
#     shifted by `c`, are the candidates;
#   * any other function of ONE loop index (a clamp, a `mod`, a contracted index
#     added to it): every cell of that index is a candidate, which costs a key
#     per cell along it and finds every change;
#   * a function of two or more loop indices: no set of per-dim cuts describes
#     where its selection changes, so the tier declines the equation.
#
# Region selection reached through an elementwise producer (`index(a + b, i)`)
# is followed into its operands, as `_stencilize_index` pushes the gather.
#
# Returns the candidate starts per dim; per dim, whether every cell of it is a
# candidate; and per dim, the starts the OTHER dims' scans must also probe
# (`_scan_dim_cuts`). A region bounded in one axis of its makearray spans the
# makearray's whole extent in every other axis, so any probe line inside that
# extent crosses it: only a region bounded in two or more axes, and the extent's
# own ends, add probe lines.
function _region_cut_candidates(body, idx_names::Vector{String})
    D = length(idx_names)
    cands = [Set{Int}() for _ in 1:D]
    probes = [Set{Int}() for _ in 1:D]
    full = falses(D)
    # What a name is in terms of the loop indices: `(d, c)` for `loop[d] + c`, a
    # `Vector{Int}` of the dims it depends on otherwise. A name absent from the
    # map depends on none (a constant, a contracted index, a variable).
    alias0 = Dict{String, Any}(idx_names[d] => (d, 0) for d in 1:D)
    # Deduped per (node, alias map CONTENT): a Set-collector over the
    # region bounds is path-multiplicity-insensitive, so entering each distinct
    # node once per distinct binding collects exactly the same candidate sets,
    # and a template gathered along many paths at the same subscripts is walked
    # once, not once per path.
    alias_ids = Dict{Vector{Pair{String, Any}}, Int}()
    aid_of = IdDict{Dict{String, Any}, Int}()
    aid(a) = get!(aid_of, a) do
        get!(alias_ids, sort!(collect(a); by = first), length(alias_ids) + 1)
    end
    seen = Set{Tuple{UInt, Int}}()
    iseen = Set{Tuple{UInt, Vector{Any}, Int}}()
    lit(x) = x isa IntExpr || (x isa NumExpr && isinteger((x::NumExpr).value))
    litval(x) = x isa IntExpr ? Int((x::IntExpr).value) : Int((x::NumExpr).value)
    function deps!(acc::Set{Int}, e, alias)
        if e isa VarExpr
            v = get(alias, (e::VarExpr).name, nothing)
            v isa Tuple && push!(acc, v[1])
            v isa Vector{Int} && union!(acc, v)
        elseif e isa OpExpr
            foreach(c -> deps!(acc, c, alias), child_exprs(e::OpExpr))
        end
        return acc
    end
    # A subscript as `nothing` (no loop dependence), `(d, c)` or a dim vector.
    function sub(e, alias)
        e isa VarExpr && return get(alias, (e::VarExpr).name, nothing)
        if e isa OpExpr && ((e::OpExpr).op == "+" || (e::OpExpr).op == "-")
            o = e::OpExpr
            if o.op == "+" || length(o.args) == 2
                aff = nothing; c = 0; ok = true
                for (k, a) in enumerate(o.args)
                    sgn = (o.op == "-" && k == 2) ? -1 : 1
                    if lit(a)
                        c += sgn * litval(a)
                        continue
                    end
                    s = sub(a, alias)
                    s === nothing && (ok = false; break)
                    (s isa Tuple && aff === nothing && sgn == 1) || (ok = false; break)
                    aff = s
                end
                ok && aff !== nothing && return (aff[1], aff[2] + c)
            end
        end
        d = deps!(Set{Int}(), e, alias)
        isempty(d) && return nothing
        return sort!(collect(d))
    end
    function mark!(s, lo_hi, probe::Bool)
        s === nothing && return
        return if s isa Tuple
            d, c = s
            lo = _ma_region_bound(lo_hi[1]); hi = _ma_region_bound(lo_hi[2])
            if lo === nothing || hi === nothing
                full[d] = true
            else
                push!(cands[d], lo - c); push!(cands[d], hi + 1 - c)
                probe && (push!(probes[d], lo - c); push!(probes[d], hi + 1 - c))
            end
        elseif length(s) == 1
            full[s[1]] = true
        else
            _decline(:region_multi_index, "no box cut describes it")
        end
    end
    # A producer gathered at subscripts `subs` (one analysis per axis).
    function indexed!(p, subs, alias)
        p isa OpExpr || return
        pe = p::OpExpr
        ikey = (objectid(pe), subs, aid(alias))
        ikey in iseen && return
        push!(iseen, ikey)
        return if pe.op == "makearray"
            regions = pe.regions === nothing ? Vector{Vector{Vector{Any}}}() : pe.regions
            values = pe.values === nothing ? ASTExpr[] : pe.values
            # Per axis, the makearray's extent over its regions (`nothing` when a
            # bound is not a literal): a region whose axis range is that extent
            # spans the axis.
            ext = map(eachindex(subs)) do j
                lo = typemax(Int); hi = typemin(Int)
                for region in regions
                    (length(region) == length(subs) && length(region[j]) >= 2) || continue
                    l = _ma_region_bound(region[j][1]); h = _ma_region_bound(region[j][2])
                    (l === nothing || h === nothing) && return nothing
                    lo = min(lo, l); hi = max(hi, h)
                end
                return lo <= hi ? (lo, hi) : nothing
            end
            spans(region, j) = ext[j] !== nothing &&
                _ma_region_bound(region[j][1]) == ext[j][1] &&
                _ma_region_bound(region[j][2]) == ext[j][2]
            for region in regions
                length(region) == length(subs) || continue
                axes = [j for j in eachindex(subs) if length(region[j]) >= 2]
                probe = count(j -> !spans(region, j), axes) >= 2
                for j in axes
                    mark!(subs[j], region[j], probe)
                end
            end
            # The extent's own ends are probed, so a probe line lies inside the
            # makearray wherever the scanned dims' defaults fall outside it.
            for j in eachindex(subs)
                sj = subs[j]
                (ext[j] !== nothing && sj isa Tuple) || continue
                d, c = sj
                push!(probes[d], ext[j][1] - c); push!(probes[d], ext[j][2] + 1 - c)
            end
            for (r, v) in enumerate(values)
                if _is_array_producer(v)
                    ve = v::OpExpr
                    rank = _producer_rank(ve)
                    vs = subs
                    if rank != length(subs) && r <= length(regions)
                        reg = regions[r]
                        vs = subs[
                            _region_value_axes(
                                rank, length(subs),
                                j -> !(j <= length(reg) && reg[j][1] != reg[j][2])
                            ),
                        ]
                    end
                    length(vs) == rank ? indexed!(ve, vs, alias) : walk(ve, alias)
                else
                    walk(v, alias)
                end
            end
        elseif _is_faq_op(pe.op)
            oi = String[
                String(s) for s in something(pe.output_idx, Any[])
                    if s isa AbstractString
            ]
            inner = copy(alias)
            pe.ranges === nothing || foreach(k -> delete!(inner, String(k)), keys(pe.ranges))
            for (d, n) in enumerate(oi)
                s = d <= length(subs) ? subs[d] : nothing
                s === nothing ? delete!(inner, n) : (inner[n] = s)
            end
            pe.expr_body === nothing || walk(pe.expr_body, inner)
            pe.filter === nothing || walk(pe.filter, inner)
        elseif _is_scalar_op(pe.op)
            for a in pe.args
                indexed!(a, subs, alias)
            end
        else
            walk(pe, alias)
        end
    end
    function walk(n, alias)
        n isa OpExpr || return
        o = n::OpExpr
        key = (objectid(o), aid(alias))
        key in seen && return
        push!(seen, key)
        if o.op == "index" && !isempty(o.args) && o.args[1] isa OpExpr
            for k in 2:length(o.args)
                walk(o.args[k], alias)
            end
            indexed!(o.args[1], Any[sub(k, alias) for k in o.args[2:end]], alias)
            return
        end
        inner = alias
        if o.ranges !== nothing || o.output_idx !== nothing
            # A binder outside a gather: its names are not loop indices here.
            inner = copy(alias)
            o.ranges === nothing || foreach(k -> delete!(inner, String(k)), keys(o.ranges))
            o.output_idx === nothing ||
                foreach(s -> s isa AbstractString && delete!(inner, String(s)), o.output_idx)
        end
        return foreach(c -> walk(c, inner), child_exprs(o))
    end
    walk(body, alias0)
    return cands, full, probes
end

# How many consecutive identical per-cell signatures certify that the interior of
# a dimension has stabilized. A finite-volume stencil operator's region + ghost
# transitions all lie within its half-width of an END (wrap columns, one-sided
# boundary rows, ghost gathers), so once this many cells in a row share a
# signature we are safely past every boundary layer. 8 covers the widest operator
# on the grid (monotone PPM's 7-cell support → ≤3-cell boundary layers) with
# margin. A wider lane transition that slipped past would give a box spanning a
# cut, which per-box verification catches; a region boundary is not verified per
# box and is found by the harvest instead (`_region_cut_candidates`).
const _AFFINE_STABLE_GUARD = 8

# Strong-key cut cap, per dim. The lane-affine key (see `_cell_ckey!`) gives a
# clamp / fold / wrap transition its own box — a handful of segments, bounded by
# the operator's half-width at each end. A GENUINELY UNSTRUCTURED gather (a
# slot indirect through a connectivity permutation) deviates from its affine
# model at every cell; carving a box per cell would trade the O(#groups) build
# for O(#cells) kernels. So when a dim's strong-key scan opens more segments
# than this cap, that dim's cuts are recomputed with the BASE key (region ×
# ghost × const-fold) and the non-uniform lane is left for the box processor's
# indirect-table derivation (`_derive_lane_repl`), which materializes a per-box
# slot table instead.
const _AFFINE_MAX_DELTA_SEGS = 16

# Cut START indices per loop dim. For each dim, hold the OTHER dims at every
# low/mid/high probe (and at each of their region starts) and record where the
# per-cell signature changes — but scan
# INWARD FROM BOTH ENDS rather than across the whole range, stopping once the
# signature has been stable for `_AFFINE_STABLE_GUARD` cells. Because a stencil
# operator's transitions are all within its half-width of an end, this finds every
# real cut in O(boundary width) instead of O(N_d) — the difference between an
# N-independent build and one that re-walks the body ~N times per dim (fatal at
# millions of cells). The interior between the two converged fronts is a single
# uniform segment. Mid-domain makearray REGION boundaries — which need not lie near
# an end — are harvested structurally up front (`_region_cut_candidates`) and
# probed explicitly. A lane access neither scan nor candidate reaches is still
# caught by per-box verification in `_derive_lane_repl` (→ an exact table): at
# the corners for a structurally affine subscript, at every cell otherwise.
# Region SELECTION is not verified per box — a box takes its first cell's
# template (`_process_affine_box!`) — so the region cuts must be complete, which
# is what the harvest and the region-start probe lines are for.
#
# `strong` selects the strong (lane-affine) key for the first scan of each
# dim, falling back to the base key when that scan's segment count exceeds
# `_AFFINE_MAX_DELTA_SEGS` (unstructured gather → the indirect-table derivation
# owns it instead).
function _affine_cut_points(eq::_AffineEq; strong::Bool = false)
    body = eq.body
    idx_names = eq.names
    ranges = eq.ranges
    D = length(idx_names)
    cuts = Vector{Vector{Int}}(undef, D)
    region_cands, full, region_probes = _region_cut_candidates(body, idx_names)
    # A region bounded in several dims is seen on a dim's probe lines only if
    # one of them crosses it, so the starts `_region_cut_candidates` names for
    # probing join each dim's probe values when the other dims are scanned. A
    # dim whose every cell is a candidate (`full`) adds none: its probe lines
    # stay low / mid / high.
    probe_extra = Vector{Vector{Int}}(undef, D)
    for d in 1:D
        rng = ranges[d]
        probe_extra[d] = full[d] ? Int[] :
            sort!(Int[c for c in region_probes[d] if first(rng) <= c <= last(rng)])
    end
    for d in 1:D
        full[d] && union!(region_cands[d], (first(ranges[d]) + 1):last(ranges[d]))
    end
    for d in 1:D
        starts = _scan_dim_cuts(eq, region_cands, d, strong, probe_extra)
        if strong && length(starts) > _AFFINE_MAX_DELTA_SEGS
            starts = _scan_dim_cuts(eq, region_cands, d, false, probe_extra)
        end
        cuts[d] = sort!(collect(starts))
    end
    return cuts
end

# One dim's edge-inward signature scan (see `_affine_cut_points`). Returns the
# set of segment-start indices for dim `d` under the signature strength `strong`.
function _scan_dim_cuts(
        eq::_AffineEq, region_cands, d::Int, strong::Bool,
        probe_extra::Vector{Vector{Int}} = [Int[] for _ in eq.names]
    )
    ranges = eq.ranges
    D = length(eq.names)
    rng = ranges[d]; lo, hi = first(rng), last(rng)
    starts = Set{Int}(); push!(starts, lo)
    otherdims = Int[dd for dd in 1:D if dd != d]
    probesets = isempty(otherdims) ? [()] :
        collect(
            Iterators.product(
                (
                    unique!(vcat(_probe_values(ranges[dd]), probe_extra[dd]))
                    for dd in otherdims
                )...
            )
        )
    loop = Vector{Int}(undef, D)
    # Two key buffers, alternated: `ck` fills the one `prev` does not hold.
    kb1 = Int[]; kb2 = Int[]
    ck(iv, prev) = (
        loop[d] = iv;
        _cell_ckey!(prev === kb1 ? kb2 : kb1, eq, loop; strong = strong)
    )
    # Region boundaries in this dim, kept only where they open a real segment
    # (lo < C ≤ hi). Each is confirmed below by comparing C-1 to C.
    cand_d = sort!(Int[c for c in region_cands[d] if lo < c <= hi])
    # Bound each front at the midpoint so a small range is covered once, not
    # twice (the two scans meet at `mid`, overlapping on that single cell so
    # the mid/mid+1 pair is still compared). For a large range each front
    # stabilizes long before `mid`, so the deep interior is never scanned.
    mid = (lo + hi) ÷ 2
    for probe in probesets
        for (ii, dd) in enumerate(otherdims)
            loop[dd] = probe[ii]
        end
        # Over-cap early exit for a strong-key scan: an unstructured gather deviates
        # from its affine model at EVERY cell, so without this the fronts would never stabilize and
        # the scan would walk the whole range before the caller's cap fallback.
        overcap() = strong && length(starts) > _AFFINE_MAX_DELTA_SEGS
        # Scan up from the low end: a change at `iv` opens a segment there.
        prev = nothing; stable = 0; iv = lo
        while iv <= mid
            cur = ck(iv, prev)
            if prev !== nothing
                if cur != prev
                    push!(starts, iv); stable = 0
                    overcap() && break
                else
                    stable += 1; stable >= _AFFINE_STABLE_GUARD && break
                end
            end
            prev = cur; iv += 1
        end
        # Scan down from the high end: a change between `iv` and `iv+1` opens a
        # segment at `iv+1`.
        prev = nothing; stable = 0; iv = hi
        while iv >= mid && !overcap()
            cur = ck(iv, prev)
            if prev !== nothing
                if cur != prev
                    push!(starts, iv + 1); stable = 0
                    overcap() && break
                else
                    stable += 1; stable >= _AFFINE_STABLE_GUARD && break
                end
            end
            prev = cur; iv -= 1
        end
        # Mid-domain region boundaries the edge scans cannot reach: confirm each
        # candidate is a genuine transition (C-1 vs C) before opening a segment.
        for C in cand_d
            (kc = ck(C - 1, nothing); ck(C, kc) != kc) && push!(starts, C)
        end
        # A strong-key scan past the cap is abandoned early — the caller redoes the
        # dim with the base key, so finishing the sweep would be wasted work.
        strong && length(starts) > _AFFINE_MAX_DELTA_SEGS && break
    end
    return starts
end

# The part of a box's range `r` a program runs, given the range `run` it
# computes: their overlap, or (none) the empty range just below `r`'s start,
# so an empty box keeps its place and its ordering among its neighbours.
function _clip_run(r::UnitRange{Int}, run::UnitRange{Int})
    c = max(first(r), first(run)):min(last(r), last(run))
    return isempty(c) ? (first(r):(first(r) - 1)) : c
end

# Turn per-dim cut starts into segment ranges covering `rng`.
function _segments(starts::Vector{Int}, rng::UnitRange{Int})
    segs = UnitRange{Int}[]
    for i in eachindex(starts)
        e = i < length(starts) ? starts[i + 1] - 1 : last(rng)
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
# collide), and the fixed shape means
# `_acc_vn_key`'s per-ACCESS-node CSE key and `_lane_repl_key`'s per-lane key hash
# with no per-node string materialization.
function _desc_key(d::_AccDesc)
    k = d.kind
    k === _AK_STATE_AFFINE && return (0x01, UInt64(0), d.delta, d.idx, 0, 0)
    k === _AK_LOOP_IDX     && return (0x02, UInt64(0), d.dim, 0, 0, 0)
    if k === _AK_CONST_BOX || k === _AK_FORCING_BOX || k === _AK_STATE_TBL_BOX
        tag = k === _AK_CONST_BOX ? 0x03 : k === _AK_FORCING_BOX ? 0x04 : 0x05
        id = objectid(k === _AK_STATE_TBL_BOX ? d.conn : d.arr)
        # A box of rank above 3 appends the strides of its dims past the third,
        # so the key stays exact at every rank (and unchanged at rank ≤ 3).
        isempty(d.sx) || return (tag, id, d.s1, d.s2, d.s3, d.off, Tuple(d.sx))
        return (tag, id, d.s1, d.s2, d.s3, d.off)
    end
    return (0xff, objectid(d), 0, 0, 0, 0)
end
function _lane_repl_key(lane_repl)
    io = IOBuffer()
    for r in lane_repl
        if r isa _LitRepl
            print(io, 'L', r.v, ';')
        else
            t = _desc_key((r::_AccRepl).desc)
            print(io, 'A', t[1], ',', t[2], ',', t[3], ',', t[4], ',', t[5], ',', t[6])
            length(t) > 6 && print(io, ',', t[7])
            print(io, ';')
        end
    end
    return String(take!(io))
end

# Box-local DENSE addressing for a materialized per-box table: strides over the
# box dims (fastest-first, matching `Iterators.product` fill order) and the
# offset that maps the cell multi-index `midx` to `off + Σ(midx_d-1)·s_d`.
function _box_local_addr(box, D)
    s = zeros(Int, max(D, 3))
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

# The addressing of a table over the cells `run` of `box` that a program runs:
# `_box_local_addr(box)` when it runs all of them. A tile that shares its
# code (range_hooks.jl) runs only its share of a box, so its tables cover
# only those cells, and its build costs what its cells
# cost. A table extent is 1 exactly where the box's is (a wider one is at
# least 2, even over one cell or none), so every stride the emitted code holds
# as the literal 1 is the one the whole-domain program holds there.
function _box_table_addr(box, run, D)
    run === box && return _box_local_addr(box, D)
    s = zeros(Int, max(D, 3))
    acc = 1
    for d in 1:D
        s[d] = acc
        acc *= length(box[d]) == 1 ? 1 : max(length(run[d]), 2)
    end
    off = 1
    for d in 1:D
        off -= (first(run[d]) - 1) * s[d]
    end
    return s, off, acc
end

# One recipe value per cell of `run` (see `_box_table_addr`) in the table's
# addressing, every other entry zero, with the table's strides and offset.
function _box_table(
        ::Type{T}, rec::_LaneRecipe, idx_names, box, run, D, var_map,
        const_arrays
    ) where {T}
    s, off, len = _box_table_addr(box, run, D)
    run === box && return (
        _fill_box_table!(
            Vector{T}(undef, len), rec, idx_names, box, D,
            var_map, const_arrays
        ), s, off,
    )
    vals = _fill_box_table!(
        Vector{T}(undef, prod(d -> length(run[d]), 1:D; init = 1)),
        rec, idx_names, run, D, var_map, const_arrays
    )
    tbl = zeros(T, len)
    j = 0
    for I in CartesianIndices(ntuple(d -> UnitRange{Int}(run[d]), D))
        j += 1
        a = off
        @inbounds for d in 1:D
            a += (I[d] - 1) * s[d]
        end
        tbl[a] = vals[j]
    end
    return tbl, s, off
end

# ── LANE-AFFINE STATE BOX (a state gather on its OWN grid) ────────────────
#
# `_AK_STATE_AFFINE` models `u[oln + Δ]` — a gather from an array laid out
# EXACTLY like the output, which is every Cartesian stencil neighbour. It does
# not model a gather whose array has a DIFFERENT shape: a lower-rank geometry
# column (`coslat_e[j]` read from an (i,j,k) loop), a staggered face field on
# (NLON+1, NLAT, NLEV), a 2-D surface field. Those slots are affine in the loop
# indices too, but with the ARRAY's own strides, so `Δ` is not constant and the
# derivation below fell through to a dense per-box slot table — one
# `_eval_recipe` and one stored `Int` per box CELL, per lane, which is the
# build's largest grid-dependent term on a transport model.
#
# The const and live-forcing branches already have the right descriptor for
# this: `_AccConstBox` / `_AccForcingBox` address their own grid as
# `off + Σ(midx_d−1)·s_d`. `_AccStateTblBox` has the same addressing, and its
# `conn` table only has to map that address to a slot — so a lane whose slot is
# affine in the loop needs no per-cell table at all: it needs the strides, and a
# table that is the IDENTITY over the variable's own slot block. That block is
# one dense contiguous run per array variable (`_enumerate_array_cell_names`
# lays cells out column-major, contiguously), so the table is the range
# `lo0:hi0` itself, never materialized.


_state_slot_identity(lo0::Int, hi0::Int) = lo0:hi0

# The variable's own contiguous slot block, from the affine slot map the recipe
# already carries (`rec.affine`, corner-verified against `var_map` in
# `_derive_var_affine`) and its `array_var_info` bounds. Strides are the
# column-major products of the extents, so all-positive; the block runs from the
# `lo` corner to the `hi` corner.
function _state_slot_block(rec::_LaneRecipe)
    aff = rec.affine
    aff === nothing && return nothing
    base, strides = aff
    n = length(rec.lo)
    (n == length(rec.hi) && n == length(strides)) || return nothing
    lo0 = base; hi0 = base
    @inbounds for d in 1:n
        strides[d] >= 0 || return nothing
        lo0 += rec.lo[d] * strides[d]
        hi0 += rec.hi[d] * strides[d]
    end
    (lo0 >= 1 && hi0 >= lo0) || return nothing
    return (lo0, hi0)
end

# One recipe value per cell of `box`, in box-local (first index fastest) order:
# the compiled lane evaluator where it answers, `_eval_recipe` where it does
# not (see "Compiled lane evaluation", stencil.jl).
function _fill_box_table!(
        tbl::Vector, rec::_LaneRecipe, idx_names, box, D,
        var_map, const_arrays
    )
    le = _lane_evaluator(rec, collect(String, idx_names), var_map, const_arrays)
    _fill_box_table_nt!(
        tbl, rec, le, idx_names, ntuple(d -> UnitRange{Int}(box[d]), D),
        var_map, const_arrays
    )
    return tbl
end

function _fill_box_table_nt!(
        tbl::Vector{T}, rec::_LaneRecipe, le, idx_names,
        rngs::NTuple{N, UnitRange{Int}}, var_map,
        const_arrays
    ) where {T, N}
    env = Dict{String, Int}()
    loop = Vector{Int}(undef, N)
    j = 0
    for I in CartesianIndices(rngs)
        j += 1
        @inbounds for d in 1:N
            loop[d] = I[d]
        end
        if le !== nothing
            v, ok = _lane_eval(le, loop)
            if ok
                @inbounds tbl[j] = v
                continue
            end
        end
        tbl[j] = _eval_recipe(
            rec, _set_env!(env, idx_names, loop), var_map,
            const_arrays
        )::T
    end
    return tbl
end

# Materialize a NON-AFFINE state lane as a per-box slot table: one `_eval_recipe` per box cell — the SAME resolution
# the per-cell fallback would run — stored densely in box-local layout, with 0
# marking a ghost (fetched as the ghost literal 0.0). This is what an
# unstructured gather (slot indirect through a connectivity const) lowers to;
# it is bit-identical by construction and O(box) — the same order as the
# connectivity input, and strictly smaller than the per-cell fallback's
# per-lane slot vectors.
function _materialize_state_tbl(
        rec::_LaneRecipe, idx_names, box, D,
        var_map, const_arrays, run = box
    )
    return _materialize_state_tbl_inner(rec, idx_names, box, D, var_map, const_arrays, run)
end
function _materialize_state_tbl_inner(
        rec::_LaneRecipe, idx_names, box, D,
        var_map, const_arrays, run = box
    )
    tbl, s, off = _box_table(Int, rec, idx_names, box, run, D, var_map, const_arrays)
    return _AccRepl(_AccStateTblBox(tbl, s, off))
end

# Materialize a NON-AFFINE live-forcing (pgather) lane as a per-box INDEX table
# into the ALIASED live buffer. The forcing chains that observed
# inlining splices into stencil lanes gather their raw buffers with clamped
# subscripts (`max(k-1,1)` / `min(k,NLEV)` at the column walls); the clamp makes the flat index non-affine across a box,
# and, since forcing-gather transitions are invisible to the per-cell cut
# signature, the corner verification would send the whole equation to the
# per-cell fallback. Lowering the lane
# to `_AccArrTblBox` instead mirrors `_materialize_state_tbl`: one
# `_eval_recipe` per box cell — the SAME index resolution the per-cell
# fallback would run — stored densely in box-local layout. The table holds
# linear INDICES (static); the VALUES are read through the aliased `pg.flat`
# at eval time, so an in-place refresh is always seen — exactly the
# `_AccForcingBox` liveness contract, and the same descriptor kind the
# per-cell merge (`_acc_merge_nodes`) already emits for divergent forcing
# reads. Bit-identical by construction; O(box) build cost.
function _materialize_pgather_tbl(
        rec::_LaneRecipe, idx_names, box, D,
        var_map, const_arrays, run = box
    )
    return _materialize_pgather_tbl_inner(rec, idx_names, box, D, var_map, const_arrays, run)
end
function _materialize_pgather_tbl_inner(
        rec::_LaneRecipe, idx_names, box, D,
        var_map, const_arrays, run = box
    )
    pg = rec.arr::_PGatherArray
    tbl, s, off = _box_table(Int, rec, idx_names, box, run, D, var_map, const_arrays)
    return _AccRepl(_AccArrTblBox(pg.flat, tbl, s, off))
end

# Materialize a NON-AFFINE const lane as a dense per-box VALUE table, addressed
# box-locally through the existing `_AccConstBox` descriptor. The values are
# `_eval_recipe`'s per-cell outputs (boundary folds included), so a fetch is
# bit-identical to the per-cell resolve. Generic over the recipe KIND — it
# only calls `_eval_recipe` — so `LANE_EXPRTBL` (a rescued build-time-
# evaluable subtree, whose recipe evaluates a compiled `_CellEval`) routes
# here too and inherits both the dense table and the exhaustive fold below.
#
# Having paid for every cell, the all-equal case folds to a literal — an
# EXHAUSTIVE invariance test (`vals` is the whole box), not a sampled one. This
# is the only place the invariance-to-literal fold is legal without a structural
# argument; the LANE_CONST fast path below derives it from the index instead.
# A tile that shares its code keeps the table: it evaluates only its own cells
# (`run`), so it could not make the decision every tile makes.
function _materialize_const_box(
        rec::_LaneRecipe, idx_names, box, D,
        var_map, const_arrays, run = box
    )
    return _materialize_const_box_inner(rec, idx_names, box, D, var_map, const_arrays, run)
end
function _materialize_const_box_inner(
        rec::_LaneRecipe, idx_names, box, D,
        var_map, const_arrays, run = box
    )
    vals, s, off = _box_table(Float64, rec, idx_names, box, run, D, var_map, const_arrays)
    if !_range_shared_code(_range_spec_now())
        v1 = vals[1]
        all(==(v1), vals) && return _LitRepl(v1)   # exhaustively verified invariant
    end
    return _AccRepl(_AccConstBox(vals, s, off))
end

# `(s, off)` with `index(l) == off + Σ_d (l[d]-1)·s[d]` on the whole box, or
# `nothing`. The strides are finite differences of `index` across one step of
# each non-thin dim from `rep`, checked at every corner. A corner check is a
# PROOF only for a structurally affine subscript (`structural`, `_affine_form`:
# such an index cannot leave its model anywhere inside the box once two
# corners pin it); for any other subscript (a gather through connectivity
# data, which can agree at the corners and differ in between) the map is
# checked at every cell of the box (`_box_holds`, memoized under `key()`).
function _affine_index_on_box(index_at, rep, corners, thin, D, structural::Bool, box, run, key)
    i_rep = index_at(rep)
    s = zeros(Int, max(D, 3))
    for d in 1:D
        if !thin[d]
            l2 = copy(rep); l2[d] += 1
            s[d] = index_at(l2) - i_rep
        end
    end
    off = i_rep - sum((rep[d] - 1) * s[d] for d in 1:D)
    model(l) = off + sum((l[d] - 1) * s[d] for d in 1:D)
    for cn in corners
        model(cn) == index_at(cn) || return nothing
    end
    structural || _box_holds(l -> model(l) == index_at(l), box, run, D, key) || return nothing
    return s, off
end

# Derive one lane's lowering for a box and VERIFY it holds on the whole box —
# one method per lane kind (`_lane_repl`). A lane that does not reduce to a
# literal or a box-addressed descriptor MATERIALIZES a per-box table instead of
# declining (`_materialize_state_tbl` / `_materialize_const_box` /
# `_materialize_pgather_tbl`; the pgather table holds indices into the aliased
# live buffer, so it stays refresh-live). A live forcing lane otherwise lowers
# to `_AccForcingBox` over the aliased buffer (never folded to a literal, so it
# stays refresh-live).
# `structural` is `_affine_idx_expr` over every one of the lane's subscripts:
# every corner-derived conclusion below (ghost fold, uniform Δ, affine const /
# forcing index) is a PROOF only when it holds; otherwise the conclusion is
# re-checked at every cell of the box (`_affine_index_on_box`). It is a
# property of the EXPRESSION, not of a cell or a box, so the box processor
# passes the per-branch classification `_lane_nonaffine_args!` already
# memoizes; the default derives it for a direct caller.
#
# `le` is the lane's compiled evaluator (`_lane_evaluator`) or `nothing`; a STATE
# lane is evaluated through it wherever it answers, which is the same slot
# `_eval_recipe` returns there.
function _derive_lane_repl(
        rec::_LaneRecipe, idx_names, rep, corners, thin,
        oln_rep, base, strides, D, var_map, const_arrays,
        flat_cache, box,
        structural::Bool =
            all(a -> _affine_idx_expr(a, idx_names), rec.idx_args);
        le::Union{Nothing, _LaneEval} = nothing, run = box
    )
    env = Dict{String, Int}()
    ev(loop) = _ev_lane(le, rec, loop, env, idx_names, var_map, const_arrays)
    lp = _LaneProbe(rec, idx_names, rep, corners, thin, D, box, run, structural, var_map, const_arrays)
    k = rec.kind
    k == LANE_STATE && return _lane_repl_state(lp, ev, le, oln_rep, base, strides)
    k == LANE_LOOPLIT && return _lane_repl_looplit(lp)
    k == LANE_EXPRTBL && return _lane_repl_exprtbl(lp)
    k == LANE_CONST && return _lane_repl_const(lp, ev, flat_cache)
    return _lane_repl_pgather(lp, ev)
end

# What every lane lowering reads: the lane, the box (its representative cell,
# corners, thin dims, rank, the run it is cut from) and the build's maps.
struct _LaneProbe{RP, CN, TH, BX, RN, VM, CA}
    rec::_LaneRecipe
    idx_names::Any
    rep::RP
    corners::CN
    thin::TH
    D::Int
    box::BX
    run::RN
    structural::Bool
    var_map::VM
    const_arrays::CA
end

_lane_tbl_state(lp::_LaneProbe) =
    _materialize_state_tbl(lp.rec, lp.idx_names, lp.box, lp.D, lp.var_map, lp.const_arrays, lp.run)
_lane_tbl_const(lp::_LaneProbe) =
    _materialize_const_box(lp.rec, lp.idx_names, lp.box, lp.D, lp.var_map, lp.const_arrays, lp.run)
_lane_tbl_pgather(lp::_LaneProbe) =
    _materialize_pgather_tbl(lp.rec, lp.idx_names, lp.box, lp.D, lp.var_map, lp.const_arrays, lp.run)

# A STATE lane: a ghost box (literal 0.0), a constant offset from the output
# slot (`_AccStateAffine`), the lane's own affine map on its array's block
# (`_AccStateTblBox` over the block's identity table), or a slot table.
function _lane_repl_state(lp::_LaneProbe, ev, le, oln_rep, base, strides)
    rec, idx_names, rep, corners, thin, D, box, run = lp.rec, lp.idx_names, lp.rep, lp.corners, lp.thin, lp.D, lp.box, lp.run
    structural = lp.structural
    slot_rep = ev(rep)
    if slot_rep == 0                              # ghost → literal 0.0
        for cn in corners
            ev(cn) == 0 || return _lane_tbl_state(lp)
        end
        _ghost_box(
            rec, idx_names, corners, structural, box, D, ev,
            lp.const_arrays, le, run
        ) || return _lane_tbl_state(lp)
        return _LitRepl(0.0)
    end
    Δ = slot_rep - oln_rep
    uniform = true
    for cn in corners
        sc = ev(cn)
        if !(sc != 0 && sc - _box_oln(base, strides, cn, D) == Δ)
            uniform = false
            break
        end
    end
    uniform && (
        structural || _box_holds(
            box, run, D,
            () -> _lane_box_key(:offset, rec, idx_names, box)
        ) do l
            sc = ev(l)
            sc != 0 && sc - _box_oln(base, strides, l, D) == Δ
        end
    ) && return _AccRepl(_AccStateAffine(Δ))
    # Not at a constant offset from the output slot. Before paying for a dense
    # per-box table, try the lane's OWN affine map (see the LANE-AFFINE STATE
    # BOX note above): finite-difference the slot across a unit step in each
    # non-thin dim, then VERIFY at every corner. A ghost anywhere in the probe
    # or the corners declines (the table's per-cell 0 sentinel is what models a
    # ghost). Only a structurally affine subscript qualifies: the block's slot
    # map is affine in the SUBSCRIPT VALUES, so the composed map is affine in
    # the loop exactly when the subscripts are, and the corner check is then a
    # proof (`_affine_index_on_box`).
    if structural
        blk = _state_slot_block(rec)
        if blk !== nothing
            lo0, hi0 = blk
            ls = zeros(Int, max(D, 3))
            ok = lo0 <= slot_rep <= hi0
            if ok
                for d in 1:D
                    thin[d] && continue
                    l2 = copy(rep); l2[d] += 1
                    v2 = ev(l2)
                    if v2 == 0
                        ok = false
                        break
                    end
                    ls[d] = v2 - slot_rep
                end
            end
            if ok
                o = slot_rep - lo0 + 1
                @inbounds for d in 1:D
                    o -= (rep[d] - 1) * ls[d]
                end
                for cn in corners
                    sc = ev(cn)
                    a = o
                    @inbounds for d in 1:D
                        a += (cn[d] - 1) * ls[d]
                    end
                    if !(sc != 0 && 1 <= a <= (hi0 - lo0 + 1) && lo0 + a - 1 == sc)
                        ok = false
                        break
                    end
                end
            end
            ok && return _AccRepl(_AccStateTblBox(_state_slot_identity(lo0, hi0), ls, o))
        end
    end
    return _lane_tbl_state(lp)
end

# The loop index itself: a literal on a thin dim, else a loop-index read.
function _lane_repl_looplit(lp::_LaneProbe)
    rec = lp.rec
    dim = findfirst(==(rec.loop_name), lp.idx_names)
    dim === nothing && _decline(:subscript_not_static, "loop literal '$(rec.loop_name)' is not an output index")
    return lp.thin[dim] ? _LitRepl(Float64(lp.rep[dim])) : _AccRepl(_AccLoopIdx(dim))
end

# A rescued build-time-evaluable SUBTREE (stencil.jl SUBTREE-TABLE RESCUE):
# its value is an arbitrary function of the loop indices, so there is no
# index-affine map to derive and no value may be folded from samples — it is
# always the dense per-box value table, which folds to a literal only when
# every cell's value is equal, exhaustively.
_lane_repl_exprtbl(lp::_LaneProbe) = _lane_tbl_const(lp)

# A CONST lane. Loop-invariance is derived from the INDEX, never sampled from
# the VALUES: a const array is arbitrary data, so agreement at the corners
# says nothing about the interior (a regrid weight column reading (0, 0.5, 0)
# across a box coincides at both ends). The resolved LINEAR INDEX
# (`_recipe_const_lin`) is affine on the box when the subscripts are affine
# expressions of the loop names — every boundary-fold transition already
# forces a box cut (`_const_fold_key!`). An all-zero stride vector then means
# the index — hence the value — does not move over the box, and only then is
# the literal fold legal. `flat[_recipe_const_lin(...)] == _eval_recipe(...)`
# (see `_recipe_const_lin`), so `val_rep` is that element and the fold is
# bit-identical.
function _lane_repl_const(lp::_LaneProbe, ev, flat_cache)
    rec, idx_names = lp.rec, lp.idx_names
    val_rep = ev(lp.rep)
    lenv = Dict{String, Int}()
    clin(loop) = _recipe_const_lin(rec, _set_env!(lenv, idx_names, loop), lp.const_arrays)
    aff = _affine_index_on_box(
        clin, lp.rep, lp.corners, lp.thin, lp.D, lp.structural, lp.box, lp.run,
        () -> _lane_box_key(:const, rec, idx_names, lp.box)
    )
    aff === nothing && return _lane_tbl_const(lp)
    s, off = aff
    all(iszero, s) && return _LitRepl(Float64(val_rep))
    arr_flat = get!(flat_cache, rec.arr) do;
        _const_flat(rec.arr)
    end
    return _AccRepl(_AccConstBox(arr_flat, s, off))
end

# A LIVE forcing (pgather) lane. `_eval_recipe` returns the flat LINEAR INDEX
# into the forcing buffer (its own grid), so this is the CONST derivation
# applied to the index, with two differences: it never folds to a literal even
# when the index is constant (the buffer is refreshed in place, so the read
# must stay live), and it passes `pg.flat` (the aliased live buffer) straight
# through, never a copy. A clamped or folded subscript (non-affine across the
# box) materializes the per-box index table.
function _lane_repl_pgather(lp::_LaneProbe, ev)
    rec = lp.rec
    pg = rec.arr::_PGatherArray
    aff = _affine_index_on_box(
        ev, lp.rep, lp.corners, lp.thin, lp.D, lp.structural, lp.box, lp.run,
        () -> _lane_box_key(:forcing, rec, lp.idx_names, lp.box)
    )
    aff === nothing && return _lane_tbl_pgather(lp)
    s, off = aff
    return _AccRepl(_AccForcingBox(pg.flat, s, off))
end

# One lane's `_eval_recipe` at `loop`, through its compiled evaluator `le` where
# that answers (a STATE lane at a `Vector{Int}` cell).
@inline function _ev_lane(
        le, rec::_LaneRecipe, loop, env, idx_names, var_map,
        const_arrays
    )
    if le !== nothing && rec.kind == LANE_STATE && loop isa Vector{Int}
        v, ok = _lane_eval_state(le, loop)
        ok && return v
    end
    return _eval_recipe(rec, _set_env!(env, idx_names, loop), var_map, const_arrays)
end

# `_eval_const_int` of the lane's `d`-th subscript at `loop`, through the
# compiled subscript where it answers.
@inline function _ev_subscript(
        le, rec::_LaneRecipe, d::Int, loop, env, idx_names,
        const_arrays
    )
    if le !== nothing && loop isa Vector{Int} && d <= length(le.args)
        v, ok = _ix_eval(le.args[d], loop)
        ok && return v
    end
    return _eval_const_int(rec.idx_args[d], _set_env!(env, idx_names, loop), const_arrays)
end

# ── GUARDED OUT-OF-RANGE LANES ─────────────────────────────────────────────
#
# The box processor reads every lane at every cell it derives, but a body may
# read a const lane only under a guard: `ifelse(i > n, 0, c[i])` reads `c[i]`
# at no cell where `i > n`. The interpreter raises E_TREEWALK_CONSTARRAY_OOB
# where an out-of-range read is EVALUATED and nowhere else, so a lane that is
# out of range at some cell of a box is lowered cell by cell: in range, its
# value (a slot, for a state lane whose subscript gathers through a const
# table); out of range, the guards it is read under decide at that cell —
#   * a guard that is not taken there: the cell never reads the lane, so its
#     table entry is a filler no evaluation reaches;
#   * every guard taken (or none): the read happens, and the build raises the
#     exact error the per-cell resolution raises;
#   * a guard that depends on the state, a parameter, time or a live buffer:
#     only the run time knows, and the equation declines to the tiers that
#     gather at run time and raise there (the whole-array nest).
# A guard is decided by evaluating its compiled condition with the lanes it
# reads replaced by their values at the cell, through `_eval_node` itself, so
# the decision is the one the kernel would make.

_is_const_oob(err) = err isa TreeWalkError && err.code == "E_TREEWALK_CONSTARRAY_OOB"

# Every guard path each lane sentinel of `tmpl` is read under (`ifelse`
# branches, the short-circuited operands of `and` / `or`). A lane with no
# recorded path — one inside a template sub-kernel, or past the walk budget —
# has unknown guards, which `_lane_guard_at` treats as a run-time guard.
function _lane_guard_paths(tmpl::_Node, nlanes::Int)
    paths = [_GuardPath[] for _ in 1:nlanes]
    stack = Tuple{_Node, Bool}[]
    seen = Set{Tuple{UInt, UInt}}()
    budget = Ref(1_000_000)
    function visit(n::_Node)
        (budget[] -= 1) < 0 && return
        key = (objectid(n), hash(Tuple{UInt, Bool}[(objectid(c), b) for (c, b) in stack]))
        key in seen && return
        push!(seen, key)
        if n.kind === _NK_STATE && n.idx < 0
            r = -n.idx
            if r <= nlanes
                p = copy(stack)
                any(
                    q -> length(q) == length(p) &&
                        all(i -> q[i][1] === p[i][1] && q[i][2] == p[i][2], eachindex(p)),
                    paths[r]
                ) || push!(paths[r], p)
            end
            return
        end
        ch = n.children
        return if n.kind === _NK_OP && n.op === :ifelse && length(ch) == 3
            visit(ch[1])
            push!(stack, (ch[1], true)); visit(ch[2]); pop!(stack)
            push!(stack, (ch[1], false)); visit(ch[3]); pop!(stack)
        elseif n.kind === _NK_OP && (n.op === :and || n.op === :or)
            for c in ch
                visit(c)
                push!(stack, (c, n.op === :and))
            end
            for _ in ch
                pop!(stack)
            end
        else
            for c in ch
                visit(c)
            end
        end
    end
    visit(tmpl)
    budget[] < 0 && foreach(empty!, paths)
    return paths
end

# A guard condition with every lane it reads replaced by that lane's value at
# the cell (`env`), or `nothing` when it reads anything the build does not know.
function _guard_at_cell(n::_Node, recipes, env, var_map, const_arrays)
    k = n.kind
    k === _NK_LITERAL && return n
    if k === _NK_STATE
        n.idx < 0 || return nothing
        r = -n.idx
        rec = recipes[r]
        rec.kind in (LANE_LOOPLIT, LANE_CONST, LANE_EXPRTBL) || return nothing
        v = try
            _eval_recipe(rec, env, var_map, const_arrays)
        catch err
            (err isa TreeWalkError || err isa _Decline) && return nothing
            rethrow()
        end
        return _mknode(kind = _NK_LITERAL, literal = Float64(v))
    elseif k === _NK_OP || k === _NK_CONST_GATHER
        ch = Vector{_Node}(undef, length(n.children))
        for i in eachindex(ch)
            c = _guard_at_cell(n.children[i], recipes, env, var_map, const_arrays)
            c === nothing && return nothing
            ch[i] = c
        end
        return _mknode(
            kind = k, op = n.op, literal = n.literal, idx = n.idx, sym = n.sym,
            payload = n.payload, children = ch
        )
    end
    return nothing
end

# Whether a lane read under `paths` happens at the cell `env`: `:taken`,
# `:not_taken`, or `:unknown` when a guard is decided only at run time.
function _lane_guard_at(paths::Vector{_GuardPath}, recipes, env, var_map, const_arrays)
    isempty(paths) && return :unknown
    unknown = false
    for p in paths
        st = :taken
        for (c, want) in p
            g = _guard_at_cell(c, recipes, env, var_map, const_arrays)
            v = g === nothing ? nothing :
                try
                    _eval_node(g, Float64[], NamedTuple(), 0.0)
            catch err
                    err isa TreeWalkError || rethrow()
                    nothing
            end
            if v === nothing
                st = :unknown
            elseif (v != 0) != want
                st = :not_taken
                break
            end
        end
        st === :taken && return :taken
        st === :unknown && (unknown = true)
    end
    return unknown ? :unknown : :not_taken
end

# The lowering of a const or state lane that is out of range at some cell of
# the box (see the section note): a dense box-local table, as
# `_materialize_const_box` / `_materialize_state_tbl` build, whose entries at
# the cells that never read the lane are fillers — a const lane's first
# in-range value (so a lane uniform where it is read still folds to a
# literal), a state lane's ghost slot 0. Over the cells `run` a program runs,
# as `_box_table` builds it.
function _guarded_lane_repl(
        rec::_LaneRecipe, paths::Vector{_GuardPath}, recipes,
        idx_names, box, D, var_map, const_arrays, run = box
    )
    s, off, len = _box_table_addr(box, run, D)
    state = rec.kind == LANE_STATE
    tbl = state ? zeros(Int, len) : zeros(Float64, len)
    unread = falses(len)
    le = _lane_evaluator(rec, collect(String, idx_names), var_map, const_arrays)
    env = Dict{String, Int}()
    loop = Vector{Int}(undef, D)
    for I in CartesianIndices(ntuple(d -> UnitRange{Int}(run[d]), D))
        j = off
        @inbounds for d in 1:D
            loop[d] = I[d]
            j += (I[d] - 1) * s[d]
        end
        if le !== nothing
            v, ok = _lane_eval(le, loop)
            if ok
                tbl[j] = v
                continue
            end
        end
        _set_env!(env, idx_names, loop)
        v = try
            _eval_recipe(rec, env, var_map, const_arrays)
        catch err
            _is_const_oob(err) || rethrow()
            g = _lane_guard_at(paths, recipes, env, var_map, const_arrays)
            g === :taken && rethrow()
            g === :unknown && _decline(:guarded_out_of_range)
            unread[j] = true
            nothing
        end
        v === nothing || (tbl[j] = v)
    end
    if state
        tbl[unread] .= 0
        return _AccRepl(_AccStateTblBox(tbl, s, off))
    end
    first_read = findfirst(!, unread)
    tbl[unread] .= first_read === nothing ? 0.0 : tbl[first_read]
    # (Kept as a table in a tile that shares its code, as
    # `_materialize_const_box` does.)
    if !_range_shared_code(_range_spec_now())
        v1 = tbl[1]
        all(x -> isequal(x, v1), tbl) && return _LitRepl(v1)
    end
    return _AccRepl(_AccConstBox(tbl, s, off))
end

# A const array's flat Float64 copy, which a box read addresses. Each `faq`
# equation's lowering makes its own; a re-lowering of a program reuses its
# build's (`_ProgramMemo`), so a tile does not copy a whole-domain array.
function _const_flat(arr)
    spec = _range_spec_now()
    memo = _range_memo(spec)
    memo === nothing && return Float64.(vec(arr))
    if _range_memo_records(spec)
        f = Float64.(vec(arr))
        lock(() -> get!(memo.flats, arr, f), memo.lock)
        return f
    end
    return _memo_get(() -> Float64.(vec(arr)), memo, :flats, arr, false)
end

# `_guarded_lane_repl` over the cells `run` of `box`. Its refusal (a guard
# only the run time decides, at some cell) is recorded for the box by the
# program's own build and raised again by every tile that shares its code,
# whichever of the box's cells it runs, so the tiles lower the box alike
# (`_box_holds`).
function _guarded_box_repl(
        rec::_LaneRecipe, paths, recipes, idx_names, box, D, var_map,
        const_arrays, run
    )
    spec = _range_spec_now()
    memo = _range_memo(spec)
    memo === nothing && return _guarded_lane_repl(
        rec, paths, recipes, idx_names, box, D,
        var_map, const_arrays, run
    )
    key = _lane_box_key(:guarded, rec, idx_names, box)
    if run !== box
        got = lock(() -> get(memo.verdicts, key, nothing), memo.lock)
        got isa Exception && throw(got)
    end
    try
        return _guarded_lane_repl(
            rec, paths, recipes, idx_names, box, D, var_map,
            const_arrays, run
        )
    catch err
        (err isa _Decline && run === box && _range_memo_records(spec)) &&
            lock(() -> get!(memo.verdicts, key, err), memo.lock)
        rethrow()
    end
end

# Does `pred(loop)` hold at EVERY cell of the box? The exact counterpart of a
# corner check, for a lane whose subscripts are not structurally affine
# (`_affine_idx_expr`): such a subscript can be arbitrary data (an
# `index(conn, i)` gather), so agreement at the 2^D corners and at `rep + e_d`
# says nothing about the interior. O(box cells) at build time; the lowered
# descriptor, and so the kernel's per-call cost, is unchanged.
function _holds_on_box(pred, box, D)
    for loop in Iterators.product((box[d] for d in 1:D)...)
        pred(loop) || return false
    end
    return true
end

# `_holds_on_box` over a box of which a program runs the cells `run`. A
# program's own build answers it over the box, as every build does, and records
# the answer (`_ProgramMemo`). A tile that shares its code runs only its cells
# of the box, but must reach the answer every tile reaches, so it takes the
# box's recorded answer (working it out, and recording it, the first time) and
# also checks it over its own cells, which is what makes its lowering correct
# there whatever layout the answer was reached in. So its build costs what its
# cells cost. An answer that raised (a const subscript out of range) is
# recorded as the error, and raises again. `key()` names the check: the lane
# (its kind, variable, subscripts and bounds), the box, the loop names and the
# site.
function _box_holds(pred, box, run, D, key)
    spec = _range_spec_now()
    memo = _range_memo(spec)
    if run === box
        memo === nothing && return _holds_on_box(pred, box, D)
        _range_memo_records(spec) || return _holds_on_box(pred, box, D)
        v = _box_answer(pred, box, D)
        k = key()
        lock(() -> get!(memo.verdicts, k, v), memo.lock)
        v isa Exception && throw(v)
        return v::Bool
    end
    k = key()
    v = memo === nothing ? nothing : lock(() -> get(memo.verdicts, k, nothing), memo.lock)
    if v === nothing
        v = _box_answer(pred, box, D)
        memo === nothing || lock(() -> get!(memo.verdicts, k, v), memo.lock)
    end
    v isa Exception && throw(v)
    return (v::Bool) && _holds_on_box(pred, run, D)
end

# `_holds_on_box`'s answer, or the out-of-range error it raised.
function _box_answer(pred, box, D)
    try
        return _holds_on_box(pred, box, D)
    catch err
        _is_const_oob(err) || rethrow()
        return err
    end
end

# The key of a box check of lane `rec` at `site` (`_box_holds`).
_lane_box_key(site::Symbol, rec::_LaneRecipe, idx_names, box) =
    (
    site, rec.kind, rec.var_name, string(rec.idx_args), copy(rec.lo), copy(rec.hi),
    String[String(x) for x in idx_names], Tuple{Int, Int}[(first(r), last(r)) for r in box],
)

# Is EVERY cell of the box a ghost read (some subscript outside the variable's
# bounds), given that every corner is? Not implied: a ghost corner can be out of
# range on either side, so an affine subscript like `3i - 40` is a ghost at both
# ends of `1:40` and in range between them. An affine subscript takes its
# extremes at the corners, so the box is all-ghost when ONE subscript is below
# its lower bound at every corner, or above its upper bound at every corner.
# Otherwise (and always for a non-affine subscript) every cell is checked.
function _ghost_box(
        rec::_LaneRecipe, idx_names, corners, structural, box, D,
        ev, const_arrays, le::Union{Nothing, _LaneEval} = nothing, run = box
    )
    if structural
        env = Dict{String, Int}()
        for d in eachindex(rec.idx_args)
            below = above = true
            for cn in corners
                v = _ev_subscript(le, rec, d, cn, env, idx_names, const_arrays)
                below &= v < rec.lo[d]
                above &= v > rec.hi[d]
            end
            (below || above) && return true
        end
    end
    return _box_holds(
        l -> ev(l) == 0, box, run, D,
        () -> _lane_box_key(:ghost, rec, idx_names, box)
    )
end

# All 2^D corners of a box, as loop vectors, the first dim varying fastest (the
# order of `Iterators.product`), repeats included where a dim is one cell wide.
function _box_corners(box)
    D = length(box)
    out = Vector{Vector{Int}}(undef, 1 << D)
    for c in 0:((1 << D) - 1)
        cn = Vector{Int}(undef, D)
        @inbounds for d in 1:D
            cn[d] = (c >> (d - 1)) & 1 == 0 ? first(box[d]) : last(box[d])
        end
        out[c + 1] = cn
    end
    return out
end

# Emit one `_AccKernel` for a box: derive + verify every lane, then lower the
# (memoized) sentinel template to a shared access spine. `cbox` is the part of
# the box the program runs (a tile's share; the whole box otherwise).
#
# With `eq.reduce`, the box's trailing `length(reduce.names)` dims are the
# contraction's (`eq.names` names them too, and `eq.strides` is zero there, so
# a corner's output slot ignores them): the lanes are derived over the whole
# box, and the kernel loops only the output dims, its spine the `_NK_AREDUCE`
# fold of the lowered body over the contracted ones.
function _process_affine_box!(kernels, eq::_AffineEq, box, cbox)
    idx_names = eq.names
    var_map = eq.var_map
    const_arrays = eq.const_arrays
    base, strides = eq.base, eq.strides
    reduce, view = eq.reduce, eq.view
    lhs_var, lhs_idx_args = eq.lhs_var, eq.lhs_idx_args
    D = length(box)
    nout = reduce === nothing ? D : D - length(reduce.names)
    rep = Int[first(box[d]) for d in 1:D]
    thin = Bool[length(box[d]) == 1 for d in 1:D]
    corners = _box_corners(box)
    bkey, branch = _cell_bkey!(eq, rep)
    tmpl, recipes = branch.tmpl, branch.recipes

    # verify the output slot map on this box against var_map (catches a bad omap)
    denv = Dict{String, Int}()
    lhs_ix = _lhs_ix_compile(eq)
    for cn in corners
        _box_oln(base, strides, cn, D) ==
            _oln_via_ix(lhs_ix, lhs_var, lhs_idx_args, cn, denv, idx_names, var_map) ||
            _decline(:output_layout_not_affine, lhs_var)
    end
    oln_rep = _box_oln(base, strides, rep, D)

    # Per-lane structural affinity of the subscripts, memoized per branch key
    # (`_lane_nonaffine_args!`): what licenses a corner check as a proof rather
    # than a sample, so `_derive_lane_repl` re-verifies at every cell only where
    # it must. Classified once per branch, not once per box.
    nonaff = _lane_nonaffine_args!(eq, bkey, recipes)
    # A tile's per-box tables cover only the cells of the box it runs
    # (`_box_table_addr`).
    run = view === nothing ? box : cbox
    evs = _box_lane_evals!(eq, bkey)
    lane_repl = Vector{_LaneRepl}(undef, length(recipes))
    for k in eachindex(recipes)
        lane_repl[k] = try
            _derive_lane_repl(
                recipes[k], idx_names, rep, corners, thin,
                oln_rep, base, strides, D, var_map,
                const_arrays, eq.flat_cache, box,
                !any(nonaff[k]); le = evs[k], run = run
            )
        catch err
            (_is_const_oob(err) && recipes[k].kind in (LANE_CONST, LANE_STATE)) || rethrow()
            paths = get!(
                () -> _lane_guard_paths(tmpl, length(recipes)),
                eq.lane_guards, bkey
            )[k]
            _guarded_box_repl(
                recipes[k], paths, recipes, idx_names, box, D,
                var_map, const_arrays, run
            )
        end
    end

    view === nothing || _range_real_repls!(view, lane_repl, recipes)
    spine, acc, cse, subs = get!(eq.spine_cache, string(bkey, '#', _lane_repl_key(lane_repl))) do
        a = _AccDesc[]
        raw = _lower_to_access(tmpl, lane_repl, a)
        if reduce !== nothing
            raw = _mknode(
                kind = _NK_AREDUCE, op = reduce.op, literal = reduce.zerobar,
                payload = _AReduceSpec(
                    collect((nout + 1):D),
                    UnitRange{Int}[box[d] for d in (nout + 1):D]
                ),
                children = _Node[raw]
            )
        end
        cs_spine, cse = _build_acc_cse(raw, a)   # per-cell CSE (shared subtrees → scratch)
        (cs_spine, a, cse, _AccKernel[])
    end
    out_ranges = eq.out_ranges
    slab = Bool[
        length(box[d]) == 1 && (
            first(box[d]) == first(out_ranges[d]) ||
                last(box[d]) == last(out_ranges[d])
        )
            for d in 1:nout
    ]
    cs = _CellSet(
        Int[strides[d] for d in 1:nout],
        UnitRange{Int}[cbox[d] for d in 1:nout],
        base - (view === nothing ? 0 : view.shift), Int[], slab
    )
    return push!(kernels, _AccKernel(cs, spine, acc, cse, subs))
end

# Every lane recipe's compiled evaluator (`nothing` where it has none), per
# branch key: what `_derive_lane_repl` evaluates a state lane through, and the
# scan key reads its state lanes from. The recipes are the branch key's own
# (`eq.branch_cache`), compiled under the equation's inputs.
function _box_lane_evals!(eq::_AffineEq, bkey::String)
    return get!(eq.box_evals, bkey) do
        recipes = eq.branch_cache[bkey].recipes
        Union{Nothing, _LaneEval}[
            rec.kind == LANE_STATE ?
                _lane_evaluator(rec, eq.names, eq.var_map, eq.const_arrays, eq.ix_memo) : nothing
                for rec in recipes
        ]
    end::Vector{Union{Nothing, _LaneEval}}
end

# The output subscripts compiled once per equation (`nothing` for one that has
# no compiled form), for `_oln_via_ix`.
function _lhs_ix_compile(eq::_AffineEq)
    eq.lhs_ix === nothing || return eq.lhs_ix
    ix = Union{Nothing, _IdxNode}[
        _ix_compile(a, eq.names, eq.const_arrays) for a in eq.lhs_idx_args
    ]
    eq.lhs_ix = ix
    return ix
end

# `_oln_via_varmap` at cell `loop`: the subscripts through their compiled form
# and the slot by the layout's arithmetic where both answer, the string lookup
# (and its error) otherwise.
function _oln_via_ix(lhs_ix, lhs_var, lhs_idx_args, loop, env, idx_names, var_map)
    if loop isa Vector{Int}
        du = Vector{Int}(undef, length(lhs_ix))
        ok = true
        @inbounds for m in eachindex(lhs_ix)
            x = lhs_ix[m]
            x === nothing && (ok = false; break)
            v, okm = _ix_eval(x, loop)
            okm || (ok = false; break)
            du[m] = v
        end
        if ok
            slot = _vm_slot(var_map, lhs_var, du)
            slot == 0 || return slot
        end
    end
    return _oln_via_varmap(lhs_var, lhs_idx_args, _set_env!(env, idx_names, loop), var_map)
end

# Mark every output slot a box owns (O(box cells) bit-ops — the sole remaining
# O(#cells) step, no tree-walk), detecting duplicate derivatives. When the slot
# map is one-to-one on the box, the box is checked and then marked a run of the
# first loop index at a time, word-wise; a box that finds a slot already taken,
# or whose map is not shown one-to-one, takes the cell-by-cell walk, which
# raises the error at the first duplicate in loop order.
function _mark_box_covered!(covered, box, base, strides, D, lhs_var, lhs_idx_args, idx_names)
    if D >= 1 && strides[1] == 1 && _affine_injective_on(Int[strides[d] for d in 1:D], box)
        rngs = ntuple(d -> UnitRange{Int}(box[d]), D)
        _mark_box_runs!(covered, rngs, base, strides) && return nothing
    end
    return _mark_box_cells!(covered, box, base, strides, D, lhs_var, lhs_idx_args, idx_names)
end

# `false`, with `covered` untouched, when a slot of the box is already set. A
# box whose slots are one contiguous run (each dim wider than one cell steps by
# the number of slots the dims before it span) is checked and claimed as that
# run.
function _mark_box_runs!(
        covered::_Covered, rngs::NTuple{N, UnitRange{Int}}, base::Int,
        strides
    ) where {N}
    st = ntuple(d -> Int(strides[d]), N)
    r1 = rngs[1]
    span = 1
    for d in 1:N
        length(rngs[d]) == 1 && continue
        st[d] == span || (span = 0; break)
        span *= length(rngs[d])
    end
    if span > 0
        lo = base
        @inbounds for d in 1:N
            lo += first(rngs[d]) * st[d]
        end
        _cover_any(covered, lo, lo + span - 1) && return false
        _cover_fill!(covered, lo, lo + span - 1; run = true)
        return true
    end
    outer = CartesianIndices(Base.tail(rngs))
    run_start(J) = (
        o = base + first(r1); @inbounds for d in 2:N
            o += J[d - 1] * st[d]
        end; o
    )
    for J in outer
        lo = run_start(J)
        _cover_any(covered, lo, lo + length(r1) - 1) && return false
    end
    for J in outer
        lo = run_start(J)
        _cover_fill!(covered, lo, lo + length(r1) - 1)
    end
    return true
end

# Whether any bit of `B[lo:hi]` is set, a 64-bit word at a time.
function _bits_any(B::BitVector, lo::Int, hi::Int)
    lo > hi && return false
    checkbounds(B, lo:hi)
    ch = B.chunks
    w1 = (lo - 1) >>> 6 + 1
    w2 = (hi - 1) >>> 6 + 1
    m1 = typemax(UInt64) << ((lo - 1) & 63)
    m2 = typemax(UInt64) >>> (63 - ((hi - 1) & 63))
    w1 == w2 && return (@inbounds(ch[w1]) & m1 & m2) != 0
    (@inbounds(ch[w1]) & m1) != 0 && return true
    @inbounds for w in (w1 + 1):(w2 - 1)
        ch[w] != 0 && return true
    end
    return (@inbounds(ch[w2]) & m2) != 0
end

function _mark_box_cells!(covered, box, base, strides, D, lhs_var, lhs_idx_args, idx_names)
    env = Dict{String, Int}()
    return @inbounds for loop in Iterators.product((box[d] for d in 1:D)...)
        o = _box_oln(base, strides, loop, D)
        if covered[o]
            du_inds = Int[_eval_const_int(a, _set_env!(env, idx_names, collect(Int, loop))) for a in lhs_idx_args]
            throw(TreeWalkError("E_TREEWALK_DUPLICATE_DERIVATIVE", _cell_key(lhs_var, du_inds)))
        end
        covered[o] = true
    end
end

# Compile an array equation via the affine polyhedral build.
# Returns `Vector{_AccKernel}`, or declines (`_Decline`) with `covered` untouched;
# the cascade (`_AffineTier`, build_array_equation.jl) files the decline and
# moves on.
#
# With `reduce` the equation is a contraction `⊕_{k…} rhs_body(i…, k…)` whose
# contracted indices `reduce.names` stay symbolic: they join the output indices
# as trailing loop dims, the cut scan and the lane derivation see them like any
# other dim, and each output box's kernel folds the body over them at run time
# (`_NK_AREDUCE`). A contracted dim that the scan cuts (a ghost or region
# transition along it) is declined, so the caller can unroll instead: one
# kernel's fold must walk its contracted range in one piece to keep the order.
function _try_affine_stencil(
        rhs_body::ASTExpr, idx_names::Vector{String},
        range_iters, lhs_body::OpExpr,
        resolved_obs::Dict{String, ASTExpr},
        array_var_info, var_map::AbstractDict{String, Int},
        const_arrays::AbstractDict, pgather::AbstractDict,
        param_sym_set, covered::_Covered;
        # The per-BUILD observed-inlining store (`_XEqStore`); `nothing`: a
        # per-call memo.
        xeq::Union{Nothing, _XEqStore} = nothing,
        reduce::Union{Nothing, _AffineReduce} = nothing,
        # A tile's lowering (`_RangeAffineView`, range_hooks.jl):
        # `range_iters` are then the equation's whole-domain
        # ranges, `run_iters` the ones the tile computes, and
        # every name/slot lookup goes through `view`.
        view = nothing, run_iters = nothing
    )
    (
        lhs_body.op == "D" && !isempty(lhs_body.args) &&
            lhs_body.args[1] isa OpExpr && (lhs_body.args[1]::OpExpr).op == "index" &&
            !isempty((lhs_body.args[1]::OpExpr).args) &&
            (lhs_body.args[1]::OpExpr).args[1] isa VarExpr
    ) || _decline(:lhs_not_indexed_derivative)

    D = length(idx_names)
    D >= 1 || _decline(:no_output_index)
    ranges = UnitRange{Int}[]
    for r in range_iters
        (length(r) >= 1 && _is_unit_run(r)) ||
            _decline(:range_not_unit_run)
        push!(ranges, first(r):last(r))
    end

    # Observed inlining. With a store, the substitution memo is shared across
    # every equation of the build (bindings — `resolved_obs` — are one fixed
    # Dict per build, `_xeq_obs_memo` pins that). Without a store: a fresh
    # per-call memo.
    body = rhs_body
    if !isempty(resolved_obs)
        memo = xeq === nothing ? _SubMemo() : _xeq_obs_memo(xeq, resolved_obs)
        body = _sub_preserving(rhs_body, resolved_obs, memo)
    end
    inner = lhs_body.args[1]::OpExpr
    lhs_var = (inner.args[1]::VarExpr).name
    lhs_idx_args = inner.args[2:end]
    length(lhs_idx_args) == D || _decline(:lhs_subscript_count)
    # The loop dims: the output's, then (for a contraction kept as a loop) the
    # contracted ones.
    all_names = reduce === nothing ? idx_names : vcat(idx_names, reduce.names)
    all_ranges = reduce === nothing ? ranges : vcat(ranges, reduce.ranges)
    Dall = length(all_names)

    ctx_proto = _StencilCtx(
        Set{String}(all_names), _LaneRecipe[], Dict{String, Int}(),
        array_var_info, const_arrays, pgather
    )
    base, strides = _derive_output_affine(lhs_var, lhs_idx_args, idx_names, ranges, var_map)
    # The output slot does not move along a contracted dim.
    all_strides = reduce === nothing ? strides : vcat(strides, zeros(Int, Dall - D))
    eq = _AffineEq(
        all_names, all_ranges, ranges, body, ctx_proto, var_map, const_arrays,
        param_sym_set, lhs_var, lhs_idx_args, base, all_strides, reduce, view
    )
    cuts = _affine_cut_points(eq; strong = true)
    for d in (D + 1):Dall
        length(cuts[d]) == 1 ||
            _decline(:contracted_axis_cut, all_names[d])
    end
    segs = [_segments(cuts[d], ranges[d]) for d in 1:D]
    run = run_iters === nothing ? nothing :
        UnitRange{Int}[first(r):last(r) for r in run_iters]
    shift = view === nothing ? 0 : view.shift
    kernels = _AccKernel[]
    boxes = Vector{UnitRange{Int}}[]
    for segtuple in Iterators.product(segs...)
        box = UnitRange{Int}[segtuple[d] for d in 1:D]
        reduce === nothing || append!(box, reduce.ranges)
        # The cells of the box this program runs: all of them, or a tile's
        # share (possibly none; the box is then derived and emitted all
        # the same, and runs no cell).
        cbox = run === nothing ? box :
            UnitRange{Int}[
                d <= D ? _clip_run(box[d], run[d]) : box[d]
                for d in eachindex(box)
            ]
        _process_affine_box!(kernels, eq, box, cbox)
        all(d -> !isempty(cbox[d]), 1:D) && push!(boxes, cbox[1:D])
    end
    # Only after every box is verified: mark covered (untouched on fallback).
    for box in boxes
        _mark_box_covered!(covered, box, base - shift, strides, D, lhs_var, lhs_idx_args, idx_names)
    end
    view === nothing || _range_real_fixed!(view, kernels)
    return kernels
end
