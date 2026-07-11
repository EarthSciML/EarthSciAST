"""
Editing operations for ESM format structures.

This module implements all editing operations specified in ESM Libraries Spec Section 4,
including variable operations, equation operations, reaction operations, event operations,
coupling operations, and model-level operations.

All operations are non-mutating: they return a new structure. Operations that
cannot be applied (missing target, out-of-bounds index, unmatched pattern)
throw [`EditError`](@ref) instead of silently returning the input unchanged.
"""

"""
    EditError(msg)

Exception thrown when an editing operation cannot be applied — e.g. removing
a variable, equation, reaction, event, or coupling entry that does not exist,
or extracting a missing component. Throwing (rather than warning and
returning the input unchanged) makes failed edits visible programmatically.
"""
struct EditError <: Exception
    msg::String
end

Base.showerror(io::IO, e::EditError) = print(io, "EditError: ", e.msg)

# ----------------------------------------------------------------------------
# Copy-with-changes helpers
#
# Editing operations rebuild immutable structs. Routing every rebuild through
# these helpers (instead of spelling out constructor arguments at each site)
# means newly added struct fields are carried over automatically instead of
# being silently dropped/reset. Private to edit.jl.
# ----------------------------------------------------------------------------

function _rebuild(model::Model;
                  variables = model.variables,
                  equations = model.equations,
                  discrete_events = model.discrete_events,
                  continuous_events = model.continuous_events,
                  subsystems = model.subsystems)
    return Model(
        variables, equations, discrete_events, continuous_events, subsystems;
        tolerance = model.tolerance,
        tests = model.tests,
        initialization_equations = model.initialization_equations,
        guesses = model.guesses,
        system_kind = model.system_kind,
    )
end

function _rebuild(system::ReactionSystem;
                  species = system.species,
                  reactions = system.reactions)
    return ReactionSystem(
        species, reactions;
        parameters = system.parameters,
        subsystems = system.subsystems,
        tolerance = system.tolerance,
        tests = system.tests,
    )
end

function _rebuild(file::EsmFile;
                  esm = file.esm,
                  metadata = file.metadata,
                  models = file.models,
                  reaction_systems = file.reaction_systems,
                  data_loaders = file.data_loaders,
                  coupling = file.coupling,
                  domain = file.domain)
    return EsmFile(
        esm, metadata;
        models = models,
        reaction_systems = reaction_systems,
        data_loaders = data_loaders,
        coupling = coupling,
        domain = domain,
        enums = file.enums,
        function_tables = file.function_tables,
        index_sets = file.index_sets,
    )
end

# Variable operations (Section 4.1)

"""
    add_variable(model::Model, name::String, variable::ModelVariable) -> Model

Add a new variable to a model.

Creates a new model with the additional variable. Warns if variable already exists.
"""
function add_variable(model::Model, name::String, variable::ModelVariable)::Model
    new_variables = copy(model.variables)

    if haskey(new_variables, name)
        @warn "Variable '$name' already exists, replacing"
    end

    new_variables[name] = variable

    return _rebuild(model; variables=new_variables)
end

"""
    remove_variable(model::Model, name::String) -> Model

Remove a variable from a model.

Creates a new model without the specified variable. Warns about dependencies
but does not automatically update equations that reference the variable.
Throws [`EditError`](@ref) if the variable does not exist.
"""
function remove_variable(model::Model, name::String)::Model
    new_variables = copy(model.variables)

    if !haskey(new_variables, name)
        throw(EditError("Variable '$name' does not exist"))
    end

    # Check for dependencies
    dependent_equations = Int[]
    for (i, eq) in enumerate(model.equations)
        lhs_vars = free_variables(eq.lhs)
        rhs_vars = free_variables(eq.rhs)
        if name in lhs_vars || name in rhs_vars
            push!(dependent_equations, i)
        end
    end

    if !isempty(dependent_equations)
        @warn "Variable '$name' is used in equations: $dependent_equations. These equations may become invalid."
    end

    delete!(new_variables, name)

    return _rebuild(model; variables=new_variables)
end

"""
    rename_variable(model::Model, old_name::String, new_name::String) -> Model

Rename a variable throughout the model.

Updates the variable definition and all references in equations.
Throws [`EditError`](@ref) if `old_name` does not exist.
"""
function rename_variable(model::Model, old_name::String, new_name::String)::Model
    if !haskey(model.variables, old_name)
        throw(EditError("Variable '$old_name' does not exist"))
    end

    if haskey(model.variables, new_name)
        @warn "Variable '$new_name' already exists, this will replace it"
    end

    # Update variables dictionary
    new_variables = copy(model.variables)
    variable = new_variables[old_name]
    delete!(new_variables, old_name)
    new_variables[new_name] = variable

    # Update equations
    substitution = Dict{String, Expr}(old_name => VarExpr(new_name))
    new_equations = [
        Equation(
            substitute(eq.lhs, substitution),
            substitute(eq.rhs, substitution)
        )
        for eq in model.equations
    ]

    return _rebuild(model; variables=new_variables, equations=new_equations)
end

# Equation operations (Section 4.2)

"""
    add_equation(model::Model, equation::Equation) -> Model

Add a new equation to a model.

Appends the equation to the end of the equations list.
"""
function add_equation(model::Model, equation::Equation)::Model
    new_equations = copy(model.equations)
    push!(new_equations, equation)

    return _rebuild(model; equations=new_equations)
end

"""
    remove_equation(model::Model, index::Int) -> Model
    remove_equation(model::Model, lhs_pattern::Expr) -> Model

Remove an equation from a model.

Can remove by index (1-based) or by matching the left-hand side expression.
Throws [`EditError`](@ref) if the index is out of bounds or no equation
matches the pattern.
"""
function remove_equation(model::Model, index::Int)::Model
    if index < 1 || index > length(model.equations)
        throw(EditError("Equation index $index out of bounds (1-$(length(model.equations)))"))
    end

    new_equations = copy(model.equations)
    deleteat!(new_equations, index)

    return _rebuild(model; equations=new_equations)
end

function remove_equation(model::Model, lhs_pattern::Expr)::Model
    # Find equation with matching LHS
    for (i, eq) in enumerate(model.equations)
        if eq.lhs == lhs_pattern  # This requires Expr equality to be defined
            return remove_equation(model, i)
        end
    end

    throw(EditError("No equation found with LHS matching: $lhs_pattern"))
end

"""
    substitute_in_equations(model::Model, bindings::Dict{String, Expr}) -> Model

Apply substitutions across all equations in a model.

Replaces variables according to the bindings dictionary.
"""
function substitute_in_equations(model::Model, bindings::Dict{String, Expr})::Model
    new_equations = [
        Equation(
            substitute(eq.lhs, bindings),
            substitute(eq.rhs, bindings)
        )
        for eq in model.equations
    ]

    return _rebuild(model; equations=new_equations)
end

# Reaction operations (Section 4.3)

"""
    add_reaction(system::ReactionSystem, reaction::Reaction) -> ReactionSystem

Add a new reaction to a reaction system.
"""
function add_reaction(system::ReactionSystem, reaction::Reaction)::ReactionSystem
    new_reactions = copy(system.reactions)
    push!(new_reactions, reaction)

    return _rebuild(system; reactions=new_reactions)
end

"""
    remove_reaction(system::ReactionSystem, id::String) -> ReactionSystem

Remove a reaction by its ID.

Throws [`EditError`](@ref) if no reaction has the given ID.
"""
function remove_reaction(system::ReactionSystem, id::String)::ReactionSystem
    new_reactions = filter(r -> r.id != id, system.reactions)

    if length(new_reactions) == length(system.reactions)
        throw(EditError("No reaction found with id: $id"))
    end

    return _rebuild(system; reactions=new_reactions)
end

"""
    add_species(system::ReactionSystem, name::String, species::Species) -> ReactionSystem

Add a new species to a reaction system.
"""
function add_species(system::ReactionSystem, name::String, species::Species)::ReactionSystem
    new_species = copy(system.species)

    # Check if species already exists
    for existing in new_species
        if existing.name == name
            @warn "Species '$name' already exists, replacing"
            # Remove the existing one
            filter!(s -> s.name != name, new_species)
            break
        end
    end

    push!(new_species, species)

    return _rebuild(system; species=new_species)
end

"""
    remove_species(system::ReactionSystem, name::String) -> ReactionSystem

Remove a species from a reaction system.

Warns about dependent reactions but does not automatically update them.
Throws [`EditError`](@ref) if the species does not exist.
"""
function remove_species(system::ReactionSystem, name::String)::ReactionSystem
    if !any(s -> s.name == name, system.species)
        throw(EditError("Species '$name' not found"))
    end

    # Check for dependencies via the unordered Dict{String,Float64} views
    # (`get_reactants_dict` / `get_products_dict`) intentionally: this is a
    # species-membership test (`haskey`), which is exactly the Dict view's
    # semantics; the ordered `raw_substrates`/`raw_products` entry vectors
    # offer nothing extra.
    dependent_reactions = Int[]
    for (i, reaction) in enumerate(system.reactions)
        if haskey(get_reactants_dict(reaction), name) || haskey(get_products_dict(reaction), name)
            push!(dependent_reactions, i)
        end
    end

    if !isempty(dependent_reactions)
        @warn "Species '$name' is used in reactions: $dependent_reactions. These reactions may become invalid."
    end

    # Remove species
    new_species = filter(s -> s.name != name, system.species)

    return _rebuild(system; species=new_species)
end

# Event operations (Section 4.4)

"""
    add_continuous_event(model::Model, event::ContinuousEvent) -> Model

Add a continuous event to a model.
"""
function add_continuous_event(model::Model, event::ContinuousEvent)::Model
    new_events = copy(model.continuous_events)
    push!(new_events, event)

    return _rebuild(model; continuous_events=new_events)
end

"""
    add_discrete_event(model::Model, event::DiscreteEvent) -> Model

Add a discrete event to a model.
"""
function add_discrete_event(model::Model, event::DiscreteEvent)::Model
    new_events = copy(model.discrete_events)
    push!(new_events, event)

    return _rebuild(model; discrete_events=new_events)
end

"""
    remove_event(model::Model, description::String) -> Model

Remove events whose `description` field equals `description` from a model.

Events carry no dedicated identifier in the ESM schema, so the `description`
string is the only name-like field available and is used as the match key.
Searches both continuous and discrete events. Throws [`EditError`](@ref) if
no event matches.
"""
function remove_event(model::Model, description::String)::Model
    # Remove from continuous events
    continuous_events = model.continuous_events
    new_continuous = filter(e -> (e.description !== nothing ? e.description : "") != description, continuous_events)

    # Remove from discrete events
    discrete_events = model.discrete_events
    new_discrete = filter(e -> (e.description !== nothing ? e.description : "") != description, discrete_events)

    if length(new_continuous) == length(continuous_events) &&
       length(new_discrete) == length(discrete_events)
        throw(EditError("Event with description '$description' not found"))
    end

    return _rebuild(model; discrete_events=new_discrete, continuous_events=new_continuous)
end

# Coupling operations (Section 4.5)

"""
    add_coupling(file::EsmFile, entry::CouplingEntry) -> EsmFile

Add a coupling entry to an ESM file.
"""
function add_coupling(file::EsmFile, entry::CouplingEntry)::EsmFile
    new_coupling = copy(file.coupling)
    push!(new_coupling, entry)

    return _rebuild(file; coupling=new_coupling)
end

"""
    remove_coupling(file::EsmFile, index::Int) -> EsmFile

Remove a coupling entry by index (1-based).
Throws [`EditError`](@ref) if the index is out of bounds.
"""
function remove_coupling(file::EsmFile, index::Int)::EsmFile
    if index < 1 || index > length(file.coupling)
        throw(EditError("Coupling index $index out of bounds (1-$(length(file.coupling)))"))
    end

    new_coupling = copy(file.coupling)
    deleteat!(new_coupling, index)

    return _rebuild(file; coupling=new_coupling)
end

"""
    compose(file::EsmFile, system_a::String, system_b::String) -> EsmFile

Convenience function to create an operator_compose coupling entry linking two systems.
"""
function compose(file::EsmFile, system_a::String, system_b::String)::EsmFile
    coupling_entry = CouplingOperatorCompose([system_a, system_b])
    return add_coupling(file, coupling_entry)
end

"""
    map_variable(file::EsmFile, from::String, to::String; transform="identity") -> EsmFile

Convenience function to create a variable_map coupling entry that forwards a
variable reference `from` into `to`. `transform` names the transform function
(e.g. `"identity"`, `"affine"`) or is an `Expr` operator node evaluated on the
source value (esm-spec §10.4 expression transform).
"""
function map_variable(file::EsmFile, from::String, to::String;
                      transform::Union{String,Expr}="identity")::EsmFile
    coupling_entry = CouplingVariableMap(from, to, transform)
    return add_coupling(file, coupling_entry)
end

# Model-level operations (Section 4.6)

"""
    Base.merge(file_a::EsmFile, file_b::EsmFile) -> EsmFile

Merge two ESM files.

Combines all components from both files. In case of conflicts, components
from `file_b` take precedence. Defined as a method of `Base.merge` (the
semantics match Base's "right operand wins" merge), so it is always in scope
for consumers without shadowing the Base function.
"""
# Right-biased merge of two optional component Dicts: a `nothing` side yields
# the other side unchanged; two Dicts merge with `b` winning key conflicts
# (Base.merge semantics).
_merge_optional(a, b) = a === nothing ? b : b === nothing ? a : merge(a, b)

function Base.merge(file_a::EsmFile, file_b::EsmFile)::EsmFile
    # Merge dictionaries (file_b takes precedence), handling nothing values
    merged_models = _merge_optional(file_a.models, file_b.models)
    merged_reaction_systems = _merge_optional(file_a.reaction_systems, file_b.reaction_systems)
    merged_data_loaders = _merge_optional(file_a.data_loaders, file_b.data_loaders)

    # v0.8.0: a single shared `domain` object (file_b takes precedence).
    merged_domain = file_b.domain === nothing ? file_a.domain : file_b.domain

    # Combine coupling arrays
    merged_coupling = vcat(file_a.coupling, file_b.coupling)

    # Merge other fields (file_b takes precedence)
    merged_metadata = file_b.metadata

    return _rebuild(file_b;
        esm=file_b.esm,  # Use file_b's version
        metadata=merged_metadata,
        models=merged_models,
        reaction_systems=merged_reaction_systems,
        data_loaders=merged_data_loaders,
        coupling=merged_coupling,
        domain=merged_domain)
end

"""
    extract(file::EsmFile, component_name::String) -> EsmFile

Extract a single component into a standalone ESM file.

Creates a new file containing only the specified component and any
coupling entries that reference it. Throws [`EditError`](@ref) if the
component does not exist.
"""
function extract(file::EsmFile, component_name::String)::EsmFile
    extracted_models = Dict{String,Model}()
    extracted_reaction_systems = Dict{String,ReactionSystem}()
    extracted_data_loaders = Dict{String,DataLoader}()

    found = false
    if file.models !== nothing && haskey(file.models, component_name)
        extracted_models[component_name] = file.models[component_name]
        found = true
    elseif file.reaction_systems !== nothing && haskey(file.reaction_systems, component_name)
        extracted_reaction_systems[component_name] = file.reaction_systems[component_name]
        found = true
    elseif file.data_loaders !== nothing && haskey(file.data_loaders, component_name)
        extracted_data_loaders[component_name] = file.data_loaders[component_name]
        found = true
    end

    if !found
        throw(EditError("Component '$component_name' not found"))
    end

    # Find relevant coupling entries
    relevant_coupling = CouplingEntry[]
    for coupling in file.coupling
        involves_component = false

        if coupling isa CouplingOperatorCompose
            involves_component = component_name in coupling.systems
        elseif coupling isa CouplingCouple
            involves_component = component_name in coupling.systems
        elseif coupling isa CouplingVariableMap
            # The from/to strings use dotted refs like "SystemName.var"
            from_parts = split(coupling.from, ".")
            to_parts = split(coupling.to, ".")
            involves_component = (length(from_parts) > 0 && from_parts[1] == component_name) ||
                                (length(to_parts) > 0 && to_parts[1] == component_name)
        elseif coupling isa CouplingOperatorApply
            involves_component = (coupling.operator == component_name)
        end

        if involves_component
            push!(relevant_coupling, coupling)
        end
    end

    return _rebuild(file;
        models=extracted_models,
        reaction_systems=extracted_reaction_systems,
        data_loaders=extracted_data_loaders,
        coupling=relevant_coupling)
end
