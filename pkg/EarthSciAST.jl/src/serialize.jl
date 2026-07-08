"""
ESM Format JSON Serialization

Provides functionality to serialize EsmFile objects to JSON strings.
"""

using JSON3

"""
    _emit_stoich(x::Real)

Emit a stoichiometric coefficient as an integer when the value is exact, else as
its Float64 form. Integer exactness keeps existing integer-only fixtures
byte-identical across a parse/re-emit cycle, while fractional values (e.g.
`0.87 CH2O`, `1.86 CH3O2`) survive untouched.
"""
function _emit_stoich(x::Real)
    if isinteger(x) && isfinite(x) && abs(x) < 2.0^53
        return Int(x)
    end
    return Float64(x)
end

# Serialize one `ranges[*]` value: either a dense integer / expression tuple
# (as today) or an index-set reference object (RFC §5.2).
function _serialize_range_value(v)
    if v isa IndexSetRef
        d = Dict{String,Any}("from" => v.from)
        isempty(v.of) || (d["of"] = v.of)
        return d
    end
    return [x isa Expr ? serialize_expression(x) : x for x in v]
end

"""
    serialize_index_set(is::IndexSet) -> Dict{String,Any}

Serialize one `index_sets` registry entry (RFC §5.2). Mirrors `coerce_index_set`:
when a categorical set carries non-string members, `coerce_index_set` retains
the originally-typed values in `members_raw` (the string-coerced `members` view
is a lossy convenience), so `members_raw` — not `members` — is what round-trips
back to the wire `members` key. String-only sets have `members_raw === nothing`
and emit `members` unchanged.
"""
function serialize_index_set(is::IndexSet)::Dict{String,Any}
    d = Dict{String,Any}("kind" => is.kind)
    is.size !== nothing && (d["size"] = is.size)
    if is.members_raw !== nothing
        d["members"] = is.members_raw
    elseif is.members !== nothing
        d["members"] = is.members
    end
    is.of !== nothing && (d["of"] = is.of)
    is.offsets !== nothing && (d["offsets"] = is.offsets)
    is.values !== nothing && (d["values"] = is.values)
    is.from_faq !== nothing && (d["from_faq"] = is.from_faq)
    return d
end

"""
    serialize_expression(expr::Expr) -> Any

Serialize an Expression to JSON-compatible format.
Handles the union type discrimination.
"""
function serialize_expression(expr::Expr)
    if isa(expr, IntExpr)
        # Int64 → JSON3 emits as integer token (no decimal). Preserves §5.4.6
        # round-trip: on parse, a token without '.'/'e' recovers as IntExpr.
        return expr.value
    elseif isa(expr, NumExpr)
        # Float64 → JSON3 emits with trailing .0 for integer-valued floats and
        # exponent form for |x| outside [1e-6, 1e21). Satisfies RFC §5.4.6.
        return expr.value
    elseif isa(expr, VarExpr)
        return expr.name
    elseif isa(expr, OpExpr)
        result = Dict{String,Any}(
            "op" => expr.op,
            "args" => [serialize_expression(arg) for arg in expr.args]
        )
        if expr.wrt !== nothing
            result["wrt"] = expr.wrt
        end
        if expr.dim !== nothing
            result["dim"] = expr.dim
        end
        if expr.int_var !== nothing
            result["var"] = expr.int_var
        end
        if expr.lower !== nothing
            result["lower"] = serialize_expression(expr.lower)
        end
        if expr.upper !== nothing
            result["upper"] = serialize_expression(expr.upper)
        end
        if expr.output_idx !== nothing
            result["output_idx"] = expr.output_idx
        end
        if expr.expr_body !== nothing
            result["expr"] = serialize_expression(expr.expr_body)
        end
        if expr.reduce !== nothing
            result["reduce"] = expr.reduce
        end
        if expr.semiring !== nothing
            result["semiring"] = expr.semiring
        end
        if expr.ranges !== nothing
            result["ranges"] = Dict{String,Any}(
                k => _serialize_range_value(v) for (k, v) in expr.ranges
            )
        end
        if expr.regions !== nothing
            result["regions"] = expr.regions
        end
        if expr.values !== nothing
            result["values"] = [serialize_expression(v) for v in expr.values]
        end
        if expr.shape !== nothing
            result["shape"] = expr.shape
        end
        if expr.perm !== nothing
            result["perm"] = expr.perm
        end
        if expr.axis !== nothing
            result["axis"] = expr.axis
        end
        if expr.fn !== nothing
            result["fn"] = expr.fn
        end
        if expr.name !== nothing
            result["name"] = expr.name
        end
        if expr.value !== nothing
            result["value"] = expr.value
        end
        # table_lookup (esm-spec §9.5, v0.4.0). Stored under JSON key "axes"
        # on the wire. ``output`` is preserved verbatim (Int or String).
        if expr.table !== nothing
            result["table"] = expr.table
        end
        if expr.table_axes !== nothing
            result["axes"] = Dict{String,Any}(
                k => serialize_expression(v) for (k, v) in expr.table_axes
            )
        end
        if expr.output !== nothing
            result["output"] = expr.output
        end
        # M2 (RFC §5.3 / §7.2): value-equality `join` clauses and the boolean
        # `filter` predicate. `join` round-trips back to the wire form
        # `[{ "on": [[left, right], …] }, …]`; the internal resolved
        # `join_gates` is a build artifact and is never serialized.
        if expr.join !== nothing
            result["join"] = [
                Dict{String,Any}("on" => [[p[1], p[2]] for p in clause])
                for clause in expr.join
            ]
        end
        if expr.filter !== nothing
            result["filter"] = serialize_expression(expr.filter)
        end
        # M4 geometry kernel (RFC §8.1): node `id` (§6.1) + `intersect_polygon`
        # `manifold` — emitted only when present so non-geometry nodes round-trip
        # byte-identically.
        if expr.id !== nothing
            result["id"] = expr.id
        end
        if expr.manifold !== nothing
            result["manifold"] = expr.manifold
        end
        # Value-invention producer vocabulary (RFC §5.5 / §6.1): the `distinct`
        # set-former flag and the emitted `key` expression. Emitted only when
        # present so non-producer nodes round-trip byte-identically.
        if expr.distinct !== nothing
            result["distinct"] = expr.distinct
        end
        if expr.key !== nothing
            result["key"] = serialize_expression(expr.key)
        end
        # Arg-witness index symbol (argmin/argmax) and expression-template
        # bindings — emitted only when present so other nodes round-trip
        # byte-identically.
        if expr.arg !== nothing
            result["arg"] = expr.arg
        end
        if expr.bindings !== nothing
            result["bindings"] = Dict{String,Any}(
                k => serialize_expression(v) for (k, v) in expr.bindings
            )
        end
        return result
    else
        throw(ArgumentError("Unknown expression type: $(typeof(expr))"))
    end
end

"""
    serialize_model_variable_type(var_type::ModelVariableType) -> String

Serialize ModelVariableType enum to string.
"""
function serialize_model_variable_type(var_type::ModelVariableType)::String
    if var_type == StateVariable
        return "state"
    elseif var_type == ParameterVariable
        return "parameter"
    elseif var_type == ObservedVariable
        return "observed"
    elseif var_type == BrownianVariable
        return "brownian"
    else
        throw(ArgumentError("Unknown ModelVariableType: $(var_type)"))
    end
end

"""
    serialize_trigger(trigger::DiscreteEventTrigger) -> Dict{String,Any}

Serialize DiscreteEventTrigger to JSON-compatible format.
"""
function serialize_trigger(trigger::DiscreteEventTrigger)::Dict{String,Any}
    if isa(trigger, ConditionTrigger)
        return Dict("type" => "condition", "expression" => serialize_expression(trigger.expression))
    elseif isa(trigger, PeriodicTrigger)
        result = Dict("type" => "periodic", "interval" => trigger.period)
        if trigger.phase != 0.0
            result["initial_offset"] = trigger.phase
        end
        return result
    elseif isa(trigger, PresetTimesTrigger)
        return Dict("type" => "preset_times", "times" => trigger.times)
    else
        throw(ArgumentError("Unknown DiscreteEventTrigger type: $(typeof(trigger))"))
    end
end

"""
    serialize_event(event::EventType) -> Dict{String,Any}

Serialize EventType to JSON-compatible format.
"""
function serialize_event(event::EventType)::Dict{String,Any}
    if isa(event, ContinuousEvent)
        result = Dict{String,Any}(
            "conditions" => [serialize_expression(c) for c in event.conditions],
            "affects" => [serialize_affect_equation(a) for a in event.affects]
        )
        if event.description !== nothing
            result["description"] = event.description
        end
        return result
    elseif isa(event, DiscreteEvent)
        return serialize_discrete_event(event)
    else
        throw(ArgumentError("Unknown EventType: $(typeof(event))"))
    end
end

"""
    serialize_discrete_event(event::DiscreteEvent) -> Dict{String,Any}

Serialize DiscreteEvent to the schema shape. Julia stores event affects as a
Vector{FunctionalAffect}(target, expression, operation) for legacy reasons,
but the schema requires discrete_events[].affects to be an array of
AffectEquation objects ({lhs, rhs}). Emit the schema shape.

A handler-based event (parsed from a schema `functional_affect` descriptor)
re-emits its raw descriptor verbatim under `functional_affect`; the schema's
oneOf admits exactly one of `affects` / `functional_affect`, so an event
carrying both is rejected here.
"""
function serialize_discrete_event(event::DiscreteEvent)::Dict{String,Any}
    result = Dict{String,Any}("trigger" => serialize_trigger(event.trigger))
    if event.functional_affect !== nothing
        isempty(event.affects) || throw(ArgumentError(
            "DiscreteEvent cannot carry both symbolic `affects` and a " *
            "`functional_affect` descriptor (schema DiscreteEvent oneOf)"))
        result["functional_affect"] = event.functional_affect
    else
        result["affects"] = [Dict{String,Any}(
            "lhs" => a.target,
            "rhs" => serialize_expression(a.expression),
        ) for a in event.affects]
    end
    if event.description !== nothing
        result["description"] = event.description
    end
    return result
end

"""
    serialize_continuous_event(event::ContinuousEvent) -> Dict{String,Any}

Serialize ContinuousEvent to JSON-compatible format.
"""
function serialize_continuous_event(event::ContinuousEvent)::Dict{String,Any}
    result = Dict{String,Any}(
        "conditions" => [serialize_expression(c) for c in event.conditions],
        "affects" => [serialize_affect_equation(a) for a in event.affects]
    )
    if event.description !== nothing
        result["description"] = event.description
    end
    return result
end

"""
    serialize_affect_equation(affect::AffectEquation) -> Dict{String,Any}

Serialize AffectEquation to JSON-compatible format.
"""
function serialize_affect_equation(affect::AffectEquation)::Dict{String,Any}
    return Dict{String,Any}(
        "lhs" => affect.lhs,
        "rhs" => serialize_expression(affect.rhs)
    )
end

"""
    serialize_model_variable(var::ModelVariable) -> Dict{String,Any}

Serialize ModelVariable to JSON-compatible format.
"""
function serialize_model_variable(var::ModelVariable)::Dict{String,Any}
    result = Dict{String,Any}(
        "type" => serialize_model_variable_type(var.type)
    )
    if var.default !== nothing
        result["default"] = var.default
    end
    if var.units !== nothing
        result["units"] = var.units
    end
    if var.default_units !== nothing
        result["default_units"] = var.default_units
    end
    if var.description !== nothing
        result["description"] = var.description
    end
    if var.expression !== nothing
        result["expression"] = serialize_expression(var.expression)
    end
    if var.shape !== nothing
        result["shape"] = String[d for d in var.shape]
    end
    if var.location !== nothing
        result["location"] = var.location
    end
    if var.noise_kind !== nothing
        result["noise_kind"] = var.noise_kind
    end
    if var.correlation_group !== nothing
        result["correlation_group"] = var.correlation_group
    end
    return result
end

"""
    serialize_equation(eq::Equation) -> Dict{String,Any}

Serialize Equation to JSON-compatible format.
"""
function serialize_equation(eq::Equation)::Dict{String,Any}
    result = Dict{String,Any}(
        "lhs" => serialize_expression(eq.lhs),
        "rhs" => serialize_expression(eq.rhs)
    )
    if eq._comment !== nothing
        result["_comment"] = eq._comment
    end
    return result
end

"""
    _serialize_subsystem(v) -> Dict{String,Any}

Serialize a single model subsystem value: a child `Model`, a pure-I/O
`DataLoader` (RFC pure-io-data-loaders §4.3), or an unresolved `SubsystemRef`
(which round-trips back to `{"ref": ...}`).
"""
function _serialize_subsystem(v)::Dict{String,Any}
    if v isa DataLoader
        return serialize_data_loader(v)
    elseif v isa SubsystemRef
        out = Dict{String,Any}("ref" => v.ref)
        # Metaparameter bindings at the subsystem edge (esm-spec §9.7.6 site 3)
        # and injected imports (§9.7.10 form A) survive only while the ref is
        # unresolved; a resolved subsystem round-trips as the instantiated,
        # fixpoint-lowered inline component and neither field remains.
        isempty(v.bindings) || (out["bindings"] = Dict{String,Any}(
            k => b for (k, b) in v.bindings))
        isempty(v.expression_template_imports) ||
            (out["expression_template_imports"] =
                [_to_native_json(e) for e in v.expression_template_imports])
        return out
    else
        return serialize_model(v)
    end
end

"""
    serialize_model(model::Model) -> Dict{String,Any}

Serialize Model to JSON-compatible format.
"""
function serialize_model(model::Model)::Dict{String,Any}
    result = Dict{String,Any}(
        "variables" => Dict(k => serialize_model_variable(v) for (k, v) in model.variables),
        "equations" => [serialize_equation(eq) for eq in model.equations]
    )

    # Serialize discrete events if present
    if !isempty(model.discrete_events)
        result["discrete_events"] = [serialize_discrete_event(ev) for ev in model.discrete_events]
    end

    # Serialize continuous events if present
    if !isempty(model.continuous_events)
        result["continuous_events"] = [serialize_continuous_event(ev) for ev in model.continuous_events]
    end

    # Add subsystems if present. A subsystem value is a child Model, a
    # DataLoader (RFC pure-io-data-loaders §4.3), or an unresolved SubsystemRef.
    if !isempty(model.subsystems)
        result["subsystems"] = Dict(k => _serialize_subsystem(v) for (k, v) in model.subsystems)
    end

    if model.tolerance !== nothing
        result["tolerance"] = serialize_tolerance(model.tolerance)
    end

    if !isempty(model.tests)
        result["tests"] = [serialize_test(t) for t in model.tests]
    end

    if !isempty(model.initialization_equations)
        result["initialization_equations"] =
            [serialize_equation(eq) for eq in model.initialization_equations]
    end

    if !isempty(model.guesses)
        guesses_out = Dict{String,Any}()
        for (k, v) in model.guesses
            guesses_out[k] = v isa Expr ?
                serialize_expression(v) : v
        end
        result["guesses"] = guesses_out
    end

    if model.system_kind !== nothing
        result["system_kind"] = model.system_kind
    end

    return result
end

"""
    serialize_tolerance(tol::Tolerance) -> Dict{String,Any}
"""
function serialize_tolerance(tol::Tolerance)::Dict{String,Any}
    result = Dict{String,Any}()
    if tol.abs !== nothing
        result["abs"] = tol.abs
    end
    if tol.rel !== nothing
        result["rel"] = tol.rel
    end
    return result
end

"""
    serialize_time_span(span::TimeSpan) -> Dict{String,Any}
"""
function serialize_time_span(span::TimeSpan)::Dict{String,Any}
    return Dict{String,Any}("start" => span.start, "end" => span.stop)
end

"""
    serialize_assertion(a::Assertion) -> Dict{String,Any}
"""
function serialize_assertion(a::Assertion)::Dict{String,Any}
    result = Dict{String,Any}(
        "variable" => a.variable,
        "time" => a.time,
        "expected" => a.expected,
    )
    if a.tolerance !== nothing
        result["tolerance"] = serialize_tolerance(a.tolerance)
    end
    if a.coords !== nothing
        result["coords"] = Dict{String,Any}(k => v for (k, v) in a.coords)
    end
    if a.reduce !== nothing
        result["reduce"] = a.reduce
    end
    if a.reference !== nothing
        if a.reference isa Expr
            result["reference"] = serialize_expression(a.reference)
        elseif a.reference isa AbstractDict
            # from_file shape: round-trip its keys verbatim
            ref_out = Dict{String,Any}()
            for (k, v) in a.reference
                ref_out[string(k)] = v
            end
            result["reference"] = ref_out
        else
            result["reference"] = a.reference
        end
    end
    return result
end

"""
    serialize_test(t::Test) -> Dict{String,Any}
"""
function serialize_test(t::EarthSciAST.Test)::Dict{String,Any}
    result = Dict{String,Any}(
        "id" => t.id,
        "time_span" => serialize_time_span(t.time_span),
        "assertions" => [serialize_assertion(a) for a in t.assertions],
    )
    if t.description !== nothing
        result["description"] = t.description
    end
    if !isempty(t.initial_conditions)
        result["initial_conditions"] = Dict{String,Any}(
            k => v for (k, v) in t.initial_conditions)
    end
    if !isempty(t.parameter_overrides)
        result["parameter_overrides"] = Dict{String,Any}(
            k => v for (k, v) in t.parameter_overrides)
    end
    if t.tolerance !== nothing
        result["tolerance"] = serialize_tolerance(t.tolerance)
    end
    # esm-spec §9.7.10 form C: a test's injected imports are authored per-run
    # config and DO survive parse → emit (unlike a component's own imports,
    # which are consumed by the fixpoint at load).
    if !isempty(t.expression_template_imports)
        result["expression_template_imports"] =
            [_to_native_json(e) for e in t.expression_template_imports]
    end
    return result
end

"""
    serialize_species(species::Species) -> Dict{String,Any}

Serialize Species to JSON-compatible format.
Note: Species name is the key in the species dictionary, not a property of the Species object.
"""
function serialize_species(species::Species)::Dict{String,Any}
    result = Dict{String,Any}()
    if species.units !== nothing
        result["units"] = species.units
    end
    if species.default !== nothing
        result["default"] = species.default
    end
    if species.default_units !== nothing
        result["default_units"] = species.default_units
    end
    if species.description !== nothing
        result["description"] = species.description
    end
    if species.constant !== nothing
        result["constant"] = species.constant
    end
    return result
end

"""
    serialize_parameter(param::Parameter) -> Dict{String,Any}

Serialize Parameter to JSON-compatible format.
Note: Parameter name is the key in the parameters dictionary, not a property of the Parameter object.
"""
function serialize_parameter(param::Parameter)::Dict{String,Any}
    result = Dict{String,Any}()
    if param.default !== nothing
        result["default"] = param.default
    end
    if param.description !== nothing
        result["description"] = param.description
    end
    if param.units !== nothing
        result["units"] = param.units
    end
    if param.default_units !== nothing
        result["default_units"] = param.default_units
    end
    return result
end

"""
    serialize_reaction(reaction::Reaction) -> Dict{String,Any}

Serialize Reaction to JSON-compatible format.
"""
function serialize_reaction(reaction::Reaction)::Dict{String,Any}
    result = Dict{String,Any}(
        "id" => reaction.id,
        "rate" => serialize_expression(reaction.rate)
    )

    if reaction.name !== nothing
        result["name"] = reaction.name
    end

    # Use getfield to bypass the legacy getproperty override that converts
    # :products into a Dict{String,Int}. We want the raw
    # Vector{StoichiometryEntry} so serialization can emit schema-compliant
    # {species, stoichiometry} objects.
    substrates_raw = getfield(reaction, :substrates)
    if substrates_raw !== nothing
        result["substrates"] = [
            Dict("species" => entry.species, "stoichiometry" => _emit_stoich(entry.stoichiometry))
            for entry in substrates_raw
        ]
    else
        result["substrates"] = nothing
    end

    products_raw = getfield(reaction, :products)
    if products_raw !== nothing
        result["products"] = [
            Dict("species" => entry.species, "stoichiometry" => _emit_stoich(entry.stoichiometry))
            for entry in products_raw
        ]
    else
        result["products"] = nothing
    end

    if reaction.reference !== nothing
        result["reference"] = serialize_reference(reaction.reference)
    end

    return result
end

"""
    serialize_reaction_system(rs::ReactionSystem) -> Dict{String,Any}

Serialize ReactionSystem to JSON-compatible format.
"""
function serialize_reaction_system(rs::ReactionSystem)::Dict{String,Any}
    result = Dict{String,Any}(
        "species" => Dict(s.name => serialize_species(s) for s in rs.species),
        "parameters" => Dict(p.name => serialize_parameter(p) for p in rs.parameters),
        "reactions" => [serialize_reaction(r) for r in rs.reactions]
    )

    if rs.tolerance !== nothing
        result["tolerance"] = serialize_tolerance(rs.tolerance)
    end

    if !isempty(rs.tests)
        result["tests"] = [serialize_test(t) for t in rs.tests]
    end

    return result
end

"""
    serialize_data_loader_source(src::DataLoaderSource) -> Dict{String,Any}
"""
function serialize_data_loader_source(src::DataLoaderSource)::Dict{String,Any}
    result = Dict{String,Any}("url_template" => src.url_template)
    if src.mirrors !== nothing
        result["mirrors"] = src.mirrors
    end
    return result
end

"""
    serialize_data_loader_temporal(t::DataLoaderTemporal) -> Dict{String,Any}
"""
function serialize_data_loader_temporal(t::DataLoaderTemporal)::Dict{String,Any}
    result = Dict{String,Any}()
    t.start !== nothing && (result["start"] = t.start)
    t.stop !== nothing && (result["end"] = t.stop)
    t.file_period !== nothing && (result["file_period"] = t.file_period)
    t.frequency !== nothing && (result["frequency"] = t.frequency)
    t.records_per_file !== nothing && (result["records_per_file"] = t.records_per_file)
    t.time_variable !== nothing && (result["time_variable"] = t.time_variable)
    return result
end

"""
    serialize_data_loader_variable(v::DataLoaderVariable) -> Dict{String,Any}
"""
function serialize_data_loader_variable(v::DataLoaderVariable)::Dict{String,Any}
    result = Dict{String,Any}(
        "file_variable" => v.file_variable,
        "units" => v.units,
    )
    if v.unit_conversion !== nothing
        result["unit_conversion"] = v.unit_conversion isa Number ?
            v.unit_conversion : serialize_expression(v.unit_conversion)
    end
    v.description !== nothing && (result["description"] = v.description)
    v.reference !== nothing && (result["reference"] = serialize_reference(v.reference))
    return result
end

"""
    serialize_data_loader_determinism(d::DataLoaderDeterminism) -> Dict{String,Any}
"""
function serialize_data_loader_determinism(d::DataLoaderDeterminism)::Dict{String,Any}
    result = Dict{String,Any}()
    d.endian !== nothing && (result["endian"] = d.endian)
    d.float_format !== nothing && (result["float_format"] = d.float_format)
    d.integer_width !== nothing && (result["integer_width"] = d.integer_width)
    return result
end

"""
    serialize_data_loader(loader::DataLoader) -> Dict{String,Any}

Serialize DataLoader to JSON-compatible format (STAC-like shape).
"""
function serialize_data_loader(loader::DataLoader)::Dict{String,Any}
    result = Dict{String,Any}(
        "kind" => loader.kind,
        "source" => serialize_data_loader_source(loader.source),
        "variables" => Dict{String,Any}(
            k => serialize_data_loader_variable(v) for (k, v) in loader.variables
        ),
    )
    if loader.temporal !== nothing
        result["temporal"] = serialize_data_loader_temporal(loader.temporal)
    end
    if loader.determinism !== nothing
        det_dict = serialize_data_loader_determinism(loader.determinism)
        isempty(det_dict) || (result["determinism"] = det_dict)
    end
    if loader.reference !== nothing
        result["reference"] = serialize_reference(loader.reference)
    end
    if loader.metadata !== nothing
        result["metadata"] = loader.metadata
    end
    return result
end

# NOTE: `serialize_operator` / `serialize_registered_function` were removed
# along with the `operators` / `registered_functions` emit path (esm-spec
# v0.3.0 §9 closure): `serialize_esm_file` now refuses to write those blocks,
# so the per-entry serializers had no remaining callers. The `Operator` /
# `RegisteredFunction` types themselves remain exported for in-memory use.

"""
    serialize_coupling_entry(entry::CouplingEntry) -> Dict{String,Any}

Serialize CouplingEntry to JSON-compatible format based on concrete type.
"""
function serialize_coupling_entry(entry::CouplingEntry)::Dict{String,Any}
    if entry isa CouplingOperatorCompose
        return serialize_operator_compose(entry)
    elseif entry isa CouplingCouple
        return serialize_couple(entry)
    elseif entry isa CouplingVariableMap
        return serialize_variable_map(entry)
    elseif entry isa CouplingOperatorApply
        return serialize_operator_apply(entry)
    elseif entry isa CouplingCallback
        return serialize_callback(entry)
    elseif entry isa CouplingEvent
        return serialize_event(entry)
    else
        throw(ArgumentError("Unknown CouplingEntry type: $(typeof(entry))"))
    end
end

"""
    serialize_operator_compose(entry::CouplingOperatorCompose) -> Dict{String,Any}

Serialize operator_compose coupling entry.
"""
function serialize_operator_compose(entry::CouplingOperatorCompose)::Dict{String,Any}
    result = Dict{String,Any}("type" => "operator_compose", "systems" => entry.systems)

    if entry.translate !== nothing
        result["translate"] = entry.translate
    end
    if entry.description !== nothing
        result["description"] = entry.description
    end
    if entry.lifting !== nothing
        result["lifting"] = entry.lifting
    end

    return result
end

"""
    serialize_couple(entry::CouplingCouple) -> Dict{String,Any}

Serialize couple coupling entry.
"""
function serialize_couple(entry::CouplingCouple)::Dict{String,Any}
    result = Dict{String,Any}(
        "type" => "couple",
        "systems" => entry.systems,
        "connector" => entry.connector
    )

    if entry.description !== nothing
        result["description"] = entry.description
    end
    if entry.lifting !== nothing
        result["lifting"] = entry.lifting
    end

    return result
end

"""
    serialize_variable_map(entry::CouplingVariableMap) -> Dict{String,Any}

Serialize variable_map coupling entry.
"""
function serialize_variable_map(entry::CouplingVariableMap)::Dict{String,Any}
    # `transform` is a named transform string or an Expression operator node
    # (esm-spec §10.4); expressions round-trip through the standard serializer.
    result = Dict{String,Any}(
        "type" => "variable_map",
        "from" => entry.from,
        "to" => entry.to,
        "transform" => entry.transform isa Expr ?
            serialize_expression(entry.transform) : entry.transform
    )

    if entry.factor !== nothing
        result["factor"] = entry.factor
    end
    if entry.description !== nothing
        result["description"] = entry.description
    end
    if entry.lifting !== nothing
        result["lifting"] = entry.lifting
    end

    return result
end

"""
    serialize_operator_apply(entry::CouplingOperatorApply) -> Dict{String,Any}

Serialize operator_apply coupling entry.
"""
function serialize_operator_apply(entry::CouplingOperatorApply)::Dict{String,Any}
    result = Dict{String,Any}("type" => "operator_apply", "operator" => entry.operator)

    if entry.description !== nothing
        result["description"] = entry.description
    end

    return result
end

"""
    serialize_callback(entry::CouplingCallback) -> Dict{String,Any}

Serialize callback coupling entry.
"""
function serialize_callback(entry::CouplingCallback)::Dict{String,Any}
    result = Dict{String,Any}("type" => "callback", "callback_id" => entry.callback_id)

    if entry.config !== nothing
        result["config"] = entry.config
    end
    if entry.description !== nothing
        result["description"] = entry.description
    end

    return result
end

"""
    serialize_event(entry::CouplingEvent) -> Dict{String,Any}

Serialize event coupling entry.
"""
function serialize_event(entry::CouplingEvent)::Dict{String,Any}
    result = Dict{String,Any}(
        "type" => "event",
        "event_type" => entry.event_type,
        "affects" => [serialize_affect_equation(a) for a in entry.affects]
    )

    if entry.conditions !== nothing
        result["conditions"] = [serialize_expression(c) for c in entry.conditions]
    end
    if entry.trigger !== nothing
        result["trigger"] = serialize_trigger(entry.trigger)
    end
    if entry.affect_neg !== nothing
        result["affect_neg"] = [serialize_affect_equation(a) for a in entry.affect_neg]
    end
    if entry.discrete_parameters !== nothing
        result["discrete_parameters"] = entry.discrete_parameters
    end
    if entry.root_find !== nothing
        result["root_find"] = entry.root_find
    end
    if entry.reinitialize !== nothing
        result["reinitialize"] = entry.reinitialize
    end
    if entry.description !== nothing
        result["description"] = entry.description
    end

    return result
end

"""
    serialize_reference(ref::Reference) -> Dict{String,Any}

Serialize Reference to JSON-compatible format.
"""
function serialize_reference(ref::Reference)::Dict{String,Any}
    result = Dict{String,Any}()
    if ref.doi !== nothing
        result["doi"] = ref.doi
    end
    if ref.citation !== nothing
        result["citation"] = ref.citation
    end
    if ref.url !== nothing
        result["url"] = ref.url
    end
    if ref.notes !== nothing
        result["notes"] = ref.notes
    end
    return result
end

"""
    serialize_metadata(metadata::Metadata) -> Dict{String,Any}

Serialize Metadata to JSON-compatible format.
"""
function serialize_metadata(metadata::Metadata)::Dict{String,Any}
    result = Dict{String,Any}("name" => metadata.name)

    if metadata.description !== nothing
        result["description"] = metadata.description
    end
    if !isempty(metadata.authors)
        result["authors"] = metadata.authors
    end
    if metadata.license !== nothing
        result["license"] = metadata.license
    end
    if metadata.created !== nothing
        result["created"] = metadata.created
    end
    if metadata.modified !== nothing
        result["modified"] = metadata.modified
    end
    if !isempty(metadata.tags)
        result["tags"] = metadata.tags
    end
    if !isempty(metadata.references)
        result["references"] = [serialize_reference(r) for r in metadata.references]
    end

    return result
end

"""
    serialize_domain(domain::Domain) -> Dict{String,Any}

Serialize Domain to JSON-compatible format.
"""
function serialize_domain(domain::Domain)::Dict{String,Any}
    result = Dict{String,Any}()
    if domain.temporal !== nothing
        result["temporal"] = domain.temporal
    end
    return result
end

"""
    serialize_esm_file(file::EsmFile) -> Dict{String,Any}

Serialize EsmFile to JSON-compatible format.
"""
function serialize_esm_file(file::EsmFile)::Dict{String,Any}
    result = Dict{String,Any}(
        "esm" => file.esm,
        "metadata" => serialize_metadata(file.metadata)
    )

    if file.models !== nothing
        result["models"] = Dict(k => serialize_model(v) for (k, v) in file.models)
    end
    if file.reaction_systems !== nothing
        result["reaction_systems"] = Dict(k => serialize_reaction_system(v) for (k, v) in file.reaction_systems)
    end
    if file.data_loaders !== nothing
        result["data_loaders"] = Dict(k => serialize_data_loader(v) for (k, v) in file.data_loaders)
    end
    # The top-level `operators` / `registered_functions` blocks were removed
    # in esm-spec v0.3.0 (§9 closure) and `load` rejects them as hard errors,
    # so emitting them would produce a file parse refuses. The typed fields
    # remain on `EsmFile` (legacy in-memory use), but they cannot reach the
    # wire: refuse loudly instead of writing an unloadable document.
    if file.operators !== nothing && !isempty(file.operators)
        throw(ArgumentError("`operators` cannot be serialized: the top-level " *
                            "`operators` block was removed in esm-spec v0.3.0 " *
                            "(§9 closure) and `load` rejects it. Migrate per " *
                            "`docs/rfcs/closed-function-registry.md` §6."))
    end
    if file.registered_functions !== nothing && !isempty(file.registered_functions)
        throw(ArgumentError("`registered_functions` cannot be serialized: the " *
                            "block was removed in esm-spec v0.3.0 (§9 closure). " *
                            "Use the closed function registry via `fn` ops with " *
                            "spec-defined names."))
    end
    if file.enums !== nothing
        # esm-spec §9.3 — enum names map to objects mapping symbol → positive
        # integer. The on-wire shape is the parsed shape unchanged.
        result["enums"] = Dict{String,Any}(
            k => Dict{String,Int}(s => i for (s, i) in v) for (k, v) in file.enums)
    end
    if file.function_tables !== nothing
        # esm-spec §9.5 — sampled function tables (v0.4.0). Tables are
        # first-class authored constructs; round-trip MUST preserve the
        # authored form (no auto-promotion of inline-const lookups).
        result["function_tables"] = Dict{String,Any}(
            k => serialize_function_table(v) for (k, v) in file.function_tables)
    end
    if !isempty(file.coupling)
        result["coupling"] = [serialize_coupling_entry(c) for c in file.coupling]
    end
    if file.domain !== nothing
        result["domain"] = serialize_domain(file.domain)
    end
    # Document-scoped index-set registry (RFC semiring-faq-unified-ir §5.2;
    # esm-spec v0.8.0) — serialized at the top level, a sibling of `models`.
    if !isempty(file.index_sets)
        result["index_sets"] = Dict{String,Any}(
            k => serialize_index_set(v) for (k, v) in file.index_sets)
    end

    return result
end

"""
    serialize_function_table(ft::FunctionTable) -> Dict{String,Any}

Serialize a [`FunctionTable`](@ref) (esm-spec §9.5) back to a JSON-compatible
dict. Tables are first-class authored constructs; no auto-promotion or
demotion of inline-const lookups happens at serialize time.
"""
function serialize_function_table(ft::FunctionTable)::Dict{String,Any}
    result = Dict{String,Any}(
        "axes" => [serialize_function_table_axis(ax) for ax in ft.axes],
        "data" => ft.data,
    )
    if ft.description !== nothing
        result["description"] = ft.description
    end
    if ft.interpolation !== nothing
        result["interpolation"] = ft.interpolation
    end
    if ft.out_of_bounds !== nothing
        result["out_of_bounds"] = ft.out_of_bounds
    end
    if ft.outputs !== nothing
        result["outputs"] = ft.outputs
    end
    if ft.shape !== nothing
        result["shape"] = ft.shape
    end
    if ft.schema_version !== nothing
        result["schema_version"] = ft.schema_version
    end
    return result
end

function serialize_function_table_axis(ax::FunctionTableAxis)::Dict{String,Any}
    result = Dict{String,Any}(
        "name" => ax.name,
        "values" => ax.values,
    )
    if ax.units !== nothing
        result["units"] = ax.units
    end
    return result
end

"""
    save(file::EsmFile, path::String)
    save(path::String, file::EsmFile)

Save an EsmFile object to a JSON file at the specified path.
Accepts either argument order for ergonomics (file, path) or (path, file).
"""
function save(file::EsmFile, path::String)
    open(path, "w") do io
        save(file, io)
    end
end

save(path::String, file::EsmFile) = save(file, path)

"""
    save(file::EsmFile, io::IO)

Save an EsmFile object to a JSON stream.
"""
function save(file::EsmFile, io::IO)
    serialized = serialize_esm_file(file)
    write(io, JSON3.write(serialized, indent=2))
end