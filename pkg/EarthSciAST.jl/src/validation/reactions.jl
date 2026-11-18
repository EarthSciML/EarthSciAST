# Reaction-system consistency.

"""
    validate_reaction_consistency(rs::ReactionSystem, path::String) -> Vector{StructuralError}

Validate reaction system consistency: species declared, positive stoichiometries,
no null-null reactions, rate references declared.
"""
function validate_reaction_consistency(
        rs::ReactionSystem, path::String;
        indep::AbstractString = "t"
    )::Vector{StructuralError}
    errors = StructuralError[]

    # Get set of declared species / parameters
    species_names = Set(sp.name for sp in rs.species)
    param_names = Set(p.name for p in rs.parameters)

    # Validate each reaction
    for (i, reaction) in enumerate(rs.reactions)
        reaction_path = "$path/reactions/$(i - 1)"

        # Check substrates (reactants) are declared species (ordered
        # StoichiometryEntry vector, not the backward-compat Dict view). An
        # undefined species is pinned at the offending ENTRY's `species` field
        # (`.../substrates/j/species`), not the whole `substrates` array (§7.1.2).
        substrates_field = raw_substrates(reaction)
        if substrates_field !== nothing
            for (j, entry) in enumerate(substrates_field)
                if entry.species ∉ species_names
                    _report!(
                        errors, ERROR_CODES.UNDEFINED_SPECIES,
                        "$reaction_path/substrates/$(j - 1)/species",
                        "Species '$(entry.species)' not declared",
                        Dict{String, Any}("species" => entry.species)
                    )
                end

                # Check positive stoichiometry
                if entry.stoichiometry <= 0
                    _report!(
                        errors, ERROR_CODES.INVALID_STOICHIOMETRY,
                        "$reaction_path/substrates/$(j - 1)/species",
                        "Species '$(entry.species)' has non-positive stoichiometry $(entry.stoichiometry)"
                    )
                end
            end
        end

        # Check products are declared species (ordered StoichiometryEntry
        # vector, not the backward-compat Dict view). Same per-entry pointer.
        products_field = raw_products(reaction)
        if products_field !== nothing
            for (j, entry) in enumerate(products_field)
                if entry.species ∉ species_names
                    _report!(
                        errors, ERROR_CODES.UNDEFINED_SPECIES,
                        "$reaction_path/products/$(j - 1)/species",
                        "Species '$(entry.species)' not declared",
                        Dict{String, Any}("species" => entry.species)
                    )
                end

                # Check positive stoichiometry
                if entry.stoichiometry <= 0
                    _report!(
                        errors, ERROR_CODES.INVALID_STOICHIOMETRY,
                        "$reaction_path/products/$(j - 1)/species",
                        "Species '$(entry.species)' has non-positive stoichiometry $(entry.stoichiometry)"
                    )
                end
            end
        end

        # Check for null-null reaction (no reactants and no products)
        has_substrates = substrates_field !== nothing && !isempty(substrates_field)
        has_products = products_field !== nothing && !isempty(products_field)
        if !has_substrates && !has_products
            _report!(
                errors, ERROR_CODES.NULL_REACTION,
                reaction_path,
                "Reaction has no reactants or products (null-null reaction)"
            )
        end

        # Rate expression references. A DOTTED name (`Meteo.T`) is a qualified
        # cross-system reference and belongs to the qualified-reference resolver,
        # not here — but a BARE name that is neither a declared parameter, a
        # declared species, the time variable, nor a builtin function can never
        # resolve to anything, so it is flagged. (This was previously skipped
        # wholesale, on the strength of the qualified-reference argument, which
        # let `tests/invalid/undefined_parameter.esm` validate clean.)
        for name in sort!(collect(_referenced_var_names(reaction.rate)))
            # (d) A DOTTED name is a SCOPED reference (`Meteo.T`) — a rate may
            # legitimately reach into another system, and it is the
            # qualified-reference resolver's job, not this one's.
            occursin('.', name) && continue
            (name == indep || name in _BUILTIN_FUNCTION_NAMES) && continue
            (name in species_names || name in param_names) && continue
            _report!(
                errors, ERROR_CODES.UNDEFINED_PARAMETER,
                "$reaction_path/rate",
                "Parameter '$name' referenced in rate expression is not declared",
                Dict{String, Any}("variable" => name)
            )
        end
    end

    # Recursively check subsystems
    for (subsys_name, subsys) in rs.subsystems
        append!(
            errors, validate_reaction_consistency(
                subsys, "$path/subsystems/$subsys_name";
                indep = indep
            )
        )
    end

    return errors
end
