# Resolving a qualified `System.sub.var` reference against a typed document
# (esm-spec §4.6).

"""
    QualifiedReferenceError(message, reference, path, code = "")

Exception thrown when qualified reference resolution fails. Fields: `code`
(`invalid_reference_syntax`, `undefined_system` or `undefined_variable`),
`message`, the `reference` as written, and `path`, the system names resolved
before the failure.
"""
struct QualifiedReferenceError <: EarthSciASTError
    code::String
    message::String
    reference::String
    path::Vector{String}
    QualifiedReferenceError(
        message::AbstractString, reference::AbstractString, path::AbstractVector,
        code::AbstractString = ""
    ) = new(String(code), String(message), String(reference), Vector{String}(path))
end

error_message(e::QualifiedReferenceError) = string(e.message, " (reference: '", e.reference, "')")

"""
    ReferenceResolution

Result of qualified reference resolution containing the resolved variable
and its location information.
"""
struct ReferenceResolution
    variable_name::String
    system_path::Vector{String}
    system_type::Symbol  # :model | :reaction_system
    resolved_system::Union{Model, ReactionSystem}
end

"""
    resolve_qualified_reference(esm_file::EsmFile, reference::String) -> ReferenceResolution

Resolve a qualified reference string using hierarchical dot notation.

The reference string is split on dots to produce segments [s₁, s₂, …, sₙ].
The final segment sₙ is the variable name. The preceding segments [s₁, …, sₙ₋₁]
form a path through the subsystem hierarchy.

## Algorithm
1. Split reference on "." to get segments
2. First segment must match a top-level system (models, reaction_systems)
3. Each subsequent segment must match a key in the parent system's subsystems map
4. Final segment is the variable name to resolve

## Examples
- `"SuperFast.O3"` → Variable `O3` in top-level model `SuperFast`
- `"SuperFast.GasPhase.O3"` → Variable `O3` in subsystem `GasPhase` of model `SuperFast`
- `"Atmosphere.Chemistry.FastChem.NO2"` → Variable `NO2` in nested subsystems

## Throws
- `QualifiedReferenceError` if reference cannot be resolved
"""
function resolve_qualified_reference(esm_file::EsmFile, reference::String)::ReferenceResolution
    if isempty(reference)
        throw(QualifiedReferenceError("Empty reference string", reference, String[], ERROR_CODES.INVALID_REFERENCE_SYNTAX))
    end

    segments = split(reference, ".")
    if length(segments) < 1
        throw(QualifiedReferenceError("Invalid reference format", reference, String[], ERROR_CODES.INVALID_REFERENCE_SYNTAX))
    end

    # Extract variable name (last segment) and system path
    variable_name = String(segments[end])
    system_path = String.(segments[1:(end - 1)])

    # Handle bare references (no dot)
    if length(system_path) == 0
        throw(QualifiedReferenceError("Bare references not supported without system context", reference, String[], ERROR_CODES.INVALID_REFERENCE_SYNTAX))
    end

    # Resolve the system path
    top_level_name = system_path[1]
    remaining_path = system_path[2:end]

    # Find top-level system
    system, system_type = find_top_level_system(esm_file, top_level_name)
    if system === nothing
        throw(QualifiedReferenceError("Top-level system '$(top_level_name)' not found", reference, system_path[1:1], ERROR_CODES.UNDEFINED_SYSTEM))
    end

    # Traverse subsystem hierarchy
    current_system = system
    traversed_path = [top_level_name]

    for segment in remaining_path
        push!(traversed_path, segment)
        current_system = find_subsystem(current_system, segment)
        if current_system === nothing
            throw(QualifiedReferenceError("Subsystem '$(segment)' not found in path", reference, traversed_path, ERROR_CODES.UNDEFINED_SYSTEM))
        end
    end

    # Validate that the variable exists in the final system
    if !variable_exists_in_system(current_system, variable_name)
        throw(QualifiedReferenceError("Variable '$(variable_name)' not found in system", reference, system_path, ERROR_CODES.UNDEFINED_VARIABLE))
    end

    return ReferenceResolution(variable_name, system_path, system_type, current_system)
end

"""
    find_top_level_system(esm_file::EsmFile, name::String) -> (Union{Model,ReactionSystem,Nothing}, Symbol)

Find a top-level system by name in models or reaction_systems.
Returns the system and its type, or (nothing, :none) if not found.

`data_sources` is deliberately NOT searched: from esm 1.0.0 a data source is an
ingest registry entry, not a component, so it can never be the root of a scoped
reference (esm-spec §8).
"""
function find_top_level_system(esm_file::EsmFile, name::String)
    # Check models
    if esm_file.models !== nothing && haskey(esm_file.models, name)
        return (esm_file.models[name], :model)
    end

    # Check reaction_systems
    if esm_file.reaction_systems !== nothing && haskey(esm_file.reaction_systems, name)
        return (esm_file.reaction_systems[name], :reaction_system)
    end

    return (nothing, :none)
end

"""
    find_subsystem(system::Union{Model,ReactionSystem}, name::String) -> Union{Model,ReactionSystem,Nothing}

Find a subsystem by name within a Model or ReactionSystem.
Returns the subsystem or nothing if not found.

A subsystem is always a component (a `Model` or a `ReactionSystem`); a data
source is a registry entry, never a subsystem.
"""
function find_subsystem(system::Model, name::String)::Union{Model, ReactionSystem, Nothing}
    return get(system.subsystems, name, nothing)
end

function find_subsystem(system::ReactionSystem, name::String)::Union{ReactionSystem, Nothing}
    return get(system.subsystems, name, nothing)
end

"""
    variable_exists_in_system(system, variable_name::String) -> Bool

Check if a variable exists in the given system.
"""
function variable_exists_in_system(system::Model, variable_name::String)::Bool
    return haskey(system.variables, variable_name)
end

function variable_exists_in_system(system::ReactionSystem, variable_name::String)::Bool
    # Check species
    for species in system.species
        if species.name == variable_name
            return true
        end
    end

    # Check parameters
    for param in system.parameters
        if param.name == variable_name
            return true
        end
    end

    return false
end

"""
    validate_reference_syntax(reference::String) -> Bool

Validate that a reference string follows proper dot notation syntax.
"""
function validate_reference_syntax(reference::String)::Bool
    if isempty(reference)
        return false
    end

    # No leading or trailing dots
    if startswith(reference, ".") || endswith(reference, ".")
        return false
    end

    # No consecutive dots
    if occursin("..", reference)
        return false
    end

    # All segments should be valid identifiers
    segments = split(reference, ".")
    for segment in segments
        if isempty(segment) || !is_valid_identifier(String(segment))
            return false
        end
    end

    return true
end

"""
    is_valid_identifier(name::String) -> Bool

Check if a string is a valid identifier (letters, numbers, underscores, no leading digit).
"""
function is_valid_identifier(name::String)::Bool
    if isempty(name)
        return false
    end

    # Must start with letter or underscore. Iterate by character (not byte
    # index): `name[2:end]` byte-indexes and throws `StringIndexError` when the
    # identifier starts with a multi-byte (non-ASCII) letter.
    first_char = first(name)
    if !isletter(first_char) && first_char != '_'
        return false
    end

    # Rest can be letters, digits, or underscores
    for c in Iterators.drop(name, 1)
        if !isletter(c) && !isdigit(c) && c != '_'
            return false
        end
    end

    return true
end
