"""
Test cases for reaction system analysis functions.
"""

import pytest
import numpy as np

from earthsci_ast import (
    ReactionSystem,
    Reaction,
    Species,
    Parameter,
    derive_odes,
    stoichiometric_matrix,
    substrate_matrix,
    product_matrix,
    ExprNode,
)


class TestStoichiometricMatrix:
    """Test cases for stoichiometric matrix computation."""

    def test_empty_system(self):
        """Test empty reaction system returns empty matrix."""
        system = ReactionSystem(name="empty", species=[], reactions=[])
        matrix = stoichiometric_matrix(system)
        assert matrix.size == 0

    def test_simple_reaction(self):
        """Test simple A -> B reaction."""
        species_A = Species(name="A")
        species_B = Species(name="B")

        reaction = Reaction(name="A_to_B", reactants={"A": 1.0}, products={"B": 1.0})

        system = ReactionSystem(name="simple", species=[species_A, species_B], reactions=[reaction])

        matrix = stoichiometric_matrix(system)
        expected = np.array([[-1.0], [1.0]])
        np.testing.assert_allclose(matrix, expected)

    def test_multiple_reactions(self):
        """Test system with multiple reactions: A -> B -> C."""
        species = [Species(name=name) for name in ["A", "B", "C"]]

        reactions = [
            Reaction(name="r1", reactants={"A": 1.0}, products={"B": 1.0}),
            Reaction(name="r2", reactants={"B": 1.0}, products={"C": 1.0}),
        ]

        system = ReactionSystem(name="sequential", species=species, reactions=reactions)

        matrix = stoichiometric_matrix(system)
        expected = np.array(
            [
                [-1.0, 0.0],  # A
                [1.0, -1.0],  # B
                [0.0, 1.0],  # C
            ]
        )
        np.testing.assert_allclose(matrix, expected)

    def test_reaction_with_coefficients(self):
        """Test reaction with stoichiometric coefficients > 1."""
        species = [Species(name=name) for name in ["A", "B", "C"]]

        # 2A + B -> 3C
        reaction = Reaction(name="complex", reactants={"A": 2.0, "B": 1.0}, products={"C": 3.0})

        system = ReactionSystem(name="complex_stoich", species=species, reactions=[reaction])

        matrix = stoichiometric_matrix(system)
        expected = np.array([[-2.0], [-1.0], [3.0]])
        np.testing.assert_allclose(matrix, expected)


class TestSubstrateProductMatrices:
    """Test cases for substrate and product matrix computation."""

    def test_substrate_matrix(self):
        """Test substrate matrix computation."""
        species = [Species(name=name) for name in ["A", "B", "C"]]

        reaction = Reaction(name="r1", reactants={"A": 2.0, "B": 1.0}, products={"C": 1.0})

        system = ReactionSystem(name="test", species=species, reactions=[reaction])

        matrix = substrate_matrix(system)
        expected = np.array([[2.0], [1.0], [0.0]])
        np.testing.assert_allclose(matrix, expected)

    def test_product_matrix(self):
        """Test product matrix computation."""
        species = [Species(name=name) for name in ["A", "B", "C"]]

        reaction = Reaction(name="r1", reactants={"A": 2.0, "B": 1.0}, products={"C": 3.0})

        system = ReactionSystem(name="test", species=species, reactions=[reaction])

        matrix = product_matrix(system)
        expected = np.array([[0.0], [0.0], [3.0]])
        np.testing.assert_allclose(matrix, expected)

    def test_matrix_consistency(self):
        """Test that stoich = product - substrate."""
        species = [Species(name=name) for name in ["A", "B", "C"]]

        reactions = [
            Reaction(name="r1", reactants={"A": 1.0}, products={"B": 1.0}),
            Reaction(name="r2", reactants={"B": 2.0}, products={"C": 1.0}),
        ]

        system = ReactionSystem(name="test", species=species, reactions=reactions)

        stoich = stoichiometric_matrix(system)
        substrate = substrate_matrix(system)
        product = product_matrix(system)

        # Stoichiometric matrix should equal product - substrate
        calculated_stoich = product - substrate
        np.testing.assert_allclose(stoich, calculated_stoich)


class TestDeriveODEs:
    """Test cases for ODE derivation from reaction systems."""

    def test_empty_system_error(self):
        """Test that empty systems raise appropriate errors."""
        with pytest.raises(ValueError, match="must contain at least one species"):
            derive_odes(ReactionSystem(name="empty", species=[], reactions=[]))

        species = [Species(name="A")]
        system = ReactionSystem(name="no_reactions", species=species, reactions=[])
        with pytest.raises(ValueError, match="must contain at least one reaction"):
            derive_odes(system)

    def test_missing_rate_constant(self):
        """Test that reactions without rate constants raise errors."""
        species = [Species(name="A"), Species(name="B")]
        reaction = Reaction(
            name="r1", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant=None
        )
        system = ReactionSystem(name="test", species=species, reactions=[reaction])

        with pytest.raises(ValueError, match="must have a rate constant"):
            derive_odes(system)

    def test_simple_ode_derivation(self):
        """Test ODE derivation for simple A -> B reaction."""
        species_A = Species(name="A", units="mol/L")
        species_B = Species(name="B", units="mol/L")
        k1 = Parameter(name="k1", value=0.1, units="1/s")

        reaction = Reaction(
            name="A_to_B", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant="k1"
        )

        system = ReactionSystem(
            name="simple", species=[species_A, species_B], parameters=[k1], reactions=[reaction]
        )

        model = derive_odes(system)

        # Check model structure
        assert model.name == "simple_odes"
        assert len(model.variables) == 3  # A, B, k1
        assert len(model.equations) == 2  # d[A]/dt, d[B]/dt

        # Check variable types
        assert model.variables["A"].type == "state"
        assert model.variables["B"].type == "state"
        assert model.variables["k1"].type == "parameter"

        # Check equations structure (they should be differential equations)
        for eq in model.equations:
            assert isinstance(eq.lhs, ExprNode)
            assert eq.lhs.op == "D"
            assert eq.lhs.wrt == "t"

    def test_unknown_species_error(self):
        """Test error when reaction references unknown species."""
        species_A = Species(name="A")
        k1 = Parameter(name="k1", value=0.1)

        # Reaction references species "B" that's not in species list
        reaction = Reaction(
            name="invalid",
            reactants={"B": 1.0},  # "B" not in species list
            products={"A": 1.0},
            rate_constant="k1",
        )

        system = ReactionSystem(
            name="invalid", species=[species_A], parameters=[k1], reactions=[reaction]
        )

        with pytest.raises(ValueError, match="not found in species list"):
            derive_odes(system)

    def test_complex_reaction_system(self):
        """Test ODE derivation for more complex system."""
        species = [Species(name=name, units="mol/L") for name in ["A", "B", "C"]]
        parameters = [
            Parameter(name="k1", value=0.1, units="1/s"),
            Parameter(name="k2", value=0.05, units="1/s"),
        ]

        reactions = [
            Reaction(name="r1", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant="k1"),
            Reaction(name="r2", reactants={"B": 1.0}, products={"C": 1.0}, rate_constant="k2"),
        ]

        system = ReactionSystem(
            name="sequential", species=species, parameters=parameters, reactions=reactions
        )

        model = derive_odes(system)

        # Check we have all variables and equations
        assert len(model.variables) == 5  # A, B, C, k1, k2
        assert len(model.equations) == 3  # d[A]/dt, d[B]/dt, d[C]/dt

        # Check parameter defaults are preserved
        assert model.variables["k1"].default == 0.1
        assert model.variables["k2"].default == 0.05

    def test_source_and_sink_reactions(self):
        """Test reactions with no reactants (source) or no products (sink)."""
        species = [Species(name=name) for name in ["A", "B"]]
        parameters = [Parameter(name="k_source", value=1.0), Parameter(name="k_sink", value=0.1)]

        reactions = [
            # Source reaction: -> A (no reactants)
            Reaction(name="source", reactants={}, products={"A": 1.0}, rate_constant="k_source"),
            # Sink reaction: B -> (no products)
            Reaction(name="sink", reactants={"B": 1.0}, products={}, rate_constant="k_sink"),
        ]

        system = ReactionSystem(
            name="source_sink", species=species, parameters=parameters, reactions=reactions
        )

        model = derive_odes(system)

        # Should successfully create model
        assert model.name == "source_sink_odes"
        assert len(model.equations) == 2  # Both A and B have rate equations

    def test_rate_with_substrate_in_denominator_is_multiplied(self):
        """Per spec §7.4 the ``rate`` field is the coefficient and the runner
        ALWAYS multiplies by the substrate product — even when a substrate
        appears inside the rate (e.g. cancellation form ``k/A``).

        For substrates A+B and rate ``k/A``: rhs(A) = -1 * (k/A) * A * B,
        which simplifies to -k*B. Each substrate appears EXACTLY once in
        the rate-factor multiplication chain (no detect-and-skip heuristic).
        """
        species = [Species(name="A"), Species(name="B")]
        params = [Parameter(name="k", value=0.1)]
        # rate = k / A (substrate appears in denominator — cancellation form)
        cancellation_rate = ExprNode(op="/", args=["k", "A"])
        reaction = Reaction(
            name="r",
            reactants={"A": 1.0, "B": 1.0},
            products={},
            rate_constant=cancellation_rate,
        )
        system = ReactionSystem(
            name="mass_action",
            species=species,
            parameters=params,
            reactions=[reaction],
        )

        model = derive_odes(system)

        da_eq = next(
            eq
            for eq in model.equations
            if isinstance(eq.lhs, ExprNode) and eq.lhs.op == "D" and eq.lhs.args[0] == "A"
        )

        def _count_var(expr, name):
            if isinstance(expr, str):
                return 1 if expr == name else 0
            if isinstance(expr, ExprNode):
                return sum(_count_var(a, name) for a in expr.args)
            return 0

        # rhs contains substrate A twice (once in k/A denominator, once in
        # the mass-action multiplier) and substrate B once.
        assert _count_var(da_eq.rhs, "A") == 2
        assert _count_var(da_eq.rhs, "B") == 1
