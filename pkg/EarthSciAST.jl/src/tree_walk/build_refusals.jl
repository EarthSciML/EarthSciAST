# tree_walk/build_refusals.jl — what a build refuses at its entry: events, Wiener noise, symbolic
# updates, a doubly-defined unknown, and data-fed parameters with nothing bound.

function _equation_tag(eq::Equation)
    if eq._comment !== nothing
        return eq._comment
    end
    return string(typeof(eq.lhs))
end

# The construct an event refusal names (esm-spec §9.6.6).
_event_construct(::ContinuousEvent) = "continuous event"
_event_construct(::DiscreteEvent) = "discrete event"

# The tree-walk evaluator's refusal of an event (esm-spec §9.6.6), one message
# for every entry that can still see the events: `_build_evaluator` on a model or
# on a flattened system, and `simulate` / `run_inline_tests`. The event is named
# `'name'`, or `(unnamed)`.
_event_refusal(ev::Union{ContinuousEvent, DiscreteEvent}) = TreeWalkError(
    ERROR_CODES.UNSUPPORTED_CONSTRUCT,
    "$(_event_construct(ev)) $(ev.name === nothing ? "(unnamed)" : "'$(ev.name)'") " *
        "is not supported by the Julia tree-walk evaluator; " *
        "refusing the build rather than running the model without it"
)

# Throw the refusal when a flattened system carries an event, continuous or
# discrete. Called when the run is prepared (`_prepare_run`): the run file
# carries no events, so the model-level check at the build entry would never see
# them.
function _refuse_flat_events(flat::FlattenedSystem)
    isempty(flat.continuous_events) || throw(_event_refusal(flat.continuous_events[1]))
    isempty(flat.discrete_events) || throw(_event_refusal(flat.discrete_events[1]))
    return nothing
end

# The first unknown carrying BOTH a derivative equation and a bare-LHS one, as
# `(name, derivative_equation, bare_equation)`; `nothing` when there is none.
#
# The search is over EQUATION SHAPES, not over any state/observed split. The
# derivative side accepts every spelling `_lhs_role` credits as `:derivative`
# (`D(x)`, `D(x[i])`, a `faq` whose body is a `D`); the competing definition
# must be a BARE variable LHS. An indexed LHS writes one cell rather than
# redefining the whole unknown and is not counted, which keeps this to the shape
# the Python and Rust builds refuse, so the three bindings refuse the same
# documents.
#
# First in equation order, so a document with several gets a stable message.
function _first_doubly_defined_unknown(equations)
    diff_eqs = Dict{String, Equation}()
    bare_eqs = Dict{String, Equation}()
    for eq in equations
        role, name = _lhs_role(eq.lhs)
        if role === :derivative
            get!(diff_eqs, name, eq)
        elseif eq.lhs isa VarExpr
            get!(bare_eqs, (eq.lhs::VarExpr).name, eq)
        end
    end
    for eq in equations
        role, name = _lhs_role(eq.lhs)
        role === :derivative || continue
        haskey(bare_eqs, name) || continue
        return (name, diff_eqs[name], bare_eqs[name])
    end
    return nothing
end

# The tree-walk evaluator's refusal of a Wiener-noise parameter (`update.kind =
# "wiener"`, esm-spec §9.6.6). Such a parameter makes the document an SDE, and
# this evaluator integrates ODEs only: building it anyway reads the noise as a
# constant and reports the trajectory of a different, deterministic model.
_wiener_refusal(name::AbstractString) = TreeWalkError(
    ERROR_CODES.UNSUPPORTED_CONSTRUCT,
    "Wiener noise parameter '$name' is not supported by the Julia tree-walk " *
        "evaluator; refusing the build rather than running the model without it"
)

# Throw the refusal when a flattened system carries a Wiener-noise parameter.
# Called next to `_refuse_flat_events`, while the flattened system is in hand.
function _refuse_flat_wiener_noise(flat::FlattenedSystem)
    isempty(flat.brownian_parameters) ||
        throw(_wiener_refusal(first(keys(flat.brownian_parameters))))
    return nothing
end

# The first Wiener-noise parameter `model` or any of its subsystems declares;
# `nothing` when there is none.
function _first_wiener_parameter(model::Model)::Union{Nothing, String}
    names = brownian_parameters(model)
    isempty(names) || return first(names)
    for sub in values(model.subsystems)
        sub isa Model || continue
        found = _first_wiener_parameter(sub)
        found === nothing || return found
    end
    return nothing
end

# A parameter that recomputes ITSELF from a symbolic `expression` update
# (esm-spec §5.4) is the 1.0.0 spelling of an event that writes it: `crossing`
# replaces a continuous event, `schedule` and `condition` a discrete one. This
# evaluator fires no events, so building it anyway freezes the parameter at its
# default and reports a different model. Refused as the event it stands for
# (esm-spec §9.6.6). An update read `from` a data source, or supplied by a
# registered `handler`, is filled from outside the model and is not refused.
_symbolic_update_construct(kind::AbstractString) =
    kind == "crossing" ? "continuous event" : "discrete event"

_symbolic_update_refusal(name::AbstractString, kind::AbstractString) = TreeWalkError(
    ERROR_CODES.UNSUPPORTED_CONSTRUCT,
    "$(_symbolic_update_construct(kind)) (the `$(kind)` update of parameter '$name', " *
        "which recomputes it from an expression) is not supported by the Julia tree-walk " *
        "evaluator; refusing the build rather than running the model without it"
)

# The first (name, kind) among `vars` whose update carries a symbolic
# `expression` rule; `nothing` when there is none. Sorted by name, so the
# refusal names the same parameter on every run.
function _first_symbolic_update(vars::AbstractDict)
    for name in sort!(collect(String, keys(vars)))
        v = vars[name]
        v isa ModelVariable && v.type == ParameterVariable || continue
        for rule in _update_rules(v)
            rule.kind != "wiener" && rule.expression !== nothing &&
                return (name, rule.kind)
        end
    end
    return nothing
end

function _first_symbolic_update(model::Model)
    found = _first_symbolic_update(model.variables)
    found === nothing || return found
    for sub in values(model.subsystems)
        sub isa Model || continue
        found = _first_symbolic_update(sub)
        found === nothing || return found
    end
    return nothing
end

# Throw the refusal when a flattened system carries a self-recomputing
# parameter. Called next to `_refuse_flat_wiener_noise`.
function _refuse_flat_symbolic_updates(flat::FlattenedSystem)
    found = _first_symbolic_update(flat.discrete_parameters)
    found === nothing || throw(_symbolic_update_refusal(found...))
    return nothing
end

# The refusal of a doubly-defined unknown (esm-spec §4.9.4), naming the unknown
# and both equations.
_doubly_defined_refusal(name::AbstractString, diff_eq::Equation, bare_eq::Equation) =
    TreeWalkError(
    ERROR_CODES.EQUATION_COUNT_MISMATCH,
    "unknown '$name' is defined twice — by `$(diff_eq)` and by " *
        "`$(bare_eq)`. esm-spec §4.9.4 counts an equation whichever form " *
        "its LHS takes, so this system has one more equation than it has unknowns " *
        "to bind; keeping the derivative and dropping the constraint would run a " *
        "model the document does not describe. Remove one of the two definitions."
)

# Throw that refusal when `equations` doubly-defines an unknown.
#
# `validate` reports the same document as `equation_count_mismatch`, and the
# build is the other place it arrives. Tie-breaking in favour of the derivative
# — which is what `algebraic_states_to_observeds` leaves standing, since it
# keeps a doubly-defined name a STATE and drops nothing — integrates a system
# free of a constraint the file declares and reports the trajectory as the
# answer.
function _refuse_doubly_defined_unknown(equations)
    found = _first_doubly_defined_unknown(equations)
    found === nothing || throw(_doubly_defined_refusal(found...))
    return nothing
end

# The first event `model` or any of its subsystems declares, a continuous one
# before a discrete one; `nothing` when there is none.
function _first_event(model::Model)::Union{Nothing, ContinuousEvent, DiscreteEvent}
    isempty(model.continuous_events) || return model.continuous_events[1]
    isempty(model.discrete_events) || return model.discrete_events[1]
    for sub in values(model.subsystems)
        sub isa Model || continue
        found = _first_event(sub)
        found === nothing || return found
    end
    return nothing
end

# ============================================================
# 5a. Data-fed parameters with nothing bound (esm-spec §9.6.6
#     `data_source_unbound`, CONFORMANCE_SPEC §5.46)
# ============================================================

# One data-fed parameter: the name the build addresses it by, and the
# `data_sources` key its `update` names.
struct _DataFeed
    name::String
    source::String
    var::ModelVariable
end

# Every data-fed parameter of `model`, in declaration order. A parameter is data-fed when some `update` rule is
# `kind == "data"` and carries a `from` binding (esm-spec §5.4/§8.5) — the same
# predicate `_loader_fields` applies, MINUS its requirement that the
# named source resolve: a source the document does not declare is not a source
# that is bound either, and dropping the parameter here is exactly how it used
# to reach the build looking ordinary and run at its `default`.
# Every build sees the flattened single model, whose variable names already
# carry their component (`"Forcing.k"`) and which has no subsystems left.
function _collect_data_feeds!(out::Vector{_DataFeed}, model::Model)
    for (var_name, var) in model.variables
        var.type == ParameterVariable || continue
        var.update === nothing && continue
        for rule in var.update
            (rule.kind == "data" && rule.from !== nothing) || continue
            push!(
                out, _DataFeed(
                    String(var_name),
                    rule.source === nothing ? "(unnamed)" : String(rule.source), var
                )
            )
            break                      # one parameter is fed by one source
        end
    end
    return out
end

# Does any of `bindings` (the build's override / const-array / forcing-buffer
# registries) bind `name`? A key matches EXACTLY or as a whole-segment dotted
# suffix of the other spelling — the bare / partially-qualified spelling esm-spec
# §6.6.2 admits for a `parameter_overrides` key (`k` or `Forcing.k` for
# `Top.Forcing.k`), and its reverse, for a raw model whose own names are bare
# while the caller qualifies the key. It never matches on the leaf alone: a key
# for `Other.k` does not bind `Forcing.k`, since a binding for one component
# must not answer for another's unbound parameter. A bare key is genuinely
# ambiguous between components and binds each; the override resolver reports
# that ambiguity, and the direction it errs in only turns a refusal into a
# build the caller asked for.
function _data_feed_is_bound(name::AbstractString, bindings)
    for d in bindings
        for k in keys(d)
            ks = String(k)
            (ks == name || endswith(name, "." * ks) || endswith(ks, "." * name)) &&
                return true
        end
    end
    return false
end

"""
    _refuse_unbound_data_feeds(model, bindings...)

The build's answer for a data-fed parameter that nothing bound — no provider,
no loaded array, no caller-supplied `p` value (esm-spec §9.6.6, CONFORMANCE_SPEC
§5.46).

A declared `default` is the parameter's value when no data is supplied
(esm-spec §6.3; user ruling 2026-09-29), so such a parameter builds. One with
neither a default nor a bound value is missing data (§10.10) and is refused as
`E_TREEWALK_MISSING_DATA`, naming the parameter and the data source that feeds
it. `data_source_unbound` stays in the registry, where the §9.6.6 vocabulary is
uniform across bindings, but this binding no longer raises it.

`bindings` are the registries a value can arrive through by the time the build
runs — the resolved `parameter_overrides`, `const_arrays` (where `esm_problem`
puts a CONST provider's materialized field and a gated provider's fetched slab)
and `param_arrays` (the live buffer a DISCRETE provider rewrites). Checked at the
build entry, before any right-hand side exists, so the answer is the same under
every `compiler`.
"""
function _refuse_unbound_data_feeds(model::Model, bindings...)
    feeds = _collect_data_feeds!(_DataFeed[], model)
    isempty(feeds) && return nothing
    for feed in feeds
        _data_feed_is_bound(feed.name, bindings) && continue
        feed.var.default === nothing || continue
        throw(_missing_data_error(feed.name, feed.var))
    end
    return nothing
end
