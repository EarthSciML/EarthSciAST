"""
Expression manipulation and analysis functions.
"""

from typing import Dict, Set, Union, Optional, List
from .esm_types import Expr, ExprNode, Model, ReactionSystem, ModelVariable
import sympy as sp


def free_variables(expr: Expr) -> Set[str]:
    """
    Extract all free variables from an expression.

    Args:
        expr: Expression to analyze

    Returns:
        Set of variable names found in the expression
    """
    if isinstance(expr, str):
        # String is a variable name
        return {expr}
    elif isinstance(expr, (int, float)):
        # Numbers have no variables
        return set()
    elif isinstance(expr, ExprNode):
        # Recursively collect variables from all arguments
        variables = set()
        for arg in expr.args:
            variables.update(free_variables(arg))
        return variables
    else:
        # Unknown type, assume no variables
        return set()


def free_parameters(expr: Expr, model: Model) -> Set[str]:
    """
    Extract free parameters from an expression.

    A parameter is a free variable that has type="parameter" in the model.

    Args:
        expr: Expression to analyze
        model: Model containing variable type information

    Returns:
        Set of parameter names found in the expression
    """
    # Get all free variables from the expression
    free_vars = free_variables(expr)

    # Filter to only include variables that are parameters
    parameters = set()
    for var_name in free_vars:
        if var_name in model.variables:
            var = model.variables[var_name]
            if var.type == 'parameter':
                parameters.add(var_name)

    return parameters


def contains(expr: Expr, var_name: str) -> bool:
    """
    Check if an expression contains a specific variable.

    Args:
        expr: Expression to search in
        var_name: Variable name to look for

    Returns:
        True if variable is found, False otherwise
    """
    return var_name in free_variables(expr)


def simplify(expr: Expr) -> Expr:
    """
    Simplify an expression by performing constant folding and basic algebraic simplifications.

    Args:
        expr: Expression to simplify

    Returns:
        Simplified expression
    """
    if isinstance(expr, (int, float, str)):
        # Atomic expressions don't need simplification
        return expr
    elif isinstance(expr, ExprNode):
        # First, simplify all arguments recursively
        simplified_args = [simplify(arg) for arg in expr.args]

        # Check if all arguments are constants
        all_constants = all(isinstance(arg, (int, float)) for arg in simplified_args)

        if all_constants and len(simplified_args) > 0:
            # Drive constant folding through the canonical AST evaluator
            # (numpy_interpreter) — the same runtime that production simulation
            # uses (esm-spec §4 / AGENTS.md "Official per-binding runners").
            from .numpy_interpreter import fold_constant_expr, NumpyInterpreterError
            try:
                temp_expr = ExprNode(op=expr.op, args=simplified_args)
                return fold_constant_expr(temp_expr)
            except (ValueError, TypeError, ZeroDivisionError, NumpyInterpreterError):
                return ExprNode(op=expr.op, args=simplified_args, wrt=expr.wrt, dim=expr.dim)

        # Apply specific simplification rules
        if expr.op == "+":
            # Remove zeros and combine constants
            non_zero_args = []
            constant_sum = 0
            has_constants = False

            for arg in simplified_args:
                if isinstance(arg, (int, float)):
                    if arg != 0:
                        constant_sum += arg
                        has_constants = True
                else:
                    non_zero_args.append(arg)

            # Add back the constant sum if non-zero or if there are no other terms
            if has_constants and (constant_sum != 0 or len(non_zero_args) == 0):
                non_zero_args.append(constant_sum)

            if len(non_zero_args) == 0:
                return 0
            elif len(non_zero_args) == 1:
                return non_zero_args[0]
            else:
                return ExprNode(op=expr.op, args=non_zero_args, wrt=expr.wrt, dim=expr.dim)

        elif expr.op == "*":
            # Remove ones, handle zeros, and combine constants
            non_one_args = []
            constant_product = 1
            has_constants = False

            for arg in simplified_args:
                if isinstance(arg, (int, float)):
                    if arg == 0:
                        return 0  # Anything times zero is zero
                    elif arg != 1:
                        constant_product *= arg
                        has_constants = True
                else:
                    non_one_args.append(arg)

            # Add back the constant product if not one or if there are no other terms
            if has_constants and (constant_product != 1 or len(non_one_args) == 0):
                non_one_args.append(constant_product)

            if len(non_one_args) == 0:
                return 1
            elif len(non_one_args) == 1:
                return non_one_args[0]
            else:
                return ExprNode(op=expr.op, args=non_one_args, wrt=expr.wrt, dim=expr.dim)

        elif expr.op == "^" or expr.op == "**":
            # Handle special cases like x^0, x^1, 1^y, 0^y
            if len(simplified_args) == 2:
                base, exponent = simplified_args
                if isinstance(exponent, (int, float)) and exponent == 0:
                    return 1  # x^0 = 1
                elif isinstance(exponent, (int, float)) and exponent == 1:
                    return base  # x^1 = x
                elif isinstance(base, (int, float)) and base == 1:
                    return 1  # 1^y = 1
                elif isinstance(base, (int, float)) and base == 0:
                    return 0  # 0^y = 0 (for positive y)

        # If no specific simplifications apply, return with simplified args
        return ExprNode(op=expr.op, args=simplified_args, wrt=expr.wrt, dim=expr.dim)
    else:
        return expr


# Unary math operators that all lower to ``func(arg)`` and share the arity-1
# error message ``"<label> requires exactly 1 argument, got <n>"``. Kept as a
# table so each op is one row instead of a five-line ``elif`` arm.
_UNARY_SYMPY_OPS = {
    "exp": (sp.exp, "Exponential"),
    "log": (sp.log, "Logarithm"),
    "sin": (sp.sin, "Sine"),
    "cos": (sp.cos, "Cosine"),
    "tan": (sp.tan, "Tangent"),
    "asin": (sp.asin, "Arcsine"),
    "acos": (sp.acos, "Arccosine"),
    "atan": (sp.atan, "Arctangent"),
    "sinh": (sp.sinh, "Hyperbolic sine"),
    "cosh": (sp.cosh, "Hyperbolic cosine"),
    "tanh": (sp.tanh, "Hyperbolic tangent"),
    "asinh": (sp.asinh, "Inverse hyperbolic sine"),
    "acosh": (sp.acosh, "Inverse hyperbolic cosine"),
    "atanh": (sp.atanh, "Inverse hyperbolic tangent"),
    "abs": (sp.Abs, "Absolute value"),
    "sign": (sp.sign, "Sign function"),
    "sqrt": (sp.sqrt, "Square root"),
    "log10": (lambda a: sp.log(a, 10), "Log10"),
    "floor": (sp.floor, "Floor"),
    "ceil": (sp.ceiling, "Ceiling"),
}


def to_sympy(expr: Expr, symbol_map: Optional[Dict[str, sp.Symbol]] = None) -> sp.Expr:
    """
    Convert ESM expression to SymPy expression.

    Args:
        expr: ESM expression to convert
        symbol_map: Optional mapping from variable names to SymPy symbols

    Returns:
        SymPy expression

    Raises:
        TypeError: If unsupported expression type or operation is encountered
    """
    if symbol_map is None:
        symbol_map = {}

    if isinstance(expr, (int, float)):
        return sp.sympify(expr)
    elif isinstance(expr, str):
        # Variable name - create symbol if not in map
        if expr not in symbol_map:
            symbol_map[expr] = sp.Symbol(expr)
        return symbol_map[expr]
    elif isinstance(expr, ExprNode):
        # Convert arguments recursively
        sympy_args = [to_sympy(arg, symbol_map) for arg in expr.args]

        # Map operations to SymPy
        if expr.op == "+":
            return sum(sympy_args) if sympy_args else 0
        elif expr.op == "-":
            if len(sympy_args) == 1:
                return -sympy_args[0]
            elif len(sympy_args) == 2:
                return sympy_args[0] - sympy_args[1]
            else:
                raise TypeError(f"Invalid number of arguments for subtraction: {len(sympy_args)}")
        elif expr.op == "*":
            result = 1
            for arg in sympy_args:
                result *= arg
            return result
        elif expr.op == "/":
            if len(sympy_args) != 2:
                raise TypeError(f"Division requires exactly 2 arguments, got {len(sympy_args)}")
            return sympy_args[0] / sympy_args[1]
        elif expr.op in ("^", "**"):
            if len(sympy_args) != 2:
                raise TypeError(f"Power requires exactly 2 arguments, got {len(sympy_args)}")
            return sympy_args[0] ** sympy_args[1]
        elif expr.op in _UNARY_SYMPY_OPS:
            func, label = _UNARY_SYMPY_OPS[expr.op]
            if len(sympy_args) != 1:
                raise TypeError(f"{label} requires exactly 1 argument, got {len(sympy_args)}")
            return func(sympy_args[0])
        elif expr.op == "atan2":
            if len(sympy_args) != 2:
                raise TypeError(f"Arctangent2 requires exactly 2 arguments, got {len(sympy_args)}")
            # Use a custom function to preserve structure when possible
            return sp.Function('atan2')(sympy_args[0], sympy_args[1])
        elif expr.op == "min":
            # n-ary min (esm-spec §4.2 — arity ≥ 2)
            if len(sympy_args) < 2:
                raise TypeError(f"Min requires at least 2 arguments, got {len(sympy_args)}")
            return sp.Min(*sympy_args)
        elif expr.op == "max":
            # n-ary max (esm-spec §4.2 — arity ≥ 2)
            if len(sympy_args) < 2:
                raise TypeError(f"Max requires at least 2 arguments, got {len(sympy_args)}")
            return sp.Max(*sympy_args)
        elif expr.op == "and":
            if len(sympy_args) < 2:
                raise TypeError(f"Logical AND requires at least 2 arguments, got {len(sympy_args)}")
            # Use custom function to preserve structure better
            return sp.Function('and')(*sympy_args)
        elif expr.op == "or":
            if len(sympy_args) < 2:
                raise TypeError(f"Logical OR requires at least 2 arguments, got {len(sympy_args)}")
            # Use custom function to preserve structure better
            return sp.Function('or')(*sympy_args)
        elif expr.op == "not":
            if len(sympy_args) != 1:
                raise TypeError(f"Logical NOT requires exactly 1 argument, got {len(sympy_args)}")
            return sp.Function('not')(sympy_args[0])
        elif expr.op == "div":
            # Divergence operator - represent as a function
            if len(sympy_args) != 1:
                raise TypeError(f"Divergence requires exactly 1 argument, got {len(sympy_args)}")
            return sp.Function('div')(sympy_args[0])
        elif expr.op == "laplacian":
            # Laplacian operator - represent as a function
            if len(sympy_args) != 1:
                raise TypeError(f"Laplacian requires exactly 1 argument, got {len(sympy_args)}")
            return sp.Function('laplacian')(sympy_args[0])
        elif expr.op == "D" and expr.wrt:
            # Derivative operation
            if len(sympy_args) != 1:
                raise TypeError(f"Derivative requires exactly 1 argument, got {len(sympy_args)}")
            wrt_symbol = to_sympy(expr.wrt, symbol_map)
            return sp.Derivative(sympy_args[0], wrt_symbol)
        elif expr.op == "Pre":
            # Previous value operator - represent as a function
            if len(sympy_args) != 1:
                raise TypeError(f"Pre operator requires exactly 1 argument, got {len(sympy_args)}")
            return sp.Function('Pre')(sympy_args[0])
        elif expr.op == "ifelse":
            # Conditional operator - map to Piecewise
            if len(sympy_args) != 3:
                raise TypeError(f"ifelse requires exactly 3 arguments (condition, true_val, false_val), got {len(sympy_args)}")
            condition, true_val, false_val = sympy_args
            return sp.Piecewise((true_val, condition), (false_val, True))
        elif expr.op == "grad":
            # Gradient operator - represent as derivative for now
            if len(sympy_args) != 1:
                raise TypeError(f"Gradient requires exactly 1 argument, got {len(sympy_args)}")
            # For gradient, we need the dimension info
            if expr.dim:
                dim_symbol = to_sympy(expr.dim, symbol_map)
                return sp.Derivative(sympy_args[0], dim_symbol)
            else:
                # No dimension specified, just return the expression
                return sympy_args[0]
        else:
            raise TypeError(f"Unsupported operation: {expr.op}")
    else:
        raise TypeError(f"Unsupported expression type: {type(expr)}")


def from_sympy(sympy_expr: sp.Expr) -> Expr:
    """
    Convert SymPy expression back to ESM expression.

    Args:
        sympy_expr: SymPy expression to convert

    Returns:
        ESM expression

    Raises:
        TypeError: If unsupported SymPy expression type is encountered
    """
    if isinstance(sympy_expr, (sp.Integer, sp.Rational, sp.Float)):
        return float(sympy_expr)
    elif isinstance(sympy_expr, sp.Symbol):
        return str(sympy_expr)
    elif isinstance(sympy_expr, sp.Add):
        # Addition
        args = [from_sympy(arg) for arg in sympy_expr.args]
        return ExprNode(op="+", args=args)
    elif isinstance(sympy_expr, sp.Mul):
        # Multiplication
        args = [from_sympy(arg) for arg in sympy_expr.args]
        return ExprNode(op="*", args=args)
    elif isinstance(sympy_expr, sp.Pow):
        # Power
        base, exp = sympy_expr.args
        return ExprNode(op="^", args=[from_sympy(base), from_sympy(exp)])
    elif isinstance(sympy_expr, sp.exp):
        # Exponential
        return ExprNode(op="exp", args=[from_sympy(sympy_expr.args[0])])
    elif isinstance(sympy_expr, sp.log):
        # Logarithm - check if it's log10 or natural log
        if len(sympy_expr.args) == 2 and sympy_expr.args[1] == 10:
            return ExprNode(op="log10", args=[from_sympy(sympy_expr.args[0])])
        else:
            return ExprNode(op="log", args=[from_sympy(sympy_expr.args[0])])
    elif isinstance(sympy_expr, sp.sin):
        # Sine
        return ExprNode(op="sin", args=[from_sympy(sympy_expr.args[0])])
    elif isinstance(sympy_expr, sp.cos):
        # Cosine
        return ExprNode(op="cos", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'tan':
        # Tangent
        return ExprNode(op="tan", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'asin':
        # Arcsine
        return ExprNode(op="asin", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'acos':
        # Arccosine
        return ExprNode(op="acos", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'atan':
        # Arctangent
        return ExprNode(op="atan", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'atan2':
        # Arctangent2
        return ExprNode(op="atan2", args=[from_sympy(arg) for arg in sympy_expr.args])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'sinh':
        # Hyperbolic sine
        return ExprNode(op="sinh", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'cosh':
        # Hyperbolic cosine
        return ExprNode(op="cosh", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'tanh':
        # Hyperbolic tangent
        return ExprNode(op="tanh", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'asinh':
        # Inverse hyperbolic sine
        return ExprNode(op="asinh", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'acosh':
        # Inverse hyperbolic cosine
        return ExprNode(op="acosh", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'atanh':
        # Inverse hyperbolic tangent
        return ExprNode(op="atanh", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'Abs':
        # Absolute value
        return ExprNode(op="abs", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'sign':
        # Sign function
        return ExprNode(op="sign", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ in ['sqrt', 'Pow'] and len(sympy_expr.args) == 2 and sympy_expr.args[1] == sp.Rational(1, 2):
        # Square root (represented as x^(1/2))
        return ExprNode(op="sqrt", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'floor':
        # Floor
        return ExprNode(op="floor", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'ceiling':
        # Ceiling
        return ExprNode(op="ceil", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'Min':
        # Min
        return ExprNode(op="min", args=[from_sympy(arg) for arg in sympy_expr.args])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'Max':
        # Max
        return ExprNode(op="max", args=[from_sympy(arg) for arg in sympy_expr.args])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'And':
        # Logical AND
        return ExprNode(op="and", args=[from_sympy(arg) for arg in sympy_expr.args])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'Or':
        # Logical OR
        return ExprNode(op="or", args=[from_sympy(arg) for arg in sympy_expr.args])
    elif hasattr(sympy_expr, 'func') and sympy_expr.func.__name__ == 'Not':
        # Logical NOT
        return ExprNode(op="not", args=[from_sympy(sympy_expr.args[0])])
    elif isinstance(sympy_expr, sp.Derivative):
        # Derivative
        expr_arg, wrt_arg = sympy_expr.args[0], sympy_expr.args[1]
        return ExprNode(op="D", args=[from_sympy(expr_arg)], wrt=str(wrt_arg))
    elif isinstance(sympy_expr, sp.Piecewise):
        # Piecewise -> ifelse (assuming 2 pieces)
        pieces = sympy_expr.args
        if len(pieces) == 2:
            (true_val, condition), (false_val, _) = pieces
            return ExprNode(op="ifelse", args=[from_sympy(condition), from_sympy(true_val), from_sympy(false_val)])
        else:
            # For more complex piecewise, just return the first expression for now
            return from_sympy(pieces[0][0])
    elif hasattr(sympy_expr, 'func') and str(sympy_expr.func) == 'Pre':
        # Pre function
        return ExprNode(op="Pre", args=[from_sympy(sympy_expr.args[0])])
    elif hasattr(sympy_expr, '__class__') and sympy_expr.__class__.__name__ in ['BooleanTrue', 'BooleanFalse']:
        # Boolean constants - just return as number
        return float(sympy_expr)
    elif isinstance(sympy_expr, sp.Function):
        # Generic function - check if it's one we know
        func_name = str(sympy_expr.func)
        if func_name == 'Pre':
            return ExprNode(op="Pre", args=[from_sympy(arg) for arg in sympy_expr.args])
        elif func_name in ['atan2', 'div', 'laplacian']:
            return ExprNode(op=func_name, args=[from_sympy(arg) for arg in sympy_expr.args])
        else:
            # Unknown function - represent as operation with function name
            return ExprNode(op=func_name, args=[from_sympy(arg) for arg in sympy_expr.args])
    elif sympy_expr.is_number:
        # Numeric constant
        return float(sympy_expr)
    else:
        raise TypeError(f"Unsupported SymPy expression type: {type(sympy_expr)}")


def symbolic_jacobian(model: Model) -> sp.Matrix:
    """
    Compute the Jacobian matrix of the ODE system in a model.

    Args:
        model: Model containing state variables and equations

    Returns:
        SymPy Matrix representing the Jacobian

    Raises:
        ValueError: If model has no state variables or equations
    """
    # Get all state variables
    state_vars = []
    for name, var in model.variables.items():
        if var.type == 'state':
            state_vars.append(name)

    if not state_vars:
        raise ValueError("Model has no state variables")

    if not model.equations:
        raise ValueError("Model has no equations")

    # Create symbol map for all variables
    symbol_map = {}
    for var_name in model.variables.keys():
        symbol_map[var_name] = sp.Symbol(var_name)

    # Extract right-hand sides of differential equations
    # Assume equations are of the form d(state_var)/dt = rhs
    rhs_expressions = []

    for equation in model.equations:
        # Convert equation to SymPy
        lhs_sympy = to_sympy(equation.lhs, symbol_map)
        rhs_sympy = to_sympy(equation.rhs, symbol_map)

        # Check if this is a differential equation
        if isinstance(lhs_sympy, sp.Derivative):
            # Extract the function being differentiated
            diff_var = lhs_sympy.args[0]
            if str(diff_var) in state_vars:
                rhs_expressions.append(rhs_sympy)
        else:
            # For non-differential equations, check if lhs is a state variable
            if str(lhs_sympy) in state_vars:
                # Treat as d(lhs)/dt = rhs
                rhs_expressions.append(rhs_sympy)

    if not rhs_expressions:
        # If no differential equations found, use all equation RHS
        for equation in model.equations:
            rhs_sympy = to_sympy(equation.rhs, symbol_map)
            rhs_expressions.append(rhs_sympy)

    # Ensure we have enough expressions
    while len(rhs_expressions) < len(state_vars):
        # Pad with zeros if needed
        rhs_expressions.append(sp.sympify(0))

    # Take only the first n expressions where n = number of state variables
    rhs_expressions = rhs_expressions[:len(state_vars)]

    # Compute Jacobian: J[i,j] = ∂(rhs_i)/∂(state_var_j)
    jacobian_elements = []
    for rhs in rhs_expressions:
        row = []
        for var_name in state_vars:
            var_symbol = symbol_map[var_name]
            partial_derivative = sp.diff(rhs, var_symbol)
            row.append(partial_derivative)
        jacobian_elements.append(row)

    return sp.Matrix(jacobian_elements)