"""
Expression substitution and variable replacement functions.
"""

from dataclasses import replace
from typing import Dict, Union, List
from .esm_types import (
    Expr, ExprNode, Model, ReactionSystem, ModelVariable, Equation,
    AffectEquation, Parameter, Reaction, EsmFile, CouplingType, OperatorComposeCoupling
)


def substitute(expr: Expr, bindings: Dict[str, Expr]) -> Expr:
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
    elif isinstance(expr, (int, float)):
        # Numbers are unchanged
        return expr
    elif isinstance(expr, ExprNode):
        # Recursively substitute in all arguments
        # ``substitute(None, ...)`` returns ``None``, so no per-field None guard
        # is needed; only ``values`` needs one because it is iterated.
        substituted_args = [substitute(arg, bindings) for arg in expr.args]
        substituted_body = substitute(expr.expr, bindings)
        substituted_values = (
            [substitute(v, bindings) for v in expr.values]
            if expr.values is not None else None
        )
        substituted_lower = substitute(expr.lower, bindings)
        substituted_upper = substitute(expr.upper, bindings)
        # Aggregate (arrayop) carries semiring/join/filter/distinct/key beside
        # output_idx/reduce/ranges; preserve all of them so a substituted
        # aggregate keeps its full semantics (RFC §5.1/§5.3/§5.5). ``filter``
        # and ``key`` are nested Expressions and must themselves be substituted.
        substituted_filter = substitute(expr.filter, bindings)
        substituted_key = substitute(expr.key, bindings)
        # Use ``replace`` so closed-function / lookup metadata (``name``,
        # ``value``, ``id``, ``manifold``, ``handler_id``, ``table``,
        # ``table_axes``, ``output``) is carried verbatim. The previous explicit
        # field list silently dropped them, so a ``const`` table substituted
        # through a ``param_to_var`` coupling lost its ``value`` and the
        # discretized document failed schema validation with an empty
        # ``{"op": "const", "args": []}`` node.
        return replace(
            expr,
            args=substituted_args,
            expr=substituted_body,
            filter=substituted_filter,
            key=substituted_key,
            values=substituted_values,
            lower=substituted_lower,
            upper=substituted_upper,
        )
    elif isinstance(expr, dict):
        # Handle dict-form expression nodes (e.g. {"op": "+", "args": ["x", "y"]})
        if "op" in expr and "args" in expr:
            substituted_args = [substitute(arg, bindings) for arg in expr["args"]]
            result = {"op": expr["op"], "args": substituted_args}
            if "wrt" in expr:
                result["wrt"] = expr["wrt"]
            if "dim" in expr:
                result["dim"] = expr["dim"]
            if "var" in expr:
                result["var"] = expr["var"]
            if "lower" in expr:
                result["lower"] = substitute(expr["lower"], bindings)
            if "upper" in expr:
                result["upper"] = substitute(expr["upper"], bindings)
            return result
        # For other dicts, return unchanged
        return expr
    else:
        # Unknown type, return unchanged
        return expr


def substitute_in_model(model, bindings: Dict[str, Expr]):
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
    # Substitute in model variables
    new_variables = {}
    for name, var in model.variables.items():
        new_expression = None
        if var.expression is not None:
            new_expression = substitute(var.expression, bindings)

        # Create new variable with substituted expression
        new_var = ModelVariable(
            type=var.type,
            units=var.units,
            default=var.default,
            description=var.description,
            expression=new_expression
        )
        new_variables[name] = new_var

    # Substitute in equations
    new_equations = []
    for eq in model.equations:
        new_lhs = substitute(eq.lhs, bindings)
        new_rhs = substitute(eq.rhs, bindings)
        new_equations.append(Equation(lhs=new_lhs, rhs=new_rhs))

    return Model(
        name=model.name,
        variables=new_variables,
        equations=new_equations,
        metadata=model.metadata.copy()  # Shallow copy metadata
    )


def substitute_in_reaction_system(system, bindings: Dict[str, Expr]):
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
            for param_name, param_data in result["parameters"].items():
                if "default" in param_data:
                    param_data["default"] = substitute(param_data["default"], bindings)
        # Substitute in reactions
        if "reactions" in result:
            for reaction in result["reactions"]:
                if "rate" in reaction:
                    reaction["rate"] = substitute(reaction["rate"], bindings)
        return result

    # Typed ReactionSystem object
    # Substitute in parameters
    new_parameters = []
    for param in system.parameters:
        new_value = param.value
        if not isinstance(param.value, (int, float)):
            # Parameter value is an expression
            new_value = substitute(param.value, bindings)

        new_param = Parameter(
            name=param.name,
            value=new_value,
            units=param.units,
            description=param.description,
            uncertainty=param.uncertainty
        )
        new_parameters.append(new_param)

    # Substitute in reactions
    new_reactions = []
    for reaction in system.reactions:
        new_rate_constant = reaction.rate_constant
        if reaction.rate_constant is not None and not isinstance(reaction.rate_constant, (int, float)):
            # Rate constant is an expression
            new_rate_constant = substitute(reaction.rate_constant, bindings)

        new_reaction = Reaction(
            name=reaction.name,
            id=reaction.id,
            reactants=reaction.reactants.copy(),
            products=reaction.products.copy(),
            rate_constant=new_rate_constant,
            conditions=reaction.conditions.copy()
        )
        new_reactions.append(new_reaction)

    return ReactionSystem(
        name=system.name,
        species=system.species.copy(),  # Species don't contain expressions typically
        parameters=new_parameters,
        reactions=new_reactions
    )


def expand_var_placeholders(expr: Expr, variable_names: List[str]) -> List[Expr]:
    """
    Expand _var placeholders in an expression to create multiple expressions,
    one for each variable name in the list.

    Args:
        expr: Expression that may contain _var placeholders
        variable_names: List of variable names to substitute for _var

    Returns:
        List of expressions with _var replaced by each variable name
    """
    expanded_expressions = []
    for var_name in variable_names:
        # Create binding to replace _var with the actual variable name
        bindings = {"_var": var_name}
        expanded_expr = substitute(expr, bindings)
        expanded_expressions.append(expanded_expr)

    return expanded_expressions


def expand_equation_placeholders(equation: Equation, variable_names: List[str]) -> List[Equation]:
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
    elif isinstance(expr, ExprNode):
        # Check recursively in all arguments
        return any(has_var_placeholder(arg) for arg in expr.args)
    else:
        # Numbers and other types don't contain placeholders
        return False


def get_state_variables(model: Model) -> List[str]:
    """
    Extract state variable names from a model.

    Args:
        model: Model to extract state variables from

    Returns:
        List of state variable names
    """
    state_variables = []
    for name, var in model.variables.items():
        if var.type == "state":
            state_variables.append(name)
    return state_variables


def expand_model_placeholders(model: Model, state_variables: List[str]) -> Model:
    """
    Expand _var placeholders in a model's equations using the provided state variables.

    Args:
        model: Model containing equations that may have _var placeholders
        state_variables: List of state variable names to expand _var to

    Returns:
        New model with _var placeholders expanded to create multiple equations
    """
    new_equations = []

    for equation in model.equations:
        # Check if this equation has _var placeholders
        has_lhs_placeholder = has_var_placeholder(equation.lhs)
        has_rhs_placeholder = has_var_placeholder(equation.rhs)

        if has_lhs_placeholder or has_rhs_placeholder:
            # Expand this equation for each state variable
            expanded_equations = expand_equation_placeholders(equation, state_variables)
            new_equations.extend(expanded_equations)
        else:
            # Keep equation unchanged
            new_equations.append(equation)

    # Return new model with expanded equations
    return Model(
        name=model.name,
        variables=model.variables.copy(),
        equations=new_equations,
        metadata=model.metadata.copy()
    )


def process_operator_compose_placeholders(esm_file: EsmFile) -> EsmFile:
    """
    Process operator_compose couplings in an ESM file and expand _var placeholders.

    This function implements the operator_compose coupling algorithm:
    1. Find all operator_compose couplings
    2. For each coupling, collect state variables from all coupled systems
    3. Expand _var placeholders in models that contain them
    4. Return the modified ESM file

    Args:
        esm_file: ESM file containing models and couplings

    Returns:
        New ESM file with _var placeholders expanded in operator_compose couplings
    """
    if not esm_file.coupling:
        return esm_file

    # Create a copy of the ESM file to avoid modifying the original
    new_models = esm_file.models.copy() if esm_file.models else {}

    # Find all operator_compose couplings
    for coupling in esm_file.coupling:
        if (isinstance(coupling, OperatorComposeCoupling) or
            (hasattr(coupling, 'coupling_type') and coupling.coupling_type == CouplingType.OPERATOR_COMPOSE)):

            if not coupling.systems or len(coupling.systems) < 2:
                continue

            # Collect state variables from all coupled systems
            all_state_variables = []
            for system_name in coupling.systems:
                if system_name in new_models:
                    model = new_models[system_name]
                    state_vars = get_state_variables(model)
                    all_state_variables.extend(state_vars)

            # Remove duplicates while preserving order
            unique_state_variables = list(dict.fromkeys(all_state_variables))

            # Process each system in the coupling
            for system_name in coupling.systems:
                if system_name in new_models:
                    model = new_models[system_name]

                    # Check if this model has any equations with _var placeholders
                    has_placeholders = any(
                        has_var_placeholder(eq.lhs) or has_var_placeholder(eq.rhs)
                        for eq in model.equations
                    )

                    if has_placeholders and unique_state_variables:
                        # Expand placeholders using state variables from all coupled systems
                        expanded_model = expand_model_placeholders(model, unique_state_variables)
                        new_models[system_name] = expanded_model

    # Create a new ESM file with the modified models
    return EsmFile(
        version=esm_file.version,
        metadata=esm_file.metadata,
        models=new_models,
        reaction_systems=esm_file.reaction_systems,
        coupling=esm_file.coupling,
        data_loaders=esm_file.data_loaders,
        operators=esm_file.operators,
        events=esm_file.events,
        domain=esm_file.domain,
    )