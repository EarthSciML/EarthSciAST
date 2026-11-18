# tree_walk/build_observed_fills.jl — the per-cell fill equations of materialized array observeds and
# their dependency levels.

# Synthesize the per-cell fill equation for one materialized array observed:
#
#     faq(D(index(obs, i…)), output_idx=[i…], ranges=1…n) = index(<def>, i…)
#
# i.e. exactly the shape `_compile_faq_equation!` consumes for an array
# STATE equation, so the fill reuses the whole array-equation cascade (affine
# polyhedral build, per-cell fallback, per-cell CSE, class merge, codegen) with
# no bespoke kernel path.
#
# THE RHS IS THE GATHER FORM `index(<def>, i…)`, not the bare producer — even
# when `<def>` is a `faq` whose own `output_idx` matches. `index(<def>, i…)`
# is EXACTLY the expression every reader of this observed used to present after
# inlining, so the fill lowers through the identical, already-exercised path.
#
# HISTORICALLY this was also a correctness requirement, because the bare form
# routed a contraction into the affine LANE derivation, whose const-lane fold
# (`_derive_lane_repl`, stencil_affine.jl) then decided a lane was loop-invariant
# by comparing its VALUES at the box CORNERS: a const gather agreeing at the
# corners and differing inside — a regrid weight column `W[i, j]` reading
# (0, 0.5, 0) — folded to a literal 0.0 and the interior cell silently computed
# the wrong number. That hole is CLOSED: `_derive_lane_repl` no longer samples
# values, deriving invariance structurally from the resolved linear index
# instead. The gather form is now a lowering-path default, not a guard.
#
# EXCEPTION, applied downstream rather than here: a producer that CONTRACTS is
# unwrapped back to the bare form by `_unwrap_identity_gather`. The gather form
# hides a contraction from `_compile_faq_equation!` entirely (it tests
# `rhs.op == "faq"` and sees `index`), so scan detection, the unrolled fold
# and the runtime contraction loop are all skipped and the equation drops to the
# per-cell tier at O(#cells) IR. A NON-contracting producer keeps the gather
# form: it lowers identically either way.
function _materialized_fill_equation(name::String, def::ASTExpr, dims::Vector{Int})
    nd = length(dims)
    # Fresh loop names; the `_mo` prefix is engine-internal and never part of a
    # cell key. Guard against the (pathological) case of a body that already
    # binds one by falling back to a name-qualified variant.
    loops = String["_mo$(d - 1)" for d in 1:nd]
    let clash = false
        foreach_subexpr_once(def) do x
            clash || (x isa VarExpr && x.name in loops && (clash = true))
            nothing
        end
        clash && (loops = String["_mo$(d - 1)_$(name)" for d in 1:nd])
    end
    ranges = Dict{String, Any}(loops[d] => Any[1, dims[d]] for d in 1:nd)
    idx_args = ASTExpr[VarExpr(name)]
    for l in loops
        push!(idx_args, VarExpr(l))
    end
    lhs = OpExpr(
        "faq", ASTExpr[];
        output_idx = Any[l for l in loops], ranges = ranges,
        expr_body = OpExpr("D", ASTExpr[OpExpr("index", idx_args)]; wrt = "t")
    )
    rhs = OpExpr("index", ASTExpr[def, (VarExpr(l) for l in loops)...])
    return Equation(lhs, rhs)
end

# The fill equations of one materialized array observed: the single gather-form
# equation above, or, for a `makearray` with a filtered or join-gated aggregate
# region value, one equation per REGION.
#
# Why per region: with the cell index symbolic, `index(makearray(...), i…)`
# cannot pick its region, so the whole fill declines every compile-once tier and
# is left to the per-cell build. A region value that CONTRACTS through a filter
# is then a per-cell triangular fold, and a strict compiler refuses it. A
# prefix-scan region (esm-spec §4.3.1) beside a rank-0 column-total region
# (`integral_lev_nodes_cumulative_from_bottom` in EarthSciDiscretizations) is
# the shape. Each region's equation runs over that region's own box and carries
# exactly the value `_resolve_index_of_makearray` picks for its cells:
#   * an array producer of the makearray's rank, as the gather
#     `index(<value>, i…)` (unwrapped to the bare aggregate downstream, which is
#     what lets `_detect_prefix_scan` see a scan);
#   * an array producer of lower rank, as the gather at the region's
#     non-singleton axes, unwrapped to the bare aggregate there when it
#     contracts;
#   * anything else (a rank-0 aggregate, a scalar expression), bare: its value
#     does not depend on the cell.
#
# Split only when the regions are constant, pairwise disjoint and tile the whole
# box, so "last region wins" and the 0 default for uncovered cells never arise
# and the per-region equations write each cell exactly once. The reference build
# (`compiler=:interpreter`, affine tier off) keeps the one gather equation, so
# the oracle is untouched.
function _materialized_fill_equations(name::String, def::ASTExpr, dims::Vector{Int})
    split = _stencil_disabled() ? nothing : _makearray_region_fills(name, def, dims)
    return split === nothing ? Equation[_materialized_fill_equation(name, def, dims)] : split
end

# A strict forward scan region beside the region holding its column total is
# ONE staggered prefix scan (`_scan_term_iters`): with the scan's terms on
# `1..n` along axis `d`, `F[…, k] = ⊕_{j<k} term_j` for `k ≤ n` and the total
# `⊕_{j≤n} term_j` at `k = n+1` are the same recurrence run one step further,
# the shape `integral_lev_nodes_cumulative_from_bottom` lowers to. Recognized,
# the total is the scan's last accumulation instead of a second fold over the
# column: the same terms in the same left-to-right order from the same 0̄ seed
# the total's own fold uses (`_combine_with_reducer` in the gather form, the
# bare contraction's in every tier; esm-spec §4.3.1), so the same bits. Returns that scan as one array aggregate over the whole
# box, or `nothing`.
#
# Required: two regions, the first the whole box but its last cell along `d`
# (from 1), the second that last cell; the first value a strict forward scan
# (`filter j < k`, no join) whose output axes are the makearray's, with `k` at
# axis `d` and `j` drawing the same range as `k`; the second an aggregate with
# no filter or join, of the scan's reduce, over the scan's other output axes
# in order, contracting `j` over the same range, with the same body once its
# output names are the scan's; and `j`'s range the constant `1..n-1` where the
# box has `n` cells along `d`.
function _makearray_staggered_scan(boxes, values, dims::Vector{Int})
    (length(boxes) == 2 && length(values) == 2) || return nothing
    nd = length(dims)
    A, B = values
    (A isa OpExpr && B isa OpExpr) || return nothing
    a, b = A::OpExpr, B::OpExpr
    (_is_faq_op(a.op) && _is_faq_op(b.op)) || return nothing
    (
        a.join === nothing && a.join_gates === nothing && b.join === nothing &&
            b.join_gates === nothing && b.filter === nothing
    ) || return nothing
    (
        a.expr_body === nothing || b.expr_body === nothing ||
            a.ranges === nothing || b.ranges === nothing
    ) && return nothing
    (a.reduce == b.reduce && a.semiring == b.semiring) || return nothing
    aout = _output_idx_strings(a)
    bout = _output_idx_strings(b)
    (length(aout) == nd && length(bout) == nd - 1) || return nothing
    f = a.filter
    (f isa OpExpr && (f::OpExpr).op == "<" && length((f::OpExpr).args) == 2) || return nothing
    jv, kv = (f::OpExpr).args
    (jv isa VarExpr && kv isa VarExpr) || return nothing
    j, k = (jv::VarExpr).name, (kv::VarExpr).name
    d = findfirst(isequal(k), aout)
    d === nothing && return nothing
    acon = _contracted_index_names(a.ranges, aout)
    bcon = _contracted_index_names(b.ranges, bout)
    (acon == [j] && bcon == [j]) || return nothing
    same(x, y) = repr(x) == repr(y)
    (same(a.ranges[k], a.ranges[j]) && same(b.ranges[j], a.ranges[j])) || return nothing
    rest = [aout[e] for e in 1:nd if e != d]
    for (x, y) in zip(bout, rest)
        same(b.ranges[x], a.ranges[y]) || return nothing
    end
    n = dims[d]
    # The terms must be exactly `1..n-1`, or the total would sum a different set.
    jr = a.ranges[j]
    (
        jr isa AbstractVector && _is_const_int_range(jr) &&
            _expand_int_range(collect(jr)) == 1:(n - 1)
    ) || return nothing
    for e in 1:nd
        want_lo, want_hi = e == d ? (1, n - 1) : (1, dims[e])
        boxes[1][e] == (want_lo, want_hi) || return nothing
        boxes[2][e] == (e == d ? (n, n) : (want_lo, want_hi)) || return nothing
    end
    ren = Dict{String, ASTExpr}(bout[i] => VarExpr(rest[i]) for i in eachindex(bout) if bout[i] != rest[i])
    bbody = isempty(ren) ? b.expr_body : _sub_preserving(b.expr_body, ren)
    same(bbody, a.expr_body) || return nothing
    ranges = Dict{String, Any}(String(x) => v for (x, v) in a.ranges)
    ranges[k] = Any[1, n]
    return reconstruct(a; ranges = ranges)
end

_region_bound_int(x::Integer) = Int(x)
_region_bound_int(x::ASTExpr) = _try_const_int(x, Dict{String, Any}())
_region_bound_int(x) = nothing

_is_gated_aggregate(v) = v isa OpExpr && _is_faq_op((v::OpExpr).op) &&
    ((v::OpExpr).filter !== nothing || (v::OpExpr).join_gates !== nothing)

function _makearray_region_fills(name::String, def::ASTExpr, dims::Vector{Int})
    def isa OpExpr || return nothing
    ma = def::OpExpr
    ma.op == "makearray" || return nothing
    (ma.regions === nothing || ma.values === nothing) && return nothing
    regions, values = ma.regions, ma.values
    (isempty(regions) || length(regions) != length(values)) && return nothing
    any(_is_gated_aggregate, values) || return nothing
    nd = length(dims)
    boxes = Vector{Vector{Tuple{Int, Int}}}()
    for region in regions
        length(region) == nd || return nothing
        box = Tuple{Int, Int}[]
        for d in 1:nd
            length(region[d]) == 2 || return nothing
            lo = _region_bound_int(region[d][1])
            hi = _region_bound_int(region[d][2])
            (lo === nothing || hi === nothing) && return nothing
            1 <= lo <= hi <= dims[d] || return nothing
            push!(box, (lo, hi))
        end
        push!(boxes, box)
    end
    overlap(a, b) = all(max(a[d][1], b[d][1]) <= min(a[d][2], b[d][2]) for d in 1:nd)
    for r in eachindex(boxes), s in (r + 1):length(boxes)
        overlap(boxes[r], boxes[s]) && return nothing
    end
    sum(prod(hi - lo + 1 for (lo, hi) in b) for b in boxes) == prod(dims) || return nothing
    staggered = _makearray_staggered_scan(boxes, values, dims)
    staggered === nothing ||
        return Equation[_materialized_fill_equation(name, staggered, dims)]
    base = _materialized_fill_equation(name, def, dims)
    loops = _output_idx_strings(base.lhs::OpExpr)
    lhs_body = (base.lhs::OpExpr).expr_body
    eqs = Equation[]
    for (box, val) in zip(boxes, values)
        ranges = Dict{String, Any}(loops[d] => Any[box[d][1], box[d][2]] for d in 1:nd)
        lhs = OpExpr(
            "faq", ASTExpr[]; output_idx = Any[l for l in loops],
            ranges = ranges, expr_body = lhs_body
        )
        rhs = if _is_array_producer(val)
            v = val::OpExpr
            rank = v.op == "makearray" ?
                ((v.regions === nothing || isempty(v.regions)) ? 0 : length(v.regions[1])) :
                length(_output_idx_strings(v))
            sel = rank == nd ? loops :
                String[loops[d] for d in 1:nd if box[d][1] != box[d][2]]
            length(sel) == rank || return nothing
            g = OpExpr("index", ASTExpr[v, (VarExpr(l) for l in sel)...])
            # The downstream unwrap sees only a gather at every loop of the
            # equation, so a lower-rank value is unwrapped here, at its own axes.
            rank == nd ? g : _unwrap_identity_gather(
                    g, sel,
                    Dict{String, Any}(l => ranges[l] for l in sel)
                )
        else
            val isa ASTExpr || return nothing
            val
        end
        push!(eqs, Equation(lhs, rhs))
    end
    return eqs
end

# Dependency LEVELS over the materialized observeds: level 1 reads none of them,
# level k only levels < k. Within a level the fills are order-independent, which
# is what lets each level run its scalar entries and then its (class-merged)
# kernel section in one go. A cycle is a genuine authoring error and is reported
# with the existing observed-cycle code.
#
# The edges must be TRANSITIVE THROUGH THE OBSERVEDS THAT STAYED INLINED: if a
# materialized `M` reads an inlined observed `X` whose body reads a materialized
# `N`, then `M`'s fill reads `N`'s buffer (X is spliced into M) even though `N`
# never appears in `M`'s own def. Ordering on direct references alone would let
# `M` fill from an unfilled `N` — a silently wrong RHS, not an error. So the
# walk expands through every non-materialized observed definition and stops at
# the materialized ones (their buffers are the dependency).
#
# A fill that reaches its OWN buffer through an inlined observed is an
# observed cycle, and is refused here with the code the inlining build
# (`_resolve_observed`) and `validate()` give it. It must be: a level's kernel
# section assumes no store to the buffers it fills aliases a load
# (`_build_codegen_rhs`; its threaded chunks run concurrently), and that
# level's writes are exactly its own observeds, whose other reads all sit on
# strictly lower levels. A build from a `Model` that skipped `validate()` would
# otherwise put a load of a slot the same section stores into one section,
# which is a race between chunks, not merely stale. The check is per observed and per name it reaches, never per cell.
#
# The one self-edge that is not a cycle is a recurrence's DIRECT self-read
# (esm-spec §4.3.1.1): its fill is an ordered sweep that reads only the cells it
# has already written (recurrence_sweep.jl), not a kernel section. So a
# recurrence's direct reads of its own name are left out of its edges; reaching
# itself through an inlined observed is still the cycle above.
function _materialized_obs_levels(
        mat_defs::Dict{String, ASTExpr}, names,
        inline_obs::Dict{String, ASTExpr}
    )
    nm = Set{String}(names)
    recur = _recurrence_names(mat_defs, nm)
    # The materialized buffers `root` reads, and for each the inlined observed
    # it was reached through (`nothing` for a direct read). A direct read of
    # `skip` is not followed.
    function reach(root::ASTExpr, skip::Union{Nothing, String} = nothing)
        out = Dict{String, Union{Nothing, String}}()
        via = Dict{String, Union{Nothing, String}}()
        frontier = Tuple{String, Union{Nothing, String}}[
            (r, nothing) for r in _referenced_var_names(root) if r != skip
        ]
        while !isempty(frontier)
            r, from = pop!(frontier)
            if r in nm
                haskey(out, r) || (out[r] = from)
            elseif !haskey(via, r) && haskey(inline_obs, r)
                via[r] = from
                append!(frontier, [(x, r) for x in _referenced_var_names(inline_obs[r])])
            end
        end
        return out, via
    end
    deps = Dict{String, Set{String}}()
    for n in sort!(collect(names))
        out, via = reach(mat_defs[n], n in recur ? n : nothing)
        if haskey(out, n)
            path = String[n]
            step = out[n]
            while step !== nothing
                pushfirst!(path, step)
                step = via[step]
            end
            throw(
                TreeWalkError(
                    "E_TREEWALK_OBSERVED_CYCLE",
                    "$(join(sort!(unique(path)), ",")): the array observed '$(n)' reads its " *
                        "own buffer ($(n) -> $(join(path, " -> ")))"
                )
            )
        end
        deps[n] = Set{String}(keys(out))
    end
    order = _dependency_order(
        sort(collect(names)), n -> deps[n];
        on_cycle = done -> throw(
            TreeWalkError(
                "E_TREEWALK_OBSERVED_CYCLE",
                join(sort(collect(setdiff(nm, done))), ",")
            )
        )
    )
    depth = Dict{String, Int}()
    for n in order
        depth[n] = isempty(deps[n]) ? 1 : 1 + maximum(depth[d] for d in deps[n])
    end
    nlev = isempty(order) ? 0 : maximum(values(depth))
    return [String[n for n in order if depth[n] == k] for k in 1:nlev]
end

# The CONST-cadence materialized observeds: those whose definition, followed
# through every observed it reads (materialized or inlined), reaches only
# literals, bound indices, scalar parameters and const arrays — no state, no
# `t`, no live forcing buffer or discrete cache. Their buffers are a function
# of `p` alone, so `f!` refills them only when `p` moves (the prelude const
# tier's rule, const_tier.jl, applied to whole buffers).
#
# FAIL CLOSED. A name is const only when it is positively one of those leaves;
# anything the walk does not recognize (the independent variable, a state, a
# forcing buffer, a recurrence's self-read, a name bound by a construct other
# than a `faq`'s indices) makes the observed dynamic, which costs a refill per
# call and never a stale number.
#
# With `allowed` (the names of `t` and of the live buffers) the same walk finds
# the observeds whose leaves may also be those: the observeds that read no
# state, whose buffers are a function of `(p, t, forcing data)` — the
# TIME-cadence ones, once the const ones are taken out.
function _const_cadence_mat_obs(
        mat_defs::Dict{String, ASTExpr}, mat_vars,
        inline_obs::AbstractDict, dynamic::Set{String},
        param_sym_set::AbstractDict,
        const_registry::AbstractDict,
        allowed::Set{String} = Set{String}()
    )
    memo = Dict{String, Bool}()
    visiting = Set{String}()
    function bound_names(e::ASTExpr)
        b = Set{String}()
        foreach_subexpr_once(e) do x
            if x isa OpExpr && _is_faq_op(x.op)
                x.output_idx === nothing || foreach(i -> push!(b, string(i)), x.output_idx)
                x.ranges === nothing || foreach(k -> push!(b, string(k)), keys(x.ranges))
            end
            nothing
        end
        return b
    end
    function name_const(n::String)
        n in dynamic && return false
        haskey(memo, n) && return memo[n]
        n in visiting && return false
        def = (n in mat_vars && haskey(mat_defs, n)) ? mat_defs[n] :
            haskey(inline_obs, n) ? inline_obs[n] : nothing
        def === nothing &&
            return n in allowed || haskey(param_sym_set, Symbol(n)) ||
            haskey(const_registry, n)
        push!(visiting, n)
        b = bound_names(def)
        c = _allof(r -> r in b || name_const(r), _referenced_var_names(def))
        delete!(visiting, n)
        memo[n] = c
        return c
    end
    return Set{String}(n for n in mat_vars if name_const(n))
end
