"""
Expression manipulation and analysis functions.
"""
from __future__ import annotations

from dataclasses import replace
from typing import Callable

import sympy as sp

from . import op_registry
from .errors import EarthSciAstError
from .esm_types import Expr, ExprNode, Model
from .expr_walk import iter_children, map_children
from .numpy_interpreter import (
    NumpyInterpreterError,
    UnreachableSpatialOperatorError,
    fold_constant_expr,
)
from .registered_functions import (
    INTERP_CONST_ARG_POSITIONS,
    closed_function_names,
    evaluate_closed_function,
    extract_const_array,
)


def free_variables(expr: Expr) -> set[str]:
    """
    Extract all free variables from an expression.

    Traverses the full canonical child set (:mod:`.expr_walk`), so variables
    hidden in aggregate bodies, ``filter`` predicates, integral bounds,
    ``makearray`` values, or ``table_lookup`` axes are all found. ``wrt`` and
    ``dim`` are not children (they bind/label, they do not reference values)
    and are not collected.

    Args:
        expr: Expression to analyze

    Returns:
        Set of variable names found in the expression
    """
    if isinstance(expr, str):
        # String is a variable name
        return {expr}
    if isinstance(expr, (int, float)):
        # Numbers have no variables
        return set()
    if isinstance(expr, ExprNode):
        # Recursively collect variables from every child expression
        variables = set()
        for child in iter_children(expr):
            variables.update(free_variables(child))
        return variables
    # Unknown type, assume no variables
    return set()


def free_parameters(expr: Expr, model: Model) -> set[str]:
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
            if var.type == "parameter":
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
    if isinstance(expr, ExprNode):
        # First, simplify every child expression recursively. ``map_children``
        # rebuilds via dataclasses.replace, so sidecar fields (ranges, reduce,
        # table metadata, ...) are preserved and children beyond ``args``
        # (aggregate bodies, integral bounds, makearray values, ...) are
        # simplified too.
        node = map_children(expr, simplify)
        simplified_args = node.args

        # Constant folding only applies to plain scalar nodes: every child is
        # an ``args`` entry (no aggregate body / bounds / values / axes) and
        # every argument is a constant.
        args_only = sum(1 for _ in iter_children(node)) == len(simplified_args)
        all_constants = all(isinstance(arg, (int, float)) for arg in simplified_args)

        if args_only and all_constants and len(simplified_args) > 0:
            # Drive constant folding through the canonical AST evaluator
            # (numpy_interpreter) — the same runtime that production simulation
            # uses (esm-spec §4 / AGENTS.md "Official per-binding runners").
            try:
                temp_expr = ExprNode(op=node.op, args=list(simplified_args))
                return fold_constant_expr(temp_expr)
            except (ValueError, TypeError, ZeroDivisionError, NumpyInterpreterError):
                return node

        # Apply specific simplification rules
        if node.op == "+":
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
            if len(non_zero_args) == 1:
                return non_zero_args[0]
            return replace(node, args=non_zero_args)

        if node.op == "*":
            # Remove ones, handle zeros, and combine constants
            non_one_args = []
            constant_product = 1
            has_constants = False

            for arg in simplified_args:
                if isinstance(arg, (int, float)):
                    if arg == 0:
                        return 0  # Anything times zero is zero
                    if arg != 1:
                        constant_product *= arg
                        has_constants = True
                else:
                    non_one_args.append(arg)

            # Add back the constant product if not one or if there are no other terms
            if has_constants and (constant_product != 1 or len(non_one_args) == 0):
                non_one_args.append(constant_product)

            if len(non_one_args) == 0:
                return 1
            if len(non_one_args) == 1:
                return non_one_args[0]
            return replace(node, args=non_one_args)

        if node.op == "^" or node.op == "**":
            # Handle special cases like x^0, x^1, 1^y, 0^y
            if len(simplified_args) == 2:
                base, exponent = simplified_args
                if isinstance(exponent, (int, float)) and exponent == 0:
                    return 1  # x^0 = 1
                if isinstance(exponent, (int, float)) and exponent == 1:
                    return base  # x^1 = x
                if isinstance(base, (int, float)) and base == 1:
                    return 1  # 1^y = 1
                if isinstance(base, (int, float)) and base == 0:
                    return 0  # 0^y = 0 (for positive y)

        # If no specific simplifications apply, return with simplified children
        return node
    return expr


class SimulationError(EarthSciAstError):
    """Exception raised during the SymPy bridge or simulation.

    Defined here (rather than in ``simulation.py``) because the shared
    ESM→SymPy converter (:func:`_expr_to_sympy`) raises it for malformed
    expressions. ``sympy_bridge.py`` (which raises it for cyclic algebraic
    equations) and ``simulation.py`` re-export the name to keep the public
    ``earthsci_ast.simulation.SimulationError`` symbol stable.
    """

    pass


class InvalidModelError(EarthSciAstError, ValueError):
    """Raised when a model is structurally unsuitable for a requested operation.

    Used by :func:`symbolic_jacobian` for its malformed-model guards (no state
    variables, no equations, non-square system). Subclasses
    :class:`EarthSciAstError` so it joins the package error hierarchy like its
    siblings, and also :class:`ValueError` so existing callers/tests that catch
    the historically-raised ``ValueError`` on these paths keep working.
    """

    pass


class _ess_numeric_abs(sp.Function):
    """``|x|`` with construction-time canonical rewrites disabled (esm-5gk).

    SymPy's ``sp.Abs.eval`` applies decompositions like
    ``Abs(exp(z) * w) → exp(re(z)) * Abs(w)`` and ``Abs(0.41**((log(N*T**(-8))
    - C)**2 + 1)) → 0.41**((log|...|**2 - arg(...)**2)/log10**2 + 1)``
    whenever the inner expression's domain cannot be proven real. Those
    decompositions look mathematically equivalent on the positive real
    branch but the ``log|...|**2 * arg(...)**2`` cross term in the second
    one evaluates to ``inf * 0 = NaN`` whenever a species concentration
    touches 0 — exactly the cse=False non-finite-derivative failure on
    geoschem_fullchem this whole bead targets.

    A subclass of :class:`sympy.Function` with a strictly numeric
    ``.eval`` rule sidesteps the decomposition entirely:

    * Symbolic argument → returns ``None`` from ``eval``, leaving an
      opaque ``_ess_numeric_abs(arg)`` node in the tree. SymPy never
      reasons about modulus/phase of the inner expression, so the
      complex-domain rewrites cannot fire.
    * Numeric argument (``Float``/``Integer``/``Rational``) → returns
      the literal absolute value, so substitution-based evaluation
      (e.g. tests doing ``expr.subs(x, 3.5)``) keeps working.

    At lambdify time we pass ``modules=[{"_ess_numeric_abs": numpy.abs},
    "numpy"]``, so the opaque calls resolve to ``numpy.abs`` on real
    floats — correct for any sign of the runtime argument. This is why
    the fix is sign-agnostic: it makes no positivity assumption about
    state or parameters and stays correct on models whose state goes
    negative.

    Class of risk this addresses: ``sp.Abs.eval`` is the SymPy operator
    whose canonical rewrites produced the chemistry-fatal decomposition
    path (``Abs(exp(z)*w)``, ``Abs(b**z)`` chains). If a future SymPy
    version adds a new rewrite-on-eval to another operator
    (``sign``, ``floor``, ``ceiling``, etc.) that emits ``re``/``im``/
    ``arg`` on real-but-symbolically-unprovable inputs, the same
    opacity treatment may need to be extended to that operator. Audit
    by checking ``inspect.getsource`` of a lambdified RHS on a fresh
    model that uses the suspected operator and grepping for ``real(``,
    ``imag(``, ``angle(``.
    """

    @classmethod
    def eval(cls, arg):
        if arg.is_number and getattr(arg, "is_real", None):
            return abs(arg)
        return None


def _make_fn_callable(
    name: str,
    total_arity: int,
    const_args_by_position: dict[int, list],
) -> Callable:
    """Build a Python callable for a single ``fn``-op call site.

    SymPy's :func:`lambdify` cannot route Python list/array literals through
    its symbolic argument list, so the table / axis arguments to closed
    functions like ``interp.bilinear`` cannot become :class:`sympy.Expr` nodes.
    Instead, each ``fn``-op call site emits a unique synthetic
    :class:`sympy.Function` placeholder over only its dynamic (state-/
    parameter-/time-dependent) arguments; the const arrays are baked into a
    Python closure that is registered in ``modules`` for that specific
    placeholder. At runtime the lambdified RHS calls into this closure, which
    reconstructs the original argument vector and dispatches through
    :func:`registered_functions.evaluate_closed_function`.

    Always returns ``float`` so the result composes with NumPy arithmetic
    inside ``solve_ivp`` regardless of whether the registry returned an int
    (``datetime.year``) or a float (``interp.bilinear``).
    """

    def _fn_call(*dynamic_args):
        all_args: list = [None] * total_arity
        for i, v in const_args_by_position.items():
            all_args[i] = v
        di = 0
        for i in range(total_arity):
            if all_args[i] is None:
                all_args[i] = float(dynamic_args[di])
                di += 1
        return float(evaluate_closed_function(name, all_args))

    return _fn_call


# Pure unary math/logical ops: each takes exactly 1 ESM argument and maps to a
# single SymPy callable applied to it. The second tuple element is the display
# name used in the arity error so the message text is preserved verbatim (e.g.
# ``exp`` reports as "Exponential"). Ops with non-uniform handling (``abs`` uses
# the NaN-safe ``_ess_numeric_abs`` placeholder; ``^`` canonicalizes integer
# Float exponents) are kept explicit below rather than table-driven.
#
# The SymPy VALUES live here (op_registry is a sympy-free leaf); the live
# dispatch table's KEY SET is DERIVED from the registry just below, so it cannot
# drift from the canonical vocabulary — see ``_UNARY_SYMPY``.
_UNARY_SYMPY_IMPL: dict[str, tuple] = {
    "exp": (sp.exp, "Exponential"),
    "log": (sp.log, "Logarithm"),
    "log10": (lambda x: sp.log(x, 10), "log10"),
    "sqrt": (sp.sqrt, "sqrt"),
    "sign": (sp.sign, "sign"),
    "floor": (sp.floor, "floor"),
    "ceil": (sp.ceiling, "ceil"),
    "sin": (sp.sin, "Sine"),
    "cos": (sp.cos, "Cosine"),
    "tan": (sp.tan, "tan"),
    "asin": (sp.asin, "asin"),
    "acos": (sp.acos, "acos"),
    "atan": (sp.atan, "atan"),
    "sinh": (sp.sinh, "sinh"),
    "cosh": (sp.cosh, "cosh"),
    "tanh": (sp.tanh, "tanh"),
    "asinh": (sp.asinh, "asinh"),
    "acosh": (sp.acosh, "acosh"),
    "atanh": (sp.atanh, "atanh"),
    "not": (sp.Not, "not"),
}

# KEY SET single-sourced from op_registry: the unary elementary functions EXCEPT
# ``abs`` (which uses the NaN-safe ``_ess_numeric_abs`` placeholder, handled
# explicitly), PLUS the unary logical ``not``. Building the dict by iterating the
# registry-derived key set makes forgetting a value a loud import-time KeyError
# and makes a stray mapping for an unregistered op impossible.
_UNARY_SYMPY: dict[str, tuple] = {
    op: _UNARY_SYMPY_IMPL[op]
    for op in (op_registry.unary_elementary() - {"abs"}) | {"not"}
}

# Pure binary math/relational ops: each takes exactly 2 ESM arguments and maps
# to a single SymPy callable applied to them. The second tuple element is the
# display name used in the arity error to preserve the message text (e.g. ``/``
# reports as "Division", ``>`` as "Greater than"). VALUES local; KEY SET derived.
_BINARY_SYMPY_IMPL: dict[str, tuple] = {
    "/": (lambda a, b: a / b, "Division"),
    "atan2": (sp.atan2, "atan2"),
    ">": (sp.StrictGreaterThan, "Greater than"),
    "<": (sp.StrictLessThan, "Less than"),
    ">=": (sp.GreaterThan, "Greater than or equal"),
    "<=": (sp.LessThan, "Less than or equal"),
    "==": (sp.Eq, "Equality"),
    "!=": (sp.Ne, "Inequality"),
}

# KEY SET single-sourced from op_registry: division, atan2, and the six evaluable
# (non-alias) comparison ops.
_BINARY_SYMPY: dict[str, tuple] = {
    op: _BINARY_SYMPY_IMPL[op]
    for op in {"/", "atan2"} | (op_registry.by_category("comparison") & op_registry.canonical_names())
}


def _expr_to_sympy(
    expr: Expr,
    symbol_map: dict[str, sp.Symbol],
    fn_callable_map: dict[str, Callable] | None = None,
    structural_ops: bool = False,
) -> sp.Expr:
    """
    Convert ESM Expr to SymPy expression.

    The ``'abs'`` op is converted to a placeholder
    :class:`sympy.Function` rather than :class:`sympy.Abs` so SymPy's
    construction-time canonical rewrites for absolute value do not fire
    (esm-5gk). See ``_ess_numeric_abs`` for the full rationale; in
    short, ``sp.Abs`` over a product of ``exp``/``log``/rational-power
    composites decomposes into a complex-domain form whose
    ``log|x|**2 * arg(x)**2`` term evaluates to ``inf*0 = NaN`` at any
    boundary value (e.g. species concentration of 0). The placeholder
    :class:`sympy.Function` has no ``.eval``, so the decomposition cannot
    fire and the lambdified RHS stays in pure-real form.

    The ``'fn'`` op (closed-function registry, esm-spec §9.2) and its
    companion ``'const'`` op are handled by extracting the inline-const
    array arguments (table / axis data) at conversion time and emitting a
    unique :class:`sympy.Function` placeholder over only the dynamic
    arguments. The const arrays are baked into a Python closure registered
    in ``fn_callable_map`` keyed by the placeholder name; the caller threads
    that map into ``sympy_bridge._LAMBDIFY_MODULES`` at lambdify time so the
    RHS can call into the registry at runtime. (esm-6ka)

    Args:
        expr: Expression to convert
        symbol_map: Mapping from variable names to SymPy symbols
        fn_callable_map: Mutable map populated with ``synthetic_name → callable``
            for every ``fn``-op call site encountered. Required when ``expr``
            contains ``fn`` ops; ``None`` raises with a clear diagnostic.
        structural_ops: When False (the simulation-lowering default), the
            rewrite-target operators ``D``/``grad``/``div``/``laplacian``
            raise :class:`UnreachableSpatialOperatorError` (they must have
            been consumed structurally or rewritten to a stencil before the
            lambdify path) and ``Pre`` is unsupported. When True (the public
            :func:`to_sympy` contract, used for symbolic analysis such as
            :func:`symbolic_jacobian`), ``D``/``grad`` become
            :class:`sympy.Derivative` and ``div``/``laplacian``/``Pre``
            become opaque :class:`sympy.Function` placeholders.

    Returns:
        SymPy expression
    """
    if isinstance(expr, (int, float)):
        return sp.Float(expr)
    if isinstance(expr, str):
        if expr in symbol_map:
            return symbol_map[expr]
        # Try to parse as a number
        try:
            return sp.Float(float(expr))
        except ValueError:
            # Create a new symbol if not found.
            symbol_map[expr] = sp.Symbol(expr)
            return symbol_map[expr]
    elif isinstance(expr, ExprNode):
        # Unlowered rewrite-target operators (esm-spec §4.2 / §9.6.8) must be
        # rewritten to a stencil by a discretization rule before reaching the
        # SymPy/lambdify path: a spatial/right-hand-side `D`, or the
        # `grad`/`div`/`laplacian` sugar ops. `D` in an equation LHS is consumed
        # structurally by `_flat_to_sympy_rhs` (never routed here), so any `D`
        # this recursion sees is an unlowered RHS derivative. Surface the uniform
        # `unlowered_operator` diagnostic instead of letting SymPy invent a
        # symbolic placeholder. Under ``structural_ops=True`` these ops are
        # instead converted symbolically (public ``to_sympy`` contract).
        if expr.op in ("grad", "div", "laplacian", "D"):
            if not structural_ops:
                raise UnreachableSpatialOperatorError(expr.op)
            sympy_args = [
                _expr_to_sympy(a, symbol_map, fn_callable_map, structural_ops) for a in expr.args
            ]
            if len(sympy_args) != 1:
                raise SimulationError(
                    f"{expr.op} requires exactly 1 argument, got {len(sympy_args)}"
                )
            if expr.op == "D":
                if not expr.wrt:
                    raise SimulationError("D operator requires a `wrt` field")
                wrt_symbol = _expr_to_sympy(expr.wrt, symbol_map, fn_callable_map, structural_ops)
                return sp.Derivative(sympy_args[0], wrt_symbol)
            if expr.op == "grad":
                # Gradient - represent as a derivative over the dimension when
                # one is declared; otherwise pass the operand through.
                if expr.dim:
                    dim_symbol = _expr_to_sympy(
                        expr.dim, symbol_map, fn_callable_map, structural_ops
                    )
                    return sp.Derivative(sympy_args[0], dim_symbol)
                return sympy_args[0]
            # div / laplacian: opaque placeholders that preserve structure.
            return sp.Function(expr.op)(sympy_args[0])

        # Closed-function registry (esm-spec §9.2 / §9.3) and inline const
        # values must be handled before the generic argument recursion below,
        # because ``fn`` calls take materialized const arrays in some argument
        # positions (table / axis data) that have no sensible SymPy
        # representation, and the bare ``const`` op carries the value in
        # ``expr.value`` rather than ``expr.args``. (esm-6ka)
        if expr.op == "const":
            v = expr.value
            if isinstance(v, bool):
                # bool subclasses int — treat as numeric scalar (0 or 1) only
                # via explicit float conversion to avoid sp.Float(True)
                # producing a Boolean atom.
                return sp.Float(float(v))
            if isinstance(v, (int, float)):
                return sp.Float(v)
            # Inline arrays only have meaning as positional arguments to a
            # ``fn`` op (the closed-function registry consumes them as raw
            # Python lists). A standalone array-valued ``const`` reaching this
            # path would mean someone tried to lambdify an array literal as
            # an ODE RHS subterm, which is not supported.
            raise SimulationError(
                f"`const` op with non-scalar value (type "
                f"{type(v).__name__}) cannot appear outside of a closed-"
                f"function `fn` argument slot in the SymPy simulator path"
            )
        if expr.op == "fn":
            if expr.name is None:
                raise SimulationError("`fn` op requires a `name` field")
            if expr.name not in closed_function_names():
                raise SimulationError(
                    f"`fn` name `{expr.name}` is not in the closed function "
                    f"registry (esm-spec §9.2)"
                )
            if fn_callable_map is None:
                raise SimulationError(
                    "`fn` op (closed-function call, esm-spec §9.2) is not "
                    "supported by the symbolic `to_sympy` conversion: a closed "
                    "function needs a runtime callable map that only the "
                    "simulation-lowering path constructs. Lower/simulate the "
                    "expression through the simulation entry point instead of "
                    "converting it to SymPy directly."
                )
            const_positions = INTERP_CONST_ARG_POSITIONS.get(expr.name, ())
            const_args_by_position: dict[int, list] = {}
            dynamic_sympy_args: list[sp.Expr] = []
            for i, a in enumerate(expr.args):
                if i in const_positions:
                    if not (isinstance(a, ExprNode) and a.op == "const"):
                        raise SimulationError(
                            f"`{expr.name}` argument {i} must be an inline "
                            f"`const` array (esm-spec §9.2 ``interp.*``)"
                        )
                    const_args_by_position[i] = extract_const_array(a)
                else:
                    dynamic_sympy_args.append(
                        _expr_to_sympy(a, symbol_map, fn_callable_map, structural_ops)
                    )
            synthetic_name = f"_ess_fn_{len(fn_callable_map)}"
            fn_callable_map[synthetic_name] = _make_fn_callable(
                expr.name,
                len(expr.args),
                const_args_by_position,
            )
            placeholder = sp.Function(synthetic_name)
            return placeholder(*dynamic_sympy_args)
        if expr.op == "enum":
            raise SimulationError(
                "`enum` op encountered in SymPy bridge — `lower_enums(file)` "
                "should have run during load (esm-spec §9.3)"
            )

        # Convert arguments recursively
        sympy_args = [
            _expr_to_sympy(arg, symbol_map, fn_callable_map, structural_ops) for arg in expr.args
        ]

        # Handle different operations
        if expr.op == "+":
            return sum(sympy_args) if sympy_args else 0
        if expr.op == "-":
            if len(sympy_args) == 1:
                return -sympy_args[0]
            if len(sympy_args) == 2:
                return sympy_args[0] - sympy_args[1]
            raise SimulationError(
                f"Invalid number of arguments for subtraction: {len(sympy_args)}"
            )
        if expr.op == "*":
            result = 1
            for arg in sympy_args:
                result *= arg
            return result
        if expr.op in ("^", "**", "pow"):
            if len(sympy_args) != 2:
                raise SimulationError(f"Power requires exactly 2 arguments, got {len(sympy_args)}")
            base, exp_arg = sympy_args
            # SymPy treats ``x**Float(2.0)`` as a non-integer rational power
            # (``exp(2.0*log(x))``) which forces the lambdified RHS into
            # complex-domain code paths (``re(...)``, ``im(...)``,
            # ``angle(...)``) under cse=False — even when ``x`` is provably
            # real. Integer-valued Float exponents from ESM JSON (``"2.0"``,
            # ``"3.0"``) are by author intent integer powers, so canonicalize
            # them to ``sp.Integer`` and keep sympy on its real-domain
            # simplification path. See esm-5gk for the geoschem_fullchem
            # non-finite-derivative failure this prevents.
            if (
                isinstance(exp_arg, sp.Float)
                and exp_arg.is_finite
                and float(exp_arg) == int(exp_arg)
            ):
                exp_arg = sp.Integer(int(exp_arg))
            return base**exp_arg
        if expr.op == "abs":
            if len(sympy_args) != 1:
                raise SimulationError(f"abs requires exactly 1 argument, got {len(sympy_args)}")
            # See ``_ess_numeric_abs`` definition — using ``sp.Abs`` here
            # would trigger the construction-time decomposition that
            # esm-5gk fixes.
            return _ess_numeric_abs(sympy_args[0])
        if expr.op == "min":
            if not sympy_args:
                raise SimulationError("min requires at least 1 argument")
            return sp.Min(*sympy_args)
        if expr.op == "max":
            if not sympy_args:
                raise SimulationError("max requires at least 1 argument")
            return sp.Max(*sympy_args)
        if expr.op == "ifelse":
            if len(sympy_args) != 3:
                raise SimulationError(f"ifelse requires exactly 3 arguments, got {len(sympy_args)}")
            return sp.Piecewise((sympy_args[1], sympy_args[0]), (sympy_args[2], True))
        if expr.op == "and":
            if len(sympy_args) < 2:
                raise SimulationError(f"and requires at least 2 arguments, got {len(sympy_args)}")
            return sp.And(*sympy_args)
        if expr.op == "or":
            if len(sympy_args) < 2:
                raise SimulationError(f"or requires at least 2 arguments, got {len(sympy_args)}")
            return sp.Or(*sympy_args)
        if expr.op in _UNARY_SYMPY:
            # Pure unary ops (exp/log/log10/sqrt, trig, hyperbolic, sign,
            # floor, ceil, not): uniform 1-arg arity check + one SymPy callable.
            sympy_fn, display = _UNARY_SYMPY[expr.op]
            if len(sympy_args) != 1:
                raise SimulationError(
                    f"{display} requires exactly 1 argument, got {len(sympy_args)}"
                )
            return sympy_fn(sympy_args[0])
        if expr.op in _BINARY_SYMPY:
            # Pure binary ops (division, atan2, relational comparisons):
            # uniform 2-arg arity check + one SymPy callable.
            sympy_fn, display = _BINARY_SYMPY[expr.op]
            if len(sympy_args) != 2:
                raise SimulationError(
                    f"{display} requires exactly 2 arguments, got {len(sympy_args)}"
                )
            return sympy_fn(sympy_args[0], sympy_args[1])
        if structural_ops and expr.op == "Pre":
            # Previous value operator - represent as an opaque function
            # (public ``to_sympy`` contract only; the simulation path handles
            # Pre in event affects structurally, never through lambdify).
            if len(sympy_args) != 1:
                raise SimulationError(
                    f"Pre operator requires exactly 1 argument, got {len(sympy_args)}"
                )
            return sp.Function("Pre")(sympy_args[0])
        raise SimulationError(f"Unsupported operation: {expr.op}")
    else:
        raise SimulationError(f"Unsupported expression type: {type(expr)}")


def to_sympy(expr: Expr, symbol_map: dict[str, sp.Symbol] | None = None) -> sp.Expr:
    """
    Convert ESM expression to SymPy expression.

    Thin wrapper over :func:`_expr_to_sympy` — the single ESM→SymPy
    converter shared with the simulation tier (``sympy_bridge.py``) — run
    with ``structural_ops=True`` so ``D``/``grad`` convert to
    :class:`sympy.Derivative` and ``div``/``laplacian``/``Pre`` become
    opaque :class:`sympy.Function` placeholders (symbolic-analysis
    semantics, e.g. for :func:`symbolic_jacobian`).

    Bare string variable names auto-create symbols: any name not present in
    ``symbol_map`` gets a fresh :class:`sympy.Symbol` which is also recorded
    in the (caller-visible) map, so repeated references share one symbol.

    Args:
        expr: ESM expression to convert
        symbol_map: Optional mapping from variable names to SymPy symbols;
            mutated in place as new symbols are created.

    Returns:
        SymPy expression

    Raises:
        SimulationError: If an unsupported expression type or operation is
            encountered, or an operation has the wrong number of arguments.
    """
    if symbol_map is None:
        symbol_map = {}
    return _expr_to_sympy(expr, symbol_map, structural_ops=True)


# SymPy ``func.__name__`` -> ESM op, for ops whose ESM form consumes ALL of the
# SymPy args (variadic ``Add``/``Mul``/``Min``/``Max``/``And``/``Or``; 2-ary
# ``atan2``).
_FROM_SYMPY_ALL_ARGS: dict[str, str] = {
    "Add": "+",
    "Mul": "*",
    "atan2": "atan2",
    "Min": "min",
    "Max": "max",
    "And": "and",
    "Or": "or",
}

# SymPy relational class name -> ESM comparison op, mirroring the forward
# mapping in ``_BINARY_SYMPY``. Relationals are binary and are NOT
# :class:`sympy.Function`, so ``from_sympy`` needs an explicit dispatch arm for
# them (otherwise ``from_sympy(to_sympy(ifelse(x>y, ...)))`` falls through to the
# final ``raise TypeError``). ``sp.Eq``/``sp.Ne`` report as ``Equality`` /
# ``Unequality``.
_FROM_SYMPY_RELATIONAL: dict[str, str] = {
    "StrictGreaterThan": ">",
    "GreaterThan": ">=",
    "StrictLessThan": "<",
    "LessThan": "<=",
    "Equality": "==",
    "Unequality": "!=",
}

# SymPy ``func.__name__`` -> ESM op, for ops whose ESM form consumes ONLY the
# first SymPy arg. Both ``Abs`` and the NaN-safe ``_ess_numeric_abs`` placeholder
# that ``_expr_to_sympy`` emits for the ``abs`` op (esm-5gk) map back to ``abs``.
_FROM_SYMPY_UNARY: dict[str, str] = {
    "exp": "exp",
    "sin": "sin",
    "cos": "cos",
    "tan": "tan",
    "asin": "asin",
    "acos": "acos",
    "atan": "atan",
    "sinh": "sinh",
    "cosh": "cosh",
    "tanh": "tanh",
    "asinh": "asinh",
    "acosh": "acosh",
    "atanh": "atanh",
    "sign": "sign",
    "floor": "floor",
    "ceiling": "ceil",
    "Not": "not",
    "Abs": "abs",
    "_ess_numeric_abs": "abs",
}


def from_sympy(sympy_expr: sp.Expr) -> Expr:
    """
    Convert SymPy expression back to ESM expression.

    Dispatch is by ``sympy_expr.func.__name__`` via the ``_FROM_SYMPY_*``
    tables for the uniform function/operator ops (trig, hyperbolic, Min/Max,
    And/Or, ...). Ops needing custom arg reshaping or metadata — ``Pow``
    (``^``), ``log`` (natural vs ``log10``), ``Derivative`` (``wrt``),
    ``Piecewise`` (``ifelse``) — and the numeric/symbol atoms stay explicit.

    Args:
        sympy_expr: SymPy expression to convert

    Returns:
        ESM expression

    Raises:
        SimulationError: If a Piecewise with more than two branches is
            encountered — it has no single-``ifelse`` representation, so it
            cannot be converted losslessly.
        TypeError: If an otherwise unsupported SymPy expression type is
            encountered.
    """
    # Numeric / symbol atoms.
    if isinstance(sympy_expr, (sp.Integer, sp.Rational, sp.Float)):
        return float(sympy_expr)
    if isinstance(sympy_expr, sp.Symbol):
        return str(sympy_expr)

    # Ops that need custom arg reshaping / metadata (not a plain op+args map),
    # handled before the func-name tables below.
    if isinstance(sympy_expr, sp.Pow):
        base, exp = sympy_expr.args
        return ExprNode(op="^", args=[from_sympy(base), from_sympy(exp)])
    if isinstance(sympy_expr, sp.log):
        # Natural log, or log10 when a base-10 second arg is present.
        if len(sympy_expr.args) == 2 and sympy_expr.args[1] == 10:
            return ExprNode(op="log10", args=[from_sympy(sympy_expr.args[0])])
        return ExprNode(op="log", args=[from_sympy(sympy_expr.args[0])])
    if isinstance(sympy_expr, sp.Derivative):
        expr_arg, wrt_arg = sympy_expr.args[0], sympy_expr.args[1]
        return ExprNode(op="D", args=[from_sympy(expr_arg)], wrt=str(wrt_arg))
    if isinstance(sympy_expr, sp.Piecewise):
        pieces = sympy_expr.args
        if len(pieces) == 2:
            (true_val, condition), (false_val, _) = pieces
            return ExprNode(
                op="ifelse",
                args=[from_sympy(condition), from_sympy(true_val), from_sympy(false_val)],
            )
        # A Piecewise with more than two branches has no single-``ifelse``
        # representation. The old code silently returned only the first
        # branch's value, dropping every other branch and its condition;
        # refuse loudly instead of producing a plausible-but-wrong result.
        raise SimulationError(
            f"Piecewise with {len(pieces)} branches cannot be converted to a "
            f"single `ifelse` ESM op; only two-branch Piecewise is supported"
        )

    # Uniform function/operator ops: dispatch by SymPy func name.
    func = getattr(sympy_expr, "func", None)
    func_name = getattr(func, "__name__", None)
    if func_name in _FROM_SYMPY_RELATIONAL:
        # Binary comparisons (>, >=, <, <=, ==, !=); not sp.Function, so handled
        # explicitly. Mirrors _BINARY_SYMPY in the forward direction.
        return ExprNode(
            op=_FROM_SYMPY_RELATIONAL[func_name],
            args=[from_sympy(arg) for arg in sympy_expr.args],
        )
    if func_name in _FROM_SYMPY_ALL_ARGS:
        return ExprNode(
            op=_FROM_SYMPY_ALL_ARGS[func_name],
            args=[from_sympy(arg) for arg in sympy_expr.args],
        )
    if func_name in _FROM_SYMPY_UNARY:
        return ExprNode(
            op=_FROM_SYMPY_UNARY[func_name],
            args=[from_sympy(sympy_expr.args[0])],
        )

    # Boolean constants -> number.
    if sympy_expr.__class__.__name__ in ("BooleanTrue", "BooleanFalse"):
        return float(sympy_expr)
    # Generic function (Pre, div, laplacian, unknown) — the function name is
    # the ESM op.
    if isinstance(sympy_expr, sp.Function):
        return ExprNode(
            op=str(sympy_expr.func),
            args=[from_sympy(arg) for arg in sympy_expr.args],
        )
    if sympy_expr.is_number:
        # Numeric constant
        return float(sympy_expr)
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
        if var.type == "state":
            state_vars.append(name)

    if not state_vars:
        raise InvalidModelError("Model has no state variables")

    if not model.equations:
        raise InvalidModelError("Model has no equations")

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

    # A well-formed ODE system contributes exactly one right-hand side per
    # state variable — from a ``D(state)/dt = rhs`` equation, or an equation
    # whose LHS is a bare state variable. If the counts disagree the model is
    # malformed for Jacobian purposes; the old code silently fell back to "all
    # equation RHS", zero-padded, then truncated to force a square matrix,
    # which yields a plausible-but-wrong Jacobian with no diagnostic. Fail
    # loudly instead of guessing.
    if len(rhs_expressions) != len(state_vars):
        raise InvalidModelError(
            f"Model has {len(state_vars)} state variables but "
            f"{len(rhs_expressions)} matching differential/state equations; "
            f"cannot build a square Jacobian. Each state variable needs "
            f"exactly one `D(state)/dt = rhs` (or bare-state-LHS) equation."
        )

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
