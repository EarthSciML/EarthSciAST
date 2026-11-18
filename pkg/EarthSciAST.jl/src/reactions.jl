# Reaction systems lowered to equations by mass-action kinetics (esm-spec §7.4,
# esm-libraries-spec §4.6.2): the lowering flatten uses, and `derive_odes`.

# What `derive_odes` gives a species that declares no `default` or `units`.
# esm-spec §7.4 makes a species' initial value its `default` and names no
# fallback; these are this binding's.
const DEFAULT_SPECIES_CONCENTRATION = 1.0
const DEFAULT_SPECIES_UNITS = "mol/L"

"""
    each_stoich_term(rxn::Reaction) -> Vector{Tuple{String,Float64}}

The reaction's stoichiometry as `(species, signed_stoichiometry)` pairs:
substrates first with NEGATIVE sign, then products with POSITIVE sign, each
side in its declared order. The one signed-stoichiometry iteration, shared by
`stoichiometric_matrix` and flatten's reaction-species collection
(`_collect_reaction_species!`).
"""
function each_stoich_term(rxn::Reaction)::Vector{Tuple{String, Float64}}
    terms = Tuple{String, Float64}[]
    substrates = raw_substrates(rxn)
    if substrates !== nothing
        for entry in substrates
            push!(terms, (entry.species, -entry.stoichiometry))
        end
    end
    products = raw_products(rxn)
    if products !== nothing
        for entry in products
            push!(terms, (entry.species, entry.stoichiometry))
        end
    end
    return terms
end

"""
    reaction_variables(rsys::ReactionSystem) -> OrderedDict{String, ModelVariable}

The variables of a reaction system's own scope, species then parameters, in
declaration order (esm-spec §7): a species is an unknown, except a reservoir
(`constant: true`, §7.4), which is held fixed and so is a parameter; it keeps
its declared `default`, `description` and `units`. A parameter keeps its whole
§6.3 value model — `update` above all, the only channel binding it to a data
source (esm-spec §5.4).
"""
function reaction_variables(rsys::ReactionSystem)
    out = OrderedDict{String, ModelVariable}()
    for sp in rsys.species
        out[sp.name] = ModelVariable(
            sp.constant === true ? ParameterVariable : UnknownVariable;
            default = sp.default, description = sp.description, units = sp.units
        )
    end
    for p in rsys.parameters
        out[p.name] = ModelVariable(
            ParameterVariable;
            default = p.default, description = p.description, units = p.units,
            default_units = p.default_units, shape = p.shape,
            distribution = p.distribution, update = p.update
        )
    end
    return out
end

"""
    derive_odes(rxn_sys::ReactionSystem) -> Model

The reaction system as a model (esm-spec §7.4): its variables
([`reaction_variables`](@ref)), each species without a `default`, `description`
or `units` given [`DEFAULT_SPECIES_CONCENTRATION`](@ref), a generated
description and [`DEFAULT_SPECIES_UNITS`](@ref); its equations
`D(X) = Σ stoich · rate` ([`lower_reactions_to_equations`](@ref)); and each
subsystem converted the same way. The reaction system's constraint equations
and events are not carried over.

# Examples
```julia
# Simple A + B -> C reaction
species = [Species("A"), Species("B"), Species("C")]
reactions = [Reaction(Dict("A"=>1, "B"=>1), Dict("C"=>1), VarExpr("k1"))]
parameters = [Parameter("k1", 0.1)]
rxn_sys = ReactionSystem(species, reactions, parameters=parameters)

model = derive_odes(rxn_sys)
# Returns Model with:
# - State variables: A, B, C
# - Parameter: k1
# - Equations: d[A]/dt = -k1*A*B, d[B]/dt = -k1*A*B, d[C]/dt = k1*A*B
```
"""
function derive_odes(rxn_sys::ReactionSystem)::Model
    variables = reaction_variables(rxn_sys)
    for species in rxn_sys.species
        v = variables[species.name]
        variables[species.name] = reconstruct(
            v; default = something(v.default, DEFAULT_SPECIES_CONCENTRATION),
            description = something(v.description, "Concentration of species $(species.name)"),
            units = something(v.units, DEFAULT_SPECIES_UNITS)
        )
    end

    equations = lower_reactions_to_equations(rxn_sys.reactions, rxn_sys.species)
    subsystems = Dict{String, Model}()
    for (name, subsys) in rxn_sys.subsystems
        subsystems[name] = derive_odes(subsys)
    end

    return Model(variables, equations, subsystems = subsystems)
end

"""
    stoichiometric_matrix(rxn_sys::ReactionSystem) -> Matrix{Float64}

The net stoichiometric matrix, species × reactions: `S[i, j]` is species `i`'s
product coefficients minus its substrate coefficients in reaction `j`, positive
for production. `Float64`, since a stoichiometry may be fractional
(`ISOP + O3 → 0.87 CH2O`).

# Examples
```julia
# For reaction A + B -> 2C:
# S = [-1  # A consumed
#      -1  # B consumed
#       2] # C produced (2 molecules)
```
"""
function stoichiometric_matrix(rxn_sys::ReactionSystem)::Matrix{Float64}
    species_idx = Dict(species.name => i for (i, species) in enumerate(rxn_sys.species))
    S = zeros(Float64, length(rxn_sys.species), length(rxn_sys.reactions))

    for (j, reaction) in enumerate(rxn_sys.reactions)
        for (species, signed_stoich) in each_stoich_term(reaction)
            if haskey(species_idx, species)
                S[species_idx[species], j] += signed_stoich
            end
        end
    end

    return S
end

"""
    mass_action_rate(reaction::Reaction, species::Vector{Species}) -> ASTExpr

The mass-action rate law of `reaction` (esm-spec §7.4): its `rate`, the rate
coefficient `k`, times `∏ Sᵢ^nᵢ` over its substrates; the coefficient alone for
a source reaction (no substrates). `species` is not read.

# Examples
```julia
# For reaction A + B -> C with rate="k":
# Returns: k * A * B
#
# For source reaction -> A with rate="k":
# Returns: k
```
"""
function mass_action_rate(reaction::Reaction, species::Vector{Species})::ASTExpr
    rate_expr = reaction.rate
    (reaction.substrates === nothing || isempty(reaction.substrates)) && return rate_expr
    mass_action_terms = ASTExpr[rate_expr]
    for entry in reaction.substrates
        species_expr = VarExpr(entry.species)
        if entry.stoichiometry == 1
            push!(mass_action_terms, species_expr)
        else
            push!(
                mass_action_terms, OpExpr(
                    "^",
                    ASTExpr[species_expr, _stoich_literal(entry.stoichiometry)]
                )
            )
        end
    end

    return OpExpr("*", mass_action_terms)
end

"""
    lower_reactions_to_equations(reactions, species) -> Vector{Equation}

The equations a set of reactions induces by mass-action kinetics,
`D(X) = Σ_j stoich_Xj · rate_j`, for `derive_odes` and `flatten` alike. The
tree is the canonical form esm-libraries-spec §4.6.2 pins byte for byte across
the bindings (`tests/conformance/reactions/lowering_form.json`): an n-ary `+`
over the species' terms in reaction order, each term the bare rate law or
`stoich * rate` with an integer literal for an integral coefficient. The
left-hand side is `D(X)` with `wrt` `"t"` whatever the domain.

No equation is emitted for a RESERVOIR (`constant: true`, §7.4), which is held
fixed but still read in every rate law it appears in, nor for a species whose
net stoichiometry is zero in every reaction (one in no reaction, or a
catalyst): esm-spec §6.3.1 classifies by complement, so leaving the equation
out makes it the algebraic unknown it is, where `D(X) = 0` would make it a
differential unknown that never moves.

A substrate or product the system does not declare is `undefined_species`
(esm-spec §7.2), a `ParseError`.
"""
function lower_reactions_to_equations(
        reactions::Vector{Reaction},
        species::Vector{Species}
    )::Vector{Equation}
    equations = Equation[]
    species_names = [sp.name for sp in species]
    species_idx = Dict{String, Int}(name => i for (i, name) in enumerate(species_names))

    # Each species' terms, filled reaction by reaction so they come out in
    # reaction order (esm-libraries-spec §4.6.2 rule 4).
    terms = [ASTExpr[] for _ in species_names]

    for rxn in reactions
        # Net stoichiometry is `P - S` (esm-libraries-spec §4.6.2): `P` sums the
        # species' product coefficients in the reaction and `S` its substrate
        # coefficients, each in listed order, and the difference is taken once.
        # Accumulating one signed running sum instead rounds differently for a
        # species listed more than once with fractional coefficients. Only the
        # species the reaction names are visited, in first-mention order.
        produced = Dict{Int, Float64}()
        consumed = Dict{Int, Float64}()
        touched = Int[]
        for (side, entries) in ((consumed, raw_substrates(rxn)), (produced, raw_products(rxn)))
            entries === nothing && continue
            for entry in entries
                sp = entry.species
                i = get(species_idx, sp, 0)
                i == 0 && throw(
                    ParseError(
                        "[$(ERROR_CODES.UNDEFINED_SPECIES)] reaction '$(rxn.id)' names species " *
                            "'$sp', which the reaction system does not declare";
                        code = ERROR_CODES.UNDEFINED_SPECIES,
                        details = Dict{String, Any}("species" => sp, "reaction_id" => rxn.id)
                    )
                )
                haskey(produced, i) || haskey(consumed, i) || push!(touched, i)
                side[i] = get(side, i, 0.0) + entry.stoichiometry
            end
        end

        for i in touched
            species[i].constant === true && continue
            stoich = get(produced, i, 0.0) - get(consumed, i, 0.0)
            stoich == 0 && continue
            # The canonical term (esm-libraries-spec §4.6.2): the bare rate law
            # for a net stoichiometry of exactly 1, and otherwise the two-operand
            # product `stoich * rate` with the coefficient FIRST and spelled as
            # an integer literal when it is integral. A loss of 1 is
            # `-1 * rate`, not a unary minus.
            rate_expr = mass_action_rate(rxn, species)
            if stoich == 1
                push!(terms[i], rate_expr)
            else
                push!(terms[i], OpExpr("*", ASTExpr[_stoich_literal(stoich), rate_expr]))
            end
        end
    end

    for (i, name) in enumerate(species_names)
        isempty(terms[i]) && continue
        lhs = OpExpr("D", ASTExpr[VarExpr(name)], wrt = "t")
        rhs = length(terms[i]) == 1 ? terms[i][1] : OpExpr("+", terms[i])
        push!(equations, Equation(lhs, rhs))
    end

    return equations
end

# A stoichiometric coefficient or exponent as the literal the lowered tree
# carries: an integer literal when the value is integral and representable in
# Int64 (CONFORMANCE_SPEC §5.5.3.1 rule 3, esm-libraries-spec §4.6.2 rule 5), a
# float literal otherwise. `2.0^63` is integral but one past `typemax(Int64)`,
# so the upper bound is strict.
_stoich_literal(x::Real)::ASTExpr =
    (isinteger(x) && -2.0^63 <= x < 2.0^63) ? IntExpr(Int64(x)) : NumExpr(Float64(x))
