"""SymPy bridge for the Python simulation tier.

Bridges ESM AST expressions to SymPy and compiles them to NumPy callables
via :func:`sympy.lambdify`. This module owns:

* :class:`_ess_numeric_abs` — the ``sp.Abs`` workaround that keeps
  lambdified RHS expressions in pure-real form (esm-5gk).
* :func:`_expr_to_sympy` — ESM ``Expr`` → SymPy expression.
* :func:`_flat_to_sympy_rhs` / :func:`_observed_to_sympy_value_exprs` —
  build per-state / per-observed SymPy expressions from a
  :class:`FlattenedSystem` with scalar algebraic-equation elimination.
* :class:`_CompiledRhs` and :func:`_compile_flat_rhs` — the lambdify +
  CSE compile that dominates ``simulate()`` wall time on large mechanisms.

``simulation.py`` imports from this module and handles the SciPy
``solve_ivp`` wiring, event handling, and array-op interpreter path.
"""

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

import numpy as np
import sympy as sp

from .esm_types import Expr, ExprNode
from .flatten import FlattenedSystem
from .numpy_interpreter import UnreachableSpatialOperatorError
from .registered_functions import (
    INTERP_CONST_ARG_POSITIONS,
    closed_function_names,
    evaluate_closed_function,
    extract_const_array,
)


class SimulationError(Exception):
    """Exception raised during the SymPy bridge or simulation.

    Defined here (rather than in ``simulation.py``) because the bridge
    itself raises it for malformed expressions and cyclic algebraic
    equations. ``simulation.py`` re-exports the name to keep the public
    ``earthsci_toolkit.simulation.SimulationError`` symbol stable.
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


# Module-mapping handed to every ``sp.lambdify`` call in this module so
# the ``_ess_numeric_abs`` calls emitted by ``_expr_to_sympy`` resolve to
# ``numpy.abs`` at runtime.
_LAMBDIFY_MODULES = [{"_ess_numeric_abs": np.abs}, "numpy"]


def _make_fn_callable(
    name: str,
    total_arity: int,
    const_args_by_position: Dict[int, list],
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
        all_args: List = [None] * total_arity
        for i, v in const_args_by_position.items():
            all_args[i] = v
        di = 0
        for i in range(total_arity):
            if all_args[i] is None:
                all_args[i] = float(dynamic_args[di])
                di += 1
        return float(evaluate_closed_function(name, all_args))

    return _fn_call


def _expr_to_sympy(
    expr: Expr,
    symbol_map: Dict[str, sp.Symbol],
    fn_callable_map: Optional[Dict[str, Callable]] = None,
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
    that map into :data:`_LAMBDIFY_MODULES` at lambdify time so the RHS can
    call into the registry at runtime. (esm-6ka)

    Args:
        expr: Expression to convert
        symbol_map: Mapping from variable names to SymPy symbols
        fn_callable_map: Mutable map populated with ``synthetic_name → callable``
            for every ``fn``-op call site encountered. Required when ``expr``
            contains ``fn`` ops; ``None`` raises with a clear diagnostic.

    Returns:
        SymPy expression
    """
    if isinstance(expr, (int, float)):
        return sp.Float(expr)
    elif isinstance(expr, str):
        if expr in symbol_map:
            return symbol_map[expr]
        else:
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
        # symbolic placeholder.
        if expr.op in ('grad', 'div', 'laplacian', 'D'):
            raise UnreachableSpatialOperatorError(expr.op)

        # Closed-function registry (esm-spec §9.2 / §9.3) and inline const
        # values must be handled before the generic argument recursion below,
        # because ``fn`` calls take materialized const arrays in some argument
        # positions (table / axis data) that have no sensible SymPy
        # representation, and the bare ``const`` op carries the value in
        # ``expr.value`` rather than ``expr.args``. (esm-6ka)
        if expr.op == 'const':
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
        if expr.op == 'fn':
            if expr.name is None:
                raise SimulationError("`fn` op requires a `name` field")
            if expr.name not in closed_function_names():
                raise SimulationError(
                    f"`fn` name `{expr.name}` is not in the closed function "
                    f"registry (esm-spec §9.2)"
                )
            if fn_callable_map is None:
                raise SimulationError(
                    "internal: `fn` op encountered without a fn_callable_map "
                    "to register the closure into. The simulator entry point "
                    "must construct one and thread it through "
                    "_expr_to_sympy."
                )
            const_positions = INTERP_CONST_ARG_POSITIONS.get(expr.name, ())
            const_args_by_position: Dict[int, list] = {}
            dynamic_sympy_args: List[sp.Expr] = []
            for i, a in enumerate(expr.args):
                if i in const_positions:
                    if not (isinstance(a, ExprNode) and a.op == 'const'):
                        raise SimulationError(
                            f"`{expr.name}` argument {i} must be an inline "
                            f"`const` array (esm-spec §9.2 ``interp.*``)"
                        )
                    const_args_by_position[i] = extract_const_array(a)
                else:
                    dynamic_sympy_args.append(
                        _expr_to_sympy(a, symbol_map, fn_callable_map)
                    )
            synthetic_name = f"_ess_fn_{len(fn_callable_map)}"
            fn_callable_map[synthetic_name] = _make_fn_callable(
                expr.name, len(expr.args), const_args_by_position,
            )
            placeholder = sp.Function(synthetic_name)
            return placeholder(*dynamic_sympy_args)
        if expr.op == 'enum':
            raise SimulationError(
                "`enum` op encountered in SymPy bridge — `lower_enums(file)` "
                "should have run during load (esm-spec §9.3)"
            )

        # Convert arguments recursively
        sympy_args = [
            _expr_to_sympy(arg, symbol_map, fn_callable_map)
            for arg in expr.args
        ]

        # Handle different operations
        if expr.op == '+':
            return sum(sympy_args) if sympy_args else 0
        elif expr.op == '-':
            if len(sympy_args) == 1:
                return -sympy_args[0]
            elif len(sympy_args) == 2:
                return sympy_args[0] - sympy_args[1]
            else:
                raise SimulationError(f"Invalid number of arguments for subtraction: {len(sympy_args)}")
        elif expr.op == '*':
            result = 1
            for arg in sympy_args:
                result *= arg
            return result
        elif expr.op == '/':
            if len(sympy_args) != 2:
                raise SimulationError(f"Division requires exactly 2 arguments, got {len(sympy_args)}")
            return sympy_args[0] / sympy_args[1]
        elif expr.op in ('^', '**', 'pow'):
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
            return base ** exp_arg
        elif expr.op == 'exp':
            if len(sympy_args) != 1:
                raise SimulationError(f"Exponential requires exactly 1 argument, got {len(sympy_args)}")
            return sp.exp(sympy_args[0])
        elif expr.op == 'log':
            if len(sympy_args) != 1:
                raise SimulationError(f"Logarithm requires exactly 1 argument, got {len(sympy_args)}")
            return sp.log(sympy_args[0])
        elif expr.op == 'log10':
            if len(sympy_args) != 1:
                raise SimulationError(f"log10 requires exactly 1 argument, got {len(sympy_args)}")
            return sp.log(sympy_args[0], 10)
        elif expr.op == 'sqrt':
            if len(sympy_args) != 1:
                raise SimulationError(f"sqrt requires exactly 1 argument, got {len(sympy_args)}")
            return sp.sqrt(sympy_args[0])
        elif expr.op == 'abs':
            if len(sympy_args) != 1:
                raise SimulationError(f"abs requires exactly 1 argument, got {len(sympy_args)}")
            # See ``_ess_numeric_abs`` definition — using ``sp.Abs`` here
            # would trigger the construction-time decomposition that
            # esm-5gk fixes.
            return _ess_numeric_abs(sympy_args[0])
        elif expr.op == 'sign':
            if len(sympy_args) != 1:
                raise SimulationError(f"sign requires exactly 1 argument, got {len(sympy_args)}")
            return sp.sign(sympy_args[0])
        elif expr.op == 'floor':
            if len(sympy_args) != 1:
                raise SimulationError(f"floor requires exactly 1 argument, got {len(sympy_args)}")
            return sp.floor(sympy_args[0])
        elif expr.op == 'ceil':
            if len(sympy_args) != 1:
                raise SimulationError(f"ceil requires exactly 1 argument, got {len(sympy_args)}")
            return sp.ceiling(sympy_args[0])
        elif expr.op == 'min':
            if not sympy_args:
                raise SimulationError("min requires at least 1 argument")
            return sp.Min(*sympy_args)
        elif expr.op == 'max':
            if not sympy_args:
                raise SimulationError("max requires at least 1 argument")
            return sp.Max(*sympy_args)
        elif expr.op == 'sin':
            if len(sympy_args) != 1:
                raise SimulationError(f"Sine requires exactly 1 argument, got {len(sympy_args)}")
            return sp.sin(sympy_args[0])
        elif expr.op == 'cos':
            if len(sympy_args) != 1:
                raise SimulationError(f"Cosine requires exactly 1 argument, got {len(sympy_args)}")
            return sp.cos(sympy_args[0])
        elif expr.op == 'tan':
            if len(sympy_args) != 1:
                raise SimulationError(f"tan requires exactly 1 argument, got {len(sympy_args)}")
            return sp.tan(sympy_args[0])
        elif expr.op == 'asin':
            if len(sympy_args) != 1:
                raise SimulationError(f"asin requires exactly 1 argument, got {len(sympy_args)}")
            return sp.asin(sympy_args[0])
        elif expr.op == 'acos':
            if len(sympy_args) != 1:
                raise SimulationError(f"acos requires exactly 1 argument, got {len(sympy_args)}")
            return sp.acos(sympy_args[0])
        elif expr.op == 'atan':
            if len(sympy_args) != 1:
                raise SimulationError(f"atan requires exactly 1 argument, got {len(sympy_args)}")
            return sp.atan(sympy_args[0])
        elif expr.op == 'atan2':
            if len(sympy_args) != 2:
                raise SimulationError(f"atan2 requires exactly 2 arguments, got {len(sympy_args)}")
            return sp.atan2(sympy_args[0], sympy_args[1])
        elif expr.op == 'sinh':
            if len(sympy_args) != 1:
                raise SimulationError(f"sinh requires exactly 1 argument, got {len(sympy_args)}")
            return sp.sinh(sympy_args[0])
        elif expr.op == 'cosh':
            if len(sympy_args) != 1:
                raise SimulationError(f"cosh requires exactly 1 argument, got {len(sympy_args)}")
            return sp.cosh(sympy_args[0])
        elif expr.op == 'tanh':
            if len(sympy_args) != 1:
                raise SimulationError(f"tanh requires exactly 1 argument, got {len(sympy_args)}")
            return sp.tanh(sympy_args[0])
        elif expr.op == 'asinh':
            if len(sympy_args) != 1:
                raise SimulationError(f"asinh requires exactly 1 argument, got {len(sympy_args)}")
            return sp.asinh(sympy_args[0])
        elif expr.op == 'acosh':
            if len(sympy_args) != 1:
                raise SimulationError(f"acosh requires exactly 1 argument, got {len(sympy_args)}")
            return sp.acosh(sympy_args[0])
        elif expr.op == 'atanh':
            if len(sympy_args) != 1:
                raise SimulationError(f"atanh requires exactly 1 argument, got {len(sympy_args)}")
            return sp.atanh(sympy_args[0])
        elif expr.op == 'ifelse':
            if len(sympy_args) != 3:
                raise SimulationError(f"ifelse requires exactly 3 arguments, got {len(sympy_args)}")
            return sp.Piecewise((sympy_args[1], sympy_args[0]), (sympy_args[2], True))
        elif expr.op == 'and':
            if len(sympy_args) < 2:
                raise SimulationError(f"and requires at least 2 arguments, got {len(sympy_args)}")
            return sp.And(*sympy_args)
        elif expr.op == 'or':
            if len(sympy_args) < 2:
                raise SimulationError(f"or requires at least 2 arguments, got {len(sympy_args)}")
            return sp.Or(*sympy_args)
        elif expr.op == 'not':
            if len(sympy_args) != 1:
                raise SimulationError(f"not requires exactly 1 argument, got {len(sympy_args)}")
            return sp.Not(sympy_args[0])
        elif expr.op == '>':
            if len(sympy_args) != 2:
                raise SimulationError(f"Greater than requires exactly 2 arguments, got {len(sympy_args)}")
            return sp.StrictGreaterThan(sympy_args[0], sympy_args[1])
        elif expr.op == '<':
            if len(sympy_args) != 2:
                raise SimulationError(f"Less than requires exactly 2 arguments, got {len(sympy_args)}")
            return sp.StrictLessThan(sympy_args[0], sympy_args[1])
        elif expr.op == '>=':
            if len(sympy_args) != 2:
                raise SimulationError(f"Greater than or equal requires exactly 2 arguments, got {len(sympy_args)}")
            return sp.GreaterThan(sympy_args[0], sympy_args[1])
        elif expr.op == '<=':
            if len(sympy_args) != 2:
                raise SimulationError(f"Less than or equal requires exactly 2 arguments, got {len(sympy_args)}")
            return sp.LessThan(sympy_args[0], sympy_args[1])
        elif expr.op == '==':
            if len(sympy_args) != 2:
                raise SimulationError(f"Equality requires exactly 2 arguments, got {len(sympy_args)}")
            return sp.Eq(sympy_args[0], sympy_args[1])
        elif expr.op == '!=':
            if len(sympy_args) != 2:
                raise SimulationError(f"Inequality requires exactly 2 arguments, got {len(sympy_args)}")
            return sp.Ne(sympy_args[0], sympy_args[1])
        else:
            raise SimulationError(f"Unsupported operation: {expr.op}")
    else:
        raise SimulationError(f"Unsupported expression type: {type(expr)}")


def _flat_to_sympy_rhs(
    flat: FlattenedSystem,
    fn_callable_map: Optional[Dict[str, Callable]] = None,
) -> Tuple[
    List[str],
    List[str],
    Dict[str, sp.Symbol],
    List[sp.Expr],
    List[str],
    Dict[str, sp.Expr],
    List[str],
    Dict[str, List[str]],
]:
    """Build the SymPy ODE RHS expressions from a FlattenedSystem.

    Performs scalar algebraic-equation elimination as part of construction:
    equations of the form ``v = <body>`` (where ``v`` is a state variable
    that has no corresponding ``D(v, t) = …`` differential equation) are
    treated as observed/algebraic. Each algebraic body is symbolically
    substituted into every other algebraic body and into every differential
    RHS, so the integrator's RHS depends only on differential states and
    parameters. This is the scalar equivalent of MTK's ``structural_simplify``
    and is required for models like ``diameter_growth`` where ``A`` and
    ``I_D`` are algebraically defined alongside an ODE for ``D_p``.

    Parameter values are NOT inlined — parameter symbols remain free in
    ``rhs_exprs`` and ``algebraic_value_exprs`` so the symbolic form (and
    its lambdified counterpart) can be cached and reused across multiple
    simulate() calls with different parameter overrides. The caller passes
    parameter values to the lambdified function as runtime arguments
    (see :func:`_compile_flat_rhs`).

    Returns
    -------
    state_names:
        Dot-namespaced state variable names in the order they appear in the
        result vector.
    parameter_names:
        Dot-namespaced parameter names in the order their symbols appear in
        the lambdified function's parameter argument slots.
    symbol_map:
        Mapping from namespaced variable name to SymPy symbol (for use by
        event functions and parameter binding).
    rhs_exprs:
        Per-state SymPy expression for ``dy_i/dt``. Differential states get
        their (algebraic-substituted) derivative; algebraic-only states get
        ``0`` — the integrator does not advance them, and their values are
        recovered at output time by evaluating ``algebraic_value_exprs``.
    algebraic_state_names:
        Subset of ``state_names`` whose values are determined algebraically
        rather than by integration.
    algebraic_value_exprs:
        Per-algebraic-state SymPy expression for the variable's value in
        its *original unexpanded form* — may reference other algebraic-state
        symbols and free parameter symbols.  Eager substitution (alg-into-alg
        and alg-into-diff) is intentionally omitted; the caller is responsible
        for evaluating algebraic states in topological order at runtime.
    sorted_alg:
        Topological ordering of ``algebraic_state_names`` (leaves first).
    alg_deps:
        Per-algebraic-state list of direct algebraic-state dependencies.

    Observed variables (``flat.observed_variables``) are not handled here
    — see :func:`_observed_to_sympy_value_exprs` for the parallel pass that
    builds their value expressions from the same equation list.

    Raises
    ------
    SimulationError
        If the algebraic equations form a cycle (including self-reference).
    """
    state_names = list(flat.state_variables.keys())
    parameter_names = list(flat.parameters.keys())

    symbol_map: Dict[str, sp.Symbol] = {}
    for name in state_names + parameter_names:
        symbol_map[name] = sp.Symbol(name)

    if fn_callable_map is None:
        fn_callable_map = {}

    # Classify equations: differential (D(var, t) = …) vs algebraic (var = …).
    diff_rhs: Dict[str, sp.Expr] = {}
    alg_rhs: Dict[str, sp.Expr] = {}
    for eq in flat.equations:
        lhs = eq.lhs
        if isinstance(lhs, ExprNode) and lhs.op == "D" and lhs.args:
            inner = lhs.args[0]
            if isinstance(inner, str) and inner in flat.state_variables:
                diff_rhs[inner] = _expr_to_sympy(
                    eq.rhs, dict(symbol_map), fn_callable_map,
                )
                continue
        if isinstance(lhs, str) and lhs in flat.state_variables:
            rhs_sym = _expr_to_sympy(
                eq.rhs, dict(symbol_map), fn_callable_map,
            )
            if lhs in alg_rhs:
                # Same-system DAE: a previous equation already defines this
                # variable. Treat ``lhs = rhs_sym`` as an algebraic constraint
                # on a different unbound state variable that appears in the
                # RHS. This is the scalar analogue of MTK's alias-elimination
                # pass and is required for equilibrium models that author
                # K = f(T) alongside K = product([H+], [OH-]).
                free_states = []
                seen_states: Set[str] = set()
                for s in rhs_sym.free_symbols:
                    nm = str(s)
                    if (
                        nm in flat.state_variables
                        and nm not in alg_rhs
                        and nm not in diff_rhs
                        and nm != lhs
                        and nm not in seen_states
                    ):
                        free_states.append(s)
                        seen_states.add(nm)
                if len(free_states) >= 1:
                    target = free_states[0]
                    target_name = str(target)
                    try:
                        solutions = sp.solve(
                            sp.Eq(symbol_map[lhs], rhs_sym), target,
                        )
                    except Exception:
                        solutions = []
                    if solutions:
                        alg_rhs[target_name] = sp.sympify(solutions[0])
                        continue
                # No unbound state variable on the RHS — the equation is
                # either a redundant restatement or a genuine contradiction.
                # Skip it; downstream output will surface any inconsistency.
                continue
            alg_rhs[lhs] = rhs_sym
            continue
        # Other LHS shapes (e.g. array ops) are handled by the NumPy path.

    # If a state has both an ODE and an algebraic equation, the ODE wins — the
    # system is overdetermined and we must pick one consistent interpretation.
    for name in list(alg_rhs.keys()):
        if name in diff_rhs:
            del alg_rhs[name]

    algebraic_state_names = [n for n in state_names if n in alg_rhs]

    # Topologically sort algebraic vars by their direct dependence on each
    # other. Detect cycles (including self-reference) and raise with the
    # offending chain so authors can fix the model.
    alg_deps: Dict[str, List[str]] = {}
    alg_set = set(algebraic_state_names)
    for n in algebraic_state_names:
        free = getattr(alg_rhs[n], "free_symbols", set()) or set()
        alg_deps[n] = [str(s) for s in free if str(s) in alg_set]

    sorted_alg: List[str] = []
    visited: Set[str] = set()
    in_progress: Set[str] = set()

    def _topo_visit(name: str, path: List[str]) -> None:
        if name in visited:
            return
        if name in in_progress:
            cycle = path[path.index(name):] + [name]
            raise SimulationError(
                "Cyclic algebraic equations detected: "
                + " -> ".join(cycle)
            )
        in_progress.add(name)
        for dep in alg_deps[name]:
            _topo_visit(dep, path + [name])
        in_progress.discard(name)
        visited.add(name)
        sorted_alg.append(name)

    for n in algebraic_state_names:
        _topo_visit(n, [])

    # Eager alg-into-alg and alg-into-diff substitutions are intentionally
    # omitted.  For models with many Piecewise algebraic bodies (e.g.
    # heat_momentum_fluxes.esm, 78 algebraic states) those substitutions cause
    # expression-tree sizes to grow combinatorially, making compile time exceed
    # CI limits (>30 min without CSE).  Instead we keep alg_rhs in its
    # original unexpanded form and build per-state lambdified functions that
    # evaluate algebraic states sequentially at runtime (see _compile_flat_rhs).

    rhs_exprs: List[sp.Expr] = []
    for name in state_names:
        if name in diff_rhs:
            rhs_exprs.append(diff_rhs[name])
        else:
            # Algebraic states and unassigned states get a zero derivative.
            # Algebraic states are recovered at output time from alg_rhs.
            rhs_exprs.append(sp.Float(0))

    return (
        state_names,
        parameter_names,
        symbol_map,
        rhs_exprs,
        algebraic_state_names,
        alg_rhs,
        sorted_alg,
        alg_deps,
    )


def _observed_to_sympy_value_exprs(
    flat: FlattenedSystem,
    state_names: List[str],
    parameter_names: List[str],
    symbol_map: Dict[str, sp.Symbol],
    algebraic_state_names: List[str],
    algebraic_value_exprs: Dict[str, sp.Expr],
    fn_callable_map: Optional[Dict[str, Callable]] = None,
) -> Tuple[List[str], Dict[str, sp.Expr]]:
    """Build SymPy value expressions for ``flat.observed_variables``.

    Mirrors the algebraic-state pass in :func:`_flat_to_sympy_rhs`: equations
    whose LHS is an observed variable are collected and topologically sorted by
    their dependence on each other.  Observed-into-observed substitution is
    applied so each body depends on differential states, parameters, and
    algebraic-state symbols (but NOT on other observed symbols).  Eager
    alg-into-observed substitution is intentionally omitted to avoid the same
    expression-tree explosion described in :func:`_flat_to_sympy_rhs`; the
    caller resolves algebraic-state values at runtime before evaluating
    observed bodies.

    This is a separate function from :func:`_flat_to_sympy_rhs` to keep the
    latter's tuple-return shape stable for external callers (the EarthSciModels
    inline-test runner pre-populates ``flat._simulate_compile_cache`` by
    unpacking the original 6-tuple — adding observed there would break that
    contract).

    Returns
    -------
    observed_names:
        Observed variables that have an algebraic body, in input order.
    observed_value_exprs:
        Per-observed SymPy expression for the variable's value.  Each
        expression depends on differential-state symbols, free parameter
        symbols, and algebraic-state symbols (the alg→obs substitution is
        intentionally skipped; alg values are resolved at runtime).
    """
    observed_names_all = list(flat.observed_variables.keys())
    if not observed_names_all:
        return [], {}

    # Extend the symbol map with observed-variable symbols so substitution
    # between observed bodies works without name collisions.
    sym_map = dict(symbol_map)
    for name in observed_names_all:
        if name not in sym_map:
            sym_map[name] = sp.Symbol(name)

    if fn_callable_map is None:
        fn_callable_map = {}

    obs_rhs: Dict[str, sp.Expr] = {}
    for eq in flat.equations:
        lhs = eq.lhs
        if isinstance(lhs, str) and lhs in flat.observed_variables:
            obs_rhs[lhs] = _expr_to_sympy(
                eq.rhs, dict(sym_map), fn_callable_map,
            )

    observed_with_eq = [n for n in observed_names_all if n in obs_rhs]
    if not observed_with_eq:
        return [], {}

    # Topologically sort observed vars by their direct dependence on each
    # other; detect cycles (including self-reference).
    obs_deps: Dict[str, List[str]] = {}
    obs_set = set(observed_with_eq)
    for n in observed_with_eq:
        free = getattr(obs_rhs[n], "free_symbols", set()) or set()
        obs_deps[n] = [str(s) for s in free if str(s) in obs_set]

    sorted_obs: List[str] = []
    obs_visited: Set[str] = set()
    obs_in_progress: Set[str] = set()

    def _obs_topo_visit(name: str, path: List[str]) -> None:
        if name in obs_visited:
            return
        if name in obs_in_progress:
            cycle = path[path.index(name):] + [name]
            raise SimulationError(
                "Cyclic observed equations detected: "
                + " -> ".join(cycle)
            )
        obs_in_progress.add(name)
        for dep in obs_deps[name]:
            _obs_topo_visit(dep, path + [name])
        obs_in_progress.discard(name)
        obs_visited.add(name)
        sorted_obs.append(name)

    for n in observed_with_eq:
        _obs_topo_visit(n, [])

    for n in sorted_obs:
        # Fold earlier observed bodies into later ones so each obs_rhs[n]
        # references only diff states, params, and alg-state symbols.
        # The alg-into-obs substitution is intentionally omitted (see
        # _flat_to_sympy_rhs for rationale); alg values are resolved at
        # runtime via the sequential closure in _compile_flat_rhs.
        deps_subs = {sym_map[d]: obs_rhs[d] for d in obs_deps[n]}
        if deps_subs:
            obs_rhs[n] = obs_rhs[n].subs(deps_subs, simultaneous=False)

    return observed_with_eq, obs_rhs


@dataclass
class _CompiledRhs:
    """Cached, parametric RHS for a FlattenedSystem.

    Both ``rhs_vector_func`` and ``algebraic_vector_func`` are produced by
    :func:`sympy.lambdify` with ``cse=True``, sharing CSE across the full
    state vector instead of one lambdify-per-expression. Each function takes
    state symbols followed by parameter symbols (in the orders given by
    ``state_names`` / ``parameter_names``) so a single compile is reusable
    across simulate() calls with different parameter overrides.
    """

    state_names: List[str]
    parameter_names: List[str]
    symbol_map: Dict[str, sp.Symbol]
    algebraic_state_names: List[str]
    rhs_vector_func: Optional[Callable]
    algebraic_vector_func: Optional[Callable]
    observed_names: List[str] = field(default_factory=list)
    observed_vector_func: Optional[Callable] = None


def _compile_flat_rhs(flat: FlattenedSystem, cse: bool = True) -> _CompiledRhs:
    """Compile (and cache) the RHS of a FlattenedSystem to numpy callables.

    The compile step (`_flat_to_sympy_rhs` + vector ``sp.lambdify`` with
    ``cse=True``) dominates simulate()'s wall time on large mechanisms
    (geoschem_fullchem: ~395 s flatten-to-sympy + ~99 s lambdify). The
    result depends only on the symbolic structure of ``flat`` — parameter
    values are runtime arguments — so we cache it as an attribute on the
    FlattenedSystem object. Repeat simulate() calls on the same ``flat``
    (e.g. an 8-plot scenario sharing one parsed model) hit the cache and
    pay near-zero compile cost.

    Parameters
    ----------
    flat:
        The flattened system to compile.
    cse:
        Forwarded to :func:`sympy.lambdify` for the rhs / algebraic / observed
        functions. ``True`` (default) shares common subexpressions across the
        full vector, which is the production setting and dominates simulate()
        cost-wise. ``False`` disables CSE — useful for diagnostics that need
        to bypass SymPy's construction-time canonical rewrites (e.g. the
        ``cse=False`` non-finite-derivative regression captured by esm-5gk).
        Compiles for ``cse=True`` and ``cse=False`` are cached independently
        on ``flat`` so flipping the flag does not invalidate the other.

    Notes
    -----
    Systems with zero state variables are supported when at least one
    observed variable has an algebraic body — ``rhs_vector_func`` is then
    ``None`` and only ``observed_vector_func`` is populated. simulate()
    handles this case by skipping the integrator and sampling the observed
    bodies on a synthetic time grid (cloud_albedo.esm and friends, where
    every variable lands as an observed binding after MTK-style scalar
    elimination).
    """
    # cse=True keeps the legacy cache attribute name so external callers
    # (notably the EarthSciModels inline-test runner pre-population path
    # documented above _observed_to_sympy_value_exprs) continue to work.
    cache_attr = "_simulate_compile_cache" if cse else "_simulate_compile_cache_no_cse"
    cached = getattr(flat, cache_attr, None)
    if cached is not None:
        return cached

    # A single fn_callable_map is shared across the differential-RHS,
    # algebraic, and observed conversions so all three lambdify calls below
    # see the same set of synthetic ``_ess_fn_<idx>`` placeholders. After
    # observed substitution into rhs_exprs / algebraic_value_exprs, fn-call
    # placeholders from observed bodies appear in the differential RHS and
    # must resolve against the same module dict.
    fn_callable_map: Dict[str, Callable] = {}

    (
        state_names,
        parameter_names,
        symbol_map,
        rhs_exprs,
        algebraic_state_names,
        algebraic_value_exprs,  # unexpanded per-alg bodies
        sorted_alg,
        alg_deps,
    ) = _flat_to_sympy_rhs(flat, fn_callable_map)

    observed_names, observed_value_exprs = _observed_to_sympy_value_exprs(
        flat,
        state_names,
        parameter_names,
        symbol_map,
        algebraic_state_names,
        algebraic_value_exprs,
        fn_callable_map,
    )

    # Observed-symbol substitution: replace dotted-name observed symbols in
    # rhs_exprs (and alg bodies that may reference observed variables) with
    # their compact bodies.  With the sequential evaluation approach the
    # observed bodies still reference algebraic-state symbols — that is
    # intentional; alg values are resolved at runtime before each rhs/obs call.
    if observed_names:
        observed_subs = {
            sp.Symbol(name): observed_value_exprs[name]
            for name in observed_names
        }
        rhs_exprs = [
            expr.subs(observed_subs, simultaneous=False)
            for expr in rhs_exprs
        ]
        # Also substitute into alg bodies to handle the rare case where an
        # algebraic state references an observed variable by its dotted name.
        algebraic_value_exprs = {
            k: v.subs(observed_subs, simultaneous=False)
            for k, v in algebraic_value_exprs.items()
        }

    state_symbols = [symbol_map[name] for name in state_names]
    param_symbols = [symbol_map[name] for name in parameter_names]
    all_args = state_symbols + param_symbols

    # Merge any fn-op closures into the lambdify module list so each
    # ``_ess_fn_<idx>`` placeholder resolves to its captured Python callable
    # at runtime. Built fresh per compile so module dicts don't leak across
    # FlattenedSystems (each call site is unique to its source AST).
    if fn_callable_map:
        modules = [fn_callable_map, *_LAMBDIFY_MODULES]
    else:
        modules = _LAMBDIFY_MODULES

    # -------------------------------------------------------------------------
    # Algebraic states — sequential lambdified closures.
    #
    # Instead of eagerly substituting alg bodies into each other and into the
    # differential RHS (which causes combinatorial expression-tree growth for
    # models with Piecewise algebraic chains), we lambdify each alg body in its
    # original unexpanded form with all_args as the argument list.  At runtime
    # the sequential closure evaluates algebraic states in topological order,
    # updating args[alg_idx[n]] in-place so that later states pick up the
    # freshly-computed value of their algebraic dependencies.
    # -------------------------------------------------------------------------
    alg_idx: Dict[str, int] = {n: state_names.index(n) for n in algebraic_state_names}

    if algebraic_state_names:
        alg_funcs: Dict[str, Callable] = {}
        for n in sorted_alg:
            alg_funcs[n] = sp.lambdify(
                all_args,
                algebraic_value_exprs[n],
                modules=modules, cse=cse,
            )

        def algebraic_vector_func(
            *all_state_and_params: Any,
            _funcs: Dict[str, Callable] = alg_funcs,
            _sorted: List[str] = sorted_alg,
            _idx: Dict[str, int] = alg_idx,
            _names: List[str] = algebraic_state_names,
        ) -> List[Any]:
            args = list(all_state_and_params)
            for n in _sorted:
                args[_idx[n]] = _funcs[n](*args)
            return [args[_idx[n]] for n in _names]
    else:
        alg_funcs = {}
        algebraic_vector_func = None

    # -------------------------------------------------------------------------
    # Differential RHS — compact core function + sequential-alg wrapper.
    # -------------------------------------------------------------------------
    if state_names:
        rhs_core_func = sp.lambdify(
            all_args, rhs_exprs, modules=modules, cse=cse
        )
        if algebraic_state_names:
            def rhs_vector_func(
                *all_state_and_params: Any,
                _core: Callable = rhs_core_func,
                _funcs: Dict[str, Callable] = alg_funcs,
                _sorted: List[str] = sorted_alg,
                _idx: Dict[str, int] = alg_idx,
            ) -> Any:
                args = list(all_state_and_params)
                for n in _sorted:
                    args[_idx[n]] = _funcs[n](*args)
                return _core(*args)
        else:
            rhs_vector_func = rhs_core_func
    else:
        rhs_vector_func = None

    # -------------------------------------------------------------------------
    # Observed variables — compact core function + sequential-alg wrapper.
    # -------------------------------------------------------------------------
    if observed_names:
        obs_value_list = [observed_value_exprs[n] for n in observed_names]
        # Observed bodies may legitimately reference the independent
        # variable ``t`` (e.g. an analytical-solution observed in
        # python_scipy_integration.esm: ``c0 * exp(-k*t)``). State and
        # parameter symbols stay anonymous in ``rhs_vector_func`` /
        # ``algebraic_vector_func`` because the integrator never feeds
        # ``t`` into their bodies, but observed evaluation happens at the
        # output time grid where ``t`` is a real value the caller must be
        # able to bind. Plumbing ``t`` here keeps the runner generic
        # without per-equation dispatch.
        t_symbol = sp.Symbol("t")
        obs_core_func = sp.lambdify(
            [t_symbol, *all_args], obs_value_list,
            modules=modules, cse=cse,
        )
        if algebraic_state_names:
            def observed_vector_func(
                t: Any,
                *all_state_and_params: Any,
                _core: Callable = obs_core_func,
                _funcs: Dict[str, Callable] = alg_funcs,
                _sorted: List[str] = sorted_alg,
                _idx: Dict[str, int] = alg_idx,
            ) -> Any:
                args = list(all_state_and_params)
                for n in _sorted:
                    args[_idx[n]] = _funcs[n](*args)
                return _core(t, *args)
        else:
            observed_vector_func = obs_core_func
    else:
        observed_vector_func = None

    compiled = _CompiledRhs(
        state_names=state_names,
        parameter_names=parameter_names,
        symbol_map=symbol_map,
        algebraic_state_names=algebraic_state_names,
        rhs_vector_func=rhs_vector_func,
        algebraic_vector_func=algebraic_vector_func,
        observed_names=observed_names,
        observed_vector_func=observed_vector_func,
    )
    try:
        setattr(flat, cache_attr, compiled)
    except (AttributeError, TypeError):
        # FlattenedSystem instances are dataclasses without __slots__, so
        # attribute assignment normally succeeds. Fall back to no-cache if
        # a future variant disables it (e.g. frozen=True).
        pass
    return compiled
