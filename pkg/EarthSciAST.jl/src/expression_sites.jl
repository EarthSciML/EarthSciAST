# ===========================================================================
# expression_sites.jl — the one list of the places an expression can sit in a
# typed document, with a rewriting walk (`map_expressions!`) and a read-only
# walk that reports each site's JSON pointer (`foreach_expression`). Both run
# the same code, so they cannot disagree about where an expression may appear.
# ===========================================================================

# `_new_typed` for every struct the walk rebuilds, so a rebuild copies every
# field positionally and a field added to one of them is carried across.
for T in (
        Equation, AffectEquation, ConditionTrigger, ContinuousEvent, DiscreteEvent,
        DataSourceBinding, FunctionalUpdate, ModelVariable, Reaction, Parameter, Assertion,
        InlineTest, Model, ReactionSystem, CouplingVariableMap, CouplingEvent,
        CouplingCouple,
    )
    _def_new_typed(T)
end

# `x` with the fields named in `kwargs` replaced and every other field copied,
# built positionally (no constructor runs).
function _reconstruct_fields(x::T; kwargs...) where {T}
    for k in keys(kwargs)
        hasfield(T, k) || throw(ArgumentError("$(nameof(T)) has no field `$k`"))
    end
    return _new_typed(
        T, ntuple(i -> get(kwargs, fieldname(T, i), getfield(x, i)), fieldcount(T))...
    )
end

"""
    reconstruct(r::ParameterUpdate; <any ParameterUpdate field>=…) -> ParameterUpdate

Rebuild a `ParameterUpdate`, copying every field from `r` and overriding only
the keywords passed. The `ParameterUpdate` analogue of
[`reconstruct(::ModelVariable)`](@ref).
"""
reconstruct(r::ParameterUpdate; kwargs...) = _reconstruct_fields(r; kwargs...)

"""
    EXPRESSION_SITE_KINDS

The kinds of expression site [`foreach_expression`](@ref) reports, one per
position an [`ASTExpr`](@ref) can take in a typed document:

| kind | position |
|:-----|:---------|
| `:equation_lhs`, `:equation_rhs` | a model's `equations[i]` |
| `:initialization_lhs`, `:initialization_rhs` | a model's `initialization_equations[i]` |
| `:guess` | a model's `guesses[name]` when it is an expression |
| `:update_when`, `:update_expression`, `:update_unit_conversion` | a parameter `update` rule's `when`, `expression` and `from.unit_conversion` (a model variable or a reaction-system parameter) |
| `:lower_bound`, `:upper_bound` | a model variable's `lb` / `ub` when it names a variable (presented as a `VarExpr`; a `VarExpr` result is stored back as the name) or is an expression |
| `:event_condition` | a continuous event's `conditions[j]` (model, reaction system or coupling event) |
| `:event_trigger` | a discrete event's condition trigger `expression` |
| `:affect`, `:affect_neg` | the right-hand side of an event's `affects[j]` / `affect_neg[j]` |
| `:test_reference` | an inline test assertion's `reference` when it is an expression |
| `:rate` | a reaction's `rate` |
| `:constraint_lhs`, `:constraint_rhs` | a reaction system's `constraint_equations[i]` |
| `:variable_map_transform` | a `variable_map` coupling entry's expression `transform` |
| `:connector_expression` | a `couple` connector equation's `expression` when it is a typed expression |
"""
const EXPRESSION_SITE_KINDS = (
    :equation_lhs, :equation_rhs, :initialization_lhs, :initialization_rhs,
    :guess, :update_when, :update_expression, :update_unit_conversion,
    :lower_bound, :upper_bound, :event_condition, :event_trigger, :affect,
    :affect_neg, :test_reference, :rate, :constraint_lhs, :constraint_rhs,
    :variable_map_transform, :connector_expression,
)

# The struct fields that hold an `ASTExpr` directly (in a `Union`, a vector or a
# dict value), each with the site kinds the walk reports for it. A test walks
# the document types by reflection and requires every field whose declared type
# mentions `ASTExpr` to be listed here; another requires every kind to be
# reported. The last two entries are declared with `Any` and so are listed by
# hand.
const _EXPRESSION_SITE_FIELDS = Dict{Tuple{DataType, Symbol}, Tuple{Vararg{Symbol}}}(
    (Equation, :lhs) => (:equation_lhs, :initialization_lhs, :constraint_lhs),
    (Equation, :rhs) => (:equation_rhs, :initialization_rhs, :constraint_rhs),
    (AffectEquation, :rhs) => (:affect, :affect_neg),
    (ConditionTrigger, :expression) => (:event_trigger,),
    (ContinuousEvent, :conditions) => (:event_condition,),
    (CouplingEvent, :conditions) => (:event_condition,),
    (ParameterUpdate, :when) => (:update_when,),
    (ParameterUpdate, :expression) => (:update_expression,),
    (DataSourceBinding, :unit_conversion) => (:update_unit_conversion,),
    (ModelVariable, :lb) => (:lower_bound,),
    (ModelVariable, :ub) => (:upper_bound,),
    (Model, :guesses) => (:guess,),
    (Reaction, :rate) => (:rate,),
    (CouplingVariableMap, :transform) => (:variable_map_transform,),
    # Declared `Any` / `Dict{String, Any}`; an expression when it is an `ASTExpr`.
    (Assertion, :reference) => (:test_reference,),
    (CouplingCouple, :connector) => (:connector_expression,),
)

_ptr(::Nothing, parts...) = nothing
_ptr(path::String, parts...) = string(path, parts...)

_rule_ptr(::Nothing, rules, ri) = nothing
_rule_ptr(base::String, rules, ri) = _update_rule_path(base, rules, ri)

# ---------------------------------------------------------------------------
# The walk. `g(expr, pointer, kind) -> ASTExpr` is called on every site; the
# value it returns replaces the expression. `pointer` is `nothing` when the
# caller asked for no pointers. A struct is rebuilt only when some expression
# in it came back as a different object, so a walk whose `g` returns its
# argument leaves every object as it was. The containers a `Model`,
# `ReactionSystem` or `EsmFile` holds directly (variable map, equation and
# event vectors, guesses, tests, reactions, parameters, coupling entries) are
# updated in place; nothing else is mutated.
# ---------------------------------------------------------------------------

function _walk_equations!(g::G, eqs::Vector{Equation}, path, lk::Symbol, rk::Symbol) where {G}
    for (i, eq) in enumerate(eqs)
        p = _ptr(path, "/", i - 1)
        l = g(eq.lhs, _ptr(p, "/lhs"), lk)
        r = g(eq.rhs, _ptr(p, "/rhs"), rk)
        (l === eq.lhs && r === eq.rhs) || (eqs[i] = _reconstruct_fields(eq; lhs = l, rhs = r))
    end
    return eqs
end

function _walk_rules(g::G, rules, base) where {G}
    rules === nothing && return rules
    out = nothing
    for (ri, r) in enumerate(rules)
        p = _rule_ptr(base, rules, ri)
        w = r.when === nothing ? nothing : g(r.when, _ptr(p, "/when"), :update_when)
        e = r.expression === nothing ? nothing :
            g(r.expression, _ptr(p, "/expression"), :update_expression)
        from = r.from
        if from !== nothing && from.unit_conversion isa ASTExpr
            uc = g(from.unit_conversion, _ptr(p, "/from/unit_conversion"), :update_unit_conversion)
            uc === from.unit_conversion || (from = _reconstruct_fields(from; unit_conversion = uc))
        end
        w === r.when && e === r.expression && from === r.from && continue
        out === nothing && (out = copy(rules))
        out[ri] = reconstruct(r; when = w, expression = e, from = from)
    end
    return out === nothing ? rules : out
end

# A bound that names a variable is a reference like any other: it is presented
# as a one-leaf `VarExpr`, and a result that is still a single variable is
# stored back as its name. A number is not a site.
_walk_bound(g, b, path, kind::Symbol) = b
_walk_bound(g::G, b::ASTExpr, path, kind::Symbol) where {G} = g(b, path, kind)
function _walk_bound(g::G, b::String, path, kind::Symbol) where {G}
    leaf = VarExpr(b)
    out = g(leaf, path, kind)
    out === leaf && return b
    return out isa VarExpr ? out.name : out
end

function _walk_variable(g::G, v::ModelVariable, path) where {G}
    update = _walk_rules(g, v.update, path)
    lb = _walk_bound(g, v.lb, _ptr(path, "/lb"), :lower_bound)
    ub = _walk_bound(g, v.ub, _ptr(path, "/ub"), :upper_bound)
    update === v.update && lb === v.lb && ub === v.ub && return v
    return _reconstruct_fields(v; update = update, lb = lb, ub = ub)
end

function _walk_affects(g::G, affects, path, kind::Symbol) where {G}
    affects === nothing && return affects
    out = nothing
    for (j, a) in enumerate(affects)
        r = g(a.rhs, _ptr(path, "/", j - 1, "/rhs"), kind)
        r === a.rhs && continue
        out === nothing && (out = copy(affects))
        out[j] = _reconstruct_fields(a; rhs = r)
    end
    return out === nothing ? affects : out
end

function _walk_conditions(g::G, conds, path) where {G}
    conds === nothing && return conds
    out = nothing
    for (j, c) in enumerate(conds)
        r = g(c, _ptr(path, "/", j - 1), :event_condition)
        r === c && continue
        out === nothing && (out = copy(conds))
        out[j] = r
    end
    return out === nothing ? conds : out
end

_walk_trigger(g, t::DiscreteEventTrigger, path) = t
function _walk_trigger(g::G, t::ConditionTrigger, path) where {G}
    e = g(t.expression, _ptr(path, "/trigger/expression"), :event_trigger)
    return e === t.expression ? t : ConditionTrigger(e)
end
_walk_trigger(g, ::Nothing, path) = nothing

function _walk_event(g::G, ev::ContinuousEvent, path) where {G}
    c = _walk_conditions(g, ev.conditions, _ptr(path, "/conditions"))
    a = _walk_affects(g, ev.affects, _ptr(path, "/affects"), :affect)
    n = _walk_affects(g, ev.affect_neg, _ptr(path, "/affect_neg"), :affect_neg)
    c === ev.conditions && a === ev.affects && n === ev.affect_neg && return ev
    return _reconstruct_fields(ev; conditions = c, affects = a, affect_neg = n)
end

function _walk_event(g::G, ev::DiscreteEvent, path) where {G}
    t = _walk_trigger(g, ev.trigger, path)
    a = _walk_affects(g, ev.affects, _ptr(path, "/affects"), :affect)
    t === ev.trigger && a === ev.affects && return ev
    return _reconstruct_fields(ev; trigger = t, affects = a)
end

function _walk_event(g::G, ev::CouplingEvent, path) where {G}
    c = _walk_conditions(g, ev.conditions, _ptr(path, "/conditions"))
    t = _walk_trigger(g, ev.trigger, path)
    a = _walk_affects(g, ev.affects, _ptr(path, "/affects"), :affect)
    n = _walk_affects(g, ev.affect_neg, _ptr(path, "/affect_neg"), :affect_neg)
    c === ev.conditions && t === ev.trigger && a === ev.affects && n === ev.affect_neg &&
        return ev
    return _reconstruct_fields(ev; conditions = c, trigger = t, affects = a, affect_neg = n)
end

function _walk_events!(g::G, events::Vector, path) where {G}
    for (i, ev) in enumerate(events)
        nev = _walk_event(g, ev, _ptr(path, "/", i - 1))
        nev === ev || (events[i] = nev)
    end
    return events
end

function _walk_tests!(g::G, tests::Vector{InlineTest}, path) where {G}
    for (i, t) in enumerate(tests)
        out = nothing
        for (j, a) in enumerate(t.assertions)
            a.reference isa ASTExpr || continue
            r = g(
                a.reference, _ptr(path, "/", i - 1, "/assertions/", j - 1, "/reference"),
                :test_reference
            )
            r === a.reference && continue
            out === nothing && (out = copy(t.assertions))
            out[j] = _reconstruct_fields(a; reference = r)
        end
        out === nothing || (tests[i] = _reconstruct_fields(t; assertions = out))
    end
    return tests
end

function _walk_sites!(g::G, m::Model, path, recurse::Bool) where {G}
    _walk_equations!(g, m.equations, _ptr(path, "/equations"), :equation_lhs, :equation_rhs)
    _walk_equations!(
        g, m.initialization_equations, _ptr(path, "/initialization_equations"),
        :initialization_lhs, :initialization_rhs
    )
    if !isempty(m.guesses)
        for name in sort!(collect(keys(m.guesses)))
            v = m.guesses[name]
            v isa ASTExpr || continue
            nv = g(v, _ptr(path, "/guesses/", name), :guess)
            nv === v || (m.guesses[name] = nv)
        end
    end
    for (name, v) in m.variables
        nv = _walk_variable(g, v, _ptr(path, "/variables/", name))
        nv === v || (m.variables[name] = nv)
    end
    _walk_events!(g, m.continuous_events, _ptr(path, "/continuous_events"))
    _walk_events!(g, m.discrete_events, _ptr(path, "/discrete_events"))
    _walk_tests!(g, m.tests, _ptr(path, "/tests"))
    if recurse
        for (name, sub) in m.subsystems
            sub isa Model || continue
            _walk_sites!(g, sub, _ptr(path, "/subsystems/", name), true)
        end
    end
    return m
end

function _walk_sites!(g::G, rs::ReactionSystem, path, recurse::Bool) where {G}
    for (i, r) in enumerate(rs.reactions)
        nr = g(r.rate, _ptr(path, "/reactions/", i - 1, "/rate"), :rate)
        nr === r.rate || (rs.reactions[i] = _reconstruct_fields(r; rate = nr))
    end
    for (i, p) in enumerate(rs.parameters)
        rules = _walk_rules(g, p.update, _ptr(path, "/parameters/", p.name))
        rules === p.update || (rs.parameters[i] = _reconstruct_fields(p; update = rules))
    end
    _walk_equations!(
        g, rs.constraint_equations, _ptr(path, "/constraint_equations"),
        :constraint_lhs, :constraint_rhs
    )
    _walk_events!(g, rs.continuous_events, _ptr(path, "/continuous_events"))
    _walk_events!(g, rs.discrete_events, _ptr(path, "/discrete_events"))
    _walk_tests!(g, rs.tests, _ptr(path, "/tests"))
    if recurse
        for (name, sub) in rs.subsystems
            _walk_sites!(g, sub, _ptr(path, "/subsystems/", name), true)
        end
    end
    return rs
end

_walk_coupling(g, ce::CouplingEntry, path) = ce
function _walk_coupling(g::G, ce::CouplingVariableMap, path) where {G}
    ce.transform isa ASTExpr || return ce
    t = g(ce.transform, _ptr(path, "/transform"), :variable_map_transform)
    return t === ce.transform ? ce : _reconstruct_fields(ce; transform = t)
end
_walk_coupling(g, ce::CouplingEvent, path) = _walk_event(g, ce, path)
function _walk_coupling(g::G, ce::CouplingCouple, path) where {G}
    eqs = get(ce.connector, "equations", nothing)
    eqs isa AbstractVector || return ce
    out = nothing
    for (j, item) in enumerate(eqs)
        item isa AbstractDict || continue
        e = get(item, "expression", nothing)
        e isa ASTExpr || continue
        ne = g(e, _ptr(path, "/connector/equations/", j - 1, "/expression"), :connector_expression)
        ne === e && continue
        out === nothing && (out = Any[x for x in eqs])
        nitem = Dict{String, Any}(String(k) => v for (k, v) in item)
        nitem["expression"] = ne
        out[j] = nitem
    end
    out === nothing && return ce
    connector = Dict{String, Any}(ce.connector)
    connector["equations"] = out
    return _reconstruct_fields(ce; connector = connector)
end

function _walk_sites!(g::G, file::EsmFile, path, recurse::Bool) where {G}
    if file.models !== nothing
        for (name, m) in file.models
            _walk_sites!(g, m, _ptr(path, "/models/", name), recurse)
        end
    end
    if file.reaction_systems !== nothing
        for (name, rs) in file.reaction_systems
            _walk_sites!(g, rs, _ptr(path, "/reaction_systems/", name), recurse)
        end
    end
    for (i, ce) in enumerate(file.coupling)
        nce = _walk_coupling(g, ce, _ptr(path, "/coupling/", i - 1))
        nce === ce || (file.coupling[i] = nce)
    end
    return file
end

# The map forms over the pieces a flattened system holds, which are not
# wrapped in a `Model`: one variable's sites, a variable table (a new table only
# when some variable changed), and an event vector (always a new vector).
_map_variable_sites(f::F, v::ModelVariable) where {F} =
    _walk_variable((e, _, _) -> f(e)::ASTExpr, v, nothing)

function _map_variable_sites(f::F, vars::OrderedDict{String, ModelVariable}) where {F}
    out = nothing
    for (name, v) in vars
        nv = _map_variable_sites(f, v)
        nv === v && continue
        out === nothing && (out = OrderedDict{String, ModelVariable}(vars))
        out[name] = nv
    end
    return out === nothing ? vars : out
end

_map_event_exprs(f::F, events::Vector{<:EventType}) where {F} =
    _walk_events!((e, _, _) -> f(e)::ASTExpr, copy(events), nothing)

# `ev` with each affect target (`lhs`, a variable name) passed through
# `rename(name)::String`; the name-valued twin of the expression sites.
function _rename_affect_targets(rename::F, ev::EventType) where {F}
    ren(as) = as === nothing ? nothing :
        AffectEquation[AffectEquation(rename(a.lhs)::String, a.rhs) for a in as]
    hasproperty(ev, :affect_neg) || return _reconstruct_fields(ev; affects = ren(ev.affects))
    return _reconstruct_fields(ev; affects = ren(ev.affects), affect_neg = ren(ev.affect_neg))
end

const _SiteHolder = Union{Model, ReactionSystem, EsmFile}

"""
    map_expressions!(f, m::Model; subsystems = true) -> m
    map_expressions!(f, rs::ReactionSystem; subsystems = true) -> rs
    map_expressions!(f, file::EsmFile; subsystems = true) -> file

Replace every expression of the document part by `f(expr)::ASTExpr`, at every
site [`EXPRESSION_SITE_KINDS`](@ref) lists, recursing into `Model` and
`ReactionSystem` subsystems (an unresolved `SubsystemRef` is skipped) unless
`subsystems = false`. For an
`EsmFile` that is every model, every reaction system and the coupling entries.

`f` sees each site's root expression; descending into it is `f`'s job
(`map_children`). A struct is rebuilt only when `f` returned a different
object for one of its expressions, so an `f` that returns its argument changes
nothing. The containers the `Model`, `ReactionSystem` or `EsmFile` holds
directly are updated in place: use [`map_expressions`](@ref) to leave the
argument untouched.

Sites are visited in this order: equations, initialization equations, guesses
(by sorted name), variables in declaration order (update rules, then `lb`,
`ub`), continuous events, discrete events, inline tests, then subsystems; a
reaction system's reactions, parameters, constraint equations, events, tests,
subsystems; a file's models, reaction systems, then coupling entries. An
equation's left-hand side is visited immediately before its right-hand side.
"""
map_expressions!(f::F, x::_SiteHolder; subsystems::Bool = true) where {F} =
    _walk_sites!((e, _, _) -> f(e)::ASTExpr, x, nothing, subsystems)

"""
    map_expressions(f, x::Union{Model, ReactionSystem, EsmFile}; subsystems = true)

[`map_expressions!`](@ref) on a copy of the containers `x` holds (and those
of every subsystem), so `x` is left as it was. Expressions and records `f`
leaves unchanged are shared with `x`.
"""
map_expressions(f::F, x::_SiteHolder; subsystems::Bool = true) where {F} =
    map_expressions!(f, _site_container_copy(x); subsystems = subsystems)

"""
    foreach_expression(f, x::Union{Model, ReactionSystem, EsmFile}, path = ""; subsystems = true)
    foreach_expression(f, entry::CouplingEntry, path)

Call `f(expr, pointer::String, kind::Symbol)` on the root expression of every
site of `x`, in the order [`map_expressions!`](@ref) documents. `pointer` is
the site's JSON pointer as written in the document, under `path` (so pass
`"/models/M"` for a model named `M`; a file's pointers start at its root), and
`kind` is one of [`EXPRESSION_SITE_KINDS`](@ref). With `subsystems = false`
only `x`'s own sites are visited (a caller that needs per-component context
recurses itself). The `CouplingEntry` form visits one coupling entry's sites,
with `path` its pointer (`"/coupling/<i>"`). The return value of `f` is
ignored and nothing is changed.
"""
function foreach_expression(
        f::F, x::_SiteHolder, path::AbstractString = ""; subsystems::Bool = true
    ) where {F}
    _walk_sites!(x, String(path), subsystems) do e, p, k
        f(e, p, k)
        e
    end
    return nothing
end

function foreach_expression(f::F, ce::CouplingEntry, path::AbstractString) where {F}
    _walk_coupling(ce, String(path)) do e, p, k
        f(e, p, k)
        e
    end
    return nothing
end

# A copy of the containers a walk updates in place, recursively through
# subsystems; everything else is shared.
function _site_container_copy(m::Model)
    subs = OrderedDict{String, SubsystemNode}(
        k => (s isa Model ? _site_container_copy(s) : s) for (k, s) in m.subsystems
    )
    return _reconstruct_fields(
        m; variables = copy(m.variables), equations = copy(m.equations),
        discrete_events = copy(m.discrete_events),
        continuous_events = copy(m.continuous_events), subsystems = subs,
        tests = copy(m.tests),
        initialization_equations = copy(m.initialization_equations),
        guesses = copy(m.guesses)
    )
end

function _site_container_copy(rs::ReactionSystem)
    subs = OrderedDict{String, ReactionSystem}(
        k => _site_container_copy(s) for (k, s) in rs.subsystems
    )
    return _reconstruct_fields(
        rs; reactions = copy(rs.reactions), parameters = copy(rs.parameters),
        constraint_equations = copy(rs.constraint_equations),
        discrete_events = copy(rs.discrete_events),
        continuous_events = copy(rs.continuous_events), subsystems = subs,
        tests = copy(rs.tests)
    )
end

function _site_container_copy(file::EsmFile)
    models = file.models === nothing ? nothing :
        OrderedDict{String, Model}(k => _site_container_copy(m) for (k, m) in file.models)
    rss = file.reaction_systems === nothing ? nothing :
        OrderedDict{String, ReactionSystem}(
            k => _site_container_copy(r) for (k, r) in file.reaction_systems
        )
    return reconstruct(
        file; models = models, reaction_systems = rss, coupling = copy(file.coupling)
    )
end
