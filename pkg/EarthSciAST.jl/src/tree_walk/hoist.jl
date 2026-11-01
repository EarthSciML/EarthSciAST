# ========================================================================
# tree_walk/hoist.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl after build.jl.
#
# HOISTING NESTED REDUCTIONS. A scalar reduction nested in the body of an
# array faq is folded again at every output cell of that faq:
#
#     D(u[i,j,k]) = -0.1·u[i,j,k] + 0.001·Σ_l u[i,j,l]
#
# folds the column sum once per LEVEL k, though it depends on (i, j) only — an
# O(N·L) right-hand side where the hand loop is O(N). When the reduction's
# body reads a STRICT SUBSET S of the enclosing faq's output indices, the
# reduction is one value per S-cell, so the build lifts it into an internal
# array observed over S,
#
#     H[i,j] = Σ_l u[i,j,l]          D(u[i,j,k]) = -0.1·u[i,j,k] + 0.001·H[i,j]
#
# which the factored-observed machinery fills once per call, in its own level,
# before its readers. A reduction that reads none of the output indices is
# lifted over a one-cell internal index set (`_HOIST_ONE_SET`), so it too is
# one array observed and takes the same route on the right-hand side and in an
# output-time observed program.
#
# WHAT QUALIFIES (the rule other bindings match): a `faq` with no output index
# (a scalar reduction) and no join, reached from the body of an equation's
# array-producing `faq` with no filter and no join (either leaves output cells
# where the body is never evaluated), through elementwise operators only, never
# through an `index` subscript, another producer, or a lazily evaluated operand (an
# `ifelse` branch, a short-circuited `and` / `or` operand) — the lifted fill
# evaluates it at every S-cell, which the original did too exactly when it was
# evaluated at every output cell. Its free names may include the enclosing
# output indices in S, which must each range over a whole declared index set,
# and must not include the enclosing faq's contracted indices.
#
# DATA GATHERS are lifted by the same rule. An `index` read of a named array
# with a subscript that reads an unknown (a state or an observed), reached the
# same way and reading a strict subset S of the output indices,
#
#     D(u[c,l]) = -0.1·u[c,l] + 0.01·u[c, max(1, cnt[c])]
#
# becomes `G[c] = u[c, max(1, cnt[c])]`, read once per column instead of once
# per level. A subscript that reads only parameters or build-time data is left
# where it is: the tiers below resolve those at build.
#
# The lifted definition is the reduction itself with S added as its output
# indices (for a gather, a `faq` over S whose body is the gather), so its
# terms and fold order are the original's, cell for cell.
# Everything about it is internal to the build: its name carries a NUL byte,
# which no document name can, it is added only to the build's own copy of the
# model (observed listings, outputs and sinks read the document), and the
# compiler report files its rule under the equation it was lifted from. Under
# `compiler = :interpreter`, which inlines every array observed, nothing is
# lifted, so the oracle is the authored body.
# ========================================================================

const _HOIST_PREFIX = "\0hoist\0"
const _HOIST_ONE_SET = "\0hoist\0one"
const _HOIST_ONE_IDX = "\0hoist\0i"
_is_hoisted_name(n::AbstractString) = occursin(_HOIST_PREFIX, n)

# The names an expression reads that no binder inside it binds. A range
# bound, and a ragged range's parent indices, are read in the enclosing scope.
function _hoist_free_names!(out::Set{String}, e::ASTExpr, bound::Set{String})
    if e isa VarExpr
        (e::VarExpr).name in bound || push!(out, (e::VarExpr).name)
        return out
    end
    e isa OpExpr || return out
    o = e::OpExpr
    binders = String[]
    o.output_idx === nothing || for x in o.output_idx
        x isa AbstractString && push!(binders, String(x))
    end
    if o.ranges !== nothing
        for (k, v) in o.ranges
            push!(binders, String(k))
            if v isa IndexSetRef
                for p in v.of
                    p in bound || push!(out, p)
                end
            elseif v isa AbstractVector
                for x in v
                    x isa ASTExpr && _hoist_free_names!(out, x, bound)
                end
            end
        end
    end
    inner = isempty(binders) ? bound : union(bound, binders)
    for a in o.args
        _hoist_free_names!(out, a, inner)
    end
    for f in (o.expr_body, o.filter, o.lower, o.upper, o.key)
        f === nothing || _hoist_free_names!(out, f, inner)
    end
    o.values === nothing || foreach(v -> _hoist_free_names!(out, v, inner), o.values)
    return out
end

mutable struct _HoistCtx
    model_vars::AbstractDict                          # the model's own variables
    vars::OrderedDict{String, ModelVariable}
    eqs::Vector{Equation}
    memo::Dict{Tuple{UInt, Vector{String}}, ASTExpr}   # (reduction, S-cell sets) → reader
    owner::Dict{String, String}                        # lifted name → the equation's LHS name
end

_hoist_scalar_reduction(e::OpExpr) = _is_faq_op(e.op) &&
    (e.output_idx === nothing || !any(x -> x isa AbstractString, e.output_idx))

_hoist_plain(e::OpExpr) = e.op != "index" && e.op != "fn" && !_is_faq_op(e.op) &&
    e.op != "makearray" && e.ranges === nothing && e.output_idx === nothing &&
    e.expr_body === nothing && e.values === nothing && e.filter === nothing &&
    e.lower === nothing && e.upper === nothing && e.key === nothing

function _hoist_walk(
        e::ASTExpr, out_idx::Vector{String}, ranges, contracted::Set{String},
        owner::String, hc::_HoistCtx
    )
    e isa OpExpr || return e
    o = e::OpExpr
    if _hoist_scalar_reduction(o)
        r = _hoist_try(o, out_idx, ranges, contracted, owner, hc)
        return r === nothing ? o : r
    end
    if o.op == "index" && _hoist_data_gather(o, ranges, hc)
        r = _hoist_try(o, out_idx, ranges, contracted, owner, hc)
        return r === nothing ? o : r
    end
    _hoist_plain(o) || return o
    eager = (o.op == "ifelse" || o.op == "and" || o.op == "or") ? 1 : length(o.args)
    new = o.args
    for j in 1:min(eager, length(o.args))
        a = o.args[j]
        b = _hoist_walk(a, out_idx, ranges, contracted, owner, hc)
        if b !== a
            new === o.args && (new = copy(o.args))
            new[j] = b
        end
    end
    return new === o.args ? o : reconstruct(o; args = new)
end

# A DATA GATHER: an `index` read of a named array with a subscript that reads
# a state or an observed (an unknown) — `u[c, max(1, cnt[c])]` — so which
# element it reads is only known on the call.
function _hoist_data_gather(g::OpExpr, ranges, hc::_HoistCtx)
    (length(g.args) >= 2 && g.args[1] isa VarExpr) || return false
    for a in @view g.args[2:end]
        for n in _hoist_free_names!(Set{String}(), a, Set{String}())
            haskey(ranges, n) && continue
            v = get(hc.model_vars, n, nothing)
            v isa ModelVariable && v.type == UnknownVariable && return true
        end
    end
    return false
end

function _hoist_try(
        g::OpExpr, out_idx::Vector{String}, ranges, contracted::Set{String},
        owner::String, hc::_HoistCtx
    )
    gather = g.op == "index"
    if !gather
        (g.join === nothing && g.join_gates === nothing) || return nothing
        (g.ranges === nothing || isempty(g.ranges) || g.expr_body === nothing) &&
            return nothing
    end
    free = _hoist_free_names!(Set{String}(), g, Set{String}())
    any(n -> n in contracted, free) && return nothing
    S = String[s for s in out_idx if s in free]
    length(S) == length(out_idx) && !(!gather && _hoist_pins_outer(g, S)) && return nothing
    # A scalar reduction whose filter bounds its index from below by an outer
    # output index would become a reverse scan once lifted over it, folding
    # descending (`_reverse_window`); in place it folds ascending, as the
    # interpreter evaluates it, so it stays in place.
    gather || !_reverse_window(g.filter, String[String(k) for k in keys(g.ranges)], S) ||
        return nothing
    sets = String[]
    for s in S
        r = get(ranges, s, nothing)
        (r isa IndexSetRef && isempty(r.of)) || return nothing
        gather || haskey(g.ranges, s) && return nothing
        push!(sets, r.from)
    end
    key = (objectid(g), vcat(S, sets))
    hit = get(hc.memo, key, nothing)
    hit === nothing || return hit
    name = string(_HOIST_PREFIX, gather ? "g" : "", length(hc.memo) + 1, '\0', owner)
    rng = gather ? Dict{String, Any}() : Dict{String, Any}(String(k) => v for (k, v) in g.ranges)
    # A gather is lifted as the faq producing it over S, its body the gather.
    lift(oi, rg) = gather ?
        OpExpr("faq", ASTExpr[]; output_idx = oi, ranges = rg, expr_body = g) :
        reconstruct(g; output_idx = oi, ranges = rg)
    if isempty(S)
        rng[_HOIST_ONE_IDX] = IndexSetRef(_HOIST_ONE_SET)
        def = lift(Any[_HOIST_ONE_IDX], rng)
        shape = String[_HOIST_ONE_SET]
        reader = OpExpr("index", ASTExpr[VarExpr(name), IntExpr(1)])
    else
        for (s, st) in zip(S, sets)
            rng[s] = ranges[s]
        end
        def = lift(Any[S...], rng)
        shape = sets
        reader = OpExpr("index", ASTExpr[VarExpr(name), (VarExpr(s) for s in S)...])
    end
    hc.vars[name] = ModelVariable(UnknownVariable; shape = shape)
    push!(hc.eqs, Equation(VarExpr(name), def))
    hc.owner[name] = owner
    hc.memo[key] = reader
    return reader
end

# A SCATTER-SHAPED reduction is lifted even when it reads every enclosing
# output index: one whose filter pins an enclosing output index `s` by an
# equality conjunct `s == e` (or `e == s`) with `e` reading none of them. In
# place it tests every point of its box at every output cell; lifted, it is a
# `faq` over S whose filter pins its own output index, which the build folds
# as a one-pass scatter (scatter.jl), and the enclosing body reads the buffer.
# The lifted fill evaluates it at every S-cell, as the original was evaluated
# at every output cell, folding the same terms in the same order.
function _hoist_pins_outer(g::OpExpr, S::Vector{String})
    g.filter === nothing && return false
    for c in _scatter_conjuncts!(ASTExpr[], g.filter)
        (c isa OpExpr && (c::OpExpr).op == "==" && length((c::OpExpr).args) == 2) || continue
        a, b = (c::OpExpr).args
        for (x, e) in ((a, b), (b, a))
            (x isa VarExpr && (x::VarExpr).name in S) || continue
            haskey(g.ranges, (x::VarExpr).name) && continue
            any(n -> n in S, _hoist_free_names!(Set{String}(), e, Set{String}())) && continue
            return true
        end
    end
    return false
end

# FILTERED AGGREGATE OPERANDS of whole-array arithmetic are lifted too. An
# array observed spelled as elementwise arithmetic over a filtered array
# aggregate,
#
#     F = faq(k; j < k) f[j]·dz[j]  +  0.5·f·dz
#
# (a cumulative integral to each layer centre), is not itself a producer, so it
# is inlined into its readers and its aggregate reaches the array-equation
# cascade as `index(faq(...), i)` inside the pointwise-lifted body, where no
# compile-once tier sees the contraction: a prefix scan becomes a per-cell
# triangular fold. Lifted to its own observed `H = faq(...)`, the aggregate is
# a producer the factored-observed machinery fills through the whole cascade
# (a prefix scan as the O(N) scan fold), and `F = H + 0.5·f·dz` reads the
# buffer. The operand is reached through elementwise operators in eager
# positions only, carries no join, and every output range is a whole declared
# index set, which is then the lifted observed's shape: the lifted fill
# evaluates it at exactly the cells the whole-array arithmetic did.
_hoist_filtered_producer(e::OpExpr) = _is_faq_op(e.op) && e.filter !== nothing &&
    e.join === nothing && e.join_gates === nothing && e.expr_body !== nothing &&
    e.ranges !== nothing && _is_array_producer(e) &&
    all(x -> x isa AbstractString, e.output_idx) &&
    all(
    x -> (r = get(e.ranges, String(x), nothing); r isa IndexSetRef && isempty(r.of)),
    e.output_idx
)

# An operand whose output ranges are integer bounds `[1, n_d]` rather than
# index sets qualifies the same way when those bounds are exactly the extents
# of the left-hand side's declared shape, axis for axis (a derived document
# writes `faq(_j1; _j1 ∈ [1, 8], i ∈ [2, 7]; i - 1 == _j1)` against a `[x]`
# unknown of size 8): the lifted observed takes that declared shape, and its
# fill covers the same cells the whole-array arithmetic did.
function _hoist_filtered_producer_on(e::OpExpr, od)
    od === nothing && return false
    (
        _is_faq_op(e.op) && e.filter !== nothing && e.join === nothing &&
            e.join_gates === nothing && e.expr_body !== nothing && e.ranges !== nothing &&
            _is_array_producer(e) && all(x -> x isa AbstractString, e.output_idx)
    ) || return false
    shape, dims = od
    length(e.output_idx) == length(dims) || return false
    for (d, x) in enumerate(e.output_idx)
        r = get(e.ranges, String(x), nothing)
        (
            r isa AbstractVector && length(r) == 2 && r[1] isa Integer && r[2] isa Integer &&
                r[1] == 1 && r[2] == dims[d]
        ) || return false
    end
    return true
end

# REGION-SPLIT OPERANDS of elementwise arithmetic are lifted too. A rule that
# lowers a spatial `D` builds a `makearray` whose regions split the axis it
# differentiates along (the interior stencil and its boundary faces, §9.6.8).
# Two such operands combined elementwise,
#
#     D(mq) = -(D_lon(Mx·q) + D_lat(My·q))
#
# reach the affine tier as one expression cut by the product of their region
# cuts: every box of the product lowers its own copy of both stencils. Lifted,
# each `makearray` is its own observed `H` over the left-hand side's shape,
# filled region by region once per call, and `D(mq) = -(H_lon + H_lat)` reads
# the buffers. The fill evaluates each region value at exactly the cells it
# covers in place, and the combination applies the same operators to the same
# values in the same order, so every result is unchanged. A `makearray`
# qualifies when it is reached through elementwise operators in eager
# positions only and has at least two regions, one integer bound pair per
# dimension of the left-hand side's declared shape inside that dimension's
# interval set, and regions that together cover every cell (an uncovered cell
# reads the `makearray` default in place). It is lifted only when the equation
# combines at least two of them. Interning makes node identity the canonical
# expression, so a term two equations share (`dev` reads `mq`'s two flux
# divergences) is lifted once and read by both.

# The qualifying `makearray` operands of `e` (see above) against the
# left-hand side's dimension sizes `dims`.
function _hoist_split_operands!(
        out::Vector{OpExpr}, e::ASTExpr, dims::Vector{Int},
        seen::IdDict{OpExpr, Nothing}
    )
    e isa OpExpr || return out
    o = e::OpExpr
    haskey(seen, o) && return out
    seen[o] = nothing
    if o.op == "makearray"
        _hoist_split_qualifies(o, dims) && push!(out, o)
        return out
    end
    _hoist_plain(o) || return out
    eager = (o.op == "ifelse" || o.op == "and" || o.op == "or") ? 1 : length(o.args)
    for j in 1:min(eager, length(o.args))
        _hoist_split_operands!(out, o.args[j], dims, seen)
    end
    return out
end

function _hoist_split_qualifies(m::OpExpr, dims::Vector{Int})
    regs = m.regions
    (
        regs === nothing || m.values === nothing || length(regs) < 2 ||
            length(m.values) != length(regs)
    ) && return false
    nd = length(dims)
    for reg in regs
        length(reg) == nd || return false
        for d in 1:nd
            b = reg[d]
            (length(b) == 2 && b[1] isa Integer && b[2] isa Integer) || return false
            (1 <= b[1] && b[2] <= dims[d] && b[2] >= b[1] - 1) || return false
        end
    end
    return _hoist_regions_cover(regs, dims)
end

# Whether the regions cover every cell of the `dims` box. Each dimension is cut
# at every region bound; a cell of the product of those cuts lies wholly inside
# or wholly outside each region, so checking one corner per product cell is
# exact, and the number of product cells depends on the regions, not the grid.
function _hoist_regions_cover(regs, dims::Vector{Int})
    nd = length(dims)
    starts = Vector{Vector{Int}}(undef, nd)
    for d in 1:nd
        s = Set{Int}(1)
        for reg in regs
            lo, hi = Int(reg[d][1]), Int(reg[d][2])
            hi >= lo || continue
            push!(s, lo)
            hi < dims[d] && push!(s, hi + 1)
        end
        starts[d] = sort!(collect(s))
    end
    for corner in Iterators.product(starts...)
        any(reg -> all(d -> reg[d][1] <= corner[d] <= reg[d][2], 1:nd), regs) ||
            return false
    end
    return true
end

function _hoist_lift_split(g::OpExpr, owner::String, shape::Vector{String}, hc::_HoistCtx)
    key = (objectid(g), vcat(String["\0makearray"], shape))
    hit = get(hc.memo, key, nothing)
    hit === nothing || return hit
    name = string(_HOIST_PREFIX, "m", length(hc.memo) + 1, '\0', owner)
    hc.vars[name] = ModelVariable(UnknownVariable; shape = copy(shape))
    push!(hc.eqs, Equation(VarExpr(name), g))
    hc.owner[name] = owner
    reader = VarExpr(name)
    hc.memo[key] = reader
    return reader
end

# The declared shape of the variable `owner` and each set's size, when every
# set is an interval of known size.
function _hoist_owner_dims(owner::String, hc::_HoistCtx, index_sets::AbstractDict)
    v = get(hc.model_vars, owner, nothing)
    (v isa ModelVariable && v.shape !== nothing && !isempty(v.shape)) || return nothing
    shape = String[String(s) for s in v.shape]
    dims = Int[]
    for s in shape
        is = get(index_sets, s, nothing)
        (is isa IndexSet && is.kind == "interval" && is.size isa Integer) || return nothing
        push!(dims, Int(is.size))
    end
    return shape, dims
end

# Memoized on node identity: this runs over every plain equation, and a body
# that shares a subexpression (a doubling DAG of `n + n`) must be walked once
# per distinct node, not once per path. `split`, when given, is the set of
# region-split operands to lift and the left-hand side's shape.
function _hoist_operand_walk(
        e::ASTExpr, owner::String, hc::_HoistCtx,
        memo::IdDict{OpExpr, ASTExpr}, split = nothing, od = nothing
    )
    e isa OpExpr || return e
    o = e::OpExpr
    _hoist_plain(o) || return o
    hit = get(memo, o, nothing)
    hit === nothing || return hit
    eager = (o.op == "ifelse" || o.op == "and" || o.op == "or") ? 1 : length(o.args)
    new = o.args
    for j in 1:min(eager, length(o.args))
        a = o.args[j]
        b = if split !== nothing && a isa OpExpr && haskey(split[1], a::OpExpr)
            _hoist_lift_split(a::OpExpr, owner, split[2], hc)
        elseif a isa OpExpr && _hoist_filtered_producer(a::OpExpr)
            _hoist_lift_producer(a::OpExpr, owner, hc)
        elseif a isa OpExpr && _hoist_filtered_producer_on(a::OpExpr, od)
            _hoist_lift_producer(a::OpExpr, owner, hc; shape = od[1])
        else
            _hoist_operand_walk(a, owner, hc, memo, split, od)
        end
        if b !== a
            new === o.args && (new = copy(o.args))
            new[j] = b
        end
    end
    out = new === o.args ? o : reconstruct(o; args = new)
    memo[o] = out
    return out
end

function _hoist_lift_producer(
        g::OpExpr, owner::String, hc::_HoistCtx;
        shape::Union{Nothing, Vector{String}} = nothing
    )
    key = (objectid(g), vcat(String["\0producer"], something(shape, String[])))
    hit = get(hc.memo, key, nothing)
    hit === nothing || return hit
    name = string(_HOIST_PREFIX, "a", length(hc.memo) + 1, '\0', owner)
    shape === nothing &&
        (shape = String[(g.ranges[String(x)]::IndexSetRef).from for x in g.output_idx])
    hc.vars[name] = ModelVariable(UnknownVariable; shape = shape)
    push!(hc.eqs, Equation(VarExpr(name), g))
    hc.owner[name] = owner
    reader = VarExpr(name)
    hc.memo[key] = reader
    return reader
end

# A compiler-report rule label with every lifted name replaced by the variable
# whose equation it was lifted from (the name ends in it, after a NUL).
_hoist_public_label(label::AbstractString) =
    replace(
    replace(
        replace(
            replace(
                label,
                r"\0hoist\0g\d+\0([^\0\[\]]*)" => s"\1 (hoisted gather)"
            ),
            r"\0hoist\0a\d+\0([^\0\[\]]*)" => s"\1 (hoisted aggregate)"
        ),
        r"\0hoist\0m\d+\0([^\0\[\]]*)" => s"\1 (hoisted region term)"
    ),
    r"\0hoist\0\d+\0([^\0\[\]]*)" => s"\1 (hoisted reduction)"
)

# The build's copy of `model` with every qualifying nested reduction lifted
# (see the header), the index sets with the one-cell set added when one was
# lifted over it, and the lifted name → owning variable map. `model` itself
# when nothing qualifies.
function _hoist_nested_reductions(model::Model, index_sets::AbstractDict)
    hc = _HoistCtx(
        model.variables, OrderedDict{String, ModelVariable}(), Equation[],
        Dict{Tuple{UInt, Vector{String}}, ASTExpr}(), Dict{String, String}()
    )
    eqs = model.equations
    for (i, eq) in enumerate(model.equations)
        rhs = eq.rhs
        if rhs isa OpExpr && _hoist_plain(rhs::OpExpr) &&
                (eq.lhs isa VarExpr || (eq.lhs isa OpExpr && (eq.lhs::OpExpr).op == "D"))
            names = sort!(
                collect(
                    _hoist_free_names!(
                        Set{String}(), eq.lhs,
                        Set{String}(["t"])
                    )
                )
            )
            owner = eq.lhs isa VarExpr ? (eq.lhs::VarExpr).name :
                isempty(names) ? "" : first(names)
            split = nothing
            od = _hoist_owner_dims(owner, hc, index_sets)
            if od !== nothing
                ops = _hoist_split_operands!(OpExpr[], rhs, od[2], IdDict{OpExpr, Nothing}())
                length(ops) >= 2 &&
                    (split = (IdDict{OpExpr, Nothing}(o => nothing for o in ops), od[1]))
            end
            new_rhs = _hoist_operand_walk(rhs, owner, hc, IdDict{OpExpr, ASTExpr}(), split, od)
            new_rhs === rhs && continue
            eqs === model.equations && (eqs = copy(model.equations))
            eqs[i] = Equation(eq.lhs, new_rhs; _comment = eq._comment)
            continue
        end
        (
            rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) &&
                (rhs::OpExpr).output_idx !== nothing && (rhs::OpExpr).ranges !== nothing &&
                (rhs::OpExpr).expr_body !== nothing
        ) || continue
        f = rhs::OpExpr
        # A filter or a join leaves output cells where the body is never
        # evaluated; the lifted fill would evaluate it there, and a gather or
        # reduction that faults at such a cell must not (esm-spec §5.5.8).
        (f.filter === nothing && f.join === nothing && f.join_gates === nothing) ||
            continue
        out_idx = String[String(x) for x in f.output_idx if x isa AbstractString]
        isempty(out_idx) && continue
        contracted = Set{String}(String(k) for k in keys(f.ranges) if !(String(k) in out_idx))
        lhs_names = sort!(
            collect(
                _hoist_free_names!(
                    Set{String}(), eq.lhs,
                    Set{String}(["t"])
                )
            )
        )
        owner = eq.lhs isa VarExpr ? (eq.lhs::VarExpr).name :
            isempty(lhs_names) ? "" : first(lhs_names)
        body = _hoist_walk(f.expr_body, out_idx, f.ranges, contracted, owner, hc)
        body === f.expr_body && continue
        eqs === model.equations && (eqs = copy(model.equations))
        eqs[i] = Equation(eq.lhs, reconstruct(f; expr_body = body); _comment = eq._comment)
    end
    isempty(hc.eqs) && return model, index_sets, hc.owner
    vars = OrderedDict{String, ModelVariable}(model.variables)
    merge!(vars, hc.vars)
    m = Model(
        vars, vcat(eqs, hc.eqs), model.discrete_events, model.continuous_events,
        model.subsystems; tolerance = model.tolerance, tests = model.tests,
        analyses = model.analyses, initialization_equations = model.initialization_equations,
        guesses = model.guesses, system_kind = model.system_kind, reference = model.reference
    )
    isets = index_sets
    if any(v -> v.shape == [_HOIST_ONE_SET], values(hc.vars))
        isets = copy(index_sets)
        isets[_HOIST_ONE_SET] = IndexSet("interval"; size = 1)
    end
    return m, isets, hc.owner
end
