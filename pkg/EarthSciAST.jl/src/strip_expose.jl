# Strip and expose (API_SPEC §5.8, "Strip and expose"; RFC U6, issue #543).
#
# `esm_problem(…; strip)` removes the named construct classes from the document
# and builds the rest unchanged; the removed constructs are read off the
# flattened ORIGINAL document and kept as a `StrippedConstructs`.
# `compile_kernels` compiles outputs as programs of the public right-hand side
# (`rhs_program.jl`): each output is a synthetic held state whose `D` equation
# is the output's expression, the program writes only those, and `u`, `z` and
# the kernel's `dt` parameters are its read-only `aux` inputs.

const STRIP_CLASSES = ("algebraic", "continuous_events", "discrete_events", "parameter_updates")

"""
    StrippedConstructs

What `esm_problem(…; strip)` removed (API_SPEC §5.8, "The stripped object"):
the events, the stripped parameter updates, the residuals of the implicit
equations, and the `z` layout with its starting values. Read it with
[`stripped`](@ref); [`canonical_json`](@ref) gives its canonical JSON.
"""
struct StrippedConstructs
    strip::Vector{String}
    events::Vector{Any}
    parameter_updates::Vector{Any}
    z_layout::Vector{Any}
    z0::Vector{Union{Float64, Nothing}}
    residuals::Vector{Any}
end

struct _StrippedEvent
    id::String
    origin::TermOrigin
    kind::String
    body::Dict{String, Any}
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

struct _ZBlock
    name::String
    offset::Int          # 1-based
    shape::Vector{Int}
    sets::Vector{String}
end

_empty_stripped(classes = String[]) = StrippedConstructs(
    classes, Any[], Any[], Any[], Union{Float64, Nothing}[], Any[]
)

Base.isempty(s::StrippedConstructs) =
    isempty(s.events) && isempty(s.parameter_updates) && isempty(s.residuals)

function _removed_classes(s::StrippedConstructs)
    out = String[]
    any(e -> e.kind == "continuous", s.events) && push!(out, "continuous_events")
    any(e -> e.kind == "discrete", s.events) && push!(out, "discrete_events")
    isempty(s.parameter_updates) || push!(out, "parameter_updates")
    isempty(s.residuals) || push!(out, "algebraic")
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
                    "algebraic, continuous_events, discrete_events and parameter_updates " *
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
        d = copy(e.body)
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
    )
end

"""
    canonical_json(s::StrippedConstructs) -> String

The stripped object's canonical JSON (API_SPEC §5.8): compact, every object's
keys ascending, numbers in the CONFORMANCE_SPEC §5.5.3.1 form. Byte-identical
across Julia, Rust and Python.
"""
canonical_json(s::StrippedConstructs) = (io = IOBuffer(); _write_canonical(io, _stripped_json(s)); String(take!(io)))

function _write_canonical(io::IO, v)
    if v === nothing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa Integer
        print(io, string(v))
    elseif v isa Real
        x = Float64(v)
        if isinteger(x) && abs(x) < 9.2e18
            print(io, string(Int64(x)))
        else
            print(io, format_canonical_float(x))
        end
    elseif v isa AbstractString
        print(io, _json_string(String(v)))
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
    return !(head isa OpExpr && head.op in ("ic", "D", "grad", "div", "laplacian"))
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
        d["trigger"] = serialize_trigger(ev.trigger)
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

function _events_of_model!(out, model::Model, prefix::String)
    local_names = Set{String}(keys(model.variables))
    for (k, _) in model.subsystems
        push!(local_names, k)
    end
    ns(e) = namespace_expr(e, prefix, local_names)
    cv, dv = ContinuousEvent[], DiscreteEvent[]
    _collect_events!(cv, dv, model.continuous_events, model.discrete_events, prefix, ns)
    foreach(e -> push!(out, (prefix, "continuous", e)), cv)
    foreach(e -> push!(out, (prefix, "discrete", e)), dv)
    for (k, sub) in model.subsystems
        sub isa Model && _events_of_model!(out, sub, "$prefix.$k")
    end
    return out
end

function _events_of_reaction_system!(out, rs::ReactionSystem, prefix::String)
    local_names = Set{String}()
    foreach(sp -> push!(local_names, sp.name), rs.species)
    foreach(p -> push!(local_names, p.name), rs.parameters)
    for (k, _) in rs.subsystems
        push!(local_names, k)
    end
    ns(e) = namespace_expr(e, prefix, local_names)
    cv, dv = ContinuousEvent[], DiscreteEvent[]
    _collect_events!(cv, dv, rs.continuous_events, rs.discrete_events, prefix, ns)
    foreach(e -> push!(out, (prefix, "continuous", e)), cv)
    foreach(e -> push!(out, (prefix, "discrete", e)), dv)
    for (k, sub) in rs.subsystems
        sub isa Model && _events_of_model!(out, sub, "$prefix.$k")
    end
    return out
end

_event_id(prefix, name, kind, j) = name === nothing ? "$prefix.$(kind)_event[$j]" : "$prefix.$name"

function _stripped_event(prefix, origin, kind, j, ev)
    trig = (hasproperty(ev, :trigger) && ev.trigger isa ConditionTrigger) ? ev.trigger.expression : nothing
    conds = (hasproperty(ev, :conditions) && ev.conditions !== nothing) ? ASTExpr[c for c in ev.conditions] : ASTExpr[]
    neg = hasproperty(ev, :affect_neg) ? ev.affect_neg : nothing
    return _StrippedEvent(
        _event_id(prefix, ev.name, kind, j), origin, kind, _event_body(ev),
        conds, trig, AffectEquation[a for a in ev.affects], neg
    )
end

# The parameters of `model` (and its subsystems) whose update `classes`
# strips, as flattened names.
function _stripped_update_names!(out, model::Model, prefix, classes)
    for (n, v) in model.variables
        v.type == ParameterVariable && v.update !== nothing &&
            _strips_update(v.update, classes) && push!(out, "$prefix.$n")
    end
    for (k, sub) in model.subsystems
        sub isa Model && _stripped_update_names!(out, sub, "$prefix.$k", classes)
    end
    return out
end

"""
    _strip_document(file::EsmFile, classes) -> (doc::Dict, constructs::StrippedConstructs)

The run document with `classes`' constructs removed, and what was removed,
read off the flattened original (API_SPEC §5.8). Coupling-level events stay in
the document: no build lowers one, and keeping them keeps the coupling indices
of the stripped document's provenance the original's.
"""
function _strip_document(file::EsmFile, classes::Vector{String})
    flat = flatten(file)
    s = _empty_stripped(classes)
    # ---- events ----
    found = Any[]
    for (name, m) in something(file.models, OrderedDict{String, Model}())
        _events_of_model!(found, m, name)
    end
    for (name, rs) in something(file.reaction_systems, OrderedDict{String, ReactionSystem}())
        _events_of_reaction_system!(found, rs, name)
    end
    counters = Dict{Tuple{String, String}, Int}()
    for (prefix, kind, ev) in found
        _strips_kind(kind, classes) || continue
        j = counters[(prefix, kind)] = get(counters, (prefix, kind), 0) + 1
        push!(s.events, _stripped_event(prefix, TermOrigin(prefix, nothing), kind, j, ev))
    end
    for (k, entry) in enumerate(file.coupling)
        entry isa CouplingEvent || continue
        kind = entry.event_type == "continuous" ? "continuous" : "discrete"
        _strips_kind(kind, classes) || continue
        prefix = "coupling[$(k - 1)]"
        j = counters[(prefix, kind)] = get(counters, (prefix, kind), 0) + 1
        push!(s.events, _stripped_event(prefix, TermOrigin(nothing, k - 1), kind, j, entry))
    end
    # ---- parameter updates ----
    names = String[]
    for (name, m) in something(file.models, OrderedDict{String, Model}())
        _stripped_update_names!(names, m, name, classes)
    end
    for (rname, rs) in something(file.reaction_systems, OrderedDict{String, ReactionSystem}())
        for p in rs.parameters
            p.update !== nothing && _strips_update(p.update, classes) &&
                push!(names, "$rname.$(p.name)")
        end
    end
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
    # ---- the document ----
    doc = serialize_esm_file(file)
    ev_classes = filter(c -> c in ("continuous_events", "discrete_events"), classes)
    for key in ("models", "reaction_systems")
        comps = get(doc, key, nothing)
        comps isa AbstractDict || continue
        for (cname, comp) in comps
            comp isa AbstractDict || continue
            _strip_component_dict!(comp, String(cname), ev_classes, nameset, "algebraic" in classes)
        end
    end
    # ---- algebraic ----
    if "algebraic" in classes && any(eq -> _strippable_implicit(eq.lhs), flat.equations)
        _collect_algebraic!(s, flat)
    end
    return doc, s
end

function _strip_component_dict!(comp::AbstractDict, prefix, ev_classes, params, algebraic)
    for c in ev_classes
        delete!(comp, c)
    end
    vars = get(comp, "variables", nothing)
    if vars isa AbstractDict
        for (n, v) in vars
            "$prefix.$n" in params && v isa AbstractDict && delete!(v, "update")
        end
    end
    ps = get(comp, "parameters", nothing)
    if ps isa AbstractDict
        for (n, v) in ps
            "$prefix.$n" in params && v isa AbstractDict && delete!(v, "update")
        end
    end
    if algebraic && haskey(comp, "equations") && comp["equations"] isa AbstractVector
        comp["equations"] = Any[
            eq for eq in comp["equations"]
                if !(eq isa AbstractDict && _strippable_implicit(expression_from_json(eq["lhs"])))
        ]
    end
    subs = get(comp, "subsystems", nothing)
    if subs isa AbstractDict
        for (k, sub) in subs
            sub isa AbstractDict && !haskey(sub, "ref") &&
                _strip_component_dict!(sub, "$prefix.$k", ev_classes, params, algebraic)
        end
    end
    return comp
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
                    "the residual of `$(to_ascii(eq))`: $(err.msg)",
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
function _z_starting_values(flat::FlattenedSystem, z, params, t0)
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
            catch
                nothing
            end
        end
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

# Refuse a coupling-level event `classes` does not strip: no compiler here
# lowers one, so building without it would be a silent drop (esm-spec §9.6.6).
function _refuse_coupling_events(file::EsmFile, classes)
    for entry in file.coupling
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
z_layout(ks::KernelSet) = StateBlock[
    StateBlock(b.name, b.base, Int[length(r) for r in b.storage]) for b in ks.rhs.layout.aux
]
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

function _bare_reads!(out::Set{String}, e::ASTExpr)
    if e isa VarExpr
        push!(out, e.name)
    elseif e isa OpExpr
        e.op == "Pre" && return out
        foreach(a -> _bare_reads!(out, a), e.args)
        e.expr_body === nothing || _bare_reads!(out, e.expr_body)
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
    seed = task_local_storage(() -> _program_seed(prob), :_esm_strip_taken, stripped(prob).strip)
    seed === nothing && throw(SimulateError("compile_kernels: this Problem carries no program seed"))
    flat = seed.flat
    s = stripped(prob)
    znames = String[b.name for b in s.z_layout]
    all_states = Set{String}(keys(flat.state_variables))
    unames = Set{String}(n for n in all_states if !(n in znames))
    rhsprog = _whole_program(seed, flat, unames, all_states, :all, :all)
    ulay = state_layout(rhsprog)
    zlay = StateBlock[StateBlock(b.name, b.base, Int[length(r) for r in b.storage]) for b in rhsprog.layout.aux]
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
        KernelBlock[KernelBlock(b.name, b.offset, b.shape) for b in ulay], n_u, n_z, np, n_u
    )
end

function _value_or_map_kernel(kname, dtp, outs, seed, flat, rhs, s, ulay, zlay)
    unresolved(what) = _kernel_error("kernel '$kname': $what does not resolve")
    kinds = ("observed", "expr", "residual", "condition", "update", "affect", "assign")
    okind(o) = (
        o isa AbstractDict || throw(_kernel_error("kernel '$kname': an output is not an object"));
        k = findfirst(x -> haskey(o, x), kinds);
        k === nothing && throw(_kernel_error("kernel '$kname': an output names no output kind"));
        kinds[k]
    )
    nmap = count(o -> okind(o) in ("affect", "assign"), outs)
    (nmap > 0 && nmap != length(outs)) && throw(
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
    unames = Set{String}(b.name for b in ulay)
    function resolve_names(e, what)
        for n in free_variables(e)
            (n == "t" || _declared_sets(n, flat) !== nothing || haskey(flat.index_sets, n)) && continue
            throw(unresolved("$what reads '$n', which"))
        end
        return
    end
    function sets_of(e, what)
        try
            return _expr_sets(e, flat)
        catch err
            err isa ArgumentError || rethrow()
            throw(_kernel_error("kernel '$kname': the shape of $what cannot be decided: $(err.msg)"))
        end
    end
    synth = Any[]   # (name, sets, expr, label, target)
    add!(sets, e, label, target) = push!(synth, ("__kernel_out_$(length(synth) + 1)", sets, e, label, target))
    function event(id)
        i = findfirst(e -> e.id == id, s.events)
        i === nothing && throw(unresolved("event '$id'"))
        return s.events[i]
    end
    for (k, o) in enumerate(outs)
        label = get(o, "label", nothing)
        kind = okind(o)
        if kind == "observed"
            n = String(o["observed"])
            sets = _declared_sets(n, flat)
            sets === nothing && throw(unresolved("observed '$n'"))
            add!(sets, VarExpr(n), something(label, n), nothing)
        elseif kind == "expr"
            e = _strip_pre(expression_from_json(o["expr"]))
            resolve_names(e, "output $k")
            add!(sets_of(e, "output $k"), e, something(label, "out[$k]"), nothing)
        elseif kind == "residual"
            id = String(o["residual"])
            i = findfirst(r -> r.id == id, s.residuals)
            i === nothing && throw(unresolved("residual '$id'"))
            r = s.residuals[i]
            add!(r.sets, r.expr, something(label, id), nothing)
        elseif kind == "condition"
            id = String(o["condition"])
            idx = Int(get(o, "index", 1))
            ev = event(id)
            e = if ev.kind == "continuous"
                idx <= length(ev.conditions) || throw(unresolved("condition $idx of event '$id'"))
                ev.conditions[idx]
            else
                ev.trigger === nothing &&
                    throw(unresolved("the condition of event '$id' (its trigger is not a `condition`), which"))
                idx == 1 || throw(unresolved("condition $idx of event '$id'"))
                OpExpr("ifelse", ASTExpr[ev.trigger, NumExpr(1.0), NumExpr(0.0)])
            end
            e = _strip_pre(e)
            add!(sets_of(e, "the condition of '$id'"), e, something(label, "$id.condition[$idx]"), nothing)
        elseif kind == "update"
            pname = String(o["update"])
            i = findfirst(u -> u.parameter == pname, s.parameter_updates)
            i === nothing && throw(unresolved("parameter update '$pname'"))
            u = s.parameter_updates[i]
            idx = haskey(o, "index") ? Int(o["index"]) :
                (
                    length(u.values) == 1 ? 1 :
                    throw(_kernel_error("kernel '$kname': parameter '$pname' has $(length(u.values)) update rules; name one with `index`"))
                )
            1 <= idx <= length(u.values) || throw(unresolved("update rule $idx of parameter '$pname'"))
            e = _strip_pre(u.values[idx])
            add!(something(_declared_sets(pname, flat), String[]), e, something(label, pname), nothing)
        elseif kind == "affect"
            id = String(o["affect"])
            ev = event(id)
            neg = get(o, "negative", false) === true
            affs = neg ? ev.affect_neg : ev.affects
            affs === nothing && throw(unresolved("the negative affects of event '$id'"))
            assigned = Set{String}(a.lhs for a in affs)
            for a in affs
                reads = _bare_reads!(Set{String}(), a.rhs)
                for v in sort!(collect(reads))
                    v in assigned || continue
                    throw(
                        SimulateError(
                            "kernel '$kname': event '$id' assigns '$v' and its affect on '$(a.lhs)' " *
                                "reads '$v' bare, which is its post-event value; read the pre-event " *
                                "value as Pre($v)",
                            ERROR_CODES.AFFECT_READS_POST_VALUE
                        )
                    )
                end
                a.lhs in unames || throw(unresolved("the affect target '$(a.lhs)' of event '$id' (not an unknown of `u`)"))
                e = _strip_pre(a.rhs)
                resolve_names(e, "the affect on '$(a.lhs)'")
                add!(something(_declared_sets(a.lhs, flat), String[]), e, a.lhs, a.lhs)
            end
        else # assign
            tgt = String(o["assign"])
            tgt in unames || throw(unresolved("the assign target '$tgt' (not an unknown of `u`)"))
            src = o["from"]
            e = _strip_pre(src isa AbstractString ? VarExpr(String(src)) : expression_from_json(src))
            resolve_names(e, "the source of '$tgt'")
            sets = something(_declared_sets(tgt, flat), String[])
            ss = sets_of(e, "the source of '$tgt'")
            (isempty(ss) || ss == sets) || throw(
                _kernel_error(
                    "kernel '$kname': the source of '$tgt' ranges over [$(join(ss, ", "))], the " *
                        "target over [$(join(sets, ", "))]"
                )
            )
            add!(sets, e, tgt, tgt)
        end
    end
    # ---- the kernel's flattened system ----
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
    for (n, sets, e, _, _) in synth
        states[n] = ModelVariable(UnknownVariable; default = 0.0, shape = isempty(sets) ? nothing : sets)
        lhs = isempty(sets) ? OpExpr("D", ASTExpr[VarExpr(n)]; wrt = "t") : _faq_shell_D(n, sets)
        body = isempty(sets) ? e : _faq_body(e, sets, flat)
        push!(eqs, Equation(lhs, body))
        push!(contribs, Contribution[Contribution(body, TermOrigin[])])
    end
    kflat = FlattenedSystem(
        flat;
        state_variables = states, parameters = params,
        discrete_parameters = OrderedDict{String, ModelVariable}(
            k => v for (k, v) in flat.discrete_parameters if !(k in dtp)
        ),
        equations = eqs, equation_contributions = contribs
    )
    W = Set{String}(x[1] for x in synth)
    prog = _whole_program(seed, kflat, W, Set{String}(keys(states)), :all, :all)
    # ---- copy plans ----
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
            SimulateError("kernel '$kname' reads parameter '$(x.name)', which the right-hand side does not")
        )
        push!(p_map, j)
    end
    out_plan = NTuple{3, Int}[]
    layout = KernelBlock[]
    off = 1
    for (n, sets, _, label, target) in synth
        b = prog.layout.u[findfirst(x -> x.name == n, prog.layout.u)]
        len = max(prod(length(r) for r in b.storage; init = 1), 1)
        if target !== nothing
            ub = ulay[findfirst(x -> x.name == target, ulay)]
            push!(out_plan, (b.base, ub.offset, len))
        else
            push!(out_plan, (b.base, off, len))
            push!(layout, KernelBlock(label, off, _set_sizes(sets, flat)))
            off += len
        end
    end
    n_u = rhs.layout.n_u
    if ismap
        layout = KernelBlock[KernelBlock(b.name, b.offset, b.shape) for b in ulay]
        out_len = n_u
    else
        out_len = off - 1
    end
    return Kernel(
        kname, prog, false, ismap, aux_plan, p_map, out_plan, layout,
        n_u, rhs.layout.n_aux, length(set_params), out_len
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
