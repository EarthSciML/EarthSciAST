"""Turn a reaction system into ordinary differential equations."""

from pathlib import Path

import numpy as np

import earthsci_ast

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


# region: reactions ops=derive_odes,reaction_system,species,reaction
doc = earthsci_ast.load_path(FIXTURES / "ozone.esm")
system = doc.reaction_systems["Ozone"]
assert [s.name for s in system.species] == ["O3", "NO", "NO2"]
assert [r.id for r in system.reactions] == ["R1", "R2"]

odes = earthsci_ast.derive_odes(system)
for eq in odes.equations:
    print(earthsci_ast.to_ascii(eq))

# One equation per species, in declaration order; rate constants become parameters.
assert earthsci_ast.ode_states(odes) == ["NO", "NO2", "O3"]
assert [eq.lhs.args[0] for eq in odes.equations] == ["O3", "NO", "NO2"]
assert odes.variables["k1"].type == "parameter"
assert earthsci_ast.to_ascii(odes.equations[2]) == "D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2"
# endregion


# region: stoichiometric_matrix ops=stoichiometric_matrix,substrate_matrix,product_matrix
# Rows are species (O3, NO, NO2) and columns are reactions (R1, R2).
net = earthsci_ast.stoichiometric_matrix(system)
assert np.array_equal(net, [[-1, 1], [-1, 1], [1, -1]])

consumed = earthsci_ast.substrate_matrix(system)
produced = earthsci_ast.product_matrix(system)
assert np.array_equal(produced - consumed, net)
# endregion
