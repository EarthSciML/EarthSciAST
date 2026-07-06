"""
Code generation for the ESM format

This module provides functions to generate self-contained scripts
from ESM files in multiple target languages:
- Julia: compatible with ModelingToolkit, Catalyst, EarthSciMLBase, and OrdinaryDiffEq
- Python: compatible with SymPy, earthsci_toolkit, and SciPy
"""

from typing import Any, Dict, List, Union


def to_julia_code(file: Dict[str, Any]) -> str:
    """
    Generate a self-contained Julia script from an ESM file.

    Args:
        file: ESM file dictionary (parsed from JSON)

    Returns:
        Julia script as a string
    """
    lines = []

    # Header comment
    lines.append("# Generated Julia script from ESM file")
    lines.append(f"# ESM version: {file.get('esm', 'unknown')}")
    if file.get("metadata", {}).get("title"):
        lines.append(f"# Title: {file['metadata']['title']}")
    if file.get("metadata", {}).get("description"):
        lines.append(f"# Description: {file['metadata']['description']}")
    lines.append("")

    # Using statements
    lines.append("# Package imports")
    lines.append("using ModelingToolkit")
    lines.append("using Catalyst")
    lines.append("using EarthSciMLBase")
    lines.append("using OrdinaryDiffEq")
    lines.append("using Unitful")
    lines.append("")

    # Generate models
    if file.get("models"):
        lines.append("# Models")
        for name, model in file["models"].items():
            lines.extend(_generate_model_code(name, model))
            lines.append("")

    # Generate reaction systems
    if file.get("reaction_systems"):
        lines.append("# Reaction Systems")
        for name, reaction_system in file["reaction_systems"].items():
            lines.extend(_generate_reaction_system_code(name, reaction_system))
            lines.append("")

    # Generate events
    if file.get("events"):
        lines.append("# Events")
        for name, event in file["events"].items():
            lines.extend(_generate_event_code(name, event))
            lines.append("")

    # Generate coupling placeholders (codegen not yet implemented)
    if file.get("coupling"):
        lines.append("# Coupling (codegen not yet implemented)")
        for coupling in file["coupling"]:
            lines.extend(_generate_coupling_comment(coupling))
        lines.append("")

    # Generate domain placeholders (codegen not yet implemented)
    if file.get("domains"):
        for domain_name, domain_data in file["domains"].items():
            lines.append(f"# Domain '{domain_name}' (codegen not yet implemented)")
            lines.extend(_generate_domain_comment(domain_data))
        lines.append("")

    # Generate data loader placeholders (codegen not yet implemented)
    if file.get("data_loaders"):
        lines.append("# Data Loaders (codegen not yet implemented)")
        for name, data_loader in file["data_loaders"].items():
            lines.extend(_generate_data_loader_comment(name, data_loader))
        lines.append("")

    return "\n".join(lines)


def to_python_code(file: Dict[str, Any]) -> str:
    """
    Generate a self-contained Python script from an ESM file.

    Args:
        file: ESM file dictionary (parsed from JSON)

    Returns:
        Python script as a string
    """
    lines = []

    # Header comment
    lines.append("# Generated Python script from ESM file")
    lines.append(f"# ESM version: {file.get('esm', 'unknown')}")
    if file.get("metadata", {}).get("title"):
        lines.append(f"# Title: {file['metadata']['title']}")
    if file.get("metadata", {}).get("description"):
        lines.append(f"# Description: {file['metadata']['description']}")
    lines.append("")

    # Import statements
    lines.append("# Package imports")
    lines.append("import sympy as sp")
    lines.append("import earthsci_toolkit as esm")
    lines.append("import scipy")
    lines.append("")

    # Generate models
    if file.get("models"):
        lines.append("# Models")
        for name, model in file["models"].items():
            lines.extend(_generate_python_model_code(name, model))
            lines.append("")

    # Generate reaction systems
    if file.get("reaction_systems"):
        lines.append("# Reaction Systems")
        for name, reaction_system in file["reaction_systems"].items():
            lines.extend(_generate_python_reaction_system_code(name, reaction_system))
            lines.append("")

    # Generate simulation stub
    lines.append("# Simulation setup (TODO: Configure parameters)")
    lines.append("tspan = (0, 10)  # time span")
    lines.append("parameters = {}  # parameter values")
    lines.append("initial_conditions = {}  # initial values")
    lines.append("")
    lines.append(
        "# result = esm.simulate(tspan=tspan, parameters=parameters, initial_conditions=initial_conditions)"
    )
    lines.append("")

    # Generate placeholders for features whose codegen is not yet implemented
    if file.get("coupling"):
        lines.append("# Coupling (codegen not yet implemented)")
        for coupling in file["coupling"]:
            lines.extend(_generate_python_coupling_comment(coupling))
        lines.append("")

    if file.get("domains"):
        for domain_name, domain_data in file["domains"].items():
            lines.append(f"# Domain '{domain_name}' (codegen not yet implemented)")
            lines.extend(_generate_python_domain_comment(domain_data))
        lines.append("")

    return "\n".join(lines)


# Helper functions for Julia code generation


def _generate_model_code(name: str, model: Dict[str, Any]) -> List[str]:
    lines = []

    lines.append(f"# Model: {name}")

    # Collect state variables and parameters
    state_vars = []
    parameters = []

    if model.get("variables"):
        for var_name, variable in model["variables"].items():
            if variable.get("type") == "state":
                state_vars.append((var_name, variable))
            elif variable.get("type") == "parameter":
                parameters.append((var_name, variable))

    # Generate @variables declaration
    if state_vars:
        var_decls = " ".join(_format_variable_declaration(name, var) for name, var in state_vars)
        lines.append(f"@variables t {var_decls}")

    # Generate @parameters declaration
    if parameters:
        param_decls = " ".join(_format_variable_declaration(name, var) for name, var in parameters)
        lines.append(f"@parameters {param_decls}")

    # Generate equations
    if model.get("equations"):
        lines.append("")
        lines.append("eqs = [")
        for equation in model["equations"]:
            lines.append(f"    {_format_equation(equation)},")
        lines.append("]")

    # Generate @named ODESystem
    lines.append("")
    lines.append(f"@named {name}_system = ODESystem(eqs)")

    return lines


def _generate_reaction_system_code(name: str, reaction_system: Dict[str, Any]) -> List[str]:
    lines = []

    lines.append(f"# Reaction System: {name}")

    # Generate @species declaration
    if reaction_system.get("species"):
        species_decls = " ".join(
            _format_species_declaration(spec_name, species)
            for spec_name, species in reaction_system["species"].items()
        )
        lines.append(f"@species {species_decls}")

    # Generate @parameters for reaction parameters
    reaction_params = set()
    if reaction_system.get("reactions"):
        for reaction in reaction_system["reactions"].values():
            if reaction.get("rate"):
                param_names = _extract_parameter_names(reaction["rate"])
                reaction_params.update(param_names)

    if reaction_params:
        lines.append(f"@parameters {' '.join(reaction_params)}")

    # Generate reactions
    if reaction_system.get("reactions"):
        lines.append("")
        lines.append("rxs = [")
        for reaction in reaction_system["reactions"].values():
            lines.append(f"    {_format_reaction(reaction)},")
        lines.append("]")

    # Generate @named ReactionSystem
    lines.append("")
    lines.append(f"@named {name}_system = ReactionSystem(rxs)")

    return lines


def _generate_event_code(name: str, event: Dict[str, Any]) -> List[str]:
    lines = []

    if "condition" in event:  # Continuous event
        lines.append(f"# Continuous Event: {name}")
        condition = _format_expression(event["condition"])
        affect = _format_affect(event.get("affect"))
        lines.append(f"{name}_event = SymbolicContinuousCallback({condition}, {affect})")
    else:  # Discrete event
        lines.append(f"# Discrete Event: {name}")
        trigger = _format_discrete_trigger(event.get("trigger", {}))
        affect = _format_affect(event.get("affect"))
        lines.append(f"{name}_event = DiscreteCallback({trigger}, {affect})")

    return lines


def _generate_coupling_comment(coupling: Dict[str, Any]) -> List[str]:
    lines = []
    lines.append(f"# Coupling: {coupling.get('type', 'unknown')}")
    if coupling.get("from"):
        lines.append(f"#   From: {coupling['from']}")
    if coupling.get("to"):
        lines.append(f"#   To: {coupling['to']}")
    return lines


def _generate_domain_comment(domain: Dict[str, Any]) -> List[str]:
    lines = []
    lines.append("# Domain")
    if domain.get("spatial", {}).get("coordinates"):
        coords = domain["spatial"]["coordinates"]
        lines.append(f"#   Spatial coordinates: {', '.join(coords)}")
    return lines


def _generate_data_loader_comment(name: str, data_loader: Dict[str, Any]) -> List[str]:
    lines = []
    lines.append(f"# Data loader: {name}")
    source = data_loader.get("source")
    if isinstance(source, dict) and "url_template" in source:
        lines.append(f"#   Source: {source['url_template']}")
    kind = data_loader.get("kind")
    if kind:
        lines.append(f"#   Kind: {kind}")
    return lines


def _format_variable_declaration(var_name: str, variable: Dict[str, Any]) -> str:
    decl = var_name

    # Add default value and units if present
    parts = []
    if variable.get("default") is not None:
        default_val = variable["default"]
        if isinstance(default_val, int):
            parts.append(f"{default_val}.0")
        else:
            parts.append(str(default_val))

    if variable.get("unit"):
        parts.append(f'u"{variable["unit"]}"')

    if parts:
        decl += f"({', '.join(parts)})"

    return decl


def _format_species_declaration(spec_name: str, species: Dict[str, Any]) -> str:
    decl = spec_name

    if species.get("initial_value") is not None:
        initial_val = species["initial_value"]
        if isinstance(initial_val, int):
            decl += f"({initial_val}.0)"
        else:
            decl += f"({initial_val})"

    return decl


def _format_equation(equation: Dict[str, Any]) -> str:
    lhs = _format_expression(equation["lhs"])
    rhs = _format_expression(equation["rhs"])
    return f"{lhs} ~ {rhs}"


def _format_reaction(reaction: Dict[str, Any]) -> str:
    rate = _format_expression(reaction.get("rate", 1.0))

    # Format reactants
    if reaction.get("substrates"):
        reactants = " + ".join(
            f"{s['stoichiometry']}*{s['species']}"
            if s.get("stoichiometry", 1) != 1
            else s["species"]
            for s in reaction["substrates"]
        )
    else:
        reactants = "∅"

    # Format products
    if reaction.get("products"):
        products = " + ".join(
            f"{p['stoichiometry']}*{p['species']}"
            if p.get("stoichiometry", 1) != 1
            else p["species"]
            for p in reaction["products"]
        )
    else:
        products = "∅"

    return f"Reaction({rate}, [{reactants}], [{products}])"


def _format_expression(expr: Union[str, int, float, Dict[str, Any]]) -> str:
    if isinstance(expr, (int, float)):
        return str(expr)
    elif isinstance(expr, str):
        return expr
    elif isinstance(expr, dict) and "op" in expr:
        return _format_expression_node(expr)
    else:
        return str(expr)


def _format_expression_node(node: Dict[str, Any]) -> str:
    op = node["op"]
    args = node.get("args", [])

    # Apply expression mappings for Julia
    if op == "+":
        return " + ".join(_format_expression(arg) for arg in args)
    elif op == "*":
        return " * ".join(_format_expression(arg) for arg in args)
    elif op == "D":
        # D(x,t) → D(x) (remove time parameter)
        if args:
            return f"D({_format_expression(args[0])})"
        return "D()"
    elif op == "exp":
        return f"exp({', '.join(_format_expression(arg) for arg in args)})"
    elif op == "ifelse":
        return f"ifelse({', '.join(_format_expression(arg) for arg in args)})"
    elif op == "Pre":
        return f"Pre({', '.join(_format_expression(arg) for arg in args)})"
    elif op == "^":
        return " ^ ".join(_format_expression(arg) for arg in args)
    elif op == "grad":
        # grad(x,y) → Differential(y)(x)
        if len(args) >= 2:
            return f"Differential({_format_expression(args[1])})({_format_expression(args[0])})"
        elif len(args) == 1:
            return f"Differential(x)({_format_expression(args[0])})"
        return "Differential(x)()"
    elif op == "-":
        if len(args) == 1:
            return f"-{_format_expression(args[0])}"
        else:
            return " - ".join(_format_expression(arg) for arg in args)
    elif op == "/":
        return " / ".join(_format_expression(arg) for arg in args)
    elif op in ["<", ">", "<=", ">=", "==", "!="]:
        return f" {op} ".join(_format_expression(arg) for arg in args)
    elif op == "and":
        return " && ".join(_format_expression(arg) for arg in args)
    elif op == "or":
        return " || ".join(_format_expression(arg) for arg in args)
    elif op == "not":
        return f"!({_format_expression(args[0])})" if args else "!()"
    else:
        # For other operators, use function call syntax
        return f"{op}({', '.join(_format_expression(arg) for arg in args)})"


def _format_affect(affect) -> str:
    if isinstance(affect, list):
        return f"[{', '.join(_format_affect_equation(a) for a in affect)}]"
    elif affect and isinstance(affect, dict):
        return _format_affect_equation(affect)
    else:
        return "nothing"


def _format_affect_equation(affect: Dict[str, Any]) -> str:
    if affect.get("lhs") and affect.get("rhs"):
        return f"{_format_expression(affect['lhs'])} ~ {_format_expression(affect['rhs'])}"
    return "nothing"


def _format_discrete_trigger(trigger: Dict[str, Any]) -> str:
    if trigger.get("condition"):
        return _format_expression(trigger["condition"])
    return "true"


def _extract_parameter_names(expr: Union[str, int, float, Dict[str, Any]]) -> set:
    params = set()

    if isinstance(expr, str):
        # Simple heuristic: single letters or names starting with k/K are likely parameters
        if len(expr) == 1 or expr.startswith("k") or expr.startswith("K"):
            params.add(expr)
    elif isinstance(expr, dict) and "op" in expr:
        # Recursively extract from arguments
        for arg in expr.get("args", []):
            params.update(_extract_parameter_names(arg))

    return params


# Helper functions for Python code generation


def _generate_python_model_code(name: str, model: Dict[str, Any]) -> List[str]:
    lines = []

    lines.append(f"# Model: {name}")

    # Collect state variables and parameters
    state_vars = []
    parameters = []

    if model.get("variables"):
        for var_name, variable in model["variables"].items():
            if variable.get("type") == "state":
                state_vars.append((var_name, variable))
            elif variable.get("type") == "parameter":
                parameters.append((var_name, variable))

    # Generate time symbol if needed
    has_derivatives = model.get("equations") and any(
        _has_derivative_in_expression(eq.get("lhs")) or _has_derivative_in_expression(eq.get("rhs"))
        for eq in model["equations"]
    )

    if has_derivatives:
        lines.append("# Time variable")
        lines.append("t = sp.Symbol('t')")
        lines.append("")

    # Generate symbol/function definitions
    if state_vars:
        lines.append("# State variables")
        for var_name, variable in state_vars:
            comment = f"  # {variable['unit']}" if variable.get("unit") else ""
            if has_derivatives:
                lines.append(f"{var_name} = sp.Function('{var_name}'){comment}")
            else:
                lines.append(f"{var_name} = sp.Symbol('{var_name}'){comment}")
        lines.append("")

    if parameters:
        lines.append("# Parameters")
        for var_name, parameter in parameters:
            comment = f"  # {parameter['unit']}" if parameter.get("unit") else ""
            lines.append(f"{var_name} = sp.Symbol('{var_name}'){comment}")
        lines.append("")

    # Generate equations
    if model.get("equations"):
        lines.append("# Equations")
        for i, equation in enumerate(model["equations"], 1):
            lhs = _format_python_expression(equation["lhs"])
            rhs = _format_python_expression(equation["rhs"])
            lines.append(f"eq{i} = sp.Eq({lhs}, {rhs})")

    return lines


def _generate_python_reaction_system_code(name: str, reaction_system: Dict[str, Any]) -> List[str]:
    lines = []

    lines.append(f"# Reaction System: {name}")

    # Generate species symbols
    if reaction_system.get("species"):
        lines.append("# Species")
        for spec_name, species in reaction_system["species"].items():
            lines.append(f"{spec_name} = sp.Symbol('{spec_name}')")
        lines.append("")

    # Generate reaction rate expressions
    if reaction_system.get("reactions"):
        lines.append("# Rate expressions")
        for reaction_name, reaction in reaction_system["reactions"].items():
            if reaction.get("rate"):
                rate_expr = _format_python_expression(reaction["rate"])
                lines.append(f"{reaction_name}_rate = {rate_expr}")
        lines.append("")

        lines.append("# Stoichiometry setup (TODO: Implement reaction network)")
        for reaction_name, reaction in reaction_system["reactions"].items():
            lines.append(f"# Reaction: {reaction_name}")
            if reaction.get("substrates"):
                reactant_str = " + ".join(
                    f"{s['stoichiometry']}*{s['species']}"
                    if s.get("stoichiometry", 1) != 1
                    else s["species"]
                    for s in reaction["substrates"]
                )
                lines.append(f"#   Reactants: {reactant_str}")
            if reaction.get("products"):
                product_str = " + ".join(
                    f"{p['stoichiometry']}*{p['species']}"
                    if p.get("stoichiometry", 1) != 1
                    else p["species"]
                    for p in reaction["products"]
                )
                lines.append(f"#   Products: {product_str}")

    return lines


def _generate_python_coupling_comment(coupling: Dict[str, Any]) -> List[str]:
    lines = []
    lines.append(f"# Coupling: {coupling.get('type', 'unknown')}")
    if coupling.get("from"):
        lines.append(f"#   From: {coupling['from']}")
    if coupling.get("to"):
        lines.append(f"#   To: {coupling['to']}")
    return lines


def _generate_python_domain_comment(domain: Dict[str, Any]) -> List[str]:
    lines = []
    lines.append("# Domain")
    if domain.get("spatial", {}).get("coordinates"):
        coords = domain["spatial"]["coordinates"]
        lines.append(f"#   Spatial coordinates: {', '.join(coords)}")
    return lines


def _format_python_expression(expr: Union[str, int, float, Dict[str, Any]]) -> str:
    if isinstance(expr, (int, float)):
        return str(expr)
    elif isinstance(expr, str):
        return expr
    elif isinstance(expr, dict) and "op" in expr:
        return _format_python_expression_node(expr)
    else:
        return str(expr)


def _format_python_expression_node(node: Dict[str, Any]) -> str:
    op = node["op"]
    args = node.get("args", [])

    # Apply expression mappings for Python
    if op == "+":
        return " + ".join(_format_python_expression(arg) for arg in args)
    elif op == "*":
        return " * ".join(_format_python_expression(arg) for arg in args)
    elif op == "D":
        # D(x,t) → Derivative(x(t), t)
        if args:
            var_name = _format_python_expression(args[0])
            return f"sp.Derivative({var_name}(t), t)"
        return "sp.Derivative()"
    elif op == "exp":
        return f"sp.exp({', '.join(_format_python_expression(arg) for arg in args)})"
    elif op == "ifelse":
        # ifelse(condition, true_val, false_val) → sp.Piecewise((true_val, condition), (false_val, True))
        if len(args) >= 3:
            condition = _format_python_expression(args[0])
            true_val = _format_python_expression(args[1])
            false_val = _format_python_expression(args[2])
            return f"sp.Piecewise(({true_val}, {condition}), ({false_val}, True))"
        return "sp.Piecewise((0, True))"
    elif op == "Pre":
        return f"sp.Function('Pre')({', '.join(_format_python_expression(arg) for arg in args)})"
    elif op == "^":
        return " ** ".join(_format_python_expression(arg) for arg in args)
    elif op == "grad":
        # grad(x,y) → sp.Derivative(x, y)
        if len(args) >= 2:
            func = _format_python_expression(args[0])
            var = _format_python_expression(args[1])
            return f"sp.Derivative({func}, {var})"
        elif len(args) == 1:
            return f"sp.Derivative({_format_python_expression(args[0])}, x)"
        return "sp.Derivative()"
    elif op == "-":
        if len(args) == 1:
            return f"-{_format_python_expression(args[0])}"
        else:
            return " - ".join(_format_python_expression(arg) for arg in args)
    elif op == "/":
        return " / ".join(_format_python_expression(arg) for arg in args)
    elif op in ["<", ">", "<=", ">=", "==", "!="]:
        return f" {op} ".join(_format_python_expression(arg) for arg in args)
    elif op == "and":
        return " & ".join(_format_python_expression(arg) for arg in args)
    elif op == "or":
        return " | ".join(_format_python_expression(arg) for arg in args)
    elif op == "not":
        return f"~({_format_python_expression(args[0])})" if args else "~()"
    else:
        # For other operators, use function call syntax
        return f"{op}({', '.join(_format_python_expression(arg) for arg in args)})"


def _has_derivative_in_expression(expr: Union[str, int, float, Dict[str, Any]]) -> bool:
    if isinstance(expr, dict) and "op" in expr:
        if expr["op"] == "D":
            return True
        return any(_has_derivative_in_expression(arg) for arg in expr.get("args", []))
    return False
