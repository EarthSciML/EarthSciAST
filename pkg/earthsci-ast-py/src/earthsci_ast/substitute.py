"""
Expression substitution and variable replacement functions.
"""
from __future__ import annotations

from dataclasses import replace

from .esm_types import (
    Equation,
    Expr,
    ExprNode,
)
from .expr_walk import any_child, map_children
from .json_walk import DICT_LIST_CHILD_FIELDS, DICT_SINGLE_CHILD_FIELDS


def substitute(expr: Expr, bindings: dict[str, Expr]) -> Expr:
    """
    Recursively substitute variables in an expression with their bindings.

    Args:
        expr: Expression to perform substitutions on
        bindings: Dictionary mapping variable names to replacement expressions

    Returns:
        Expression with variables substituted
    """
    if expr is None:
        return None
    if isinstance(expr, str):
        # String is a variable name - substitute if binding exists
        return bindings.get(expr, expr)
    if isinstance(expr, (int, float)):
        # Numbers are unchanged
        return expr
    if isinstance(expr, ExprNode):
        # Recursively substitute in every child expression via the canonical
        # walker: ``args``, aggregate body/``filter``/``key``, integral
        # ``lower``/``upper``, ``makearray`` values, and ``table_lookup`` axes
        # (RFC §5.1/§5.3/§5.5). ``map_children`` rebuilds with ``replace`` so
        # closed-function / lookup metadata (``name``, ``value``, ``id``,
        # ``manifold``, ``handler_id``, ``table``, ``output``) is carried
        # verbatim. A previous explicit field list silently dropped them, so a
        # ``const`` table substituted through a ``param_to_var`` coupling lost
        # its ``value`` and the discretized document failed schema validation
        # with an empty ``{"op": "const", "args": []}`` node.
        return map_children(expr, lambda child: substitute(child, bindings))
    if isinstance(expr, dict):
        # Handle dict-form expression nodes (e.g. {"op": "+", "args": ["x", "y"]}).
        # Copy ALL keys verbatim — hand-listing keys silently dropped
        # expr/values/filter/key/name/value/... — recursing only into the
        # expression-bearing keys. The single-child slots and list slots come
        # from the shared canonical field set (``json_walk.DICT_*_CHILD_FIELDS``,
        # the dict-form mirror of expr_walk's child set) rather than being
        # re-listed here; ``axes`` is table_lookup's per-axis input map. Order is
        # immaterial — each field is rebuilt independently and every non-child
        # key is preserved verbatim by the initial ``dict(expr)`` copy.
        if "op" in expr:
            result = dict(expr)
            for k in DICT_SINGLE_CHILD_FIELDS:
                if k in result:
                    result[k] = substitute(result[k], bindings)
            for k in DICT_LIST_CHILD_FIELDS:
                if k in result and isinstance(result[k], list):
                    result[k] = [substitute(v, bindings) for v in result[k]]
            if "axes" in result and isinstance(result["axes"], dict):
                result["axes"] = {ak: substitute(av, bindings) for ak, av in result["axes"].items()}
            return result
        # For other dicts, return unchanged
        return expr
    # Unknown type, return unchanged
    return expr


def substitute_in_model(model, bindings: dict[str, Expr]):
    """
    Apply substitutions to all expressions in a model.

    Args:
        model: Model object or dict to perform substitutions on
        bindings: Dictionary mapping variable names to replacement expressions

    Returns:
        New model (same type as input) with substitutions applied
    """
    # Handle dict-form models
    if isinstance(model, dict):
        import copy

        result = copy.deepcopy(model)
        # Substitute in equations
        if "equations" in result:
            for eq in result["equations"]:
                eq["lhs"] = substitute(eq["lhs"], bindings)
                eq["rhs"] = substitute(eq["rhs"], bindings)
        return result

    # Typed Model object
    # Substitute in model variables. ``replace`` keeps every other field
    # (shape, default_units, location, noise_kind, ...) — the previous
    # hand-listed ModelVariable(...) rebuild silently dropped them.
    new_variables = {
        name: replace(var, expression=substitute(var.expression, bindings))
        for name, var in model.variables.items()
    }

    # Substitute in equations (``replace`` preserves _comment).
    new_equations = [
        replace(eq, lhs=substitute(eq.lhs, bindings), rhs=substitute(eq.rhs, bindings))
        for eq in model.equations
    ]

    # ``replace`` carries subsystems, tests, examples, initialization_equations,
    # guesses, system_kind, continuous_events/discrete_events (and any future
    # Model field) — the previous hand-listed Model(...) rebuild dropped them.
    return replace(
        model,
        variables=new_variables,
        equations=new_equations,
        metadata=model.metadata.copy(),  # Shallow copy metadata
    )


def substitute_in_reaction_system(system, bindings: dict[str, Expr]):
    """
    Apply substitutions to all expressions in a reaction system.

    Args:
        system: Reaction system object or dict to perform substitutions on
        bindings: Dictionary mapping variable names to replacement expressions

    Returns:
        New reaction system (same type as input) with substitutions applied
    """
    # Handle dict-form reaction systems
    if isinstance(system, dict):
        import copy

        result = copy.deepcopy(system)
        # Substitute in parameters
        if "parameters" in result:
            for _param_name, param_data in result["parameters"].items():
                if "default" in param_data:
                    param_data["default"] = substitute(param_data["default"], bindings)
        # Substitute in reactions
        if "reactions" in result:
            for reaction in result["reactions"]:
                if "rate" in reaction:
                    reaction["rate"] = substitute(reaction["rate"], bindings)
        return result

    # Typed ReactionSystem object
    # Substitute in parameters. ``replace`` keeps default_units (and any
    # future Parameter field) — the previous hand-listed rebuild dropped it.
    new_parameters = []
    for param in system.parameters:
        new_value = param.value
        if not isinstance(param.value, (int, float)):
            # Parameter value is an expression
            new_value = substitute(param.value, bindings)
        new_parameters.append(replace(param, value=new_value))

    # Substitute in reactions
    new_reactions = []
    for reaction in system.reactions:
        new_rate_constant = reaction.rate_constant
        if reaction.rate_constant is not None and not isinstance(
            reaction.rate_constant, (int, float)
        ):
            # Rate constant is an expression
            new_rate_constant = substitute(reaction.rate_constant, bindings)

        new_reactions.append(
            replace(
                reaction,
                reactants=reaction.reactants.copy(),
                products=reaction.products.copy(),
                rate_constant=new_rate_constant,
                conditions=reaction.conditions.copy(),
            )
        )

    # ``replace`` carries constraint_equations, subsystems, tolerance, tests,
    # examples, continuous_events/discrete_events (and any future field) —
    # the previous hand-listed ReactionSystem(...) rebuild dropped them.
    return replace(
        system,
        species=system.species.copy(),  # Species don't contain expressions typically
        parameters=new_parameters,
        reactions=new_reactions,
    )


def expand_equation_placeholders(equation: Equation, variable_names: list[str]) -> list[Equation]:
    """
    Expand _var placeholders in an equation to create multiple equations,
    one for each variable name in the list.

    Args:
        equation: Equation that may contain _var placeholders
        variable_names: List of variable names to substitute for _var

    Returns:
        List of equations with _var replaced by each variable name
    """
    expanded_equations = []
    for var_name in variable_names:
        # Create binding to replace _var with the actual variable name
        bindings = {"_var": var_name}
        expanded_lhs = substitute(equation.lhs, bindings)
        expanded_rhs = substitute(equation.rhs, bindings)
        expanded_equation = Equation(lhs=expanded_lhs, rhs=expanded_rhs)
        expanded_equations.append(expanded_equation)

    return expanded_equations


def has_var_placeholder(expr: Expr) -> bool:
    """
    Check if an expression contains _var placeholder.

    Args:
        expr: Expression to check

    Returns:
        True if expression contains _var placeholder, False otherwise
    """
    if isinstance(expr, str):
        return expr == "_var"
    if isinstance(expr, ExprNode):
        # Check recursively in every child expression — including aggregate
        # bodies, filter predicates, integral bounds, makearray values, and
        # table_lookup axes, where a ``_var`` hidden from the old args-only
        # walk escaped flatten's operator_compose expansion.
        return any_child(expr, has_var_placeholder)
    # Numbers and other types don't contain placeholders
    return False
