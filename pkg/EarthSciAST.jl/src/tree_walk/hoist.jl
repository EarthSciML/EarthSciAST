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
# array-producing `faq` through elementwise operators only, never through an
# `index` subscript, another producer, or a lazily evaluated operand (an
# `ifelse` branch, a short-circuited `and` / `or` operand) — the lifted fill
# evaluates it at every S-cell, which the original did too exactly when it was
# evaluated at every output cell. Its free names may include the enclosing
# output indices in S, which must each range over a whole declared index set,
# and must not include the enclosing faq's contracted indices.
#
# The lifted definition is the reduction itself with S added as its output
# indices, so its terms and fold order are the original's, cell for cell.
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
    vars::OrderedDict{String,ModelVariable}
    eqs::Vector{Equation}
    memo::Dict{Tuple{UInt,Vector{String}},ASTExpr}   # (reduction, S-cell sets) → reader
    owner::Dict{String,String}                        # lifted name → the equation's LHS name
end

_hoist_scalar_reduction(e::OpExpr) = _is_faq_op(e.op) &&
    (e.output_idx === nothing || !any(x -> x isa AbstractString, e.output_idx))

_hoist_plain(e::OpExpr) = e.op != "index" && e.op != "fn" && !_is_faq_op(e.op) &&
    e.op != "makearray" && e.ranges === nothing && e.output_idx === nothing &&
    e.expr_body === nothing && e.values === nothing && e.filter === nothing &&
    e.lower === nothing && e.upper === nothing && e.key === nothing

function _hoist_walk(e::ASTExpr, out_idx::Vector{String}, ranges, contracted::Set{String},
                     owner::String, hc::_HoistCtx)
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
    return new === o.args ? o : reconstruct(o; args=new)
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

function _hoist_try(g::OpExpr, out_idx::Vector{String}, ranges, contracted::Set{String},
                    owner::String, hc::_HoistCtx)
    gather = g.op == "index"
    if !gather
        (g.join === nothing && g.join_gates === nothing) || return nothing
        (g.ranges === nothing || isempty(g.ranges) || g.expr_body === nothing) &&
            return nothing
    end
    free = _hoist_free_names!(Set{String}(), g, Set{String}())
    any(n -> n in contracted, free) && return nothing
    S = String[s for s in out_idx if s in free]
    length(S) == length(out_idx) && return nothing
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
    rng = gather ? Dict{String,Any}() : Dict{String,Any}(String(k) => v for (k, v) in g.ranges)
    # A gather is lifted as the faq producing it over S, its body the gather.
    lift(oi, rg) = gather ?
        OpExpr("faq", ASTExpr[]; output_idx=oi, ranges=rg, expr_body=g) :
        reconstruct(g; output_idx=oi, ranges=rg)
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
    hc.vars[name] = ModelVariable(UnknownVariable; shape=shape)
    push!(hc.eqs, Equation(VarExpr(name), def))
    hc.owner[name] = owner
    hc.memo[key] = reader
    return reader
end

# A compiler-report rule label with every lifted name replaced by the variable
# whose equation it was lifted from (the name ends in it, after a NUL).
_hoist_public_label(label::AbstractString) =
    replace(replace(label, r"\0hoist\0g\d+\0([^\0\[\]]*)" => s"\1 (hoisted gather)"),
            r"\0hoist\0\d+\0([^\0\[\]]*)" => s"\1 (hoisted reduction)")

# The build's copy of `model` with every qualifying nested reduction lifted
# (see the header), the index sets with the one-cell set added when one was
# lifted over it, and the lifted name → owning variable map. `model` itself
# when nothing qualifies.
function _hoist_nested_reductions(model::Model, index_sets::AbstractDict)
    hc = _HoistCtx(model.variables, OrderedDict{String,ModelVariable}(), Equation[],
                   Dict{Tuple{UInt,Vector{String}},ASTExpr}(), Dict{String,String}())
    eqs = model.equations
    for (i, eq) in enumerate(model.equations)
        rhs = eq.rhs
        (rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) &&
         (rhs::OpExpr).output_idx !== nothing && (rhs::OpExpr).ranges !== nothing &&
         (rhs::OpExpr).expr_body !== nothing) || continue
        f = rhs::OpExpr
        out_idx = String[String(x) for x in f.output_idx if x isa AbstractString]
        isempty(out_idx) && continue
        contracted = Set{String}(String(k) for k in keys(f.ranges) if !(String(k) in out_idx))
        lhs_names = sort!(collect(_hoist_free_names!(Set{String}(), eq.lhs,
                                                     Set{String}(["t"]))))
        owner = eq.lhs isa VarExpr ? (eq.lhs::VarExpr).name :
                isempty(lhs_names) ? "" : first(lhs_names)
        body = _hoist_walk(f.expr_body, out_idx, f.ranges, contracted, owner, hc)
        body === f.expr_body && continue
        eqs === model.equations && (eqs = copy(model.equations))
        eqs[i] = Equation(eq.lhs, reconstruct(f; expr_body=body); _comment=eq._comment)
    end
    isempty(hc.eqs) && return model, index_sets, hc.owner
    vars = OrderedDict{String,ModelVariable}(model.variables)
    merge!(vars, hc.vars)
    m = Model(vars, vcat(eqs, hc.eqs), model.discrete_events, model.continuous_events,
              model.subsystems; tolerance=model.tolerance, tests=model.tests,
              analyses=model.analyses, initialization_equations=model.initialization_equations,
              guesses=model.guesses, system_kind=model.system_kind, reference=model.reference)
    isets = index_sets
    if any(v -> v.shape == [_HOIST_ONE_SET], values(hc.vars))
        isets = copy(index_sets)
        isets[_HOIST_ONE_SET] = IndexSet("interval"; size=1)
    end
    return m, isets, hc.owner
end
