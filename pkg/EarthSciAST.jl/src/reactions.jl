"""
Reaction system to ODE conversion functionality.

This module implements the conversion of ReactionSystem objects to ODE-based Models
using standard mass action kinetics as specified in Libraries Spec Section 7.4.
"""

# Fallback initial concentration / units for a species that declares no scalar
# `default`. esm-spec §7.4 pins a species' initial value to `species.default`
# ("Initial conditions. A species' initial value is its scalar
# `species.default`") but specifies NO fallback value or unit system when it is
# absent — `1.0` in `"mol/L"` is this library's historical convention, kept for
# backward compatibility of `derive_odes` output.
const DEFAULT_SPECIES_CONCENTRATION = 1.0
const DEFAULT_SPECIES_UNITS = "mol/L"

"""
    each_stoich_term(rxn::Reaction) -> Vector{Tuple{String,Float64}}

The reaction's stoichiometry as `(species, signed_stoichiometry)` pairs:
substrates first with NEGATIVE sign, then products with POSITIVE sign, each
side in its declared order. Uses `raw_substrates`/`raw_products`, which bypass
the backward-compat `getproperty` Dict shim on `Reaction`. This is the single
signed-stoichiometry iteration shared by `lower_reactions_to_equations`,
`stoichiometric_matrix`, and flatten's reaction-species collection
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

Generate an ODE model from a reaction system using standard mass action kinetics.

Creates state variables for each species, parameters for rate constants, and equations
with d[species]/dt = net_stoichiometry * rate_law. Handles source reactions (null
substrates), sink reactions (null products), and constraint equations.

# Arguments
- `rxn_sys::ReactionSystem`: Input reaction system with species, reactions, and parameters

# Returns
- `Model`: ODE model with variables, equations, and optional events/subsystems

# Algorithm (Libraries Spec Section 7.4)
1. Create state variables for all species in the reaction system, except
   reservoir species (`constant: true`), which become parameters
2. Create parameter variables for all parameters (rate constants)
3. For each reaction, compute the mass action rate expression
4. For each species, compute the net rate of change from all reactions
5. Create differential equations d[species]/dt = net_rate, except for
   reservoir species, which are held fixed and get none

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
    # Each species keeps its declared default, description and units; the
    # library conventions fill in only what it does not declare.
    variables = reaction_variables(rxn_sys)
    for species in rxn_sys.species
        v = variables[species.name]
        variables[species.name] = reconstruct(
            v; default = something(v.default, DEFAULT_SPECIES_CONCENTRATION),
            description = something(v.description, "Concentration of species $(species.name)"),
            units = something(v.units, DEFAULT_SPECIES_UNITS)
        )
    end

    # Equations come from the shared lowering helper used by flatten.
    equations = lower_reactions_to_equations(rxn_sys.reactions, rxn_sys.species)

    # Handle subsystems recursively
    subsystems = Dict{String, Model}()
    for (name, subsys) in rxn_sys.subsystems
        subsystems[name] = derive_odes(subsys)
    end

    return Model(variables, equations, subsystems = subsystems)
end

"""
    stoichiometric_matrix(rxn_sys::ReactionSystem) -> Matrix{Float64}

Compute the net stoichiometric matrix (species × reactions).

The stoichiometric matrix S has dimensions (n_species × n_reactions) where:
- S[i,j] = net stoichiometry of species i in reaction j
- Net stoichiometry = products - reactants
- Positive values indicate production, negative values indicate consumption

Values are `Float64` because v0.2.x allows fractional stoichiometries
(e.g. `ISOP+O3 → 0.87 CH2O`). Integer-only systems produce a matrix whose
entries happen to be exact integers stored as `Float64`.

# Arguments
- `rxn_sys::ReactionSystem`: Input reaction system

# Returns
- `Matrix{Float64}`: Stoichiometric matrix with dimensions (n_species, n_reactions)

# Examples
```julia
# For reaction A + B -> 2C:
# S = [-1  # A consumed
#      -1  # B consumed
#       2] # C produced (2 molecules)
```
"""
function stoichiometric_matrix(rxn_sys::ReactionSystem)::Matrix{Float64}
    n_species = length(rxn_sys.species)
    n_reactions = length(rxn_sys.reactions)

    # Create species name to index mapping
    species_idx = Dict(species.name => i for (i, species) in enumerate(rxn_sys.species))

    # Initialize stoichiometric matrix
    S = zeros(Float64, n_species, n_reactions)

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

Compute the mass action rate expression for a reaction.

Uses standard mass action kinetics: `rate = k * ∏[reactants]^stoichiometry`.

Per `esm-spec.md` §7.4 the `reaction.rate` field is the rate **coefficient**
(`k`, possibly a temperature-dependent expression). The full rate law is
always `k · ∏ Sᵢ^nᵢ` — the runner unconditionally multiplies the coefficient
by the substrate product. Source reactions (no substrates) return the
coefficient unchanged.

# Arguments
- `reaction::Reaction`: The reaction to compute the rate for
- `species::Vector{Species}`: All species in the system (unused by this
  helper; retained for API stability and future validation)

# Returns
- `ASTExpr`: Mass action rate expression

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

    # Source reactions (no substrates): the rate expression IS the full rate.
    if reaction.substrates === nothing || isempty(reaction.substrates)
        return rate_expr
    end

    # Always multiply the rate coefficient by ∏[substrate]^stoich (spec §7.4).
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

    # The substrate loop above pushed at least one factor (the early return
    # covers the no-substrate case), so there are always ≥ 2 terms here.
    return OpExpr("*", mass_action_terms)
end

# ========================================
# Reaction Lowering Helper (§4.6 + §4.7.6)
# ========================================

"""
    lower_reactions_to_equations(reactions, species) -> Vector{Equation}

Produce the ODE equations induced by a set of reactions using standard
mass-action kinetics: `d[X]/dt = Σ (stoich_ij * rate_j)`.

Shared by `derive_odes` (reaction → Model) and `flatten` (EsmFile → FlattenedSystem)
so there is exactly one place that turns stoichiometry into equations.

The tree is the canonical form esm-libraries-spec §4.6.2 pins byte for byte
across the bindings (`tests/conformance/reactions/lowering_form.json`): an
n-ary `+` over the species' terms in reaction order, each term the bare rate
law or `stoich * rate` with an integer literal for an integral coefficient.

The LHS is always `D(X, t)` symbolically, regardless of the document's
domain — dimension promotion (§4.7.6) is applied by `flatten`, not here.
Spatial operators are added downstream when coupling adds them.

A species with `constant: true` is a RESERVOIR (§7.4): it is held fixed, so no
`D(X, t)` equation is emitted for it, while it still contributes its
concentration to every rate law it appears in. It is therefore skipped as an
equation TARGET only — it stays in `species` so `mass_action_rate` keeps
reading it as a substrate/product factor.

A species whose NET stoichiometry is zero in every reaction likewise gets no
equation — usually because it appears in no reaction at all, but a catalyst
(equal substrate and product stoichiometry everywhere it appears) meets the same
test. Its rate is the empty sum, and emitting `D(X, t) = 0` for it would make it
a differential unknown that never moves; esm-spec §6.3.1 classifies by
COMPLEMENT, so leaving the equation out is what makes it the ALGEBRAIC unknown it
is. See the comment at the skip below.
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
                # A substrate or product the system does not declare is refused,
                # not dropped: dropping it lowers a different reaction (a product
                # that is never produced) with no diagnostic (esm-spec §7.2,
                # `undefined_species`). The other bindings refuse it too.
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
            # Reservoir species (§7.4): held fixed, so it gets no ODE. Its
            # mass-action contribution to the OTHER species' rates is untouched —
            # `mass_action_rate` reads it from the reaction either way.
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
        # A species with NO net contribution from any reaction gets NO equation,
        # rather than a vacuous `D(X, t) = 0`. The empty sum is zero, so emitting
        # it is defensible arithmetic — but esm-spec §6.3.1 classifies by
        # COMPLEMENT, and the two readings give the species different roles: with
        # the equation it is a differential unknown that never moves, without it
        # an unknown no equation names, i.e. ALGEBRAIC. §6.3.1 is the operative
        # rule and the second is its answer.
        #
        # This is also what the other four bindings do (Python `reactions.py`,
        # Rust `reactions.rs`, Go `flatten.go`, TypeScript `reactions.ts`); Julia
        # emitting the zero was a 4-1 outlier, and the divergence was recorded in
        # `flatten_conformance_test.jl`'s `_FC_DIVERGENCES` until this changed.
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
