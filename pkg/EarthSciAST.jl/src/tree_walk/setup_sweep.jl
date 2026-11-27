# tree_walk/setup_sweep.jl — the compiled setup sweep of a build-once `faq`:
# its loop frame, join gates and overlap or bin-equality drives, and the
# rank-specialized loops (the body compiler is geometry_compile.jl).

# Extent of an IndexSetRef range against the model's index sets + derived extents.
#
# A `kind:"derived"` set resolves through its `from_faq`, exactly as
# `_resolve_index_set_ranges` (tree_walk/index_sets.jl) does for the ODE stream:
# `derived_extents` is keyed by the PRODUCER id, not by the set name. Setup-time
# geometry can range over one because the projection pushdown re-points a binning
# aggregate onto `pd_support__<C>` — and when that aggregate's weight is an
# overlap-area template, its body IS setup-time geometry.
function _geo_index_extent(ref, index_sets, derived_extents)
    # A dense `[1, n]` tuple (a template's loop over a vertex-slot count,
    # esm-spec §9.6.1) is the same loop as an index set of size n. Another
    # lower bound has no setup-time form.
    if ref isa AbstractVector
        (length(ref) == 2 && ref[1] isa Integer && ref[1] == 1 && ref[2] isa Integer) ||
            throw(
            TreeWalkError(
                "E_TREEWALK_GEOMETRY_SETUP",
                "setup-time geometry loops only over an index set or a dense [1, n] range, not $(ref)"
            )
        )
        return max(Int(ref[2]), 0)
    end
    name = ref isa IndexSetRef ? ref.from : String(ref)
    haskey(derived_extents, name) && return derived_extents[name]
    s = index_sets === nothing ? nothing : get(index_sets, name, nothing)
    if s isa IndexSet && s.kind == "derived" && s.from_faq !== nothing
        e = get(derived_extents, String(s.from_faq), nothing)
        e === nothing || return Int(e)
    end
    sz = s === nothing ? nothing :
        _dynamic(hasproperty, s, :size)::Bool ? getproperty(s, :size) :
        (s isa AbstractDict ? get(s, "size", get(s, :size, nothing)) : nothing)
    sz === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_GEOMETRY_SETUP",
            "cannot resolve extent of index set '$(name)' for setup-time geometry"
        )
    )
    return Int(sz)
end

# A geometry body is compiled once per sweep into the shared `_Node` IR and its
# scalar operators evaluate through `_eval_node_op`'s registry-generated arms
# (tree_walk/geometry_compile.jl).

# Map a join key column to the aggregate loop var that indexes it (via its
# declared 1-D shape's index set), by the right-hand side's rule
# (`_join_sym_for_key`, CONFORMANCE_SPEC §5.5.8 "Two ranges over one index
# set"): `pick` is the clause's `syms` entry for this side when it has one, else
# `:left` / `:right`, which take the first / second of two candidate loop vars
# in `order` (the node's canonical range order). Three or more candidates
# without `syms` are refused, never settled by hash order.
function _geo_loopvar_for(col, setof, var_shapes, pick = :left, order = nothing)
    sets = get(var_shapes, col, String[])
    isempty(sets) && return nothing
    if pick isa AbstractString
        return get(setof, String(pick), nothing) == sets[1] ? String(pick) : nothing
    end
    cands = String[String(lv) for (lv, st) in setof if st == sets[1]]
    ord = order === nothing ? sort(cands) : order
    rank(s) = something(findfirst(==(s), ord), length(ord) + 1)
    sort!(cands; by = s -> (rank(s), s))
    isempty(cands) && return nothing
    length(cands) == 1 && return cands[1]
    length(cands) == 2 && return cands[pick === :right ? 2 : 1]
    throw(
        TreeWalkError(
            "E_TREEWALK_JOIN_AMBIGUOUS_KEY",
            "index set '$(sets[1])' of join key column '$col' is drawn by " *
                "$(length(cands)) range symbols ($(cands)); name the clause's two sides " *
                "with `join.syms` (CONFORMANCE_SPEC §5.5.8)"
        )
    )
end

# Loop-invariant context for the setup-time geometry COMPILER (`_geo_compile`,
# tree_walk/geometry_compile.jl) and the join-gate resolution: the value
# environment (name → const arrays + scalar params + materialized geometry),
# the document index-set registry, the derived-extent map, and the declared
# per-variable shapes (for join-column resolution). Build-time-only path — one
# small struct per materialization is fine. `derived_extents` is read-only
# inside a compile/sweep (it is grown by the materializers before evaluation).
struct _GeoCtx
    env::AbstractDict
    index_sets::Any
    derived_extents::AbstractDict
    var_shapes::AbstractDict
end

# A node's `join` resolves ONCE per sweep through `_resolve_geo_join_gates` below
# and then compiles to slot-addressed `_GeoSlotGate`s; the `filter` predicate
# compiles to a `_Node` evaluated per cell. Key-equality broad phase per RFC §5.3 /
# §5.8, gate then filter — see `_geo_gate_ok` and `_geo_eval_agg` in
# tree_walk/geometry_compile.jl.

# One resolved join-key equality: the two participating column arrays and the
# loop-var names that index them. Everything here is INVARIANT across the output ×
# candidate product `_materialize_geom_array` sweeps — only `ie[lvA]`/`ie[lvB]`
# vary per cell — so it is resolved ONCE (`_resolve_geo_join_gates`) instead of
# re-deriving `String(pair[…])`, `_geo_loopvar_for`, and two `env` Dict lookups on
# every candidate pair (the dominant cost of the conservative-regrid broad phase).
struct _GeoJoinGate
    arrA::Any
    lvA::String
    arrB::Any
    lvB::String
end

# Pre-resolve `expr.join` (once per sweep). Each side of a pair resolves to a
# loop var as on the right-hand side, honouring the clause's `syms`. A pair
# whose loop vars do not resolve, or whose columns are not both in `env` (a key
# column the setup sweep has no value for, such as a binning coordinate the
# regrid templates leave to the right-hand side), gates nothing here. Returns `nothing`
# when the node has no join (lets the compiled gate skip the whole arm).
# Consumed by `_geo_slot_gates` (tree_walk/geometry_compile.jl), which maps the
# loop-var names to frame slots.
function _resolve_geo_join_gates(expr, ctx::_GeoCtx, setof)
    expr.join === nothing && return nothing
    gates = _GeoJoinGate[]
    order = _canonical_range_order(
        expr.output_idx, expr.ranges === nothing ? Dict{String, Any}() : expr.ranges
    )
    for clause in expr.join
        # Only bin-equality (key-column-pair) clauses resolve HERE. An
        # `overlap` clause is a `_OverlapJoinSpec` (not a pair vector) and is
        # handled separately, at the TOP-LEVEL sweep, by `_geo_overlap_gate` /
        # `_geo_overlap_drive` below — because its candidate set does not just
        # gate, it DRIVES enumeration, which this per-tuple gate cannot express.
        # (A nested `:geo_agg` therefore still ignores an overlap clause; no
        # shipped template puts one there. See the block above.)
        clause isa AbstractVector || continue
        csyms = _clause_syms(clause)
        pick_l = csyms === nothing ? :left : csyms[1]
        pick_r = csyms === nothing ? :right : csyms[2]
        for pair in clause
            colA, colB = String(pair[1]), String(pair[2])
            lvA = _geo_loopvar_for(colA, setof, ctx.var_shapes, pick_l, order)
            lvB = _geo_loopvar_for(colB, setof, ctx.var_shapes, pick_r, order)
            (lvA === nothing || lvB === nothing) && continue
            (haskey(ctx.env, colA) && haskey(ctx.env, colB)) || continue
            push!(gates, _GeoJoinGate(ctx.env[colA], lvA, ctx.env[colB], lvB))
        end
    end
    return gates
end

# The geometry chain COMPILES ONCE per materialization sweep into the shared
# `_Node` IR and evaluates per cell through `_eval_node`: see
# tree_walk/geometry_compile.jl for the compiler (`_geo_compile` / `_geo_source`),
# the compiled gate (`_geo_gate_ok`), and the `:geo_gather`/`:geo_agg`
# evaluator arms.

# The (init, ⊕) fold for a setup-time array reduction, keyed by the aggregate's
# `reduce` / `semiring`. Defaults to SUM (the `sum_product` FAQ additive identity),
# so every existing geometry materialization (`A_j` row-sum, `A_ij` map) is
# byte-identical; `min` / `max` / `prod` support a build-time BINNING-COORDINATE
# projection over an in-file geometry array (e.g. `src_lon[i] = min_v src_poly[i,v,1]`,
# RFC §8.6.1 broad phase) so the coordinate need not be supplied by the host.
#
# The identity VALUES are shared vocabulary with the runtime aggregate resolver:
# sourced from `_OPLUS_IDENTITY` (tree_walk/semiring.jl) so the 0̄ constants live
# in one table. Two behaviors DELIBERATELY diverge from `_aggregate_oplus_identity`
# (geometry-specific, behavior-pinned — do not "unify" silently):
#   * precedence: here `reduce` wins over `semiring`; the runtime resolver
#     treats `semiring` as authoritative (§5.1);
#   * spelling:  here the projection kinds `"sum"`/`"prod"` are accepted
#     (`_REDUCE_PROJECTION_KINDS`); the runtime resolver speaks only ⊕
#     spellings (`+`, `*`, `max`, `min`, `or`).
# Failure handling matches the runtime: an unrecognized reduce spelling or
# semiring name fails with the same E_TREEWALK codes rather than degrading to
# the additive fold.
function _geo_reduce_fold(reduce_spec, semiring_spec)
    oplus = if reduce_spec !== nothing
        # `reduce` shorthand, plus the geometry-only projection spellings.
        reduce_spec == "sum" ? "+" : reduce_spec == "prod" ? "*" : reduce_spec
    elseif semiring_spec !== nothing
        # A `semiring` name resolves ⊕ through the same closed registry as the
        # runtime — unknown names fail closed here too.
        sr = get(_SEMIRING_REGISTRY, semiring_spec, nothing)
        sr === nothing && throw(
            TreeWalkError(
                "E_TREEWALK_UNKNOWN_SEMIRING",
                "unknown semiring '$semiring_spec'; the closed registry is " *
                    join(sort(collect(keys(_SEMIRING_REGISTRY))), ", ")
            )
        )
        sr.oplus
    else
        "+"   # unspecified → additive fold (§5.1 note 1)
    end
    if _is_numeric_reducer(oplus)
        r = _REDUCER_INDEX[Symbol(oplus)]
        return (r.zerobar, r.fn)
    end
    throw(
        TreeWalkError(
            "E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
            "unsupported geometry reduce=$(repr(reduce_spec)) / semiring=$(repr(semiring_spec)); " *
                "expected reduce ∈ (+, sum, *, prod, max, min) or a numeric registry semiring"
        )
    )
end

# ---- The RANK-SPECIALIZED sweep (the geometry materializer's inner loops) ----
#
# The sweeps run in methods typed `Array{Float64,N}` over `CartesianIndices`:
# one dynamic dispatch PER SWEEP, and a loop body with a statically known rank.
# `CartesianIndices` visits a column-major product first index fastest, so the
# assignment order and — what matters for bit-identity — the CONTRACTION FOLD
# ORDER are the term sequence the document defines.
#
# `_eval_node`/`_geo_gate_ok` calls stay OUTSIDE any `@inbounds` region: a geometry
# gather's bounds check is load-bearing (a mis-derived extent must raise, not read
# a neighbouring cell), and `@inbounds` propagates into inlined callees. Only the
# frame writes — whose indices come from `CartesianIndices` over the array being
# written — are elided.
#
# The `Any`-typed source payload each `:geo_gather` node carries is narrowed in
# the evaluator arms (`_geo_gather_value`, `_geo_ring_value` —
# tree_walk/geometry_compile.jl): the SAME method with the SAME arguments,
# reached through a concrete `isa` instead of a generic call.
# `geom_sweep_specialize_test.jl` checks the sweeps against hand-computed arrays
# and the narrowed arms against a source type that misses them.

# MAP sweep (no contracted indices), specialized on the output rank `N`.
function _geom_sweep_map!(
        arr::Array{Float64, N}, body, gates, filt,
        u::Vector{Float64}, ov = nothing
    ) where {N}
    for I in CartesianIndices(arr)
        @inbounds for k in 1:N
            u[k] = Float64(I[k])
        end
        # A no-contraction map still honors an output-cell join/filter gate: a
        # rejected cell keeps the zero-initialized 0̄ (a cross-bin W_ij, a
        # sub-atol sliver). Degenerate (no join/filter) ⇒ gate is always true.
        # `ov` is the OVERLAP membership test for a gate `_overlap_drive_plan`
        # declined to drive; `nothing` (the usual case) compiles away.
        _geo_ov_ok(ov, u) || continue
        _geo_gate_ok(gates, filt, u) || continue
        v = _geo_body_eval(body, u)
        @inbounds arr[I] = v
    end
    return arr
end

# CONTRACTING sweep, specialized on the output rank `N`, the contracted rank
# `M` and the fold `F`. The contracted slots follow the output slots in the
# frame (`_materialize_geom_array` allocates them in that order).
function _geom_sweep_contract!(
        arr::Array{Float64, N}, body, gates, filt,
        u::Vector{Float64}, cidx::CartesianIndices{M},
        init::Float64, fold::F, ov = nothing
    ) where {N, M, F}
    for I in CartesianIndices(arr)
        @inbounds for k in 1:N
            u[k] = Float64(I[k])
        end
        acc = init
        for C in cidx
            @inbounds for k in 1:M
                u[N + k] = Float64(C[k])
            end
            _geo_ov_ok(ov, u) || continue
            _geo_gate_ok(gates, filt, u) || continue
            acc = fold(acc, _geo_body_eval(body, u))
        end
        @inbounds arr[I] = acc
    end
    return arr
end

# ---- The OVERLAP broad phase at SETUP (RFC §5.3 / projection-pushdown 2a) ----
#
# `_resolve_geo_join_gates` above resolves only bin-EQUALITY clauses. For an
# array that materializes at setup this sweep is the only evaluation the
# aggregate gets, so the `overlap` clause is applied here, and its candidate set
# DRIVES the enumeration rather than filtering the `#src × #tgt` product. Which
# symbol(s) it drives is `_overlap_drive_plan`'s policy (src/broad_phase.jl),
# shared with the value-invention producer (`_vi_enumerate_join`) and the dense
# aggregate expansion (`_foreach_aggregate_term`), and the candidate set comes
# from the same primitive (`_overlap_candidate_set` → `broad_phase_candidates`).
#
# A tuple outside the candidate set contributes the fold identity 0̄ (§5.3), the
# clause's specified meaning (CONFORMANCE_SPEC §5.5.6, join admission and
# identity fill): the interpreter tests membership per tuple, `native` drives.
# For the conservative-regrid shapes it is value-neutral (disjoint envelopes
# give an overlap area of exactly `+0.0`); where a pruned tuple would contribute
# (a `min`/`prod` fold, a body not zero off the overlap) both compilers give the
# gated answer (`geom_overlap_drive_test.jl`).
#
# SCOPE: the TOP-LEVEL materialization sweep only. A nested `:geo_agg` in the body
# keeps its ungated behaviour (`_geo_compile_agg` still routes through
# `_resolve_geo_join_gates`); no shipped template puts an overlap clause on a
# nested aggregate, and gating one would need its own drive plan.

# The clause is part of the document's meaning, so every compiler applies it.
# Off (`compiler=:interpreter`), the gate is applied as a per-tuple membership
# test over the dense product and never drives the enumeration: that is the
# differential oracle for the driven sweeps.
_geom_overlap_drive_disabled() = !_compiler_plan_now().geom_overlap_gate

# Engagement counts (`_count!`, compiler.jl): `:geom_overlap_drive` for a sweep
# whose enumeration was driven from the candidate set (the O(#candidates) path);
# `:geom_overlap_gate_only` for one where a gate resolved but
# `_overlap_drive_plan` declined to drive it, so the sweep stayed dense with a
# per-tuple membership test; `:geom_overlap_none` for one with no usable
# overlap clause. A silently-declining drive shows up as no
# `:geom_overlap_drive`.

# A resolved setup-time OVERLAP gate: the shared `_JoinGate` (so it can be
# handed straight to `_overlap_drive_plan`) plus the frame slots its two range
# symbols occupy in this sweep's `u`.
struct _GeoOverlapGate
    gate::_JoinGate
    slot_l::Int
    slot_r::Int
end

# Membership test for the DENSE fallback (`_overlap_drive_plan` said `:none`):
# the tuple's two gated positions must be a candidate pair. `nothing` ⇒ no
# overlap gate, which admits everything and compiles away.
@inline _geo_ov_ok(::Nothing, u) = true
@inline function _geo_ov_ok(ov::_GeoOverlapGate, u)
    @inbounds return (Int(u[ov.slot_l]), Int(u[ov.slot_r])) in
        (ov.gate.candidates::_OverlapIndex)
end

# Build (or reuse) the candidate index for one overlap clause. ReSEACT resolves
# the SAME `(src_poly, tgt_poly, eps)` clause six times — once for `A_ij` and
# once per applied species — so the index is memoized per setup pass. The cache
# is scoped to one `_materialize_geometry_setup` call, where a name→array
# binding in `env` is written once and never replaced, which is what makes the
# name-keyed identity sound. Memoizing the `_OverlapIndex` (not the raw pair
# set) also shares its lazily built sorted-pair and adjacency views across the
# six sweeps.
function _geo_overlap_index(clause::_OverlapJoinSpec, env::AbstractDict, cache)
    key = (clause.src_env, clause.tgt_env, clause.eps)
    if cache !== nothing
        hit = get(cache, key, nothing)
        hit === nothing || return hit::_OverlapIndex
    end
    oi = _OverlapIndex(
        _overlap_candidate_set(
            clause.src_env, clause.tgt_env, env;
            eps = clause.eps
        )
    )
    cache === nothing || (cache[key] = oi)
    return oi
end

# Resolve this aggregate's FIRST usable `overlap` clause against the sweep's
# lexical scope. Declines (⇒ `nothing`, the ungated sweep) when
# either env-factor list does not map to a loop var in scope, or when a named
# envelope factor is not a materialized array in `env`; every compiler declines
# alike, so the compilers agree there.
#
# The env-factor → loop-var rule is the setup path's own `_geo_loopvar_for`
# (the same one the bin-equality `on` keys use): the FIRST factor's FIRST shape
# axis names the range, which holds for every env form because a factor's first
# axis is always its position axis (`_overlap_env_rank`). The factor ranks are
# checked below against `_overlap_env_rank`, the rule `_overlap_env_sym` in
# tree_walk/join_gates.jl (the right-hand side's resolver) also checks. The two
# differ in what a mismatch does: here it declines to the ungated sweep, which
# computes the same values; the right-hand side throws `E_TREEWALK_JOIN_OVERLAP`.
function _geo_overlap_gate(faq, ctx::_GeoCtx, setof, scope, cache)
    faq.join === nothing && return nothing
    for clause in faq.join
        clause isa _OverlapJoinSpec || continue
        isempty(clause.src_env) && continue
        isempty(clause.tgt_env) && continue
        order = _canonical_range_order(
            faq.output_idx, faq.ranges === nothing ? Dict{String, Any}() : faq.ranges
        )
        sym_l = _geo_loopvar_for(String(clause.src_env[1]), setof, ctx.var_shapes, :left, order)
        sym_r = _geo_loopvar_for(String(clause.tgt_env[1]), setof, ctx.var_shapes, :right, order)
        (sym_l === nothing || sym_r === nothing) && continue
        sym_l == sym_r && continue                # a self-join cannot drive
        sl = get(scope, sym_l, 0)
        sr = get(scope, sym_r, 0)
        (sl == 0 || sr == 0) && continue
        # Every envelope factor must be a materialized array of the rank
        # `_envelope_vectors_from_cols` expects for that list length: 1 name is a
        # `[pos, verts, coord]` RING stack (3-D), 2 or 4 names are per-position
        # columns (1-D). A factor of another rank declines the drive here, and
        # the sweep runs ungated, rather than letting `broad_phase_candidates`
        # throw.
        _geo_env_ok(names) = begin
            want = _overlap_env_rank(length(names))
            want === nothing && return false
            for f in names
                a = get(ctx.env, String(f), nothing)
                (a isa AbstractArray && ndims(a) == want) || return false
            end
            true
        end
        (_geo_env_ok(clause.src_env) && _geo_env_ok(clause.tgt_env)) || continue
        oi = _geo_overlap_index(clause, ctx.env, cache)
        return _GeoOverlapGate(
            _JoinGate(
                sym_l, sym_r, Dict{Int, Int}(),
                Dict{Int, Int}(), oi
            ), sl, sr
        )
    end
    return nothing
end

# What the shared planner decided for THIS sweep. `pos_*` are 1-based positions,
# which double as frame slots: `_materialize_geom_array` allocates slot k to the
# k-th output index and slot `nout + k` to the k-th contracted index.
#
#   :pairs    — both gated symbols are OUTPUT indices; `pos_l`/`pos_r` are their
#               output positions and `restpos` the remaining output positions,
#               which product around each candidate pair.
#   :restrict — one gated symbol is an OUTPUT index (`pos_l`, bound per output
#               cell, living on side `side` of the pair) and the other is
#               CONTRACTED (`pos_r`, its position among the contracted indices).
struct _GeoOverlapDrive
    kind::Symbol
    pos_l::Int
    pos_r::Int
    restpos::Vector{Int}
    side::Symbol
end

# Ask `_overlap_drive_plan` (src/broad_phase.jl — the ONE implementation of the
# drive policy, shared with `_vi_enumerate_join` and `_foreach_aggregate_term`)
# how this sweep should be driven, and translate its answer into frame
# positions. Returns `nothing` for any shape it declines, or that this sweep
# cannot express — the caller then sweeps densely with the membership test, so
# a decline costs speed, never correctness.
function _geo_overlap_drive(
        ov::_GeoOverlapGate, out::Vector{String},
        contract::Vector{String}, exts::Vector{Int},
        index_sets, derived_extents, faq;
        cexts::Vector{Int} = _geo_contract_extents(faq, contract, index_sets, derived_extents)
    )
    g = ov.gate
    nout = length(out)
    if isempty(contract)
        # A pure MAP: both gated symbols are free, so the planner returns the
        # candidate PAIRS and they enumerate the output cells directly.
        plan = _overlap_drive_plan(
            g, out, Dict{String, Int}(),
            s -> (k = findfirst(==(s), out); k === nothing ? (1:0) : (1:exts[k]))
        )
        plan[1] === :pairs || return nothing
        pl = findfirst(==(g.sym_l), out)
        pr = findfirst(==(g.sym_r), out)
        (pl === nothing || pr === nothing) && return nothing
        # Positions must BE the frame slots (they are, by construction); refuse
        # to drive rather than write the wrong slot if that ever stops holding.
        (ov.slot_l == pl && ov.slot_r == pr) || return nothing
        rest = Int[k for k in 1:nout if k != pl && k != pr]
        return _GeoOverlapDrive(:pairs, pl, pr, rest, :l)
    end
    # A CONTRACTION: bind the output indices (the planner only needs to know
    # WHICH are bound, so the probe cell's positions are immaterial) and ask
    # what the still-free contracted symbols may be restricted to.
    probe = Dict{String, Int}(o => 1 for o in out)
    plan = _overlap_drive_plan(
        g, contract, probe,
        s -> (k = findfirst(==(s), contract); k === nothing ? (1:0) : (1:cexts[k]))
    )
    plan[1] === :restrict || return nothing
    free = String(plan[2])
    gc = findfirst(==(free), contract)
    gc === nothing && return nothing
    fixed = free == g.sym_l ? g.sym_r : g.sym_l
    po = findfirst(==(fixed), out)
    po === nothing && return nothing
    side = fixed == g.sym_l ? :l : :r
    # Same slot check as above, for both ends of the pair.
    slot_fixed = fixed == g.sym_l ? ov.slot_l : ov.slot_r
    slot_free = free == g.sym_l ? ov.slot_l : ov.slot_r
    (slot_fixed == po && slot_free == nout + gc) || return nothing
    return _GeoOverlapDrive(:restrict, po, gc, Int[], side)
end

# ---- The bin-equality broad phase at SETUP ----
#
# A `join.on` key pair (`_GeoSlotGate`, e.g. `src_bin[i] == tgt_bin[j]` in the
# conservative regrid) is otherwise tested one tuple at a time over the whole
# output × contracted product, which is quadratic in the grid. Its candidate
# pairs are the key-equality matches (`_equality_match_index`, broad_phase.jl),
# and they drive the sweep exactly as an overlap gate's candidates do: the
# same drive plan, the same `:pairs` MAP and `:restrict` contraction sweeps.
# Both sweeps still run `_geo_gate_ok` on every tuple they visit, so the
# admitted set is the dense sweep's; a MAP writes the same cells, and a
# contraction folds the same terms in the same order (the restriction is an
# ascending subsequence of the contracted range).
#
# Gated by the plan's `join_on_gate`, the switch for the ODE path's `on`-gate
# driver: off (`compiler = :interpreter`), the sweep is the dense one, which is
# the oracle. A gate whose key column is shorter than its range, or whose keys
# are of a kind the index declines, keeps the dense sweep.
# Counted as `:geom_eq_drive` when the key drives the sweep.

function _geo_equality_drive(
        gates, out::Vector{String}, contract::Vector{String},
        exts::Vector{Int}, index_sets, derived_extents, faq;
        eq_cache = nothing,
        cexts::Vector{Int} = _geo_contract_extents(faq, contract, index_sets, derived_extents)
    )
    (gates === nothing || isempty(gates)) && return nothing
    _join_on_gate_disabled() && return nothing
    nout = length(out)
    nslot = nout + length(contract)
    slotname(s) = s <= nout ? out[s] : contract[s - nout]
    slotext(s) = s <= nout ? exts[s] : cexts[s - nout]
    for gt in gates
        sA, sB = gt.slotA, gt.slotB
        (sA != sB && 1 <= sA <= nslot && 1 <= sB <= nslot) || continue
        a, b = gt.arrA, gt.arrB
        (a isa AbstractArray && b isa AbstractArray) || continue
        eA, eB = slotext(sA), slotext(sB)
        (length(a) >= eA && length(b) >= eB) || continue
        # The match index depends only on the two key columns and extents; one
        # setup pass gates several aggregates on the same pair of bin buffers.
        oi = if eq_cache === nothing
            _equality_match_index(1:eA, p -> a[p], 1:eB, p -> b[p])
        else
            get!(
                () -> _equality_match_index(1:eA, p -> a[p], 1:eB, p -> b[p]),
                eq_cache, (objectid(a), objectid(b), eA, eB)
            )
        end
        oi === nothing && continue
        g = _GeoOverlapGate(
            _JoinGate(
                slotname(sA), slotname(sB), Dict{Int, Int}(),
                Dict{Int, Int}(), oi
            ), sA, sB
        )
        d = _geo_overlap_drive(
            g, out, contract, exts, index_sets, derived_extents, faq; cexts = cexts
        )
        d === nothing || return (g, d)
    end
    return nothing
end

# PAIRS-driven MAP sweep: `_overlap_drive_plan` bound BOTH gated symbols, and
# both are OUTPUT indices, so the candidate pairs enumerate the output cells
# directly and every remaining output index products around them. Output cells
# no pair reaches keep the zero-initialized 0̄ — exactly what the dense sweep's
# `_geo_gate_ok || continue` leaves behind for a rejected cell.
#
# `pairs` is `_overlap_sorted_pairs`, ascending by `(pos_l, pos_r)`; a MAP
# writes each cell independently, so the visit order cannot affect the result.
# An out-of-range position (an envelope factor longer than the declared range)
# is skipped rather than trusted.
function _geom_sweep_pairs_map!(
        arr::Array{Float64, N}, body, gates, filt,
        u::Vector{Float64},
        pairs::Vector{Tuple{Int, Int}},
        pos_l::Int, pos_r::Int,
        restpos::NTuple{K, Int},
        restidx::CartesianIndices{K}
    ) where {N, K}
    ix = zeros(Int, N)
    eL = size(arr, pos_l)
    eR = size(arr, pos_r)
    for (pl, pr) in pairs
        (1 <= pl <= eL && 1 <= pr <= eR) || continue
        @inbounds begin
            ix[pos_l] = pl; ix[pos_r] = pr
            u[pos_l] = Float64(pl); u[pos_r] = Float64(pr)
        end
        for R in restidx
            @inbounds for d in 1:K
                ix[restpos[d]] = R[d]
                u[restpos[d]] = Float64(R[d])
            end
            _geo_gate_ok(gates, filt, u) || continue
            v = _geo_body_eval(body, u)
            @inbounds arr[CartesianIndex(ntuple(d -> ix[d], Val(N)))] = v
        end
    end
    return arr
end

# RESTRICT-driven CONTRACTING sweep: one gated symbol is an output index (bound
# per output cell) and the other is contracted, so the contracted loop visits
# only that cell's candidate partners.
#
# The FOLD TERM SEQUENCE is preserved, which is what keeps a `+` reduction
# bit-identical to the gated dense sweep: `_overlap_partners` returns partners
# ASCENDING and `_overlap_restrict` proves the restriction is an order-preserving
# SUBSEQUENCE of the full range, and the surrounding contracted dimensions keep
# their nesting — so the visited tuples are exactly the dense column-major
# sequence with the gate-rejected ones removed, in the same relative order.
# Every removed term would have contributed 0̄, by the gate's definition.
function _geom_sweep_restrict_contract!(
        arr::Array{Float64, N}, body, gates, filt,
        u::Vector{Float64}, oi::_OverlapIndex,
        side::Symbol, pos_o::Int,
        cexts::NTuple{M, Int}, gc::Int, nout::Int,
        init::Float64, fold::F
    ) where {N, M, F}
    for I in CartesianIndices(arr)
        @inbounds for k in 1:N
            u[k] = Float64(I[k])
        end
        acc = init
        parts = _overlap_partners(oi, side, I[pos_o])
        # `1:cexts[gc]` is an ascending contiguous `UnitRange`, the one shape
        # `_overlap_restrict` can always prove order-preserving, so it never
        # declines here. The assert is fail-closed insurance: a future caller
        # handing this a permuted range would raise rather than quietly fold a
        # different term set.
        vals = _overlap_restrict(1:cexts[gc], parts)::Vector{Int}
        if !isempty(vals)
            dims = ntuple(d -> d == gc ? length(vals) : cexts[d], Val(M))
            for C in CartesianIndices(dims)
                @inbounds for k in 1:M
                    u[nout + k] = Float64(k == gc ? vals[C[k]] : C[k])
                end
                _geo_gate_ok(gates, filt, u) || continue
                acc = fold(acc, _geo_body_eval(body, u))
            end
        end
        @inbounds arr[I] = acc
    end
    return arr
end

# The extents of an aggregate's contracted indices, in `contract` order.
_geo_contract_extents(faq, contract::Vector{String}, index_sets, derived_extents) =
    Int[_geo_index_extent(faq.ranges[c], index_sets, derived_extents) for c in contract]

# The frame one sweep runs in: the output indices and their extents, the
# contracted indices (`ranges` keys not among the outputs, §5.1) and theirs,
# the loop-var → index-set map (seeded with BOTH, so a join can resolve a key
# column indexed by either: per-cell F_tgt keys on an outer output var, the
# row-sum keys on the contracted `i`), and each loop var's frame slot (outputs
# first, then the contracted vars, in declaration order). `nslots` grows while
# the body compiles (a nested aggregate takes slots of its own).
struct _GeoFrame
    out::Vector{String}
    exts::Vector{Int}
    contract::Vector{String}
    cexts::Vector{Int}
    setof::Dict{String, String}
    scope::Dict{String, Int}
    nslots::Base.RefValue{Int}
end
function _geo_frame(faq, index_sets, derived_extents)
    out = String[v for v in faq.output_idx]
    exts = Int[_geo_index_extent(faq.ranges[v], index_sets, derived_extents) for v in out]
    contract = String[k for k in keys(faq.ranges) if !(k in out)]
    setof = Dict{String, String}()
    scope = Dict{String, Int}()
    for v in Iterators.flatten((out, contract))
        r = faq.ranges[v]
        r isa IndexSetRef && (setof[v] = r.from)
        scope[v] = length(scope) + 1
    end
    return _GeoFrame(
        out, exts, contract, _geo_contract_extents(faq, contract, index_sets, derived_extents),
        setof, scope, Ref(length(scope))
    )
end

# With a zero RHS codegen budget, a plan that licenses per-cell walks walks a
# tiny one-off setup sweep rather than compiling it; a strict plan has no
# license and always compiles. On large sweeps, walking each tuple can cost
# more than compilation. Count the full loop product as an upper bound even
# with gates.
function _geo_emit_setup_kernel(fr::_GeoFrame)
    _codegen_node_budget() != 0 && return true
    _optional_percell_license() === nothing && return true
    limit = 64
    terms = 1
    for extent in Iterators.flatten((fr.exts, fr.cexts))
        terms *= min(extent, limit + 1)
        terms > limit && return true
    end
    return false
end

# The compiled body and filter as the sweep calls them. With subtree sharing
# on, a body keyed like one already compiled in this pass takes that kernel
# over its own arrays, with no memoize pass and no emission
# (`_GeoKernelCache`); otherwise the shared sub-trees are memoized and the
# body is emitted as native code when the emitter models it (the walker
# otherwise).
function _geo_body_callable(body, filt, kernel_cache, fr::_GeoFrame)
    plan = _compiler_plan_now()
    emit = plan.share_subtrees && _geo_emit_setup_kernel(fr)
    shape = emit && filt === nothing && kernel_cache !== nothing ? _geo_shape_key(body) : nothing
    known = shape === nothing ? missing : get(kernel_cache.byshape, shape[1], missing)
    if known isa Tuple
        f, order, fns = known
        _tally_cascade!(:geo_kernel)
        return _GeoKernel(f, Tuple(shape[2][i] for i in order), fns), filt
    end
    if plan.share_subtrees
        roots = _geo_memoize!(filt === nothing ? _Node[body] : _Node[filt, body])
        filt === nothing ? (body = roots[1]) : ((filt, body) = (roots[1], roots[2]))
    end
    (emit && known === missing) || return body, filt
    kbody = _geo_kernel(body; cache = kernel_cache)
    if shape !== nothing
        kernel_cache.byshape[shape[1]] = kbody === nothing ? nothing :
            (kbody.f, Int[findfirst(a -> a === s, shape[2]) for s in kbody.srcs], kbody.fns)
    end
    return (kbody === nothing ? body : kbody), filt
end

# How the sweep is driven: `(drive, dov, ovdense)` — the candidate drive
# (`_GeoOverlapDrive`) or `nothing` for the dense product, the gate whose
# candidate index a driven sweep reads, and the overlap gate a dense sweep
# tests per tuple (`nothing` when there is none or the sweep is driven).
#
# The OVERLAP broad phase (see `_geo_overlap_gate` above): resolve the gate,
# then ask the SHARED planner (`_overlap_drive_plan`, src/broad_phase.jl) which
# symbol(s) its candidate set drives. Only the two shapes the
# conservative-regrid templates produce are driven; anything else keeps the
# dense sweep with the membership test applied per tuple, which is the same
# admitted set at the full product's cost. With no overlap gate, a
# bin-equality (`on`) gate drives instead, through the same two sweep shapes
# (`_geo_equality_drive`).
function _geo_choose_drive(faq, fr::_GeoFrame, gates, ctx::_GeoCtx, index_sets, derived_extents, ov_cache, eq_cache)
    ov = _geo_overlap_gate(faq, ctx, fr.setof, fr.scope, ov_cache)
    drive = ov === nothing || _geom_overlap_drive_disabled() ? nothing :
        _geo_overlap_drive(
            ov, fr.out, fr.contract, fr.exts, index_sets, derived_extents, faq;
            cexts = fr.cexts
        )
    ovdense = drive === nothing ? ov : nothing     # gate per tuple only if not driven
    if ov === nothing
        _count!(:geom_overlap_none)
    elseif drive === nothing
        _count!(:geom_overlap_gate_only)
    else
        _count!(:geom_overlap_drive)
    end
    dov = ov
    if ov === nothing
        eq = _geo_equality_drive(
            gates, fr.out, fr.contract, fr.exts, index_sets,
            derived_extents, faq; eq_cache = eq_cache, cexts = fr.cexts
        )
        if eq !== nothing
            dov, drive = eq
            _count!(:geom_eq_drive)
        end
    end
    return drive, dov, ovdense
end

# Materialize a geometry-derived array observed (e.g. `area[p]`, `A_ij[i,j]`) by
# evaluating its `faq` body once per output cell against the (already
# materialized) geometry in `env`.
#
# Two shapes are handled uniformly. A pure MAP (`output_idx == ranges` keys, e.g.
# `A_ij[i,j] = overlap_area_planar(src, i, nv, tgt, j, nv)`) evaluates the body once
# per output cell. A CONTRACTING aggregate — the on-disk einsum form where some
# `ranges` keys are NOT in `output_idx` (e.g. `A_j[j] = Σ_i A_ij[i,j]`, the
# row-sum) — folds the body over the contracted indices for each output cell.
# Both honor the aggregate's `join` / `filter` gate (`_geo_gate_ok`): a
# rejected contraction tuple contributes the identity 0̄ (RFC §5.3 / §5.8).
# This is the setup-time twin of the ODE faq einsum path.
#
# The steps: the frame (`_geo_frame`); the body, filter and join gate compiled
# ONCE against it (tree_walk/geometry_compile.jl: the loop vars become frame
# slots and the per-cell work is one `_eval_node` walk, or a call of the
# emitted kernel, over the Float64 frame); the drive; the sweep.
function _materialize_geom_array(
        faq, env, index_sets, derived_extents,
        var_shapes = Dict{String, Vector{String}}();
        ov_cache = nothing, eq_cache = nothing, kernel_cache = nothing
    )
    fr = _geo_frame(faq, index_sets, derived_extents)
    ctx = _GeoCtx(env, index_sets, derived_extents, var_shapes)
    g = _GeoCompileCtx(ctx, fr.scope, fr.setof, fr.nslots)
    gates = _geo_slot_gates(faq, g)
    filt = faq.filter === nothing ? nothing : _geo_compile(faq.filter, g)
    body, filt = _geo_body_callable(_geo_compile(faq.expr_body, g), filt, kernel_cache, fr)
    drive, dov, ovdense = _geo_choose_drive(
        faq, fr, gates, ctx, index_sets, derived_extents, ov_cache, eq_cache
    )
    u = zeros(Float64, fr.nslots[])
    # A candidate-driven MAP writes only the cells its pairs reach.
    arr = _zeros_f64(fr.exts...; sparse = drive !== nothing && isempty(fr.contract))
    if isempty(fr.contract)
        if drive !== nothing
            rp = Tuple(drive.restpos)
            _geom_sweep_pairs_map!(
                arr, body, gates, filt, u,
                _overlap_sorted_pairs(dov.gate.candidates::_OverlapIndex),
                drive.pos_l, drive.pos_r, rp,
                CartesianIndices(map(k -> fr.exts[k], rp))
            )
        else
            _geom_sweep_map!(arr, body, gates, filt, u, ovdense)
        end
    else
        init, fold = _geo_reduce_fold(faq.reduce, faq.semiring)
        if drive !== nothing
            _geom_sweep_restrict_contract!(
                arr, body, gates, filt, u,
                dov.gate.candidates::_OverlapIndex,
                drive.side, drive.pos_l,
                Tuple(fr.cexts), drive.pos_r, length(fr.out),
                Float64(init), fold
            )
        else
            _geom_sweep_contract!(
                arr, body, gates, filt, u,
                CartesianIndices(Tuple(fr.cexts)), Float64(init), fold,
                ovdense
            )
        end
    end
    return arr
end
