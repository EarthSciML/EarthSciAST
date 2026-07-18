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
    return [x isa ASTExpr ? serialize_expression(x) : x for x in v]
end


# Wire encoding for one optional `OpExpr` field, DRIVEN BY the field's `kind`
# in `OPEXPR_FIELD_TABLE` (types.jl) — the same column the parse extraction
# and the expression walkers derive from:
#
# - `:expr` (`lower`/`upper`/`expr_body`/`filter`/`key`): nested expression
#   trees (`expr_body` lives under the JSON key "expr"; `key` is the
#   value-invention producer's emitted skolem/tuple expression, RFC §5.5/§6.1).
# - `:expr_vec` (`values`): one nested expression per `regions` entry.
# - `:expr_map` (`table_axes`, `bindings`): expression-valued maps — the
#   table_lookup per-axis inputs (JSON key "axes", esm-spec §9.5) and the
#   expression-template parameter → argument map.
# - `:ranges`: dense integer/expression tuples or index-set reference objects
#   (`_serialize_range_value`, RFC §5.2).
# - `:join` (M2, RFC §5.3 / §7.2): round-trips back to the wire clause form
#   `[{ "on": [[left, right], …] }, …]`.
# - `:scalar`: identity-encoded JSON scalars/arrays (`output` is preserved
#   verbatim, Int or String).
function _serialize_opexpr_field(field::Symbol, v)
    kind = getproperty(OPEXPR_FIELD_TABLE, field).kind
    if kind === :expr
        return serialize_expression(v)
    elseif kind === :expr_vec
        return [serialize_expression(x) for x in v]
    elseif kind === :ranges
        return Dict{String,Any}(k => _serialize_range_value(x) for (k, x) in v)
    elseif kind === :expr_map
        return Dict{String,Any}(k => serialize_expression(x) for (k, x) in v)
    elseif kind === :join
        return [Dict{String,Any}("on" => [[p[1], p[2]] for p in clause])
                for clause in v]
    else
        return v
    end
end

"""
    serialize_expression(expr::ASTExpr) -> Any

Serialize an Expression to JSON-compatible format.
Handles the union type discrimination.
"""
function serialize_expression(expr::ASTExpr)
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
        # The optional-field portion is DRIVEN BY `OPEXPR_WIRE_KEYS` (types.jl,
        # derived from `OPEXPR_FIELD_TABLE`), the single OpExpr field ↔ wire-key
        # contract, so a newly added struct
        # field cannot be forgotten here: once it joins the table it is emitted
        # under its wire key (identity-encoded unless `_serialize_opexpr_field`
        # gives it a bespoke encoding), and `round_trip_regression_test.jl`
        # pins the wire form field-by-field. Every optional field is emitted
        # only when present (`!== nothing`) so nodes round-trip
        # byte-identically; `join_gates` — the build-time resolved join — is
        # deliberately absent from the table and is never serialized.
        result = Dict{String,Any}(
            "op" => expr.op,
            "args" => [serialize_expression(arg) for arg in expr.args]
        )
        for (field, wire_key) in pairs(OPEXPR_WIRE_KEYS)
            (field === :op || field === :args) && continue
            v = getfield(expr, field)
            v === nothing && continue
            result[string(wire_key)] = _serialize_opexpr_field(field, v)
        end
        return result
    else
        throw(ArgumentError("Unknown expression type: $(typeof(expr))"))
    end
end

"""
    serialize_model_variable_type(var_type::ModelVariableType) -> String

Serialize ModelVariableType enum to its canonical wire spelling, per
[`MODEL_VARIABLE_TYPE_TABLE`](@ref) (types.jl — the derived
`_MODEL_VARIABLE_TYPE_WIRE` lookup).
"""
function serialize_model_variable_type(var_type::ModelVariableType)::String
    s = get(_MODEL_VARIABLE_TYPE_WIRE, var_type, nothing)
    s === nothing && throw(ArgumentError("Unknown ModelVariableType: $(var_type)"))
    return s
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

    # Raw ordered Vector{StoichiometryEntry} (not the legacy Dict property
    # view) so serialization emits schema-compliant {species, stoichiometry}
    # objects in author order.
    substrates_raw = raw_substrates(reaction)
    if substrates_raw !== nothing
        result["substrates"] = [
            Dict("species" => entry.species, "stoichiometry" => _emit_stoich(entry.stoichiometry))
            for entry in substrates_raw
        ]
    else
        result["substrates"] = nothing
    end

    products_raw = raw_products(reaction)
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
        return serialize_coupling_event(entry)
    elseif entry isa CouplingImport
        return serialize_coupling_import(entry)
    else
        throw(ArgumentError("Unknown CouplingEntry type: $(typeof(entry))"))
    end
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
        "transform" => entry.transform isa ASTExpr ?
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

    # The top-level `expression_templates` registry and `metaparameters` block,
    # written back VERBATIM. Option A expands call sites; it does not delete
    # declarations (§9.6.4 rule 5). Dropping these emitted a pure template
    # library as `{esm, metadata, index_sets}` — no payload key — which the
    # top-level `anyOf` rejects, making a conforming library file unrepresentable
    # once loaded. A library must round-trip to itself.
    if file.expression_templates !== nothing && !isempty(file.expression_templates)
        result["expression_templates"] = file.expression_templates
    end
    if file.metaparameters !== nothing && !isempty(file.metaparameters)
        result["metaparameters"] = file.metaparameters
    end

    # esm-spec §9.6.4 rule 5 (Option B): re-inject each component's MATERIALIZED
    # `expression_templates` registry so `save(EsmFile)` emits the
    # reference-preserving form byte-identically to the raw `emit_document` path.
    # The component's surviving `apply_expression_template` references already
    # round-tripped through `serialize_expression` (call sites verbatim); these
    # blocks supply the referenced template bodies (authored-first, then
    # materialized-lexicographic). Keyed "<compkind>.<cname>".
    if file.component_templates !== nothing
        for (key, block) in file.component_templates
            parts = split(key, "."; limit=2)
            length(parts) == 2 || continue
            compkind, cname = String(parts[1]), String(parts[2])
            haskey(result, compkind) || continue
            comp = result[compkind]
            (comp isa AbstractDict && haskey(comp, cname)) || continue
            comp[cname]["expression_templates"] = block
        end
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

Save an EsmFile object to a JSON file at the specified path. Argument order is
data-first (`save(file, path)`), matching `write(io, x)` and the `save(file, io)`
stream method below.
"""
function save(file::EsmFile, path::String)
    open(path, "w") do io
        save(file, io)
    end
end

"""
    save(file::EsmFile, io::IO)

Save an EsmFile object to a JSON stream.
"""
function save(file::EsmFile, io::IO)
    serialized = serialize_esm_file(file)
    if file.component_templates !== nothing
        # esm-spec §9.6.4 rule 5 (Option B): a document carrying surviving
        # references / materialized registries emits in the canonical
        # reference-preserving byte form — keys sorted except the ordered
        # `expression_templates` blocks — byte-identical to the raw
        # `emit_document` path. Other documents keep the historical JSON3 form.
        write(io, emit_esm_string(serialized))
    else
        write(io, JSON3.write(serialized, indent=2))
    end
end
# ========================================
# Table-generated record serializers
# ========================================
#
# One `serialize_<fn>` per `RECORD_FIELD_TABLES` entry (types.jl — the shared
# per-type field tables; the parse direction is generated from the SAME table
# in parse.jl). Each generated serializer emits one wire key per row, in table
# order, honoring the row's omission policy (`emit` column); a coupling
# entry's `tag` emits its `"type"` discriminator first. JSON object equality
# — the round-trip contract — is key-order agnostic, so table order is the
# one emission order. `:custom` rows name hand-written whole-struct hooks
# (returning `nothing` to skip the key) for the cross-field policies.

# Serialize-side wire encoding for one table row: returns the expression
# encoding `v` (the struct field's value) per the row's `kind`. Kinds without
# a case are identity-encoded JSON scalars / arrays / verbatim values.
function _record_emit_expr(row, v)
    kind = row.kind
    if kind === :expr
        :(serialize_expression($v))
    elseif kind === :expr_vec
        :([serialize_expression(x) for x in $v])
    elseif kind === :number_or_expr
        :(let x = $v; x isa Number ? x : serialize_expression(x) end)
    elseif kind === :float_map
        :(Dict{String,Any}(k => x for (k, x) in $v))
    elseif kind === :raw_vec
        :([_to_native_json(e) for e in $v])
    elseif kind === :model_variable_type
        :(serialize_model_variable_type($v))
    elseif kind === :record
        :($(Symbol(:serialize_, row.of))($v))
    elseif kind === :record_vec
        :([$(Symbol(:serialize_, row.of))(x) for x in $v])
    elseif kind === :record_map
        :(Dict{String,Any}(k => $(Symbol(:serialize_, row.of))(x) for (k, x) in $v))
    else
        v
    end
end

# ── Hand-written `:custom` emit hooks (cross-field / doubly-conditional
# omission policies the table names by symbol; `nothing` skips the key) ──────

# DataLoader.determinism: emitted only when present AND its serialized dict is
# non-empty (the historical `isempty(det_dict) ||` guard).
function _emit_data_loader_determinism(loader::DataLoader)
    loader.determinism === nothing && return nothing
    det = serialize_data_loader_determinism(loader.determinism)
    return isempty(det) ? nothing : det
end

# coupling_import `bind`: always emitted (an empty bind map round-trips as {}).
_emit_coupling_import_bind(entry::CouplingImport) = Dict{String,Any}(entry.bind)

# index_sets `members`: `members_raw` — the originally-typed values — is what
# round-trips back to the wire `members` key when present (mirroring
# `_coerce_index_set_members_raw`); the stringified `members` view emits
# otherwise; a set carrying neither omits the key.
_emit_index_set_members(is::IndexSet) =
    is.members_raw !== nothing ? is.members_raw : is.members


# Model `subsystems`: emitted when non-empty; each entry dispatches on its
# §4.7 union arm (`_serialize_subsystem`).
_emit_model_subsystems(m::Model) = isempty(m.subsystems) ? nothing :
    Dict{String,Any}(k => _serialize_subsystem(v) for (k, v) in m.subsystems)

# Model `guesses`: number-or-Expression map (gt-ebuq).
function _emit_model_guesses(m::Model)
    isempty(m.guesses) && return nothing
    out = Dict{String,Any}()
    for (k, v) in m.guesses
        out[k] = v isa ASTExpr ? serialize_expression(v) : v
    end
    return out
end


# DiscreteEvent `affects` / `functional_affect` — the schema oneOf pair.
# A handler-based event yields the affects key to its descriptor; the
# descriptor hook re-emits it verbatim and refuses an event carrying both.
_emit_discrete_event_affects(e::DiscreteEvent) =
    e.functional_affect === nothing ?
        [serialize_affect_equation(a) for a in e.affects] : nothing

function _emit_discrete_event_functional_affect(e::DiscreteEvent)
    e.functional_affect === nothing && return nothing
    isempty(e.affects) || throw(ArgumentError(
        "DiscreteEvent cannot carry both symbolic `affects` and a " *
        "`functional_affect` descriptor (schema DiscreteEvent oneOf)"))
    return e.functional_affect
end

# Assertion `reference`: an Expression AST serializes through the standard
# serializer; the from_file shape round-trips its keys verbatim.
function _emit_assertion_reference(a::Assertion)
    a.reference === nothing && return nothing
    if a.reference isa ASTExpr
        return serialize_expression(a.reference)
    elseif a.reference isa AbstractDict
        ref_out = Dict{String,Any}()
        for (k, v) in a.reference
            ref_out[string(k)] = v
        end
        return ref_out
    end
    return a.reference
end


# One emit statement per row, per the row's `emit` omission policy; `nothing`
# for a `:never` (parse-only) row.
function _record_emit_stmt(row)
    w = row.wire
    f = row.f
    emit = row.emit
    if emit === :never
        nothing
    elseif emit === :always
        :(result[$w] = $(_record_emit_expr(row, :(x.$f))))
    elseif emit === :nonnothing
        :(let v = x.$f
              v === nothing || (result[$w] = $(_record_emit_expr(row, :v)))
          end)
    elseif emit === :nonempty
        :(isempty(x.$f) || (result[$w] = $(_record_emit_expr(row, :(x.$f)))))
    elseif emit === :nondefault
        :(x.$f == $(row.default) || (result[$w] = $(_record_emit_expr(row, :(x.$f)))))
    elseif emit === :custom
        :(let v = $(row.emit_fn)(x)
              v === nothing || (result[$w] = v)
          end)
    else
        error("RECORD_FIELD_TABLES: unknown emit policy $(emit) for field $(row.f)")
    end
end

# GENERATED serializers: one per table entry, named `serialize_<fn>`.
for spec in RECORD_FIELD_TABLES
    sname = Symbol(:serialize_, spec.fn)
    stmts = Any[]
    tag = get(spec, :tag, nothing)
    tag === nothing || push!(stmts, :(result["type"] = $tag))
    for row in spec.rows
        s = _record_emit_stmt(row)
        s === nothing || push!(stmts, s)
    end
    @eval function $sname(x::$(spec.T))::Dict{String,Any}
        result = Dict{String,Any}()
        $(stmts...)
        return result
    end
    @eval @doc $("""
        serialize_$(spec.fn)(x::$(spec.T)) -> Dict{String,Any}

    Serialize `$(spec.T)` to its JSON-compatible wire form. GENERATED from
    `RECORD_FIELD_TABLES` (types.jl); the parse direction is generated from
    the same table in parse.jl.
    """) $sname
end
