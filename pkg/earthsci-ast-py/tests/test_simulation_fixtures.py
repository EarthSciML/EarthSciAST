"""Simulation-oriented ESM integration tests.

Verifies that models and reaction systems shaped for simulation (state
variables, parameters, rate constants, ODE right-hand sides) survive the
earthsci_ast save/load round trip with their simulation-relevant
structure intact.

Historical note: this module once carried a large suite of numpy / scipy /
sympy / matplotlib self-tests (broadcasting, solve_ivp accuracy, optimizer
convergence, Jupyter reprs, multiprocessing, wall-clock benchmarks). Those
tested the vendored libraries rather than this package and were removed;
only the ESM-format integration tests remain.
"""

from earthsci_ast.esm_types import (
    Model,
    ModelVariable,
    Equation,
    ExprNode,
    EsmFile,
    Metadata,
    ReactionSystem,
    Species,
    Parameter,
    Reaction,
)
from earthsci_ast.parse import load
from earthsci_ast.serialize import save


class TestEarthSciASTIntegration:
    """Test integration of simulation capabilities with ESM format."""

    def test_simulation_model_serialization(self):
        """Test serialization of models suitable for simulation."""
        # Create a model representing exponential decay.
        # The units are REAL unit strings: "concentration", "1/time" and "time"
        # name a physical *quantity*, not a unit, and no binding's registry
        # resolves them — which is now a hard `unit_inconsistency` error rather
        # than a silently-ignored warning.
        model = Model(
            name="exponential_decay",
            variables={
                "x": ModelVariable(type="state", units="mol/L", default=1.0),
                "k": ModelVariable(type="parameter", units="1/s", default=0.1),
                "t": ModelVariable(type="parameter", units="s", default=0.0),
            },
            equations=[
                Equation(
                    lhs=ExprNode(op="D", args=["x"], wrt="t"),
                    rhs=ExprNode(op="*", args=[ExprNode(op="-", args=["k"]), "x"]),
                )
            ],
        )

        # Create ESM file
        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Exponential Decay Simulation"),
            models={"exponential_decay": model},
        )

        # Serialize and deserialize
        json_str = save(esm_file)
        reconstructed = load(json_str)

        # Verify simulation-relevant properties
        assert len(reconstructed.models) == 1
        recon_model = reconstructed.models["exponential_decay"]
        assert recon_model.name == "exponential_decay"
        assert "x" in recon_model.variables
        assert "k" in recon_model.variables
        assert recon_model.variables["x"].type == "state"
        assert recon_model.variables["k"].type == "parameter"

    def test_reaction_system_simulation_setup(self):
        """Test setting up reaction systems for simulation."""
        # Create a simple reaction system: A -> B
        reaction_system = ReactionSystem(
            name="simple_decay",
            species=[Species(name="A", units="mol/L"), Species(name="B", units="mol/L")],
            parameters=[Parameter(name="k1", value=0.5, units="1/s")],
            reactions=[
                Reaction(
                    name="A_to_B", reactants={"A": 1.0}, products={"B": 1.0}, rate_constant="k1"
                )
            ],
        )

        # Create ESM file with reaction system
        esm_file = EsmFile(
            version="0.1.0",
            metadata=Metadata(title="Reaction System Simulation"),
            reaction_systems={"simple_decay": reaction_system},
        )

        # Test serialization
        json_str = save(esm_file)
        reconstructed = load(json_str)

        # Verify reaction system for simulation
        assert len(reconstructed.reaction_systems) == 1
        rs = reconstructed.reaction_systems["simple_decay"]

        # Check species (state variables)
        assert len(rs.species) == 2
        species_names = {sp.name for sp in rs.species}
        assert species_names == {"A", "B"}

        # Check parameters
        assert len(rs.parameters) == 1
        assert rs.parameters[0].name == "k1"
        assert rs.parameters[0].value == 0.5

        # Check reaction (defines dynamics)
        assert len(rs.reactions) == 1
        reaction = rs.reactions[0]
        assert reaction.reactants == {"A": 1.0}
        assert reaction.products == {"B": 1.0}
        assert reaction.rate_constant == "k1"
