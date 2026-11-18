# The Typst math of an expression or an equation for messages and `show`
# (`print_math` under the names it uses). A typed expression is serialized to
# its JSON form first.
function _math_text(x)
    v = x isa Equation ? Dict{String, Any}("lhs" => serialize_expression(x.lhs), "rhs" => serialize_expression(x.rhs)) :
        x isa ASTExpr ? serialize_expression(x) : x
    return print_math(v, expression_names(v), :typst)
end

# `show` of an expression or an equation: its Typst math. An expression the
# printer cannot take (e.g. a malformed node built by hand) shows as its JSON
# form, so a `show` inside an error message never throws in turn.
function _show_math(io::IO, x)
    text = try
        _math_text(x)
    catch err
        err isa InterruptException && rethrow()
        v = x isa Equation ? Dict("lhs" => serialize_expression(x.lhs), "rhs" => serialize_expression(x.rhs)) :
            serialize_expression(x)
        JSON3.write(v)
    end
    return print(io, text)
end

Base.show(io::IO, expr::ASTExpr) = _show_math(io, expr)
Base.show(io::IO, eq::Equation) = _show_math(io, eq)

# `show` of the component types: the two-argument form is a one-line summary
# (used inside reprs and collections); the `text/plain` form lists the
# component's declarations, with every expression in its Typst math.

_math_string(x) = sprint(_show_math, x)

function Base.show(io::IO, model::Model)
    return print(
        io, "Model(", length(model.variables), " variables, ",
        length(model.equations), " equations)"
    )
end

function Base.show(io::IO, ::MIME"text/plain", model::Model)
    println(io, "Model:")
    println(io, "  Variables ($(length(model.variables))):")
    for (name, var) in model.variables
        print(io, "    ", name, ": ", _variable_type_word(var.type))
        isnothing(var.default) || print(io, " = ", var.default)
        isnothing(var.units) || print(io, " [", var.units, "]")
        isnothing(var.description) || print(io, " - ", var.description)
        println(io)
        if !isnothing(var.update)
            println(io, "      update: ", join((r.kind for r in var.update), ", "))
        end
    end
    println(io, "  Equations ($(length(model.equations))):")
    for (i, eq) in enumerate(model.equations)
        println(io, "    ", i, ". ", _math_string(eq))
    end
    _show_events(io, model.discrete_events, model.continuous_events)
    return _show_subsystem_names(io, model.subsystems)
end

function Base.show(io::IO, rs::ReactionSystem)
    return print(
        io, "ReactionSystem(", length(rs.species), " species, ",
        length(rs.reactions), " reactions)"
    )
end

# One side of a reaction in chemical notation, in author order: `2A + B`,
# `∅` for an empty side.
function _show_reaction_side(entries::Union{Vector{StoichiometryEntry}, Nothing})
    (entries === nothing || isempty(entries)) && return "∅"
    coefficient(c) = c == 1 ? "" : isinteger(c) ? string(Int(c)) : string(c)
    return join((coefficient(e.stoichiometry) * e.species for e in entries), " + ")
end

function Base.show(io::IO, ::MIME"text/plain", rs::ReactionSystem)
    println(io, "ReactionSystem:")
    println(io, "  Species ($(length(rs.species))):")
    for species in rs.species
        print(io, "    ", species.name)
        isnothing(species.units) || print(io, " [", species.units, "]")
        isnothing(species.default) || print(io, " = ", species.default)
        isnothing(species.description) || print(io, " - ", species.description)
        println(io)
    end
    println(io, "  Parameters ($(length(rs.parameters))):")
    for param in rs.parameters
        print(io, "    ", param.name, " = ", isnothing(param.default) ? "unset" : param.default)
        isnothing(param.units) || print(io, " [", param.units, "]")
        isnothing(param.description) || print(io, " - ", param.description)
        println(io)
    end
    println(io, "  Reactions ($(length(rs.reactions))):")
    for (i, reaction) in enumerate(rs.reactions)
        print(
            io, "    ", i, ". ", _show_reaction_side(raw_substrates(reaction)), " → ",
            _show_reaction_side(raw_products(reaction))
        )
        isnothing(reaction.rate) || print(io, "  [rate: ", _math_string(reaction.rate), "]")
        println(io)
    end
    _show_events(io, rs.discrete_events, rs.continuous_events)
    return _show_subsystem_names(io, rs.subsystems)
end

function Base.show(io::IO, esm_file::EsmFile)
    return print(io, "EsmFile(v", esm_file.esm, ", \"", esm_file.metadata.name, "\")")
end

function Base.show(io::IO, ::MIME"text/plain", esm_file::EsmFile)
    md = esm_file.metadata
    println(io, "ESM v", esm_file.esm, ": ", md.name)
    isnothing(md.description) || println(io, "Description: ", md.description)
    isempty(md.authors) || println(io, "Authors: ", join(md.authors, ", "))
    isnothing(md.license) || println(io, "License: ", md.license)
    isempty(md.tags) || println(io, "Tags: ", join(md.tags, ", "))
    for (label, section) in (
            ("Models", esm_file.models),
            ("Reaction systems", esm_file.reaction_systems),
            ("Data sources", esm_file.data_sources),
        )
        (isnothing(section) || isempty(section)) && continue
        println(io, label, " (", length(section), "): ", join(keys(section), ", "))
    end
    isempty(esm_file.coupling) || println(io, "Coupling entries: ", length(esm_file.coupling))
    isnothing(esm_file.domain) || println(io, "Domain: configured")
    return nothing
end

function _show_events(io::IO, discrete, continuous)
    affects(as) = join((string(a.lhs, " = ", _math_string(a.rhs)) for a in as), ", ")
    if !isempty(discrete)
        println(io, "  Discrete events ($(length(discrete))):")
        for (i, event) in enumerate(discrete)
            t = event.trigger
            trigger = t isa ConditionTrigger ? "when " * _math_string(t.expression) :
                t isa PeriodicTrigger ? "every $(t.period) s" :
                t isa PresetTimesTrigger ? "at times [" * join(t.times, ", ") * "]" :
                string(nameof(typeof(t)))
            println(io, "    ", i, ". ", trigger, ": ", affects(event.affects))
        end
    end
    if !isempty(continuous)
        println(io, "  Continuous events ($(length(continuous))):")
        for (i, event) in enumerate(continuous)
            conditions = join((_math_string(c) for c in event.conditions), ", ")
            println(io, "    ", i, ". when [", conditions, "] → [", affects(event.affects), "]")
        end
    end
    return nothing
end

function _show_subsystem_names(io::IO, subsystems)
    isempty(subsystems) || println(io, "  Subsystems ($(length(subsystems))): ", join(keys(subsystems), ", "))
    return nothing
end
