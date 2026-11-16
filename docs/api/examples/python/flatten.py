"""Flatten a coupled document into one system."""

from pathlib import Path

import earthsci_ast
from earthsci_ast import ExprNode

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


# region: flatten ops=flatten,flattened_system,flattened_equation,flattened_variable
coupled = earthsci_ast.load_path(FIXTURES / "coupled.esm")
flat = earthsci_ast.flatten(coupled)

# Every name is now qualified by the model it came from.
assert list(flat.state_variables) == ["Heater.T", "Box.T_air"]
assert {"Heater.rate", "Box.k"} <= set(flat.parameters)
for name, var in flat.state_variables.items():
    print(f"{name}: {var.units}, default {var.default}")

heater, box = flat.equations
assert heater.lhs == ExprNode(op="D", args=["Heater.T"], wrt="t")
assert heater.rhs == "Heater.rate"

# The param_to_var variable_map replaced the box's wall-temperature parameter
# with the heater's temperature: it is gone from the equations AND from the
# parameters.
assert box.rhs == ExprNode(op="*", args=["Box.k", ExprNode(op="-", args=["Heater.T", "Box.T_air"])])
assert "Box.T_wall" not in earthsci_ast.free_variables(box.rhs)
assert "Box.T_wall" not in flat.parameters
assert flat.metadata.source_systems == ["Heater", "Box"]
# endregion
