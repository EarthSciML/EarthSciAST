"""SymPy bridge for the Python simulation tier.

Bridges ESM AST expressions to SymPy and compiles them to NumPy callables
via :func:`sympy.lambdify`. This module owns:

* :func:`_flat_to_sympy_rhs` / :func:`_observed_to_sympy_value_exprs` —
  build per-state / per-observed SymPy expressions from a
  :class:`FlattenedSystem` with scalar algebraic-equation elimination.
* :class:`_CompiledRhs` and :func:`_compile_flat_rhs` — the lambdify +
  CSE compile that dominates ``simulate()`` wall time on large mechanisms.

The ESM ``Expr`` → SymPy converter itself (:func:`_expr_to_sympy`), the
NaN-safe abs placeholder (:class:`_ess_numeric_abs`, esm-5gk), and
:class:`SimulationError` live in :mod:`.expression` — the single shared
converter for both the public ``to_sympy`` API and this simulation tier —
and are re-imported here so existing ``sympy_bridge`` imports keep working.

``simulation.py`` imports from this module and handles the SciPy
``solve_ivp`` wiring, event handling, and array-op interpreter path.
"""
from __future__ import annotations

import warnings
from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np
import sympy as sp

from .esm_types import ExprNode

# _ess_numeric_abs is re-exported for existing importers (tests, simulation
# diagnostics) even though this module only references it by name inside
# _LAMBDIFY_MODULES.
from .expression import SimulationError, _ess_numeric_abs, _expr_to_sympy  # noqa: F401
from .flatten import FlattenedSystem

# Module-mapping handed to every ``sp.lambdify`` call in this module so
# the ``_ess_numeric_abs`` calls emitted by ``_expr_to_sympy`` resolve to
# ``numpy.abs`` at runtime.
_LAMBDIFY_MODULES = [{"_ess_numeric_abs": np.abs}, "numpy"]


def _topo_sort(names: list[str], deps: dict[str, list[str]], label: str) -> list[str]:
    """Depth-first topological sort (leaves first) of ``names`` by ``deps``.

    Detects cycles (including self-reference) and raises with the offending
    chain so authors can fix the model; ``label`` names the equation class in
    the diagnostic ("algebraic" / "observed").
    """
    sorted_out: list[str] = []
    visited: set[str] = set()
    in_progress: set[str] = set()

    def _visit(name: str, path: list[str]) -> None:
        if name in visited:
            return
        if name in in_progress:
            cycle = path[path.index(name) :] + [name]
            raise SimulationError(f"Cyclic {label} equations detected: " + " -> ".join(cycle))
        in_progress.add(name)
        for dep in deps[name]:
            _visit(dep, path + [name])
        in_progress.discard(name)
        visited.add(name)
        sorted_out.append(name)

    for n in names:
        _visit(n, [])
    return sorted_out


def _flat_to_sympy_rhs(
    flat: FlattenedSystem,
    fn_callable_map: dict[str, Callable] | None = None,
) -> tuple[
    list[str],
    list[str],
    dict[str, sp.Symbol],
    list[sp.Expr],
    list[str],
    dict[str, sp.Expr],
    list[str],
    dict[str, list[str]],
]:
    """Build the SymPy ODE RHS expressions from a FlattenedSystem.

    Performs scalar algebraic-equation classification as part of construction:
    equations of the form ``v = <body>`` (where ``v`` is a state variable that
    has no corresponding ``D(v, t) = …`` differential equation) are treated as
    observed/algebraic. Eager substitution of each algebraic body into the
    others and into the differential RHS is intentionally NOT performed (see the
    Returns note and ``_compile_flat_rhs``): the bodies are kept in their
    original unexpanded form, topologically sorted by their inter-dependence,
    and evaluated sequentially at runtime. Substituting eagerly would grow the
    expression trees combinatorially for models with many ``Piecewise``
    algebraic bodies. This is the scalar analogue of MTK's
    ``structural_simplify`` and is required for models like ``diameter_growth``
    where ``A`` and ``I_D`` are algebraically defined alongside an ODE for
    ``D_p``.

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

    symbol_map: dict[str, sp.Symbol] = {}
    for name in state_names + parameter_names:
        symbol_map[name] = sp.Symbol(name)

    if fn_callable_map is None:
        fn_callable_map = {}

    # Classify equations: differential (D(var, t) = …) vs algebraic (var = …).
    diff_rhs: dict[str, sp.Expr] = {}
    alg_rhs: dict[str, sp.Expr] = {}
    for eq in flat.equations:
        lhs = eq.lhs
        if isinstance(lhs, ExprNode) and lhs.op == "D" and lhs.args:
            inner = lhs.args[0]
            if isinstance(inner, str) and inner in flat.state_variables:
                diff_rhs[inner] = _expr_to_sympy(
                    eq.rhs,
                    dict(symbol_map),
                    fn_callable_map,
                )
                continue
        if isinstance(lhs, str) and lhs in flat.state_variables:
            rhs_sym = _expr_to_sympy(
                eq.rhs,
                dict(symbol_map),
                fn_callable_map,
            )
            if lhs in alg_rhs:
                # Same-system DAE: a previous equation already defines this
                # variable. Treat ``lhs = rhs_sym`` as an algebraic constraint
                # on a different unbound state variable that appears in the
                # RHS. This is the scalar analogue of MTK's alias-elimination
                # pass and is required for equilibrium models that author
                # K = f(T) alongside K = product([H+], [OH-]).
                free_states = []
                seen_states: set[str] = set()
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
                            sp.Eq(symbol_map[lhs], rhs_sym),
                            target,
                        )
                    except Exception as exc:
                        # sp.solve's failure surface is wide (NotImplementedError,
                        # PolynomialError, GeneratorsNeeded, …), so keep the broad
                        # catch — but no longer swallow it silently: the equation
                        # is about to be dropped, which the author should know.
                        warnings.warn(
                            f"Could not solve algebraic constraint "
                            f"`{lhs} = {rhs_sym}` for `{target_name}` "
                            f"({type(exc).__name__}: {exc}); skipping it.",
                            RuntimeWarning,
                            stacklevel=2,
                        )
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
    alg_deps: dict[str, list[str]] = {}
    alg_set = set(algebraic_state_names)
    for n in algebraic_state_names:
        free = getattr(alg_rhs[n], "free_symbols", set()) or set()
        alg_deps[n] = [str(s) for s in free if str(s) in alg_set]

    sorted_alg = _topo_sort(algebraic_state_names, alg_deps, "algebraic")

    # Eager alg-into-alg and alg-into-diff substitutions are intentionally
    # omitted.  For models with many Piecewise algebraic bodies (e.g.
    # heat_momentum_fluxes.esm, 78 algebraic states) those substitutions cause
    # expression-tree sizes to grow combinatorially, making compile time exceed
    # CI limits (>30 min without CSE).  Instead we keep alg_rhs in its
    # original unexpanded form and build per-state lambdified functions that
    # evaluate algebraic states sequentially at runtime (see _compile_flat_rhs).

    rhs_exprs: list[sp.Expr] = []
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
    symbol_map: dict[str, sp.Symbol],
    fn_callable_map: dict[str, Callable] | None = None,
) -> tuple[list[str], dict[str, sp.Expr]]:
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
    unpacking :func:`_flat_to_sympy_rhs`'s return tuple — adding observed there
    would break that contract).

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

    obs_rhs: dict[str, sp.Expr] = {}
    for eq in flat.equations:
        lhs = eq.lhs
        if isinstance(lhs, str) and lhs in flat.observed_variables:
            obs_rhs[lhs] = _expr_to_sympy(
                eq.rhs,
                dict(sym_map),
                fn_callable_map,
            )

    observed_with_eq = [n for n in observed_names_all if n in obs_rhs]
    if not observed_with_eq:
        return [], {}

    # Topologically sort observed vars by their direct dependence on each
    # other; detect cycles (including self-reference).
    obs_deps: dict[str, list[str]] = {}
    obs_set = set(observed_with_eq)
    for n in observed_with_eq:
        free = getattr(obs_rhs[n], "free_symbols", set()) or set()
        obs_deps[n] = [str(s) for s in free if str(s) in obs_set]

    sorted_obs = _topo_sort(observed_with_eq, obs_deps, "observed")

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

    state_names: list[str]
    parameter_names: list[str]
    symbol_map: dict[str, sp.Symbol]
    algebraic_state_names: list[str]
    rhs_vector_func: Callable | None
    algebraic_vector_func: Callable | None
    observed_names: list[str] = field(default_factory=list)
    observed_vector_func: Callable | None = None


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
    fn_callable_map: dict[str, Callable] = {}

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
        symbol_map,
        fn_callable_map,
    )

    # Observed-symbol substitution: replace dotted-name observed symbols in
    # rhs_exprs (and alg bodies that may reference observed variables) with
    # their compact bodies.  With the sequential evaluation approach the
    # observed bodies still reference algebraic-state symbols — that is
    # intentional; alg values are resolved at runtime before each rhs/obs call.
    if observed_names:
        observed_subs = {sp.Symbol(name): observed_value_exprs[name] for name in observed_names}
        rhs_exprs = [expr.subs(observed_subs, simultaneous=False) for expr in rhs_exprs]
        # Also substitute into alg bodies to handle the rare case where an
        # algebraic state references an observed variable by its dotted name.
        algebraic_value_exprs = {
            k: v.subs(observed_subs, simultaneous=False) for k, v in algebraic_value_exprs.items()
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
    alg_idx: dict[str, int] = {n: state_names.index(n) for n in algebraic_state_names}

    if algebraic_state_names:
        alg_funcs: dict[str, Callable] = {}
        for n in sorted_alg:
            alg_funcs[n] = sp.lambdify(
                all_args,
                algebraic_value_exprs[n],
                modules=modules,
                cse=cse,
            )

        def algebraic_vector_func(
            *all_state_and_params: Any,
            _funcs: dict[str, Callable] = alg_funcs,
            _sorted: list[str] = sorted_alg,
            _idx: dict[str, int] = alg_idx,
            _names: list[str] = algebraic_state_names,
        ) -> list[Any]:
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
        rhs_core_func = sp.lambdify(all_args, rhs_exprs, modules=modules, cse=cse)
        if algebraic_state_names:

            def rhs_vector_func(
                *all_state_and_params: Any,
                _core: Callable = rhs_core_func,
                _funcs: dict[str, Callable] = alg_funcs,
                _sorted: list[str] = sorted_alg,
                _idx: dict[str, int] = alg_idx,
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
            [t_symbol, *all_args],
            obs_value_list,
            modules=modules,
            cse=cse,
        )
        if algebraic_state_names:

            def observed_vector_func(
                t: Any,
                *all_state_and_params: Any,
                _core: Callable = obs_core_func,
                _funcs: dict[str, Callable] = alg_funcs,
                _sorted: list[str] = sorted_alg,
                _idx: dict[str, int] = alg_idx,
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
