"""Flatten a coupled document into one system."""

from pathlib import Path

import earthsci_ast

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


# region: flatten ops=flatten,flattened_system,flattened_equation,flattened_variable
coupled = earthsci_ast.load_path(FIXTURES / "coupled.esm")
flat = earthsci_ast.flatten(coupled)

# Every name is now qualified by the model it came from.
assert list(flat.state_variables) == ["Heater.T", "Box.T_air"]
assert {"Heater.rate", "Box.k"} <= set(flat.parameters)
for name, var in flat.state_variables.items():
    print(f"{name}: {var.units}, default {var.default}")

for eq in flat.equations:
    print(eq.lhs_str, "=", eq.rhs_str)
heater, box = flat.equations
assert earthsci_ast.to_ascii(heater.rhs) == "Heater.rate"

# The variable_map coupling wired the heater's temperature into the box.
assert earthsci_ast.to_ascii(box.rhs) == "Box.k * (Heater.T - Box.T_air)"
assert "Box.T_wall" not in earthsci_ast.free_variables(box.rhs)
assert flat.metadata.source_systems == ["Heater", "Box"]
# endregion
