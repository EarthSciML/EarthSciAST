# Strip and expose (API_SPEC §5.8, "Strip and expose"; RFC U6, issue #543).
#
# `esm_problem(…; strip)` removes the named construct classes from the document
# and builds the rest unchanged; the removed constructs are read off the
# flattened ORIGINAL document and kept as a `StrippedConstructs`.
# `compile_kernels` compiles outputs as programs of the public right-hand side
# (`rhs_program.jl`): each output is a synthetic held state whose `D` equation
# is the output's expression, the program writes only those, and `u`, `z` and
# the kernel's `dt` parameters are its read-only `aux` inputs.

const STRIP_CLASSES = (
    "algebraic", "continuous_events", "discrete_events", "initialization", "parameter_updates",
)

# One stripped event: the namespaced typed event (`_event_body` writes its JSON)
# and the expressions a kernel reads off it.
struct _StrippedEvent
    id::String
    origin::TermOrigin
    kind::String
    event::Union{ContinuousEvent, DiscreteEvent, CouplingEvent}
    conditions::Vector{ASTExpr}
    trigger::Union{ASTExpr, Nothing}
    affects::Vector{AffectEquation}
    affect_neg::Union{Vector{AffectEquation}, Nothing}
end

struct _StrippedUpdate
    parameter::String
    origin::TermOrigin
    rules::Vector{Any}
    values::Vector{ASTExpr}
end

struct _StrippedResidual
    id::String
    origin::TermOrigin
    shape::Vector{Int}
    expr::ASTExpr
    sets::Vector{String}
end

# The removed implicit part of the initialization system (esm-spec §11.4.3,
# API_SPEC §5.8 strip class `initialization`, PR #820's draft): residuals with
# their `ic` terms kept, the unknowns as element names in state-layout order,
# and each one's starting point. Filled after the build (`_stripped_problem`).
mutable struct _StrippedInit
    residuals::Vector{_StrippedResidual}
    unknowns::Vector{String}
    x0::Vector{Float64}
end
_StrippedInit() = _StrippedInit(_StrippedResidual[], String[], Float64[])

struct _ZBlock
    name::String
    offset::Int          # 1-based
    shape::Vector{Int}
    sets::Vector{String}
end

"""
    StrippedConstructs

What `esm_problem(…; strip)` removed (API_SPEC §5.8, "The stripped object"):
the events, the stripped parameter updates, the residuals of the implicit
equations, and the `z` layout with its starting values. Read it with
[`stripped`](@ref); [`canonical_json`](@ref) gives its canonical JSON.
"""
struct StrippedConstructs
    strip::Vector{String}
    events::Vector{_StrippedEvent}
    parameter_updates::Vector{_StrippedUpdate}
    z_layout::Vector{_ZBlock}
    z0::Vector{Union{Float64, Nothing}}
    residuals::Vector{_StrippedResidual}
    initialization::_StrippedInit
end

_empty_stripped(classes = String[]) = StrippedConstructs(
    classes, _StrippedEvent[], _StrippedUpdate[], _ZBlock[], Union{Float64, Nothing}[],
    _StrippedResidual[], _StrippedInit()
)

Base.isempty(s::StrippedConstructs) =
    isempty(s.events) && isempty(s.parameter_updates) && isempty(s.residuals) &&
    isempty(s.initialization.residuals)

function _removed_classes(s::StrippedConstructs)
    out = String[]
    any(e -> e.kind == "continuous", s.events) && push!(out, "continuous_events")
    any(e -> e.kind == "discrete", s.events) && push!(out, "discrete_events")
    isempty(s.parameter_updates) || push!(out, "parameter_updates")
    isempty(s.residuals) || push!(out, "algebraic")
    isempty(s.initialization.residuals) || push!(out, "initialization")
    return sort!(out)
end

"""
    stripped(prob::EsmProblem) -> StrippedConstructs

What `strip` removed from `prob` (API_SPEC §5.8), flattened and namespaced.
Empty when nothing was.
"""
stripped(prob::EsmProblem) =
    prob.stripped === nothing ? _empty_stripped() : prob.stripped::StrippedConstructs

"""
    is_stripped(prob::EsmProblem) -> Bool

Whether `strip` removed anything from `prob`; `solve` and `init` refuse it then
(`stripped_problem_not_solvable`).
"""
is_stripped(prob::EsmProblem) = !isempty(stripped(prob))

function _refuse_stripped(prob::EsmProblem, call::AbstractString)
    is_stripped(prob) || return nothing
    throw(
        SimulateError(
            "`$call` cannot run a Problem `strip` removed constructs from " *
                "($(join(_removed_classes(stripped(prob)), ", "))): running it without " *
                "them would report a number the document does not describe. Evaluate its " *
                "right-hand side and the removed constructs with `compile_kernels`",
            ERROR_CODES.STRIPPED_PROBLEM_NOT_SOLVABLE
        )
    )
end

function _strip_classes(strip)::Vector{String}
    out = String[]
    for c in strip
        s = String(c)
        s in STRIP_CLASSES || throw(
            ArgumentError(
                "`strip` names '$s', which is not a strippable class; the classes are " *
                    "algebraic, continuous_events, discrete_events, initialization and " *
                    "parameter_updates " *
                    "(Wiener noise is never strippable)"
            )
        )
        s in out || push!(out, s)
    end
    return sort!(out)
end

# ============================================================================
# Canonical JSON
# ============================================================================

_origin_json(o::TermOrigin) = o.component !== nothing ?
    Dict{String, Any}("component" => o.component) :
    Dict{String, Any}("coupling" => o.coupling)

function _stripped_json(s::StrippedConstructs)
    events = Any[]
    for e in s.events
        d = _event_body(e.event)
        d["id"] = e.id
        d["origin"] = _origin_json(e.origin)
        d["kind"] = e.kind
        push!(events, d)
    end
    updates = Any[
        Dict{String, Any}(
            "parameter" => u.parameter, "origin" => _origin_json(u.origin),
            "rules" => u.rules
        ) for u in s.parameter_updates
    ]
    zl = Dict{String, Any}()
    for b in s.z_layout
        zl[b.name] = Dict{String, Any}("base" => b.offset, "shape" => b.shape)
    end
    residuals = Any[
        Dict{String, Any}(
            "id" => r.id, "origin" => _origin_json(r.origin), "shape" => r.shape,
            "expr" => serialize_expression(r.expr)
        ) for r in s.residuals
    ]
    return Dict{String, Any}(
        "strip" => s.strip,
        "events" => events,
        "parameter_updates" => updates,
        "algebraic" => Dict{String, Any}(
            "unknowns" => String[b.name for b in s.z_layout],
            "z_layout" => zl,
            "z0" => Any[x === nothing || !isfinite(x) ? nothing : x for x in s.z0],
            "residuals" => residuals,
        ),
        "initialization" => _stripped_init_json(s.initialization),
    )
end

# The `initialization` member (API_SPEC §5.8, PR #820's draft shape).
_stripped_init_json(si::_StrippedInit) = Dict{String, Any}(
    "residuals" => Any[
        Dict{String, Any}(
            "id" => r.id, "origin" => _origin_json(r.origin), "shape" => r.shape,
            "expr" => serialize_expression(r.expr)
        ) for r in si.residuals
    ],
    "unknowns" => si.unknowns,
    "x0" => Any[x for x in si.x0],
)

# The member from what the build took (`_StrippedInitialization`): one residual
# `lhs - rhs` per removed equation, `id` `<component>.initialization[j]`, the
# component being the one its first starting value belongs to.
function _stripped_init_from_build(took, flat::FlattenedSystem)
    si = _StrippedInit()
    took === nothing && return si
    counters = Dict{String, Int}()
    for eq in took.equations
        names = String[first(r) for r in _ic_reads(eq.lhs)]
        isempty(names) && (names = String[first(r) for r in _ic_reads(eq.rhs)])
        first_name = isempty(names) ? "" : first(names)
        k = findlast('.', first_name)
        prefix = k === nothing ? "" : first_name[1:prevind(first_name, k)]
        j = counters[prefix] = get(counters, prefix, 0) + 1
        expr = OpExpr("-", ASTExpr[eq.lhs, eq.rhs])
        sets = try
            _expr_sets(expr, flat)
        catch err
            err isa ArgumentError || rethrow()
            String[]
        end
        push!(
            si.residuals, _StrippedResidual(
                "$prefix.initialization[$j]", TermOrigin(prefix, nothing),
                _set_sizes(sets, flat), expr, sets
            )
        )
    end
    append!(si.unknowns, took.unknowns)
    append!(si.x0, took.x0)
    return si
end

"""
    canonical_json(s::StrippedConstructs) -> String

The stripped object's canonical JSON (API_SPEC §5.8): compact, every object's
keys ascending, numbers in the CONFORMANCE_SPEC §5.5.3.1 form. Byte-identical
across Julia, Rust and Python.
"""
canonical_json(s::StrippedConstructs) = (io = IOBuffer(); _write_canonical(io, _stripped_json(s)); String(take!(io)))

# Numbers, booleans and strings print as the package's canonical value
# emitter prints them (`_emit_canonical_value`), so an integral float has one
# cut-off for printing as an integer token everywhere.
function _write_canonical(io::IO, v)
    if v === nothing
        print(io, "null")
    elseif v isa Union{Bool, Integer, AbstractFloat, AbstractString}
        print(io, _emit_canonical_value(v))
    elseif v isa Real
        print(io, _emit_canonical_value(Float64(v)))
    elseif v isa Symbol
        print(io, _json_string(String(v)))
    elseif v isa AbstractDict
        ks = sort!(String[String(k) for k in keys(v)])
        print(io, '{')
        for (i, k) in enumerate(ks)
            i > 1 && print(io, ',')
            print(io, _json_string(k), ':')
            _write_canonical(io, haskey(v, k) ? v[k] : v[Symbol(k)])
        end
        print(io, '}')
    elseif v isa AbstractVector || v isa Tuple
        print(io, '[')
        for (i, x) in enumerate(v)
            i > 1 && print(io, ',')
            _write_canonical(io, x)
        end
        print(io, ']')
    else
        throw(ArgumentError("canonical_json: cannot write a $(typeof(v))"))
    end
    return nothing
end

# ============================================================================
# Which constructs a class takes
# ============================================================================

function _strippable_implicit(lhs::ASTExpr)
    first(_lhs_role(lhs)) === :implicit || return false
    head = _lhs_unwrap(lhs)
    return !(head isa OpExpr && _is_calculus_op(head.op))
end

function _strips_update(rules, classes::Vector{String})
    "parameter_updates" in classes || return false
    isempty(rules) && return false
    for r in rules
        r.kind in ("schedule", "condition", "crossing") || return false
        (r.expression !== nothing && r.from === nothing && r.handler === nothing) ||
            return false
        r.kind == "crossing" && !("continuous_events" in classes) && return false
    end
    return true
end

_strips_kind(kind::String, classes) = (kind == "continuous" ? "continuous_events" : "discrete_events") in classes

# ============================================================================
# Collecting from the document
# ============================================================================

function _affect_json(a::AffectEquation)
    return Dict{String, Any}("lhs" => a.lhs, "rhs" => serialize_expression(a.rhs))
end

# An event's members as the stripped object writes them: the defaults
# (`root_find: left`, `reinitialize: false`, `initial_offset: 0`) are omitted.
function _event_body(ev)
    d = Dict{String, Any}()
    ev.name === nothing || (d["name"] = ev.name)
    if ev isa ContinuousEvent || (ev isa CouplingEvent && ev.conditions !== nothing)
        d["conditions"] = Any[serialize_expression(c) for c in ev.conditions]
    end
    if ev isa DiscreteEvent || (ev isa CouplingEvent && ev.trigger !== nothing)
        trig = serialize_trigger(ev.trigger)
        get(trig, "initial_offset", nothing) == 0 && delete!(trig, "initial_offset")
        d["trigger"] = trig
    end
    d["affects"] = Any[_affect_json(a) for a in ev.affects]
    if !(ev isa DiscreteEvent) && ev.affect_neg !== nothing
        d["affect_neg"] = Any[_affect_json(a) for a in ev.affect_neg]
    end
    if !(ev isa DiscreteEvent) && ev.root_find == "right"
        d["root_find"] = "right"
    end
    ev.reinitialize === true && (d["reinitialize"] = true)
    ev.description === nothing || (d["description"] = ev.description)
    return d
end

# A component's own events, namespaced as flatten namespaces them, appended to
# `out` as `(prefix, kind, event)`, continuous before discrete.
function _component_events!(out, comp, prefix::String, local_names)
    ns(e) = namespace_expr(e, prefix, local_names)
    cv, dv = ContinuousEvent[], DiscreteEvent[]
    _collect_events!(cv, dv, comp.continuous_events, comp.discrete_events, prefix, ns)
    foreach(e -> push!(out, (prefix, "continuous", e)), cv)
    foreach(e -> push!(out, (prefix, "discrete", e)), dv)
    return out
end

# The event lists of a component with the stripped event classes emptied.
function _kept_events(comp, classes)
    return (
        continuous_events = "continuous_events" in classes ?
            ContinuousEvent[] : comp.continuous_events,
        discrete_events = "discrete_events" in classes ?
            DiscreteEvent[] : comp.discrete_events,
    )
end

_event_id(prefix, name, kind, j) = name === nothing ? "$prefix.$(kind)_event[$j]" : "$prefix.$name"

function _stripped_event(prefix, origin, kind, j, ev)
    trig = (hasproperty(ev, :trigger) && ev.trigger isa ConditionTrigger) ? ev.trigger.expression : nothing
    conds = (hasproperty(ev, :conditions) && ev.conditions !== nothing) ? ASTExpr[c for c in ev.conditions] : ASTExpr[]
    neg = hasproperty(ev, :affect_neg) ? ev.affect_neg : nothing
    return _StrippedEvent(
        _event_id(prefix, ev.name, kind, j), origin, kind, ev,
        conds, trig, AffectEquation[a for a in ev.affects], neg
    )
end

# One visit of a model and its subsystems: its events are collected into
# `events` (`_component_events!`), the parameters whose update `classes` strips
# into `updates` (flattened names), and the model is returned with both
# removed, and with its implicit algebraic equations removed when `classes`
# takes `algebraic`. An unresolved subsystem reference is kept as it is.
function _strip_model(model::Model, prefix::String, classes, events, updates)
    local_names = Set{String}(keys(model.variables))
    union!(local_names, keys(model.subsystems))
    _component_events!(events, model, prefix, local_names)
    variables = OrderedDict{String, ModelVariable}()
    for (n, v) in model.variables
        if v.type == ParameterVariable && v.update !== nothing && _strips_update(v.update, classes)
            push!(updates, "$prefix.$n")
            v = reconstruct(v; update = nothing)
        end
        variables[n] = v
    end
    subsystems = OrderedDict{String, SubsystemNode}(
        k => (sub isa Model ? _strip_model(sub, "$prefix.$k", classes, events, updates) : sub)
            for (k, sub) in model.subsystems
    )
    equations = "algebraic" in classes ?
        filter(eq -> !_strippable_implicit(eq.lhs), model.equations) : model.equations
    return reconstruct(
        model; variables, equations, subsystems, _kept_events(model, classes)...
    )
end

# A reaction system and its subsystems, as `_strip_model` visits a model. A
# parameter update is stripped from a top-level reaction system's own
# parameters only.
function _strip_reaction_system(
        rs::ReactionSystem, prefix::String, classes, events, updates; top::Bool = true
    )
    local_names = Set{String}()
    foreach(sp -> push!(local_names, sp.name), rs.species)
    foreach(p -> push!(local_names, p.name), rs.parameters)
    union!(local_names, keys(rs.subsystems))
    _component_events!(events, rs, prefix, local_names)
    parameters = Parameter[]
    for p in rs.parameters
        if top && p.update !== nothing && _strips_update(p.update, classes)
            push!(updates, "$prefix.$(p.name)")
            p = reconstruct(p; update = nothing)
        end
        push!(parameters, p)
    end
    subsystems = OrderedDict{String, ReactionSystem}(
        k => _strip_reaction_system(sub, "$prefix.$k", classes, events, updates; top = false)
            for (k, sub) in rs.subsystems
    )
    return reconstruct(rs; parameters, subsystems, _kept_events(rs, classes)...)
end

"""
    _strip_document(file::EsmFile, classes) -> (stripped::EsmFile, constructs::StrippedConstructs)

`file` with `classes`' constructs removed, and what was removed, read off the
flattened original (API_SPEC §5.8). One walk of the component tree decides both
what is reported and what is removed. Coupling-level events stay in the
document: no build lowers one, and keeping them keeps the coupling indices of
the stripped document's provenance the original's.
"""
function _strip_document(file::EsmFile, classes::Vector{String})
    flat = flatten(file)
    s = _empty_stripped(classes)
    found = Any[]
    names = String[]
    models = file.models === nothing ? nothing : OrderedDict{String, Model}(
            name => _strip_model(m, name, classes, found, names) for (name, m) in file.models
        )
    rsystems = file.reaction_systems === nothing ? nothing :
        OrderedDict{String, ReactionSystem}(
            name => _strip_reaction_system(rs, name, classes, found, names)
            for (name, rs) in file.reaction_systems
        )
    # ---- events ----
    counters = Dict{Tuple{String, String}, Int}()
    for (prefix, kind, ev) in found
        _strips_kind(kind, classes) || continue
        j = counters[(prefix, kind)] = get(counters, (prefix, kind), 0) + 1
        push!(s.events, _stripped_event(prefix, TermOrigin(prefix, nothing), kind, j, ev))
    end
    for (k, entry) in enumerate(expand_coupling_imports(file))
        entry isa CouplingEvent || continue
        kind = entry.event_type == "continuous" ? "continuous" : "discrete"
        _strips_kind(kind, classes) || continue
        prefix = "coupling[$(k - 1)]"
        j = counters[(prefix, kind)] = get(counters, (prefix, kind), 0) + 1
        push!(s.events, _stripped_event(prefix, TermOrigin(nothing, k - 1), kind, j, entry))
    end
    # ---- parameter updates ----
    nameset = Set(names)
    for (name, v) in flat.parameters
        name in nameset || continue
        v.update === nothing && continue
        origin = something(findlast('.', name), 0)
        push!(
            s.parameter_updates, _StrippedUpdate(
                name, TermOrigin(origin == 0 ? "" : name[1:(origin - 1)], nothing),
                Any[serialize_parameter_update(r) for r in v.update],
                ASTExpr[r.expression for r in v.update if r.expression !== nothing]
            )
        )
    end
    # ---- algebraic ----
    if "algebraic" in classes && any(eq -> _strippable_implicit(eq.lhs), flat.equations)
        _collect_algebraic!(s, flat)
    end
    return reconstruct(file; models = models, reaction_systems = rsystems), s
end

function _set_sizes(sets, flat::FlattenedSystem)
    return Int[
        (s2 = get(flat.index_sets, s, nothing); s2 === nothing || s2.size === nothing ? 0 : Int(s2.size))
            for s in sets
    ]
end

function _declared_sets(name::AbstractString, flat::FlattenedSystem)
    for d in (flat.state_variables, flat.observed_variables, flat.parameters)
        v = get(d, name, nothing)
        v === nothing || return v.shape === nothing ? String[] : String[String(x) for x in v.shape]
    end
    return nothing
end

# The index sets an expression's value ranges over (API_SPEC §5.8): a
# top-level faq's output ranges, a bare variable's declared shape, an
# elementwise operator's common operand shape, else scalar.
function _expr_sets(e::ASTExpr, flat::FlattenedSystem)::Vector{String}
    e isa VarExpr && return something(_declared_sets(e.name, flat), String[])
    e isa OpExpr || return String[]
    if _is_faq_op(e.op)
        out = String[]
        for i in something(e.output_idx, String[])
            r = e.ranges === nothing ? nothing : get(e.ranges, String(i), nothing)
            set = (r isa AbstractDict && haskey(r, "from")) ? String(r["from"]) :
                (hasproperty(r, :from) ? String(getproperty(r, :from)) : nothing)
            set === nothing && throw(ArgumentError("the output range `$i` does not name an index set"))
            push!(out, set)
        end
        return out
    end
    e.op == "index" && return String[]
    out = String[]
    for a in e.args
        s = _expr_sets(a, flat)
        isempty(s) && continue
        if isempty(out)
            out = s
        elseif out != s
            throw(
                ArgumentError(
                    "operands of `$(e.op)` range over different index sets " *
                        "($(join(out, ", ")) and $(join(s, ", ")))"
                )
            )
        end
    end
    return out
end

function _collect_algebraic!(s::StrippedConstructs, flat::FlattenedSystem)
    counters = Dict{String, Int}()
    read = Set{String}()
    contribs = flat.equation_contributions
    for (k, eq) in enumerate(flat.equations)
        _strippable_implicit(eq.lhs) || continue
        origin = (k <= length(contribs) && !isempty(contribs[k]) && !isempty(contribs[k][1].origins)) ?
            contribs[k][1].origins[1] : TermOrigin("", nothing)
        prefix = origin.component !== nothing ? origin.component : "coupling[$(origin.coupling)]"
        j = counters[prefix] = get(counters, prefix, 0) + 1
        expr = OpExpr("-", ASTExpr[eq.lhs, eq.rhs])
        sets = try
            _expr_sets(expr, flat)
        catch err
            err isa ArgumentError || rethrow()
            throw(
                SimulateError(
                    "the residual of `$(eq)`: $(err.msg)",
                    ERROR_CODES.KERNEL_OUTPUT_UNRESOLVED
                )
            )
        end
        union!(read, free_variables(expr))
        push!(
            s.residuals,
            _StrippedResidual("$prefix.residual[$j]", origin, _set_sizes(sets, flat), expr, sets)
        )
    end
    z = String[n for n in keys(flat.algebraic_variables) if n in read]
    shaped(n) = (v = get(flat.state_variables, n, nothing); v !== nothing && v.shape !== nothing && !isempty(v.shape))
    sort!(z; by = n -> (shaped(n), n))
    off = 1
    for n in z
        v = flat.state_variables[n]
        sets = v.shape === nothing ? String[] : String[String(x) for x in v.shape]
        shape = _set_sizes(sets, flat)
        push!(s.z_layout, _ZBlock(n, off, shape, sets))
        off += max(prod(shape; init = 1), 1)
    end
    return s
end

# The `z` starting values: each unknown's `ic` evaluated at the start of the
# run, else its declared default, column-major; `nothing` where neither is.
# PR #820's draft order (API_SPEC §5.8): the element's explicit `ic` value, else
# the caller's `u0` entry (`u0`, by element name), else its `guesses` entry,
# else its declared default.
function _z_starting_values(
        flat::FlattenedSystem, z, params, t0;
        u0::AbstractDict = Dict{String, Float64}(), guesses::AbstractDict = Dict{String, Any}()
    )
    out = Union{Float64, Nothing}[]
    for b in z
        n = max(prod(b.shape; init = 1), 1)
        rhs = nothing
        for eq in flat.equations
            l = eq.lhs
            if l isa OpExpr && l.op == "ic" && length(l.args) == 1 && l.args[1] isa VarExpr &&
                    (l.args[1]::VarExpr).name == b.name
                rhs = eq.rhs
                break
            end
        end
        if rhs === nothing
            for (tgt, r) in flat.field_ics
                tgt == b.name && (rhs = r; break)
            end
        end
        vals = nothing
        if rhs !== nothing
            cells = isempty(b.shape) ? [Int[]] :
                [collect(Int, Tuple(c)) for c in vec(collect(CartesianIndices(Tuple(b.shape))))]
            vals = try
                evaluate_cellwise(rhs, cells; params = params, t = t0)
            catch err
                err isa EarthSciASTError || rethrow()
                nothing
            end
        end
        if vals === nothing && !isempty(u0)
            cells = isempty(b.shape) ? [Int[]] :
                [collect(Int, Tuple(c)) for c in vec(collect(CartesianIndices(Tuple(b.shape))))]
            keys_ = [isempty(c) ? b.name : _cell_key(b.name, c) for c in cells]
            if haskey(u0, b.name) || any(k -> haskey(u0, k), keys_)
                whole = get(u0, b.name, nothing)
                vals = Union{Float64, Nothing}[
                    haskey(u0, k) ? u0[k] : whole for k in keys_
                ]
                if any(isnothing, vals)
                    # The cells the caller left take the next source.
                    rest = _z_fallback(flat, b, guesses, params)
                    vals = Float64[
                        x === nothing ? (rest === nothing ? NaN : rest[min(i, length(rest))]) : x
                        for (i, x) in enumerate(vals)
                    ]
                end
            end
        end
        vals === nothing && (vals = _z_fallback(flat, b, guesses, params))
        if vals === nothing
            v = get(flat.state_variables, b.name, nothing)
            d = v === nothing ? nothing : v.default
            vals = d isa Real ? [Float64(d)] : d isa AbstractArray ? vec(Float64.(d)) : nothing
        end
        if vals === nothing
            append!(out, fill(nothing, n))
        elseif length(vals) == 1
            append!(out, fill(Float64(vals[1]), n))
        elseif length(vals) == n
            append!(out, Float64.(vals))
        else
            append!(out, fill(nothing, n))
        end
    end
    return out
end

# A `z` block's `guesses` entry evaluated with the parameters (a number for
# every cell), or `nothing`.
function _z_fallback(flat::FlattenedSystem, b, guesses::AbstractDict, params)
    g = get(guesses, b.name, nothing)
    g === nothing && return nothing
    g isa Real && return [Float64(g)]
    g isa ASTExpr || return nothing
    return try
        [Float64(evaluate_expr(g, params))]
    catch err
        err isa EarthSciASTError || rethrow()
        nothing
    end
end

# Refuse a coupling-level event `classes` does not strip: no compiler here
# lowers one, so building without it would be a silent drop (esm-spec §9.6.6).
# The coupling read is the one after `coupling_import` expansion, which is what
# `flatten` applies: an event edge a library brings in is an event too.
function _refuse_coupling_events(file::EsmFile, classes)
    for entry in expand_coupling_imports(file)
        entry isa CouplingEvent || continue
        kind = entry.event_type == "continuous" ? "continuous" : "discrete"
        _strips_kind(kind, classes) && continue
        throw(
            TreeWalkError(
                ERROR_CODES.UNSUPPORTED_CONSTRUCT,
                "$kind event $(entry.name === nothing ? "(unnamed)" : "'$(entry.name)'") " *
                    "(a coupling-level event) is not supported by the Julia tree-walk " *
                    "evaluator; refusing the build rather than running the model without it"
            )
        )
    end
    return nothing
end

# The `lifting` kinds esm-spec §10.5 reserves: no compiler here implements
# their reduction.
const _RESERVED_LIFTINGS = ("mean", "integral")

# Every `variable_map` in `coupling` whose `lifting` esm-spec §10.5 reserves, as
# `(from, to, lifting)` in coupling order. Flatten records them in
# `FlattenMetadata.reserved_liftings`.
function _reserved_liftings(coupling)
    out = NTuple{3, String}[]
    for entry in coupling
        entry isa CouplingVariableMap || continue
        entry.lifting in _RESERVED_LIFTINGS || continue
        push!(out, (String(entry.from), String(entry.to), String(entry.lifting)))
    end
    return out
end

# Refuse a `variable_map` whose `lifting` is `mean` or `integral`: esm-spec §10.5
# reserves both kinds and no compiler here implements the reduction, so building
# would read the raw array where the document asks for its mean or integral.
# Validation and flatten accept them; only a build of a runnable problem
# refuses. From a document the coupling read is the one after `coupling_import`
# expansion, as for `_refuse_coupling_events`; from a flattened system it is the
# edges flatten recorded, so a system flattened beforehand is refused too.
_refuse_reserved_liftings(file::EsmFile) =
    _refuse_reserved_liftings(_reserved_liftings(expand_coupling_imports(file)))
_refuse_reserved_liftings(flat::FlattenedSystem) =
    _refuse_reserved_liftings(flat.metadata.reserved_liftings)
function _refuse_reserved_liftings(edges::AbstractVector{NTuple{3, String}})
    isempty(edges) && return nothing
    from, to, kind = first(edges)
    throw(
        TreeWalkError(
            ERROR_CODES.UNSUPPORTED_CONSTRUCT,
            "variable_map $(from) -> $(to) declares lifting " *
                "\"$(kind)\", which esm-spec §10.5 reserves and which is not " *
                "supported yet; refusing the build rather than running the model " *
                "without it"
        )
    )
end

# ============================================================================
# Kernels
# ============================================================================

"""
    KernelBlock(label, offset, shape)

One output's block of a kernel's `out` (`offset` 1-based).
"""
struct KernelBlock
    label::String
    offset::Int
    shape::Vector{Int}
end

_kernel_blocks(blocks::Vector{StateBlock}) =
    KernelBlock[KernelBlock(b.name, b.offset, b.shape) for b in blocks]

"""
    Kernel

A compiled kernel (API_SPEC §5.8, "Strip and expose"). Evaluate it with
[`kernel!`](@ref) on a [`kernel_workspace`](@ref) per concurrent caller.
"""
struct Kernel
    name::String
    prog::RhsProgram
    direct::Bool
    map::Bool
    aux_plan::Vector{NTuple{4, Int}}   # (source: 1 u, 2 z, 3 dt, 0 zero; src; dst; len)
    p_map::Vector{Int}
    out_plan::Vector{NTuple{3, Int}}    # (du offset, out offset, len)
    layout::Vector{KernelBlock}
    n_u::Int
    n_z::Int
    n_p::Int
    out_len::Int
end

struct KernelWorkspace
    kernel::Kernel
    ws::RhsWorkspace
    u::Vector{Float64}
    aux::Vector{Float64}
    p::Vector{Float64}
    du::Vector{Float64}
end

"""
    KernelSet

The kernels of one [`compile_kernels`](@ref) call: `ks["name"]`, with one
`u` layout ([`state_layout`](@ref)), one `z` layout ([`z_layout`](@ref)), one
parameter vector ([`parameters`](@ref), [`parameter_vector`](@ref)) and one
forcing signature ([`forcing_slots`](@ref), [`default_forcing_set`](@ref)).
"""
struct KernelSet
    kernels::OrderedDict{String, Kernel}
    rhs::RhsProgram
end

Base.getindex(ks::KernelSet, name) = ks.kernels[String(name)]
Base.keys(ks::KernelSet) = keys(ks.kernels)
Base.length(k::Kernel) = k.out_len
state_layout(ks::KernelSet) = state_layout(ks.rhs)
"""
    z_layout(ks::KernelSet) -> Vector{StateBlock}

The `z` layout every kernel of `ks` reads (empty when nothing algebraic was
stripped).
"""
z_layout(ks::KernelSet) = _state_blocks(ks.rhs.layout.aux)
parameters(ks::KernelSet) = parameters(ks.rhs)
parameter_vector(ks::KernelSet, overrides::AbstractDict = Dict{String, Float64}()) =
    parameter_vector(ks.rhs, overrides)
forcing_slots(ks::KernelSet) = forcing_slots(ks.rhs)
default_forcing_set(ks::KernelSet) = default_forcing_set(ks.rhs)

"""
    kernel_layout(k::Kernel) -> Vector{KernelBlock}

One block per output, in spec order; a map kernel's is the `u` layout.
"""
kernel_layout(k::Kernel) = k.layout

"""
    kernel_workspace(k::Kernel) -> KernelWorkspace

The buffers of [`kernel!`](@ref) on `k`, one per concurrent caller.
"""
function kernel_workspace(k::Kernel)
    L = k.prog.layout
    return KernelWorkspace(
        k, rhs_workspace(k.prog), zeros(L.n_u), zeros(L.n_aux),
        zeros(length(k.p_map)), zeros(L.n_u)
    )
end

"""
    kernel!(out, k::Kernel, ws::KernelWorkspace, u, z, p, t, dt, fs::ForcingSet) -> out

Evaluate kernel `k` (API_SPEC §5.8, "The kernel ABI"): `u` and `z` in the
kernel set's layouts, `p` its parameter vector, `fs` a forcing set for its
slots; the kernel's `dt_params` read `dt`.
"""
function kernel!(
        out::AbstractVector, k::Kernel, ws::KernelWorkspace, u::AbstractVector,
        z::AbstractVector, p::AbstractVector, t, dt, fs::ForcingSet
    )
    ws.kernel === k || throw(ArgumentError("kernel!: the workspace was made by kernel_workspace of another kernel"))
    for (what, got, want) in (("u", length(u), k.n_u), ("z", length(z), k.n_z), ("p", length(p), k.n_p), ("out", length(out), k.out_len))
        got == want || throw(DimensionMismatch("kernel!: `$what` has $got elements; the kernel takes $want"))
    end
    aux = ws.aux
    dtf = Float64(dt)
    @inbounds for (src, s, d, n) in k.aux_plan
        if src == 1
            copyto!(aux, d, u, s, n)
        elseif src == 2
            copyto!(aux, d, z, s, n)
        elseif src == 3
            for i in 0:(n - 1)
                aux[d + i] = dtf
            end
        else
            for i in 0:(n - 1)
                aux[d + i] = 0.0
            end
        end
    end
    @inbounds for (i, j) in enumerate(k.p_map)
        ws.p[i] = p[j]
    end
    if k.direct
        rhs!(out, k.prog, ws.ws, u, aux, ws.p, Float64(t), fs)
        return out
    end
    rhs!(ws.du, k.prog, ws.ws, ws.u, aux, ws.p, Float64(t), fs)
    k.map && copyto!(out, u)
    @inbounds for (s, d, n) in k.out_plan
        copyto!(out, d, ws.du, s, n)
    end
    return out
end

_kernel_error(msg) = SimulateError(msg, ERROR_CODES.KERNEL_OUTPUT_UNRESOLVED)

_strip_pre(e::ASTExpr) = e
function _strip_pre(e::OpExpr)
    e.op == "Pre" && length(e.args) == 1 && return _strip_pre(e.args[1])
    return _map_opexpr(e, _strip_pre)
end

# `e` with every child expression mapped by `f`.
_map_opexpr(e::OpExpr, f) = map_children(f, e)

# Every name `e` reads outside a `Pre`, in every expression-bearing field (a
# `faq` filter, a `makearray` value, an integral bound included).
function _bare_reads!(out::Set{String}, e::ASTExpr)
    if e isa VarExpr
        push!(out, e.name)
    elseif e isa OpExpr
        e.op == "Pre" && return out
        foreach_child(c -> _bare_reads!(out, c), e)
    end
    return out
end

function _parse_kernel_spec(spec)
    d = spec isa AbstractString ? JSON3.read(spec, Dict{String, Any}) : spec
    d isa AbstractDict || throw(_kernel_error("a kernel spec is a JSON object"))
    name = get(d, "name", nothing)
    name isa AbstractString || throw(_kernel_error("a kernel spec needs a string `name`"))
    dtp = String[String(x) for x in get(d, "dt_params", Any[])]
    outs = Any[o for o in get(d, "outputs", Any[])]
    return String(name), dtp, outs
end

function _normalize_specs(specs)
    specs isa AbstractString && (specs = JSON3.read(specs, Vector{Any}))
    specs isa AbstractDict && (specs = Any[specs])
    return Any[s isa AbstractString ? JSON3.read(s, Dict{String, Any}) : _plain_dict(s) for s in specs]
end

_plain_dict(x::AbstractDict) = Dict{String, Any}(String(k) => _plain_dict(v) for (k, v) in x)
_plain_dict(x::AbstractVector) = Any[_plain_dict(v) for v in x]
_plain_dict(x) = x

"""
    compile_kernels(prob::EsmProblem, specs) -> KernelSet

Compile kernel specs (API_SPEC §5.8, "Kernel specs") against `prob`'s build:
each spec a `Dict` or a JSON string, `specs` a vector of them or one JSON array
string. The reserved name `rhs`, with no outputs, is the stripped right-hand
side. Refuses with `kernel_output_unresolved` and `affect_reads_post_value`.
"""
function compile_kernels(prob::EsmProblem, specs)
    c = compiler(prob)
    c in (:native, :interpreter) || throw(
        SimulateError(
            "compile_kernels serves the :native and :interpreter compilers; this Problem was " *
                "built with :$c",
            ERROR_CODES.COMPILER_UNAVAILABLE
        )
    )
    seed = prob.build.seed
    seed === nothing && throw(SimulateError("compile_kernels: this Problem carries no program seed", ERROR_CODES.COMPILER_UNAVAILABLE))
    flat = seed.prep.flat
    s = stripped(prob)
    znames = String[b.name for b in s.z_layout]
    all_states = Set{String}(keys(flat.state_variables))
    unames = Set{String}(n for n in all_states if !(n in znames))
    rhsprog = _whole_program(seed, flat, unames, all_states)
    ulay = state_layout(rhsprog)
    zlay = _state_blocks(rhsprog.layout.aux)
    kernels = OrderedDict{String, Kernel}()
    for spec in _normalize_specs(specs)
        name, dtp, outs = _parse_kernel_spec(spec)
        haskey(kernels, name) && throw(_kernel_error("two kernel specs are named '$name'"))
        if name == "rhs"
            (isempty(outs) && isempty(dtp)) || throw(
                _kernel_error("kernel 'rhs' is the reserved stripped right-hand side and takes no outputs or dt_params")
            )
            kernels[name] = _rhs_kernel(rhsprog, ulay, zlay)
        else
            kernels[name] = _value_or_map_kernel(name, dtp, outs, seed, flat, rhsprog, s, ulay, zlay)
        end
    end
    return KernelSet(kernels, rhsprog)
end

_block_len(b::StateBlock) = max(prod(b.shape; init = 1), 1)

function _rhs_kernel(rhs::RhsProgram, ulay, zlay)
    n_u = rhs.layout.n_u
    n_z = rhs.layout.n_aux
    aux_plan = NTuple{4, Int}[(2, b.offset, b.offset, _block_len(b)) for b in zlay]
    np = length(parameters(rhs))
    return Kernel(
        "rhs", rhs, true, false, aux_plan, collect(1:np), NTuple{3, Int}[],
        _kernel_blocks(ulay), n_u, n_z, np, n_u
    )
end

# One output of a value or map kernel: the synthetic held state it becomes, the
# index sets it ranges over, its expression, its label in the kernel's layout,
# and the `u` state a map output assigns (`nothing` for a value output).
struct _KernelOutput
    name::String
    sets::Vector{String}
    expr::ASTExpr
    label::String
    target::Union{Nothing, String}
end

# What resolving a kernel's outputs reads: the kernel's name, the flattened
# system, what `strip` removed, and the names of `u`'s unknowns.
struct _KernelCx
    kname::String
    flat::FlattenedSystem
    stripped::StrippedConstructs
    unames::Set{String}
end

const _KERNEL_OUTPUT_KINDS = ("observed", "expr", "residual", "condition", "update", "affect", "assign")

_kunresolved(cx::_KernelCx, what) = _kernel_error("kernel '$(cx.kname)': $what does not resolve")

function _koutput_kind(cx::_KernelCx, o)
    o isa AbstractDict || throw(_kernel_error("kernel '$(cx.kname)': an output is not an object"))
    k = findfirst(x -> haskey(o, x), _KERNEL_OUTPUT_KINDS)
    k === nothing && throw(_kernel_error("kernel '$(cx.kname)': an output names no output kind"))
    return _KERNEL_OUTPUT_KINDS[k]
end

# Every name `e` reads resolves: time, a declared variable, or an index set.
function _kresolve_names(cx::_KernelCx, e, what)
    for n in free_variables(e)
        (n == _indep_var(cx.flat) || _declared_sets(n, cx.flat) !== nothing || haskey(cx.flat.index_sets, n)) &&
            continue
        throw(_kunresolved(cx, "$what reads '$n', which"))
    end
    return nothing
end

function _ksets_of(cx::_KernelCx, e, what)
    try
        return _expr_sets(e, cx.flat)
    catch err
        err isa ArgumentError || rethrow()
        throw(_kernel_error("kernel '$(cx.kname)': the shape of $what cannot be decided: $(err.msg)"))
    end
end

# A spec's `index` is a 1-based integer; anything else is the spec's error, not
# a bounds error out of the lookup it feeds.
function _kspec_index(cx::_KernelCx, o, k, default)
    i = get(o, "index", default)
    (i isa Integer && !(i isa Bool) && i >= 1) ||
        throw(_kernel_error("kernel '$(cx.kname)': output $k `index` is a 1-based integer"))
    return Int(i)
end

function _kevent(cx::_KernelCx, id)
    i = findfirst(e -> e.id == id, cx.stripped.events)
    i === nothing && throw(_kunresolved(cx, "event '$id'"))
    return cx.stripped.events[i]
end

# The outputs output `o` (the `k`th of its spec) contributes, appended to
# `outs`, one method per output kind.
_kernel_output!(outs, cx, o, k) =
    _kernel_output!(Val(Symbol(_koutput_kind(cx, o))), outs, cx, o, k, get(o, "label", nothing))

function _kadd!(outs, sets, e, label, target)
    push!(outs, _KernelOutput("__kernel_out_$(length(outs) + 1)", sets, e, String(label), target))
    return outs
end

function _kernel_output!(::Val{:observed}, outs, cx, o, k, label)
    n = String(o["observed"])
    sets = _declared_sets(n, cx.flat)
    sets === nothing && throw(_kunresolved(cx, "observed '$n'"))
    return _kadd!(outs, sets, VarExpr(n), something(label, n), nothing)
end

function _kernel_output!(::Val{:expr}, outs, cx, o, k, label)
    e = _strip_pre(expression_from_json(o["expr"]))
    _kresolve_names(cx, e, "output $k")
    return _kadd!(outs, _ksets_of(cx, e, "output $k"), e, something(label, "out[$k]"), nothing)
end

function _kernel_output!(::Val{:residual}, outs, cx, o, k, label)
    id = String(o["residual"])
    i = findfirst(r -> r.id == id, cx.stripped.residuals)
    i === nothing && throw(_kunresolved(cx, "residual '$id'"))
    r = cx.stripped.residuals[i]
    return _kadd!(outs, r.sets, r.expr, something(label, id), nothing)
end

function _kernel_output!(::Val{:condition}, outs, cx, o, k, label)
    id = String(o["condition"])
    idx = _kspec_index(cx, o, k, 1)
    ev = _kevent(cx, id)
    e = if ev.kind == "continuous"
        idx <= length(ev.conditions) || throw(_kunresolved(cx, "condition $idx of event '$id'"))
        ev.conditions[idx]
    else
        ev.trigger === nothing && throw(
            _kunresolved(cx, "the condition of event '$id' (its trigger is not a `condition`), which")
        )
        idx == 1 || throw(_kunresolved(cx, "condition $idx of event '$id'"))
        OpExpr("ifelse", ASTExpr[ev.trigger, NumExpr(1.0), NumExpr(0.0)])
    end
    e = _strip_pre(e)
    return _kadd!(
        outs, _ksets_of(cx, e, "the condition of '$id'"), e,
        something(label, "$id.condition[$idx]"), nothing
    )
end

function _kernel_output!(::Val{:update}, outs, cx, o, k, label)
    pname = String(o["update"])
    i = findfirst(u -> u.parameter == pname, cx.stripped.parameter_updates)
    i === nothing && throw(_kunresolved(cx, "parameter update '$pname'"))
    u = cx.stripped.parameter_updates[i]
    idx = haskey(o, "index") ? _kspec_index(cx, o, k, 1) :
        length(u.values) == 1 ? 1 :
        throw(
            _kernel_error(
                "kernel '$(cx.kname)': parameter '$pname' has $(length(u.values)) update " *
                "rules; name one with `index`"
            )
        )
    1 <= idx <= length(u.values) || throw(_kunresolved(cx, "update rule $idx of parameter '$pname'"))
    e = _strip_pre(u.values[idx])
    return _kadd!(outs, something(_declared_sets(pname, cx.flat), String[]), e, something(label, pname), nothing)
end

function _kernel_output!(::Val{:affect}, outs, cx, o, k, label)
    id = String(o["affect"])
    ev = _kevent(cx, id)
    neg = get(o, "negative", false) === true
    affs = neg ? ev.affect_neg : ev.affects
    affs === nothing && throw(_kunresolved(cx, "the negative affects of event '$id'"))
    assigned = Set{String}(a.lhs for a in affs)
    for a in affs
        reads = _bare_reads!(Set{String}(), a.rhs)
        for v in sort!(collect(reads))
            v in assigned || continue
            throw(
                SimulateError(
                    "kernel '$(cx.kname)': event '$id' assigns '$v' and its affect on '$(a.lhs)' " *
                        "reads '$v' bare, which is its post-event value; read the pre-event " *
                        "value as Pre($v)",
                    ERROR_CODES.AFFECT_READS_POST_VALUE
                )
            )
        end
        a.lhs in cx.unames || throw(
            _kunresolved(cx, "the affect target '$(a.lhs)' of event '$id' (not an unknown of `u`)")
        )
        e = _strip_pre(a.rhs)
        _kresolve_names(cx, e, "the affect on '$(a.lhs)'")
        _kadd!(outs, something(_declared_sets(a.lhs, cx.flat), String[]), e, a.lhs, a.lhs)
    end
    return outs
end

function _kernel_output!(::Val{:assign}, outs, cx, o, k, label)
    tgt = String(o["assign"])
    tgt in cx.unames || throw(_kunresolved(cx, "the assign target '$tgt' (not an unknown of `u`)"))
    src = o["from"]
    e = _strip_pre(src isa AbstractString ? VarExpr(String(src)) : expression_from_json(src))
    _kresolve_names(cx, e, "the source of '$tgt'")
    sets = something(_declared_sets(tgt, cx.flat), String[])
    ss = _ksets_of(cx, e, "the source of '$tgt'")
    (isempty(ss) || ss == sets) || throw(
        _kernel_error(
            "kernel '$(cx.kname)': the source of '$tgt' ranges over [$(join(ss, ", "))], the " *
                "target over [$(join(sets, ", "))]"
        )
    )
    return _kadd!(outs, sets, e, tgt, tgt)
end

# The kernel's flattened system: the model's non-`D` equations, each `dt`
# parameter a held state, and each output a held state whose `D` equation is
# its expression.
function _kernel_flat(flat::FlattenedSystem, dtp, outs::Vector{_KernelOutput})
    eqs = Equation[]
    contribs = Vector{Contribution}[]
    for (eq, cs) in zip(flat.equations, flat.equation_contributions)
        _d_target(eq.lhs) === nothing || continue
        push!(eqs, eq)
        push!(contribs, cs)
    end
    states = OrderedDict{String, ModelVariable}(flat.state_variables)
    params = OrderedDict{String, ModelVariable}(flat.parameters)
    for p in dtp
        v = params[p]
        delete!(params, p)
        states[p] = ModelVariable(UnknownVariable; default = 0.0, units = v.units)
    end
    for out in outs
        sets = out.sets
        states[out.name] = ModelVariable(UnknownVariable; default = 0.0, shape = isempty(sets) ? nothing : sets)
        lhs = isempty(sets) ? OpExpr("D", ASTExpr[VarExpr(out.name)]; wrt = "t") : _faq_shell_D(out.name, sets)
        body = isempty(sets) ? out.expr : _faq_body(out.expr, sets, flat)
        push!(eqs, Equation(lhs, body))
        push!(contribs, Contribution[Contribution(body, TermOrigin[])])
    end
    return FlattenedSystem(
        flat;
        state_variables = states, parameters = params,
        discrete_parameters = OrderedDict{String, ModelVariable}(
            k => v for (k, v) in flat.discrete_parameters if !(k in dtp)
        ),
        equations = eqs, equation_contributions = contribs
    )
end

# The copy plans of a kernel program `prog`: where each `aux` block comes from
# (`u`, `z`, a `dt` argument, or nothing), the right-hand side's parameter of
# each of `prog`'s, and where each output lands (its own buffer, or the `u`
# state a map output assigns), with the value outputs' layout.
function _kernel_plans(kname, prog, rhs, outs::Vector{_KernelOutput}, ulay, zlay, dtp, flat)
    aux_plan = NTuple{4, Int}[]
    for b in prog.layout.aux
        n = max(prod(length(r) for r in b.storage; init = 1), 1)
        iu = findfirst(x -> x.name == b.name, ulay)
        iz = findfirst(x -> x.name == b.name, zlay)
        if iu !== nothing
            push!(aux_plan, (1, ulay[iu].offset, b.base, n))
        elseif iz !== nothing
            push!(aux_plan, (2, zlay[iz].offset, b.base, n))
        elseif b.name in dtp
            push!(aux_plan, (3, 0, b.base, n))
        else
            push!(aux_plan, (0, 0, b.base, n))
        end
    end
    set_params = String[x.name for x in parameters(rhs)]
    p_map = Int[]
    for x in parameters(prog)
        j = findfirst(==(x.name), set_params)
        j === nothing && throw(
            SimulateError("kernel '$kname' reads parameter '$(x.name)', which the right-hand side does not", ERROR_CODES.KERNEL_OUTPUT_UNRESOLVED)
        )
        push!(p_map, j)
    end
    out_plan = NTuple{3, Int}[]
    layout = KernelBlock[]
    off = 1
    for out in outs
        b = prog.layout.u[findfirst(x -> x.name == out.name, prog.layout.u)]
        len = max(prod(length(r) for r in b.storage; init = 1), 1)
        if out.target !== nothing
            ub = ulay[findfirst(x -> x.name == out.target, ulay)]
            push!(out_plan, (b.base, ub.offset, len))
        else
            push!(out_plan, (b.base, off, len))
            push!(layout, KernelBlock(out.label, off, _set_sizes(out.sets, flat)))
            off += len
        end
    end
    return aux_plan, p_map, out_plan, layout, off - 1, length(set_params)
end

function _value_or_map_kernel(kname, dtp, specs, seed, flat, rhs, s, ulay, zlay)
    cx = _KernelCx(String(kname), flat, s, Set{String}(b.name for b in ulay))
    nmap = count(o -> _koutput_kind(cx, o) in ("affect", "assign"), specs)
    (nmap > 0 && nmap != length(specs)) && throw(
        _kernel_error(
            "kernel '$kname' mixes map outputs (assign, affect) with value outputs; a map " *
                "kernel's output is a whole state"
        )
    )
    ismap = nmap > 0
    for p in dtp
        v = get(flat.parameters, p, nothing)
        (v !== nothing && (v.shape === nothing || isempty(v.shape))) || throw(
            _kernel_error("kernel '$kname': dt_params entry '$p' is not a scalar parameter")
        )
    end
    outs = _KernelOutput[]
    for (k, o) in enumerate(specs)
        _kernel_output!(outs, cx, o, k)
    end
    kflat = _kernel_flat(flat, dtp, outs)
    W = Set{String}(out.name for out in outs)
    prog = _whole_program(seed, kflat, W, Set{String}(keys(kflat.state_variables)))
    aux_plan, p_map, out_plan, layout, value_len, np = _kernel_plans(
        kname, prog, rhs, outs, ulay, zlay, dtp, flat
    )
    n_u = rhs.layout.n_u
    return Kernel(
        kname, prog, false, ismap, aux_plan, p_map, out_plan,
        ismap ? _kernel_blocks(ulay) : layout,
        n_u, rhs.layout.n_aux, np, ismap ? n_u : value_len
    )
end

# `faq{i…}(D(index(n, i…)))` over `sets`.
function _faq_shell_D(n, sets)
    idx = ["__k$d" for d in eachindex(sets)]
    body = OpExpr("D", ASTExpr[OpExpr("index", ASTExpr[VarExpr(n); ASTExpr[VarExpr(i) for i in idx]])]; wrt = "t")
    return _faq_over(body, idx, sets)
end

# The per-cell body of an array-valued output: a top-level faq's own body
# (its output symbols renamed to the shell's), else `index(e, i…)` of a bare
# array variable, else elementwise `e` with every array operand indexed.
function _faq_body(e::ASTExpr, sets, flat)
    idx = ["__k$d" for d in eachindex(sets)]
    return _faq_over(_cellwise(e, idx, flat), idx, sets)
end

function _cellwise(e::ASTExpr, idx, flat)
    if e isa VarExpr
        s = _declared_sets(e.name, flat)
        (s === nothing || isempty(s)) && return e
        return OpExpr("index", ASTExpr[e; ASTExpr[VarExpr(i) for i in idx]])
    end
    e isa OpExpr || return e
    if _is_faq_op(e.op) && e.output_idx !== nothing && !isempty(e.output_idx)
        ren = Dict{String, ASTExpr}(String(o) => VarExpr(idx[d]) for (d, o) in enumerate(e.output_idx))
        rest = filter(((k, _),) -> !(String(k) in keys(ren)), collect(e.ranges))
        body = substitute(e.expr_body, ren)
        if isempty(rest)
            return body
        end
        return reconstruct(
            e; output_idx = Any[],
            ranges = Dict{String, Any}(String(k) => v for (k, v) in rest), expr_body = body
        )
    end
    (e.op == "index" || _is_faq_op(e.op)) && return e
    return _map_opexpr(e, a -> _cellwise(a, idx, flat))
end

function _faq_over(body::ASTExpr, idx, sets)
    ranges = OrderedDict{String, Any}(i => Dict{String, Any}("from" => s) for (i, s) in zip(idx, sets))
    return expression_from_json(
        Dict{String, Any}(
            "op" => "faq", "args" => Any[], "output_idx" => collect(idx),
            "ranges" => ranges, "expr" => serialize_expression(body)
        )
    )
end
