"""
Code generation for the ESM format

This module provides functions to generate self-contained scripts
from ESM files in multiple target languages:
- Julia: compatible with ModelingToolkit, Catalyst, EarthSciMLBase, and OrdinaryDiffEq
- Python: compatible with SymPy, earthsci_ast, and SciPy
"""
from __future__ import annotations

import warnings
from typing import Any

from . import op_registry


def _warn_unregistered_op(op: str, target: str) -> None:
    """Surface the silent-degradation path the audit flagged (loud, non-fatal).

    ``codegen`` intentionally special-cases only the operator / control-flow
    subset (see ``tests/test_op_registry.py``) and generic function-call syntax
    ``op(args)`` is the correct, deliberate rendering for the rest of the
    registered vocabulary (``sin``, ``log``, ``min``, the array ops, …). But an
    op that is not even in the canonical vocabulary (:mod:`.op_registry`) reaching
    generic rendering is a new / mistyped op degrading silently — warn naming it
    rather than emitting plausible-but-unchecked code with no signal. Raising is
    avoided so legitimate open-tier user ops still generate.
    """
    if not op_registry.is_known(op):
        warnings.warn(
            f"codegen ({target}): op {op!r} is not in the canonical op registry "
            f"(earthsci_ast.op_registry); emitting the generic 'op(args)' "
            f"fallback. If this is a real op, add a handler and register it.",
            RuntimeWarning,
            stacklevel=3,
        )


def to_julia_code(file: dict[str, Any]) -> str:
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

    # Generate coupling placeholders (codegen not yet implemented)
    if file.get("coupling"):
        lines.append("# Coupling (codegen not yet implemented)")
        for coupling in file["coupling"]:
            lines.extend(_generate_coupling_comment(coupling))
        lines.append("")

    # Generate data loader placeholders (codegen not yet implemented)
    if file.get("data_loaders"):
        lines.append("# Data Loaders (codegen not yet implemented)")
        for name, data_loader in file["data_loaders"].items():
            lines.extend(_generate_data_loader_comment(name, data_loader))
        lines.append("")

    return "\n".join(lines)


def to_python_code(file: dict[str, Any]) -> str:
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
    lines.append("import earthsci_ast as esm")
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

    return "\n".join(lines)


# Helper functions for Julia code generation


def _generate_model_code(name: str, model: dict[str, Any]) -> list[str]:
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


def _generate_reaction_system_code(name: str, reaction_system: dict[str, Any]) -> list[str]:
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
        for reaction in reaction_system["reactions"]:
            if reaction.get("rate"):
                param_names = _extract_parameter_names(reaction["rate"])
                reaction_params.update(param_names)

    if reaction_params:
        lines.append(f"@parameters {' '.join(reaction_params)}")

    # Generate reactions
    if reaction_system.get("reactions"):
        lines.append("")
        lines.append("rxs = [")
        for reaction in reaction_system["reactions"]:
            lines.append(f"    {_format_reaction(reaction)},")
        lines.append("]")

    # Generate @named ReactionSystem
    lines.append("")
    lines.append(f"@named {name}_system = ReactionSystem(rxs)")

    return lines


def _generate_coupling_comment(coupling: dict[str, Any]) -> list[str]:
    lines = []
    lines.append(f"# Coupling: {coupling.get('type', 'unknown')}")
    if coupling.get("from"):
        lines.append(f"#   From: {coupling['from']}")
    if coupling.get("to"):
        lines.append(f"#   To: {coupling['to']}")
    return lines


def _generate_data_loader_comment(name: str, data_loader: dict[str, Any]) -> list[str]:
    lines = []
    lines.append(f"# Data loader: {name}")
    source = data_loader.get("source")
    if isinstance(source, dict) and "url_template" in source:
        lines.append(f"#   Source: {source['url_template']}")
    kind = data_loader.get("kind")
    if kind:
        lines.append(f"#   Kind: {kind}")
    return lines


def _format_variable_declaration(var_name: str, variable: dict[str, Any]) -> str:
    decl = var_name

    # Add default value and units if present
    parts = []
    if variable.get("default") is not None:
        default_val = variable["default"]
        if isinstance(default_val, int):
            parts.append(f"{default_val}.0")
        else:
            parts.append(str(default_val))

    if variable.get("units"):
        parts.append(f'u"{variable["units"]}"')

    if parts:
        decl += f"({', '.join(parts)})"

    return decl


def _format_species_declaration(spec_name: str, species: dict[str, Any]) -> str:
    decl = spec_name

    if species.get("default") is not None:
        default_val = species["default"]
        if isinstance(default_val, int):
            decl += f"({default_val}.0)"
        else:
            decl += f"({default_val})"

    return decl


def _format_equation(equation: dict[str, Any]) -> str:
    lhs = _format_expression(equation["lhs"])
    rhs = _format_expression(equation["rhs"])
    return f"{lhs} ~ {rhs}"


def _format_reaction(reaction: dict[str, Any]) -> str:
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


# ---------------------------------------------------------------------------
# Unified per-op expression renderer.
#
# Julia and Python differ only in *operator spellings*, so a single dispatch
# keyed by ``target`` ("julia" / "python") replaces what were two structurally
# identical renderers. Ops whose rendered *shape* is the same across targets
# (variadic infix joins, unary minus/negation, the generic call fallback) read
# their spelling from these tables; the handful whose shape genuinely differs
# (D, grad, ifelse) keep an explicit per-target branch in ``_format_expr_node``.
# ---------------------------------------------------------------------------

# Variadic infix operators: op -> per-target join separator.
_INFIX_SEP = {
    "+": {"julia": " + ", "python": " + "},
    "*": {"julia": " * ", "python": " * "},
    "/": {"julia": " / ", "python": " / "},
    "^": {"julia": " ^ ", "python": " ** "},
    "**": {"julia": " ^ ", "python": " ** "},
    "pow": {"julia": " ^ ", "python": " ** "},
    "and": {"julia": " && ", "python": " & "},
    "or": {"julia": " || ", "python": " | "},
}

# Comparison operators render with the op token itself as the separator.
_COMPARISON_OPS = ("<", ">", "<=", ">=", "==", "!=")

# Plain ``name(args...)`` ops with a per-target callee name.
_CALL_NAME = {
    "exp": {"julia": "exp", "python": "sp.exp"},
    "Pre": {"julia": "Pre", "python": "sp.Function('Pre')"},
}

# Logical-negation prefix: ``!(x)`` (Julia) / ``~(x)`` (Python).
_NOT_PREFIX = {"julia": "!", "python": "~"}


def _format_expr(expr: str | int | float | dict[str, Any], target: str) -> str:
    if isinstance(expr, (int, float)):
        return str(expr)
    if isinstance(expr, str):
        return expr
    if isinstance(expr, dict) and "op" in expr:
        return _format_expr_node(expr, target)
    return str(expr)


def _format_expr_node(node: dict[str, Any], target: str) -> str:
    op = node["op"]
    args = node.get("args", [])

    def r(arg: Any) -> str:
        return _format_expr(arg, target)

    # Table-driven ops (same shape across targets).
    if op in _INFIX_SEP:
        return _INFIX_SEP[op][target].join(r(arg) for arg in args)
    if op in _COMPARISON_OPS:
        return f" {op} ".join(r(arg) for arg in args)
    if op == "-":
        if len(args) == 1:
            return f"-{r(args[0])}"
        return " - ".join(r(arg) for arg in args)
    if op == "not":
        pfx = _NOT_PREFIX[target]
        return f"{pfx}({r(args[0])})" if args else f"{pfx}()"
    if op in _CALL_NAME:
        return f"{_CALL_NAME[op][target]}({', '.join(r(arg) for arg in args)})"

    # Shape-divergent ops (explicit per-target branch).
    if op == "D":
        if target == "julia":
            # D(x,t) → D(x) (drop the time parameter)
            return f"D({r(args[0])})" if args else "D()"
        # D(x,t) → sp.Derivative(x(t), t)
        return f"sp.Derivative({r(args[0])}(t), t)" if args else "sp.Derivative()"
    # `grad`/`div`/`laplacian`/`curl` are no longer special operators here: they
    # are open-tier rewrite-target keywords a discretization template lowers to a
    # stencil before any code-generation. One reaching codegen was never rewritten;
    # render it via the generic `grad(args)` fallback (it is a registered op, so no
    # unregistered-op warning) rather than inventing a Differential/Derivative form.
    if op == "ifelse":
        if target == "julia":
            return f"ifelse({', '.join(r(arg) for arg in args)})"
        # ifelse(cond, t, f) → sp.Piecewise((t, cond), (f, True))
        if len(args) >= 3:
            return f"sp.Piecewise(({r(args[1])}, {r(args[0])}), ({r(args[2])}, True))"
        return "sp.Piecewise((0, True))"

    # For other operators, use function call syntax.
    _warn_unregistered_op(op, target)
    return f"{op}({', '.join(r(arg) for arg in args)})"


def _format_expression(expr: str | int | float | dict[str, Any]) -> str:
    """Render an expression for the Julia target."""
    return _format_expr(expr, "julia")


def _extract_parameter_names(expr: str | int | float | dict[str, Any]) -> set:
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


def _reaction_label(reaction: dict[str, Any], index: int) -> str:
    """Derive a stable, code-friendly label for a reaction.

    ``reactions`` is a schema-defined array (each entry an object), so a
    reaction has no dict key to name it. Prefer the optional ``name`` field,
    fall back to the required ``id``, then to a positional label.
    """
    return reaction.get("name") or reaction.get("id") or f"reaction_{index}"


def _generate_python_model_code(name: str, model: dict[str, Any]) -> list[str]:
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
            comment = f"  # {variable['units']}" if variable.get("units") else ""
            if has_derivatives:
                lines.append(f"{var_name} = sp.Function('{var_name}'){comment}")
            else:
                lines.append(f"{var_name} = sp.Symbol('{var_name}'){comment}")
        lines.append("")

    if parameters:
        lines.append("# Parameters")
        for var_name, parameter in parameters:
            comment = f"  # {parameter['units']}" if parameter.get("units") else ""
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


def _generate_python_reaction_system_code(name: str, reaction_system: dict[str, Any]) -> list[str]:
    lines = []

    lines.append(f"# Reaction System: {name}")

    # Generate species symbols
    if reaction_system.get("species"):
        lines.append("# Species")
        for spec_name, _species in reaction_system["species"].items():
            lines.append(f"{spec_name} = sp.Symbol('{spec_name}')")
        lines.append("")

    # Generate reaction rate expressions
    if reaction_system.get("reactions"):
        lines.append("# Rate expressions")
        for i, reaction in enumerate(reaction_system["reactions"]):
            if reaction.get("rate"):
                rate_expr = _format_python_expression(reaction["rate"])
                lines.append(f"{_reaction_label(reaction, i)}_rate = {rate_expr}")
        lines.append("")

        lines.append("# Stoichiometry setup (TODO: Implement reaction network)")
        for i, reaction in enumerate(reaction_system["reactions"]):
            lines.append(f"# Reaction: {_reaction_label(reaction, i)}")
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


def _generate_python_coupling_comment(coupling: dict[str, Any]) -> list[str]:
    lines = []
    lines.append(f"# Coupling: {coupling.get('type', 'unknown')}")
    if coupling.get("from"):
        lines.append(f"#   From: {coupling['from']}")
    if coupling.get("to"):
        lines.append(f"#   To: {coupling['to']}")
    return lines


def _format_python_expression(expr: str | int | float | dict[str, Any]) -> str:
    """Render an expression for the Python target."""
    return _format_expr(expr, "python")


def _has_derivative_in_expression(expr: str | int | float | dict[str, Any]) -> bool:
    if isinstance(expr, dict) and "op" in expr:
        if expr["op"] == "D":
            return True
        return any(_has_derivative_in_expression(arg) for arg in expr.get("args", []))
    return False
