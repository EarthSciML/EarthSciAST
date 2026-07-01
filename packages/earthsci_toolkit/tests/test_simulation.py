"""
Tests for the Python simulation tier with SciPy integration.

This module tests the core simulation functionality including:
- Basic ODE system simulation
- Mass-action kinetics generation
- Expression conversion to SymPy
- SciPy integration backend
- Event handling capabilities
"""

import pytest
import numpy as np
from earthsci_toolkit.simulation import simulate_reaction_system as simulate, SimulationResult, SimulationError
from earthsci_toolkit.sympy_bridge import _expr_to_sympy
from earthsci_toolkit.numpy_interpreter import UnreachableSpatialOperatorError
from earthsci_toolkit.esm_types import (
    ReactionSystem, Species, Parameter, Reaction,
    ContinuousEvent, ExprNode
)
import sympy as sp


class TestExpressionConversion:
    """Test conversion of ESM expressions to SymPy."""

    def test_simple_constants(self):
        """Test conversion of numeric constants."""
        symbol_map = {}

        # Test integers
        result = _expr_to_sympy(42, symbol_map)
        assert result == sp.Float(42)

        # Test floats
        result = _expr_to_sympy(3.14, symbol_map)
        assert result == sp.Float(3.14)

    def test_variables(self):
        """Test conversion of variable names."""
        symbol_map = {}

        result = _expr_to_sympy("x", symbol_map)
        assert str(result) == "x"
        assert "x" in symbol_map

        # Should reuse existing symbols
        result2 = _expr_to_sympy("x", symbol_map)
        assert result == result2

    def test_arithmetic_operations(self):
        """Test conversion of arithmetic operations."""
        symbol_map = {"x": sp.Symbol("x"), "y": sp.Symbol("y")}

        # Addition
        expr = ExprNode(op="+", args=["x", "y"])
        result = _expr_to_sympy(expr, symbol_map)
        expected = symbol_map["x"] + symbol_map["y"]
        assert result.equals(expected)

        # Multiplication
        expr = ExprNode(op="*", args=["x", 2])
        result = _expr_to_sympy(expr, symbol_map)
        expected = symbol_map["x"] * 2
        assert result.equals(expected)

        # Division
        expr = ExprNode(op="/", args=["x", "y"])
        result = _expr_to_sympy(expr, symbol_map)
        expected = symbol_map["x"] / symbol_map["y"]
        assert result.equals(expected)

    def test_functions(self):
        """Test conversion of mathematical functions."""
        symbol_map = {"x": sp.Symbol("x")}

        # Exponential
        expr = ExprNode(op="exp", args=["x"])
        result = _expr_to_sympy(expr, symbol_map)
        expected = sp.exp(symbol_map["x"])
        assert result.equals(expected)

        # Logarithm
        expr = ExprNode(op="log", args=["x"])
        result = _expr_to_sympy(expr, symbol_map)
        expected = sp.log(symbol_map["x"])
        assert result.equals(expected)

    @pytest.mark.parametrize("spatial_op", ["grad", "div", "laplacian"])
    def test_spatial_operator_rejected(self, spatial_op):
        """esm-i7b: feeding a non-discretized AST containing a spatial
        differential operator (`grad`/`div`/`laplacian`) to the
        SymPy/lambdify simulator path must raise the canonical
        pipeline-violation error rather than silently producing a
        symbolic placeholder."""
        symbol_map = {"u": sp.Symbol("u")}
        expr = ExprNode(op=spatial_op, args=["u"])
        with pytest.raises(UnreachableSpatialOperatorError) as excinfo:
            _expr_to_sympy(expr, symbol_map)
        msg = str(excinfo.value)
        assert "UnreachableSpatialOperatorError" in msg
        assert spatial_op in msg
        assert "Pipeline contract violated" in msg
        assert excinfo.value.op == spatial_op


class TestSimpleReactionSystems:
    """Test simulation of simple reaction systems."""

    def test_single_decay_reaction(self):
        """Test A -> products with rate k."""
        # Create species
        species_A = Species(name="A", formula="A")

        # Create parameter
        k = Parameter(name="k", value=0.1)

        # Create reaction: A -> (products) with rate k*[A]
        reaction = Reaction(
            name="decay",
            reactants={"A": 1.0},
            products={},  # Products are removed from system
            rate_constant=0.1
        )

        # Create reaction system
        system = ReactionSystem(
            name="decay_system",
            species=[species_A],
            parameters=[k],
            reactions=[reaction]
        )

        # Initial conditions
        initial = {"A": 1.0}

        # Simulate
        result = simulate(system, initial, (0, 10))

        # Check result
        assert result.success, f"Simulation failed: {result.message}"
        assert len(result.t) > 1
        assert result.y.shape[0] == 1  # One species

        # Check exponential decay behavior
        A_final = result.y[0, -1]
        A_initial = result.y[0, 0]
        assert A_final < A_initial  # Should decay
        assert A_final > 0  # Should not go negative

    def test_reversible_reaction(self):
        """Test A <-> B reversible reaction."""
        # Create species
        species_A = Species(name="A")
        species_B = Species(name="B")

        # Forward reaction: A -> B
        reaction_fwd = Reaction(
            name="forward",
            reactants={"A": 1.0},
            products={"B": 1.0},
            rate_constant=0.5
        )

        # Reverse reaction: B -> A
        reaction_rev = Reaction(
            name="reverse",
            reactants={"B": 1.0},
            products={"A": 1.0},
            rate_constant=0.2
        )

        # Create system
        system = ReactionSystem(
            name="reversible",
            species=[species_A, species_B],
            reactions=[reaction_fwd, reaction_rev]
        )

        # Initial conditions: only A present
        initial = {"A": 1.0, "B": 0.0}

        # Simulate
        result = simulate(system, initial, (0, 20))

        # Check success
        assert result.success, f"Simulation failed: {result.message}"

        # Check conservation: A + B should be approximately constant
        total = result.y[0, :] + result.y[1, :]  # A + B
        initial_total = initial["A"] + initial["B"]

        # Allow small numerical errors
        assert np.allclose(total, initial_total, atol=1e-6), "Mass not conserved"

    def test_empty_system(self):
        """Test handling of empty reaction system."""
        system = ReactionSystem(
            name="empty",
            species=[],
            reactions=[]
        )

        initial = {}
        result = simulate(system, initial, (0, 1))

        # Should handle empty system gracefully
        assert not result.success  # Empty systems should fail appropriately

    def test_simulation_with_events(self):
        """Test simulation with continuous events."""
        # Simple decay system
        species_A = Species(name="A")

        reaction = Reaction(
            name="decay",
            reactants={"A": 1.0},
            products={},
            rate_constant=0.1
        )

        system = ReactionSystem(
            name="decay_with_event",
            species=[species_A],
            reactions=[reaction]
        )

        # Event: stop when A drops below 0.5
        event_condition = ExprNode(op="-", args=["A", 0.5])  # A - 0.5
        event = ContinuousEvent(
            name="threshold",
            conditions=[event_condition],  # Changed to array
            affects=[]
        )

        initial = {"A": 1.0}

        # Simulate with event
        result = simulate(system, initial, (0, 20), events=[event])

        # Check that simulation stopped early due to event
        assert result.success or "event" in result.message.lower()


class TestSimulationErrors:
    """Test error handling in simulation."""

    def test_invalid_initial_conditions(self):
        """Test handling of invalid initial conditions."""
        species_A = Species(name="A")
        reaction = Reaction(name="r1", rate_constant=0.1)

        system = ReactionSystem(
            name="test",
            species=[species_A],
            reactions=[reaction]
        )

        # Missing initial condition should default to 0
        result = simulate(system, {}, (0, 1))
        # This should still work, just with zero initial conditions

    def test_invalid_time_span(self):
        """Test handling of invalid time spans."""
        species_A = Species(name="A")
        system = ReactionSystem(name="test", species=[species_A])

        # Backwards time span
        result = simulate(system, {"A": 1.0}, (10, 0))

        # SciPy should handle this or return an error
        # We just check that we get a result (success or failure)
        assert isinstance(result, SimulationResult)

    def test_species_default_used_as_initial_value(self):
        """simulate_reaction_system seeds y0 from each species' `default`.

        When an initial condition is omitted, the species' declared scalar
        `default` (here 3.0) must be used instead of 0.0; an explicit override
        still wins, and a species with no default falls back to 0.0.
        """
        species_A = Species(name="A", default=3.0)
        species_B = Species(name="B")  # no default -> 0.0 fallback
        # Effectively frozen reaction so the reported t=0 state is exactly y0.
        reaction = Reaction(
            name="slow",
            reactants={"A": 1.0},
            products={"B": 1.0},
            rate_constant=1e-12,
        )
        system = ReactionSystem(
            name="defaults",
            species=[species_A, species_B],
            reactions=[reaction],
        )

        # No initial conditions: A starts at its declared default, B at 0.0.
        result = simulate(system, {}, (0.0, 1.0))
        assert result.success, f"Simulation failed: {result.message}"
        idx = {name: i for i, name in enumerate(result.vars)}
        assert result.y[idx["A"], 0] == pytest.approx(3.0)
        assert result.y[idx["B"], 0] == pytest.approx(0.0)

        # An explicit override still wins over the species default.
        result2 = simulate(system, {"A": 0.5}, (0.0, 1.0))
        assert result2.success, f"Simulation failed: {result2.message}"
        idx2 = {name: i for i, name in enumerate(result2.vars)}
        assert result2.y[idx2["A"], 0] == pytest.approx(0.5)


if __name__ == "__main__":
    pytest.main([__file__])