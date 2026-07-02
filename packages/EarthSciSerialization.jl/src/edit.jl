"""
Editing operations for ESM format structures.

This module implements all editing operations specified in ESM Libraries Spec Section 4,
including variable operations, equation operations, reaction operations, event operations,
coupling operations, and model-level operations.
"""

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

    return Model(
        new_variables,
        model.equations,
        model.discrete_events,
        model.continuous_events,
        model.subsystems
    )
end

"""
    remove_variable(model::Model, name::String) -> Model

Remove a variable from a model.

Creates a new model without the specified variable. Warns about dependencies
but does not automatically update equations that reference the variable.
"""
function remove_variable(model::Model, name::String)::Model
    new_variables = copy(model.variables)

    if !haskey(new_variables, name)
        @warn "Variable '$name' does not exist"
        return model
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

    return Model(
        new_variables,
        model.equations,
        model.discrete_events,
        model.continuous_events,
        model.subsystems
    )
end

"""
    rename_variable(model::Model, old_name::String, new_name::String) -> Model

Rename a variable throughout the model.

Updates the variable definition and all references in equations.
"""
function rename_variable(model::Model, old_name::String, new_name::String)::Model
    if !haskey(model.variables, old_name)
        @warn "Variable '$old_name' does not exist"
        return model
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
    substitution = Dict{String, EarthSciSerialization.Expr}(old_name => VarExpr(new_name))
    new_equations = [
        Equation(
            substitute(eq.lhs, substitution),
            substitute(eq.rhs, substitution)
        )
        for eq in model.equations
    ]

    return Model(
        new_variables,
        new_equations,
        model.discrete_events,
        model.continuous_events,
        model.subsystems
    )
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

    return Model(
        model.variables,
        new_equations,
        model.discrete_events,
        model.continuous_events,
        model.subsystems
    )
end

"""
    remove_equation(model::Model, index::Int) -> Model
    remove_equation(model::Model, lhs_pattern::Expr) -> Model

Remove an equation from a model.

Can remove by index (1-based) or by matching the left-hand side expression.
"""
function remove_equation(model::Model, index::Int)::Model
    if index < 1 || index > length(model.equations)
        @warn "Equation index $index out of bounds (1-$(length(model.equations)))"
        return model
    end

    new_equations = copy(model.equations)
    deleteat!(new_equations, index)

    return Model(
        model.variables,
        new_equations,
        model.discrete_events,
        model.continuous_events,
        model.subsystems
    )
end

function remove_equation(model::Model, lhs_pattern::EarthSciSerialization.Expr)::Model
    # Find equation with matching LHS
    for (i, eq) in enumerate(model.equations)
        if eq.lhs == lhs_pattern  # This requires Expr equality to be defined
            return remove_equation(model, i)
        end
    end

    @warn "No equation found with LHS matching: $lhs_pattern"
    return model
end

"""
    substitute_in_equations(model::Model, bindings::Dict{String, Expr}) -> Model

Apply substitutions across all equations in a model.

Replaces variables according to the bindings dictionary.
"""
function substitute_in_equations(model::Model, bindings::Dict{String, EarthSciSerialization.Expr})::Model
    new_equations = [
        Equation(
            substitute(eq.lhs, bindings),
            substitute(eq.rhs, bindings)
        )
        for eq in model.equations
    ]

    return Model(
        model.variables,
        new_equations,
        model.discrete_events,
        model.continuous_events,
        model.subsystems
    )
end

# Reaction operations (Section 4.3)

"""
    add_reaction(system::ReactionSystem, reaction::Reaction) -> ReactionSystem

Add a new reaction to a reaction system.
"""
function add_reaction(system::ReactionSystem, reaction::Reaction)::ReactionSystem
    new_reactions = copy(system.reactions)
    push!(new_reactions, reaction)

    return ReactionSystem(
        system.species,
        new_reactions,
        parameters=system.parameters,
        subsystems=system.subsystems,
        tolerance=system.tolerance,
        tests=system.tests,
    )
end

"""
    remove_reaction(system::ReactionSystem, id::String) -> ReactionSystem

Remove a reaction by its ID.

Note: This assumes reactions have an `id` field. If not available,
this function will search by reaction equality.
"""
function remove_reaction(system::ReactionSystem, id::String)::ReactionSystem
    new_reactions = Reaction[]

    for reaction in system.reactions
        if reaction.id != id
            push!(new_reactions, reaction)
        end
    end

    if length(new_reactions) == length(system.reactions)
        @warn "No reaction found with id: $id"
    end

    return ReactionSystem(
        system.species,
        new_reactions,
        parameters=system.parameters,
        subsystems=system.subsystems,
        tolerance=system.tolerance,
        tests=system.tests,
    )
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

    return ReactionSystem(
        new_species,
        system.reactions,
        parameters=system.parameters,
        subsystems=system.subsystems,
        tolerance=system.tolerance,
        tests=system.tests,
    )
end

"""
    remove_species(system::ReactionSystem, name::String) -> ReactionSystem

Remove a species from a reaction system.

Warns about dependent reactions but does not automatically update them.
"""
function remove_species(system::ReactionSystem, name::String)::ReactionSystem
    # Check for dependencies
    dependent_reactions = Int[]
    for (i, reaction) in enumerate(system.reactions)
        if haskey(reaction.reactants, name) || haskey(reaction.products, name)
            push!(dependent_reactions, i)
        end
    end

    if !isempty(dependent_reactions)
        @warn "Species '$name' is used in reactions: $dependent_reactions. These reactions may become invalid."
    end

    # Remove species
    new_species = filter(s -> s.name != name, system.species)

    if length(new_species) == length(system.species)
        @warn "Species '$name' not found"
    end

    return ReactionSystem(
        new_species,
        system.reactions,
        parameters=system.parameters,
        subsystems=system.subsystems,
        tolerance=system.tolerance,
        tests=system.tests,
    )
end

# Event operations (Section 4.4)

"""
    add_continuous_event(model::Model, event::ContinuousEvent) -> Model

Add a continuous event to a model.
"""
function add_continuous_event(model::Model, event::ContinuousEvent)::Model
    new_events = copy(model.continuous_events)
    push!(new_events, event)

    return Model(
        model.variables,
        model.equations,
        model.discrete_events,
        new_events,
        model.subsystems
    )
end

"""
    add_discrete_event(model::Model, event::DiscreteEvent) -> Model

Add a discrete event to a model.
"""
function add_discrete_event(model::Model, event::DiscreteEvent)::Model
    new_events = copy(model.discrete_events)
    push!(new_events, event)

    return Model(
        model.variables,
        model.equations,
        new_events,
        model.continuous_events,
        model.subsystems
    )
end

"""
    remove_event(model::Model, name::String) -> Model

Remove an event by name from a model.

Searches both continuous and discrete events.
"""
function remove_event(model::Model, name::String)::Model
    # Remove from continuous events
    continuous_events = model.continuous_events
    new_continuous = filter(e -> (e.description !== nothing ? e.description : "") != name, continuous_events)

    # Remove from discrete events
    discrete_events = model.discrete_events
    new_discrete = filter(e -> (e.description !== nothing ? e.description : "") != name, discrete_events)

    if length(new_continuous) == length(continuous_events) &&
       length(new_discrete) == length(discrete_events)
        @warn "Event '$name' not found"
    end

    return Model(
        model.variables,
        model.equations,
        new_discrete,
        new_continuous,
        model.subsystems
    )
end

# Coupling operations (Section 4.5)

"""
    add_coupling(file::EsmFile, entry::CouplingEntry) -> EsmFile

Add a coupling entry to an ESM file.
"""
function add_coupling(file::EsmFile, entry::CouplingEntry)::EsmFile
    new_coupling = copy(file.coupling)
    push!(new_coupling, entry)

    return EsmFile(
        file.esm,
        file.metadata;
        models=file.models,
        reaction_systems=file.reaction_systems,
        data_loaders=file.data_loaders,
        operators=file.operators,
        coupling=new_coupling,
        domain=file.domain
    )
end

"""
    remove_coupling(file::EsmFile, index::Int) -> EsmFile

Remove a coupling entry by index.
"""
function remove_coupling(file::EsmFile, index::Int)::EsmFile
    if index < 1 || index > length(file.coupling)
        @warn "Coupling index $index out of bounds (1-$(length(file.coupling)))"
        return file
    end

    new_coupling = copy(file.coupling)
    deleteat!(new_coupling, index)

    return EsmFile(
        file.esm,
        file.metadata;
        models=file.models,
        reaction_systems=file.reaction_systems,
        data_loaders=file.data_loaders,
        operators=file.operators,
        coupling=new_coupling,
        domain=file.domain
    )
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
                      transform::Union{String,EarthSciSerialization.Expr}="identity")::EsmFile
    coupling_entry = CouplingVariableMap(from, to, transform)
    return add_coupling(file, coupling_entry)
end

# Model-level operations (Section 4.6)

"""
    merge(file_a::EsmFile, file_b::EsmFile) -> EsmFile

Merge two ESM files.

Combines all components from both files. In case of conflicts, components
from file_b take precedence.
"""
function merge(file_a::EsmFile, file_b::EsmFile)::EsmFile
    # Merge dictionaries (file_b takes precedence), handling nothing values
    merged_models = file_a.models === nothing ? file_b.models :
                   file_b.models === nothing ? file_a.models :
                   Base.merge(file_a.models, file_b.models)

    merged_reaction_systems = file_a.reaction_systems === nothing ? file_b.reaction_systems :
                             file_b.reaction_systems === nothing ? file_a.reaction_systems :
                             Base.merge(file_a.reaction_systems, file_b.reaction_systems)

    merged_data_loaders = file_a.data_loaders === nothing ? file_b.data_loaders :
                         file_b.data_loaders === nothing ? file_a.data_loaders :
                         Base.merge(file_a.data_loaders, file_b.data_loaders)

    merged_operators = file_a.operators === nothing ? file_b.operators :
                      file_b.operators === nothing ? file_a.operators :
                      Base.merge(file_a.operators, file_b.operators)

    # v0.8.0: a single shared `domain` object (file_b takes precedence).
    merged_domain = file_b.domain === nothing ? file_a.domain : file_b.domain

    # Combine coupling arrays
    merged_coupling = vcat(file_a.coupling, file_b.coupling)

    # Merge other fields (file_b takes precedence)
    merged_metadata = file_b.metadata

    return EsmFile(
        file_b.esm,  # Use file_b's version
        merged_metadata;
        models=merged_models,
        reaction_systems=merged_reaction_systems,
        data_loaders=merged_data_loaders,
        operators=merged_operators,
        coupling=merged_coupling,
        domain=merged_domain
    )
end

"""
    extract(file::EsmFile, component_name::String) -> EsmFile

Extract a single component into a standalone ESM file.

Creates a new file containing only the specified component and any
coupling entries that reference it.
"""
function extract(file::EsmFile, component_name::String)::EsmFile
    extracted_models = Dict{String,Model}()
    extracted_reaction_systems = Dict{String,ReactionSystem}()
    extracted_data_loaders = Dict{String,DataLoader}()
    extracted_operators = Dict{String,Operator}()

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
    elseif file.operators !== nothing && haskey(file.operators, component_name)
        extracted_operators[component_name] = file.operators[component_name]
        found = true
    end

    if !found
        @warn "Component '$component_name' not found"
        return EsmFile(
            file.esm,
            Metadata("empty");
            models=Dict{String,Model}(),
            reaction_systems=Dict{String,ReactionSystem}(),
            data_loaders=Dict{String,DataLoader}(),
            operators=Dict{String,Operator}(),
            coupling=CouplingEntry[]
        )
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

    return EsmFile(
        file.esm,
        file.metadata;
        models=extracted_models,
        reaction_systems=extracted_reaction_systems,
        data_loaders=extracted_data_loaders,
        operators=extracted_operators,
        coupling=relevant_coupling,
        domain=file.domain
    )
end