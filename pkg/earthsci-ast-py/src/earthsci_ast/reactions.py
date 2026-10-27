"""
Reaction system analysis and ODE generation functions.

This module provides functions to:
1. Generate ODE systems from reaction systems using mass action kinetics
2. Compute stoichiometric matrices for reaction networks
3. Handle substrate and product matrices separately
"""

from __future__ import annotations

import numpy as np

from .esm_types import (
    Equation,
    Expr,
    ExprNode,
    Model,
    ModelVariable,
    Reaction,
    ReactionSystem,
    Species,
)


def lower_reactions_to_equations(
    reactions: list[Reaction],
    species: list[Species],
) -> list[Equation]:
    """
    Lower a list of reactions into ODE equations using mass-action kinetics.

    Canonical mass-action helper shared by :func:`derive_odes` (which wraps the
    result in a :class:`Model`) and the SciPy simulation path in
    ``simulation.py`` (which converts these equations to SymPy for lambdify).
    Mirrors the single-implementation pattern used by the Rust and Julia
    toolkits — there is exactly one mass-action lowering in Python.

    Builds ``d[species]/dt = sum_r net_stoich(species, r) * rate(r)`` expressions
    using ESM :class:`ExprNode` trees (not SymPy), so the output is directly
    usable by any consumer that handles the ESM expression AST. The tree is the
    canonical form of esm-libraries-spec §4.6.2, which every binding emits byte
    for byte (``tests/conformance/reactions/lowering_form.json``): one n-ary
    ``+`` over a species' terms in reaction order, each term the bare rate law
    for a net coefficient of 1 and ``coefficient * rate`` otherwise, with an
    integer literal for an integral coefficient.

    Args:
        reactions: List of reactions in the system.
        species: List of species in the system. Used for both ordering and
            validation (reactants OR products referencing unknown species are
            rejected).

    Returns:
        List of :class:`Equation` objects of the form
        ``D(species, t) = rhs``. Only species with non-zero net rates are
        included; species that don't participate in any reaction are omitted.

    Raises:
        ValueError: If any reaction has no rate_constant, or references a
            reactant or product that isn't in the species list.
    """
    species_names = [s.name for s in species]
    # Reservoir species (`constant: true`, §7.4): held fixed, so they get NO
    # dX/dt equation. Their concentration is STILL a mass-action factor in the
    # rate laws of the other species (built below from ``reaction.reactants``),
    # so the only change here is to skip emitting their own ODE — mirroring the
    # Julia reference (flatten.jl `lower_reactions_to_equations`,
    # `species[i].constant === true && continue`).
    constant_names = {s.name for s in species if s.constant is True}
    # Each species' terms, in reaction order. A list rather than a running sum:
    # the canonical form (esm-libraries-spec §4.6.2) is ONE n-ary ``+`` over the
    # terms, and an empty list -- not a literal zero -- is what means "no
    # equation".
    species_terms: dict[str, list[Expr]] = {name: [] for name in species_names}

    for reaction in reactions:
        if reaction.rate_constant is None:
            raise ValueError(f"Reaction {reaction.name} must have a rate constant")

        for reactant in reaction.reactants:
            if reactant not in species_names:
                raise ValueError(f"Reactant {reactant} not found in species list")

        for product in reaction.products:
            if product not in species_names:
                raise ValueError(f"Product {product} not found in species list")

        # Per esm-spec.md §7.4 the ``rate`` field is the rate COEFFICIENT.
        # The full mass-action rate law is always ``k · ∏ Sᵢ^nᵢ`` -- the
        # runner is responsible for the substrate product. No heuristic, and no
        # simplification: a literal ``1`` or ``0`` rate stays in the tree.
        rate_expr = _mass_action_rate(reaction.rate_constant, reaction.substrate_list())

        # Apply net stoichiometry (product_coeff - reactant_coeff) to the
        # species this reaction names. The maps hold each side's coefficients
        # summed in listed order, so this is `P - S` of §4.6.2 rule 2.
        for species_name in dict.fromkeys([*reaction.reactants, *reaction.products]):
            net_stoich_coeff = reaction.products.get(species_name, 0) - reaction.reactants.get(
                species_name, 0
            )
            if net_stoich_coeff == 0:
                continue
            if net_stoich_coeff == 1:
                term: Expr = rate_expr
            else:
                term = ExprNode(op="*", args=[_stoich_literal(net_stoich_coeff), rate_expr])
            species_terms[species_name].append(term)

    equations: list[Equation] = []
    for species_name in species_names:
        if species_name in constant_names:
            continue
        terms = species_terms[species_name]
        if not terms:
            continue
        rhs = terms[0] if len(terms) == 1 else ExprNode(op="+", args=list(terms))
        lhs = ExprNode(op="D", args=[species_name], wrt="t")
        equations.append(Equation(lhs=lhs, rhs=rhs))

    return equations


def derive_odes(system: ReactionSystem) -> Model:
    """
    Derive ODEs from a reaction system using mass action kinetics.

    Thin wrapper around :func:`lower_reactions_to_equations` that bundles the
    resulting equations with a ``variables`` dict (state variables for species,
    parameter variables for rate constants) into a :class:`Model`. Handles
    source reactions (null substrates) and sink reactions (null products).

    Args:
        system: ReactionSystem containing species, reactions, and parameters

    Returns:
        Model: Mathematical model with ODE equations for each species

    Raises:
        ValueError: If system is empty or contains invalid reactions
    """
    if not system.species:
        raise ValueError("ReactionSystem must contain at least one species")

    if not system.reactions:
        raise ValueError("ReactionSystem must contain at least one reaction")

    variables: dict[str, ModelVariable] = {}

    for species in system.species:
        # Reservoir species (`constant: true`, §7.4) are held fixed and get no
        # ODE, so they lower to PARAMETERS carrying their declared ``default``
        # as the fixed value — the same treatment as the flatten path
        # (`_collect_reaction_system`) and the Julia reference (reactions.jl
        # `derive_odes`, namespacing.jl `_collect_reaction_system!`).
        if species.constant is True:
            variables[species.name] = ModelVariable(
                type="parameter",
                units=species.units,
                default=species.default,
                description=f"Concentration of {species.name} (reservoir, held fixed)",
            )
        else:
            variables[species.name] = ModelVariable(
                # An UNKNOWN: the ODE derived below is what makes it a state.
                # 1.0.0 has no `state` type to declare -- ODE-state-ness follows
                # from the D(.,t) equation, which `derive_odes` emits.
                type="unknown",
                units=species.units,
                description=f"Concentration of {species.name}",
            )

    # A reaction parameter whose `value` is a NUMBER is a plain parameter. One
    # whose value is an EXPRESSION (a temperature-dependent rate constant, say)
    # is no longer expressible as a parameter at all: 1.0.0 gives a parameter a
    # `default` or a `distribution`, never a formula. It lowers to an UNKNOWN
    # defined by a bare-variable-LHS equation -- which is what an observed IS
    # (esm-spec §6.3.1), and what the value already meant.
    derived_equations: list[Equation] = []
    for param in system.parameters:
        if isinstance(param.value, (int, float)) and not isinstance(param.value, bool):
            # The §6.3 value model travels with the parameter. ``update`` above
            # all: it is the only channel binding a parameter to a data source
            # (esm-spec §5.4), so dropping it here would lower a data-driven
            # parameter to a constant. Mirrors the Julia reference
            # (reactions.jl `derive_odes`).
            variables[param.name] = ModelVariable(
                type="parameter",
                units=param.units,
                description=param.description,
                default=param.value,
                default_units=param.default_units,
                shape=param.shape,
                distribution=param.distribution,
                update=param.update,
            )
            continue
        # `shape` is the one §6.3 field an unknown can carry; `default_units` /
        # `distribution` / `update` are parameter-only and have no meaning on an
        # observed defined by the equation appended below.
        variables[param.name] = ModelVariable(
            type="unknown",
            units=param.units,
            description=param.description,
            shape=param.shape,
        )
        if param.value is not None:
            derived_equations.append(Equation(lhs=param.name, rhs=param.value))

    equations = derived_equations + lower_reactions_to_equations(system.reactions, system.species)

    return Model(
        name=f"{system.name}_odes",
        variables=variables,
        equations=equations,
        metadata={"derived_from": system.name, "generation_method": "mass_action_kinetics"},
    )


def _build_stoich_matrix(system: ReactionSystem, cell_coeff) -> np.ndarray:
    """Build a ``(n_species, n_reactions)`` coefficient matrix.

    ``cell_coeff(reaction, species_name)`` supplies each entry; the three public
    matrix functions differ only in that per-cell rule. Returns an empty array
    for a system with no species or no reactions.
    """
    if not system.species or not system.reactions:
        return np.array([])

    species_names = [s.name for s in system.species]
    matrix = np.zeros((len(species_names), len(system.reactions)))

    for j, reaction in enumerate(system.reactions):
        for i, species_name in enumerate(species_names):
            matrix[i, j] = cell_coeff(reaction, species_name)

    return matrix


def stoichiometric_matrix(system: ReactionSystem) -> np.ndarray:
    """
    Compute the net stoichiometric matrix for a reaction system.

    The stoichiometric matrix S is defined such that S[i,j] gives the net
    stoichiometric coefficient of species i in reaction j. Negative values
    indicate reactants (consumed), positive values indicate products (formed).

    Args:
        system: ReactionSystem containing species and reactions

    Returns:
        np.ndarray: Stoichiometric matrix with shape (n_species, n_reactions)
                   where S[i,j] = net stoichiometric coefficient of species i in reaction j

    Raises:
        ValueError: If system is empty
    """
    return _build_stoich_matrix(
        system,
        lambda r, s: r.products.get(s, 0) - r.reactants.get(s, 0),
    )


def substrate_matrix(system: ReactionSystem) -> np.ndarray:
    """
    Compute the substrate (reactant) stoichiometric matrix.

    The substrate matrix gives only the reactant stoichiometric coefficients.
    All entries are non-negative, with S[i,j] giving the coefficient of
    species i as a reactant in reaction j.

    Args:
        system: ReactionSystem containing species and reactions

    Returns:
        np.ndarray: Substrate matrix with shape (n_species, n_reactions)
                   where S[i,j] = reactant coefficient of species i in reaction j
    """
    return _build_stoich_matrix(system, lambda r, s: r.reactants.get(s, 0))


def product_matrix(system: ReactionSystem) -> np.ndarray:
    """
    Compute the product stoichiometric matrix.

    The product matrix gives only the product stoichiometric coefficients.
    All entries are non-negative, with P[i,j] giving the coefficient of
    species i as a product in reaction j.

    Args:
        system: ReactionSystem containing species and reactions

    Returns:
        np.ndarray: Product matrix with shape (n_species, n_reactions)
                   where P[i,j] = product coefficient of species i in reaction j
    """
    return _build_stoich_matrix(system, lambda r, s: r.products.get(s, 0))


# Helper functions for the canonical lowering (esm-libraries-spec §4.6.2)


_INT64_BOUND = 2**63


def _stoich_literal(value: int | float) -> int | float:
    """A stoichiometric coefficient or exponent as the literal the tree carries:
    an ``int`` when the value is integral and representable in Int64
    (CONFORMANCE_SPEC §5.5.3.1 rule 3, esm-libraries-spec §4.6.2 rule 5), a
    ``float`` otherwise -- the same cutoff as the other bindings."""
    if isinstance(value, float) and not value.is_integer():
        return value
    if -_INT64_BOUND <= value < _INT64_BOUND:
        return int(value)
    return float(value)


def _mass_action_rate(rate: Expr, reactants: list[tuple[str, int | float]]) -> Expr:
    """The rate law ``k · ∏ Sᵢ^nᵢ``: the coefficient alone for a source
    reaction, otherwise one n-ary ``*`` with the coefficient FIRST and one
    factor per substrate ENTRY in listed order (a species listed twice gives
    two factors) -- the bare species for a coefficient of 1, ``Sᵢ ^ nᵢ``
    otherwise."""
    if not reactants:
        return rate
    factors: list[Expr] = [rate]
    for reactant, coeff in reactants:
        if coeff == 1:
            factors.append(reactant)
        else:
            factors.append(ExprNode(op="^", args=[reactant, _stoich_literal(coeff)]))
    return ExprNode(op="*", args=factors)
