# Event consistency and event affect targets.

"""
    validate_event_consistency(model::Model, path::String) -> Vector{StructuralError}

Validate event consistency: continuous conditions are expressions,
discrete conditions produce booleans, affect variables declared,
functional affect refs valid.
"""
function validate_event_consistency(
        model::Model, path::String; is_coupled::Bool = false
    )::Vector{StructuralError}
    # A subsystem of a coupled model is composed along with its parent, so it
    # inherits the exemption.
    errors = StructuralError[]
    _foreach_component(model, path) do m, p, _
        append!(errors, _validate_event_consistency_here(m, p; is_coupled = is_coupled))
    end
    return errors
end

function _validate_event_consistency_here(
        model::Model, path::String;
        is_coupled::Bool = false
    )::Vector{StructuralError}
    errors = StructuralError[]

    # Validate discrete events
    for (i, event) in enumerate(model.discrete_events)
        event_path = _pointer(path, "discrete_events", i)
        append!(
            errors, validate_single_event_consistency(
                model, event, event_path;
                is_coupled = is_coupled
            )
        )
    end

    # Validate continuous events
    for (i, event) in enumerate(model.continuous_events)
        event_path = _pointer(path, "continuous_events", i)
        append!(
            errors, validate_single_event_consistency(
                model, event, event_path;
                is_coupled = is_coupled
            )
        )
    end


    return errors
end

# The §6.4 operator placeholder. In an operator-composed / coupled model `_var`
# stands for each matching state variable of the system this one is composed
# with, and it is substituted at composition — so an event affect that ASSIGNS to
# it is legal, exactly as an equation that differentiates it is
# (tests/valid/full_coupled.esm).
const _OPERATOR_PLACEHOLDER_VAR = "_var"

_is_declared_event_target(model::Model, name::AbstractString, is_coupled::Bool)::Bool =
    haskey(model.variables, name) || (is_coupled && name == _OPERATOR_PLACEHOLDER_VAR)

"""
    validate_single_event_consistency(model::Model, event::EventType, event_path::String;
                                      is_coupled=false) -> Vector{StructuralError}

Validate consistency of a single event.
"""
function validate_single_event_consistency(
        model::Model, event::EventType, event_path::String;
        is_coupled::Bool = false
    )::Vector{StructuralError}
    errors = StructuralError[]

    if isa(event, ContinuousEvent)
        # Continuous event conditions should be mathematical expressions (zero-crossing)
        # This is automatically satisfied by the type system (Vector{ASTExpr})

        # A continuous event's `affects` and its `affect_neg` (the affects of a
        # falling crossing) write the same way and are checked the same way.
        for (field, affects) in (("affects", event.affects), ("affect_neg", event.affect_neg))
            affects === nothing && continue
            _check_event_affect_targets!(errors, model, affects, "$event_path/$field", is_coupled)
            _check_event_affects_unknowns!(errors, model, event, affects, "$event_path/$field", "continuous")
        end
    elseif isa(event, DiscreteEvent)
        _check_event_affect_targets!(errors, model, event.affects, "$event_path/affects", is_coupled)
        _check_event_affects_unknowns!(errors, model, event, event.affects, "$event_path/affects", "discrete")
    end

    return errors
end

# An affect's target must be declared: `event_var_undeclared` at the affect's
# `lhs` field (§7.1 / §7.1.3(h)).
function _check_event_affect_targets!(
        errors::Vector{StructuralError}, model::Model, affects, at::String, is_coupled::Bool
    )
    for (j, affect) in enumerate(affects)
        _is_declared_event_target(model, affect.lhs, is_coupled) && continue
        _report!(
            errors, ERROR_CODES.EVENT_VAR_UNDECLARED,
            _pointer(at, j, "lhs"),
            "Variable '$(affect.lhs)' in event affects is not declared",
            Dict{String, Any}("variable" => affect.lhs)
        )
    end
    return errors
end

"""
    _check_event_affects_unknowns!(errors, model, event, affects, at, event_kind)

esm-spec §5.4 / §6.3.1: **an event may affect UNKNOWNS only.** From 1.0.0 a
parameter that changes during a run declares its own `update` block, so the
0.x `discrete_parameters` list and `functional_affect` handler are gone and an
`affects` LHS naming a parameter is the `event_affects_parameter` defect —
reported at the affect entry, which is where the offending write is written.

The remedy names the `update.kind` that expresses the same intent legally, so
the diagnostic tells the author what to write instead of only what is wrong: a
periodic/preset-times trigger becomes a `schedule`, a boolean condition becomes
a `condition`, and a continuous event's zero crossing becomes a `crossing`.
"""
function _check_event_affects_unknowns!(
        errors::Vector{StructuralError},
        model::Model, event, affects, at::String,
        event_kind::String
    )
    for (j, affect) in enumerate(affects)
        var = get(model.variables, affect.lhs, nothing)
        (var !== nothing && var.type == ParameterVariable) || continue
        details = Dict{String, Any}(
            "variable" => affect.lhs,
            "variable_type" => "parameter",
            "event_type" => event_kind,
            "remedy" => _event_affect_remedy(event, affect.lhs)
        )
        ename = event.name
        ename === nothing || (details["event_name"] = ename)
        tkind = _event_trigger_kind(event)
        tkind === nothing || (details["trigger_type"] = tkind)
        subject = ename === nothing ? "Event" : "Event '$(ename)'"
        _report!(
            errors, ERROR_CODES.EVENT_AFFECTS_PARAMETER,
            _pointer(at, j),
            "$(subject) affects '$(affect.lhs)', which is a parameter; " *
                "an event may affect unknowns only",
            details
        )
    end
    return errors
end


function _event_trigger_kind(event)::Union{String, Nothing}
    isa(event, DiscreteEvent) || return nothing
    t = event.trigger
    t isa PeriodicTrigger && return "periodic"
    t isa PresetTimesTrigger && return "preset_times"
    t isa ConditionTrigger && return "condition"
    return nothing
end

# The legal 1.0.0 spelling of the same intent, named concretely where the
# trigger supplies enough to name it.
function _event_affect_remedy(event, name::AbstractString)::String
    if isa(event, DiscreteEvent)
        t = event.trigger
        if t isa PeriodicTrigger
            return "declare the change as update: {kind: \"schedule\", " *
                "interval: $(t.period)} on '$(name)' (esm-spec 5.4)"
        elseif t isa PresetTimesTrigger
            return "declare the change as update: {kind: \"schedule\", times: " *
                "$(t.times)} on '$(name)' (esm-spec 5.4)"
        elseif t isa ConditionTrigger
            return "declare the change as update: {kind: \"condition\", when: …} " *
                "on '$(name)' (esm-spec 5.4)"
        end
    elseif isa(event, ContinuousEvent)
        return "declare the change as update: {kind: \"crossing\", when: …} " *
            "on '$(name)' (esm-spec 5.4)"
    end
    return "declare the change as the parameter's own update (esm-spec 5.4)"
end
