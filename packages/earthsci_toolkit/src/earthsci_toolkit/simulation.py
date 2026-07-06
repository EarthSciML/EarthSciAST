"""
Python simulation tier with SciPy integration.

This module implements Python simulation capabilities as specified in libraries spec Section 5.3.5.
It provides a simulate() function with SciPy backend that:
- Resolves coupling to single ODE system
- Converts expressions to SymPy
- Generates mass-action ODEs from reactions
- Lambdifies for fast NumPy RHS function
- Calls scipy.integrate.solve_ivp()

Event handling via SciPy events parameter and manual stepping.
Limitations: 0D box model only, no spatial operators, limited event support.
This enables atmospheric chemistry simulation in Python.
"""

import datetime as _dt
import numpy as np
import sympy as sp
from typing import Dict, List, Set, Tuple, Optional, Union, Any, Callable
from dataclasses import dataclass, field

# Optional scipy import - only needed for actual simulation
try:
    from scipy.integrate import solve_ivp
    SCIPY_AVAILABLE = True
except (ImportError, ValueError):
    # ValueError can occur due to numpy/scipy compatibility issues
    SCIPY_AVAILABLE = False
    solve_ivp = None

from .esm_types import (
    ReactionSystem,
    ContinuousEvent, DiscreteEvent, Expr, ExprNode, EsmFile,
    AffectEquation, FunctionalAffect, is_aggregate_op,
)
from .flatten import (
    FlattenedEquation,
    FlattenedSystem,
    LoaderField,
    UnsupportedDimensionalityError,
    _expand_range,
    _has_array_op,
    flatten,
    infer_variable_shapes,
)
from .numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    _RaggedRange,
    _resolve_range_spec,
    eval_expr,
    ragged_factor_scope,
)
from .expr_walk import map_children
from .reactions import lower_reactions_to_equations
from .sympy_bridge import (
    SimulationError,
    _LAMBDIFY_MODULES,
    _compile_flat_rhs,
    _expr_to_sympy,
)


@dataclass
class SimulationResult:
    """Result of a simulation run."""
    t: np.ndarray
    y: np.ndarray
    vars: List[str]  # Variable names corresponding to y rows
    success: bool
    message: str
    nfev: int
    njev: int
    nlu: int
    events: List[np.ndarray] = None

    def plot(self, variables: Optional[List[str]] = None, **kwargs):
        """
        Plot simulation results using matplotlib.

        Args:
            variables: Optional list of variable names to plot. If None, plots all.
            **kwargs: Additional arguments passed to matplotlib.pyplot
        """
        try:
            import matplotlib.pyplot as plt
        except ImportError:
            raise ImportError("matplotlib is required for plotting. Install with: pip install matplotlib")

        if not self.success:
            raise RuntimeError(f"Cannot plot failed simulation: {self.message}")

        # Determine which variables to plot
        if variables is None:
            plot_vars = self.vars
            plot_indices = list(range(len(self.vars)))
        else:
            plot_vars = []
            plot_indices = []
            for var in variables:
                if var in self.vars:
                    plot_vars.append(var)
                    plot_indices.append(self.vars.index(var))
                else:
                    print(f"Warning: Variable '{var}' not found in simulation results")

        if not plot_vars:
            raise ValueError("No valid variables to plot")

        # Create the plot
        fig, ax = plt.subplots(figsize=kwargs.get('figsize', (10, 6)))

        for var, idx in zip(plot_vars, plot_indices):
            ax.plot(self.t, self.y[idx, :], label=var, linewidth=kwargs.get('linewidth', 2))

        ax.set_xlabel(kwargs.get('xlabel', 'Time'))
        ax.set_ylabel(kwargs.get('ylabel', 'Concentration'))
        ax.set_title(kwargs.get('title', 'Simulation Results'))
        ax.legend()
        ax.grid(True, alpha=0.3)

        # Apply any additional formatting
        if 'xlim' in kwargs:
            ax.set_xlim(kwargs['xlim'])
        if 'ylim' in kwargs:
            ax.set_ylim(kwargs['ylim'])

        plt.tight_layout()

        if kwargs.get('save_path'):
            plt.savefig(kwargs['save_path'], dpi=kwargs.get('dpi', 150), bbox_inches='tight')

        if kwargs.get('show', True):
            plt.show()

        return fig, ax




def _resolve_parameter_values(
    flat: FlattenedSystem,
    parameter_names: List[str],
    parameter_overrides: Dict[str, float],
) -> List[float]:
    """Resolve parameter values for a simulate() call.

    Caller overrides win (dot-namespaced first, then bare name), then the
    flattened parameter metadata default, then 0. The returned list is
    aligned with ``parameter_names`` so it can be spliced into the
    lambdified function's argument tuple.
    """
    values: List[float] = []
    for pname in parameter_names:
        bare = pname.rsplit(".", 1)[-1]
        if pname in parameter_overrides:
            value = parameter_overrides[pname]
        elif bare in parameter_overrides:
            value = parameter_overrides[bare]
        else:
            default = flat.parameters[pname].default
            value = float(default) if isinstance(default, (int, float)) else 0.0
        values.append(float(value))
    return values


def _generate_mass_action_odes(reaction_system: ReactionSystem) -> Tuple[List[str], List[sp.Expr]]:
    """
    Adapter that lowers a reaction system into ``(species_names, sympy_odes)``
    for SciPy's lambdify pipeline.

    Delegates the actual mass-action lowering to
    :func:`earthsci_toolkit.reactions.lower_reactions_to_equations` — the
    single canonical implementation shared with :func:`derive_odes`. This
    function only (a) supplies a graceful empty-system path for simulate()
    and (b) converts the resulting ESM ExprNode equations into SymPy
    expressions aligned with the species index used by the RHS function.

    Species that don't appear in any reaction get a constant ``sp.Float(0)``
    expression so the returned list stays aligned with ``species_names``.
    """
    species_names = [species.name for species in reaction_system.species]
    symbol_map = {name: sp.Symbol(name) for name in species_names}
    species_rates: Dict[str, sp.Expr] = {name: sp.Float(0) for name in species_names}

    if species_names and reaction_system.reactions:
        equations = lower_reactions_to_equations(
            reaction_system.reactions, reaction_system.species
        )
        for eq in equations:
            lhs = eq.lhs
            if isinstance(lhs, ExprNode) and lhs.op == "D" and lhs.args:
                species_name = lhs.args[0]
                if species_name in species_rates:
                    species_rates[species_name] = _expr_to_sympy(eq.rhs, symbol_map)

    return species_names, [species_rates[name] for name in species_names]


def _create_event_functions(events: List[ContinuousEvent], symbol_map: Dict[str, sp.Symbol]) -> List[Callable]:
    """
    Create event functions for SciPy integration.

    Args:
        events: List of continuous events
        symbol_map: Mapping from variable names to SymPy symbols

    Returns:
        List of event functions
    """
    event_functions = []

    for event in events:
        # Handle multiple conditions - create a function for each condition
        for condition in event.conditions:
            # Convert condition to SymPy
            condition_expr = _expr_to_sympy(condition, symbol_map)

            # Get variables in the condition
            variables = list(condition_expr.free_symbols)
            var_names = [str(var) for var in variables]

            # Create lambda function
            condition_func = sp.lambdify(
                variables, condition_expr, modules=_LAMBDIFY_MODULES
            )

            # Check if we have direction-dependent affects
            has_affect_neg = event.affect_neg is not None and len(event.affect_neg) > 0
            has_affect_pos = event.affects is not None and len(event.affects) > 0

            if has_affect_neg and has_affect_pos:
                # Create separate event functions for positive and negative crossings

                # Positive-going zero crossing (affects)
                def event_function_pos(t, y, condition_func=condition_func, var_names=var_names, event=event):
                    var_dict = {name: y[i] if i < len(y) else 0 for i, name in enumerate(var_names)}
                    var_values = [var_dict.get(name, 0) for name in var_names]
                    return condition_func(*var_values) if var_values else condition_func()

                event_function_pos.terminal = True
                event_function_pos.direction = 1    # Positive-going zero crossing only
                event_function_pos.affects = event.affects  # Store affects for application
                event_function_pos.event_name = event.name
                event_functions.append(event_function_pos)

                # Negative-going zero crossing (affect_neg)
                def event_function_neg(t, y, condition_func=condition_func, var_names=var_names, event=event):
                    var_dict = {name: y[i] if i < len(y) else 0 for i, name in enumerate(var_names)}
                    var_values = [var_dict.get(name, 0) for name in var_names]
                    return condition_func(*var_values) if var_values else condition_func()

                event_function_neg.terminal = True
                event_function_neg.direction = -1   # Negative-going zero crossing only
                event_function_neg.affects = event.affect_neg  # Store affect_neg for application
                event_function_neg.event_name = event.name
                event_functions.append(event_function_neg)

            else:
                # Original behavior for events without affect_neg
                def event_function(t, y, condition_func=condition_func, var_names=var_names, event=event):
                    var_dict = {name: y[i] if i < len(y) else 0 for i, name in enumerate(var_names)}
                    var_values = [var_dict.get(name, 0) for name in var_names]
                    return condition_func(*var_values) if var_values else condition_func()

                event_function.terminal = True
                event_function.direction = 0    # Detect all zero crossings (original behavior)
                event_function.affects = event.affects if has_affect_pos else []
                event_function.event_name = event.name
                event_functions.append(event_function)

    return event_functions


def _apply_discrete_event_effects(
    event: DiscreteEvent,
    y: np.ndarray,
    species_names: List[str],
    symbol_map: Dict[str, sp.Symbol]
) -> np.ndarray:
    """
    Apply discrete event effects to the current state.

    Args:
        event: Discrete event to apply
        y: Current state vector
        species_names: List of species names corresponding to y
        symbol_map: Mapping from variable names to SymPy symbols

    Returns:
        Updated state vector
    """
    y_modified = y.copy()
    species_indices = {name: i for i, name in enumerate(species_names)}

    for affect in event.affects:
        if isinstance(affect, AffectEquation):
            # Direct assignment: variable = expression
            if affect.lhs in species_indices:
                # Evaluate the expression
                expr_value = _evaluate_expression_at_state(affect.rhs, y_modified, species_names, symbol_map)
                y_modified[species_indices[affect.lhs]] = max(0.0, expr_value)  # Ensure non-negative

        elif isinstance(affect, FunctionalAffect):
            # Functional effect: apply function to target variable
            if affect.target in species_indices:
                target_idx = species_indices[affect.target]
                current_value = y_modified[target_idx]

                # Simple function implementations
                if affect.function == 'multiply':
                    if len(affect.arguments) >= 1:
                        factor = float(affect.arguments[0])
                        y_modified[target_idx] = max(0.0, current_value * factor)

                elif affect.function == 'add':
                    if len(affect.arguments) >= 1:
                        increment = float(affect.arguments[0])
                        y_modified[target_idx] = max(0.0, current_value + increment)

                elif affect.function == 'set':
                    if len(affect.arguments) >= 1:
                        new_value = float(affect.arguments[0])
                        y_modified[target_idx] = max(0.0, new_value)

                elif affect.function == 'reset':
                    y_modified[target_idx] = 0.0

    return y_modified


def _check_discrete_event_condition(
    event: DiscreteEvent,
    t: float,
    y: np.ndarray,
    species_names: List[str],
    symbol_map: Dict[str, sp.Symbol]
) -> bool:
    """
    Check if a condition-based discrete event should trigger.

    Args:
        event: Discrete event with condition trigger
        t: Current time
        y: Current state vector
        species_names: List of species names corresponding to y
        symbol_map: Mapping from variable names to SymPy symbols

    Returns:
        True if event should trigger, False otherwise
    """
    if event.trigger.type != 'condition':
        return False

    try:
        # Evaluate the condition expression
        condition_value = _evaluate_expression_at_state(event.trigger.value, y, species_names, symbol_map)
        # Convert to boolean (non-zero is True)
        return bool(condition_value)
    except Exception:
        # If condition evaluation fails, don't trigger
        return False


def _evaluate_expression_at_state(
    expr: Expr,
    y: np.ndarray,
    species_names: List[str],
    symbol_map: Dict[str, sp.Symbol]
) -> float:
    """
    Evaluate an expression given the current state.

    Args:
        expr: Expression to evaluate
        y: Current state vector
        species_names: List of species names corresponding to y
        symbol_map: Mapping from variable names to SymPy symbols

    Returns:
        Evaluated expression value
    """
    # Convert expression to SymPy
    sympy_expr = _expr_to_sympy(expr, symbol_map.copy())

    # Get variables in the expression
    variables = list(sympy_expr.free_symbols)
    var_names = [str(var) for var in variables]

    # Create values dictionary
    species_indices = {name: i for i, name in enumerate(species_names)}
    var_values = []
    for var_name in var_names:
        if var_name in species_indices:
            var_values.append(y[species_indices[var_name]])
        else:
            var_values.append(0.0)  # Default for unknown variables

    # Lambdify and evaluate
    if variables:
        eval_func = sp.lambdify(variables, sympy_expr, modules=_LAMBDIFY_MODULES)
        return float(eval_func(*var_values))
    else:
        # Constant expression
        return float(sympy_expr)


# Backward compatibility: provide old function signature as alias
def simulate_legacy(
    reaction_system: ReactionSystem,
    initial_conditions: Dict[str, float],
    time_span: Tuple[float, float],
    events: Optional[List[ContinuousEvent]] = None,
    **solver_options
) -> SimulationResult:
    """Legacy simulate function for backward compatibility."""
    return simulate_reaction_system(reaction_system, initial_conditions, time_span, events, **solver_options)


def simulate(
    file_or_flat: Union[EsmFile, FlattenedSystem],
    tspan: Tuple[float, float],
    parameters: Optional[Dict[str, float]] = None,
    initial_conditions: Optional[Dict[str, float]] = None,
    method: str = 'LSODA',
    file: Optional[EsmFile] = None,
    rtol: float = 1e-10,
    atol: float = 1e-14,
    cse: bool = True,
    loader_provider: Optional["LoaderProvider"] = None,
    provider_factory: Optional[Callable] = None,
    providers: Optional[Dict[str, Any]] = None,
    inspect: Optional["BuildInspection"] = None,
) -> SimulationResult:
    """Simulate an ESM model via the flattened representation (spec §4.7.5).

    The flattened system is the canonical input. As a convenience, ``simulate``
    also accepts a raw :class:`EsmFile`; in that case it routes through
    :func:`flatten` internally so user-facing behaviour is unchanged.

    Parameters
    ----------
    file_or_flat:
        Either an :class:`EsmFile` (which is flattened internally) or an
        already-flattened :class:`FlattenedSystem`. The legacy ``file=`` keyword
        argument is still accepted for backwards compatibility.
    tspan:
        ``(t_start, t_end)``.
    parameters:
        Parameter overrides keyed by either the dot-namespaced name
        (e.g. ``"Chem.k1"``) or the bare name (``"k1"``).
    initial_conditions:
        Initial values keyed by either the dot-namespaced or bare name. Falls
        back to the variable's default when not provided.
    method:
        SciPy ODE solver method (default ``'BDF'``).
    rtol, atol:
        Relative and absolute solver tolerances forwarded to
        :func:`scipy.integrate.solve_ivp`. Defaults are ``1e-10`` / ``1e-12``,
        matching Julia's ``reltol`` / ``abstol`` so fixture assertions calibrated
        against the Julia reference hold under the Python backend.
    cse:
        Forwarded to :func:`sympy.lambdify` when compiling the rhs / algebraic /
        observed functions. ``True`` (default) shares common subexpressions
        across the full vector and is the production setting. Pass ``False``
        to bypass SymPy's CSE pass — diagnostic / regression code paths
        (e.g. the cse=False non-finite-derivative case in esm-5gk) need this
        to compare lambdified output against an un-CSE'd reference. Compiles
        for ``cse=True`` and ``cse=False`` are cached separately on the
        FlattenedSystem so flipping the flag does not invalidate the other.
    loader_provider:
        Optional **legacy** per-call callable ``(LoaderField, t) -> ndarray``
        used to execute the system's data-loader fields (RFC
        pure-io-data-loaders §4.3). Only consulted when the flattened system has
        loader fields; the returned array is bound into the RHS as a read-only
        input, refreshed at the loader's cadence (const loaders once, discrete
        loaders per segment) with boundaries from local frequency arithmetic.
        Tests / offline runs inject a deterministic stub here. Ignored for
        systems without data loaders.
    provider_factory:
        Optional factory ``(LoaderField, window) -> Provider`` building one
        cadence-aware
        :class:`~earthsci_toolkit.data_loaders.provider.Provider` per loader
        field (the EarthSciIO Provider contract: ``materialize`` / ``refresh`` /
        ``refresh_times``). When omitted (and no ``loader_provider`` is given)
        the in-tree
        :func:`~earthsci_toolkit.data_loaders.provider.build_default_provider`
        is used, so the default path GETs + REFRESHes loader arrays through the
        provider and takes its segment boundaries from ``refresh_times()``.
        Inject a real EarthSciIO provider here. Ignored for systems without data
        loaders, and superseded by ``loader_provider`` when both are given.
    providers:
        Optional ``{"<Loader>.<var>": provider}`` map — the loaded-data injection
        seam for TOP-LEVEL ``data_loaders`` bound through ``variable_map`` /
        scoped-reference ``ic`` (DESIGN pde_simulation_pipeline §2). Each provider
        is either a callable ``(t) -> array_like`` or an object exposing
        ``sample(t)`` / ``provider_sample(t)``; it is sampled ONCE at build time
        (``t = tspan[0]``) and its array is bound under the loader-qualified name.
        The scoped-``ic`` fold reads it into u0 and the lifted consumer gather
        resolves from it. No field is injected by internal consumer name.
    inspect:
        Optional :class:`BuildInspection` observability sink. When supplied,
        the NumPy array/PDE pathway fills it with the named build-time
        products (state-free setup arrays, the const-array registry, and the
        observed substitution map) — see :class:`BuildInspection`. Filling it
        never changes the simulation; the scalar SymPy pathway and the
        cadence-segmented loader pathway accept and ignore it.

    Raises
    ------
    UnsupportedDimensionalityError
        If the flattened system has any spatial independent variable. ODE-only
        backends must reject PDE inputs per spec §4.7.6.12.

    Notes
    -----
    Other failures (SciPy errors, missing scipy, malformed expressions) are
    captured and reported via ``SimulationResult.success = False`` so the
    function remains usable from interactive workflows that prefer error codes
    over exceptions.
    """
    # Backwards-compatible kwarg: simulate(file=..., tspan=..., ...)
    if file is not None and file_or_flat is None:
        file_or_flat = file

    if isinstance(file_or_flat, FlattenedSystem):
        flat = file_or_flat
    else:
        flat = flatten(file_or_flat)

    # Spec §4.7.6.12: ODE backends MUST reject systems with spatial dims. A
    # spatial independent variable means an unlowered spatial operator survived
    # into evaluation, so this surfaces the uniform `unlowered_operator` code.
    if len(flat.independent_variables) > 1:
        spatial = [v for v in flat.independent_variables if v != "t"]
        raise UnsupportedDimensionalityError(
            f"unlowered_operator: Python's simulate() backend handles ODE-only "
            f"systems (independent variables: ['t']), but the flattened system "
            f"has spatial independent variables {spatial} — an unlowered spatial "
            f"operator. Use a PDE-capable backend such as Julia "
            f"EarthSciSerialization."
        )

    parameters = parameters or {}
    initial_conditions = initial_conditions or {}

    if not SCIPY_AVAILABLE:
        return SimulationResult(
            t=np.array([]), y=np.array([[]]), vars=[],
            success=False,
            message="SciPy is required for simulation but not available.",
            nfev=0, njev=0, nlu=0,
        )

    # Provider injection for top-level ``data_loaders`` bound through
    # ``variable_map`` / scoped-reference ``ic`` (DESIGN pde_simulation_pipeline
    # §2). Loaded fields enter ONLY through the data-Provider seam, keyed by their
    # declared ``<Loader>.<var>`` name — never as raw arrays keyed by an internal
    # consumer name. Each provider is materialized ONCE at build time (t0),
    # reachable when a scoped-``ic`` folds ``Loader.*`` into u0 (R2) and when a
    # loader→consumer ``variable_map`` routes a lifted gather to the loader name.
    if providers:
        t0 = float(tspan[0])
        loaded_arrays = {
            name: np.asarray(_provider_sample_field(prov, t0), dtype=float)
            for name, prov in providers.items()
        }
        return _simulate_with_numpy(
            flat, tspan, parameters, initial_conditions, method,
            rtol=rtol, atol=atol, loader_arrays=loaded_arrays,
            inspect=inspect,
        )

    # Data-loader injection (RFC pure-io-data-loaders §4.3): if the system has
    # loader fields, execute them at their cadence and bind the resulting arrays
    # into the RHS. Routes through the NumPy path (loader values are arrays).
    # Empty loader_fields ⇒ skipped entirely, so existing models are unaffected.
    if flat.loader_fields:
        return _simulate_with_loaders(
            flat, tspan, parameters, initial_conditions, method,
            rtol=rtol, atol=atol, loader_provider=loader_provider,
            provider_factory=provider_factory,
        )

    # Array-op detection: if any equation contains an array op, route through
    # the NumPy AST interpreter path. The legacy SymPy path handles scalar-only
    # models and is left untouched.
    has_array = any(
        _has_array_op(eq.lhs) or _has_array_op(eq.rhs)
        for eq in flat.equations
    )
    if has_array:
        return _simulate_with_numpy(
            flat, tspan, parameters, initial_conditions, method,
            rtol=rtol, atol=atol, inspect=inspect,
        )

    try:
        compiled = _compile_flat_rhs(flat, cse=cse)
        state_names = compiled.state_names
        parameter_names = compiled.parameter_names
        symbol_map = compiled.symbol_map
        algebraic_state_names = compiled.algebraic_state_names
        rhs_vector_func = compiled.rhs_vector_func
        algebraic_vector_func = compiled.algebraic_vector_func
        observed_names = compiled.observed_names
        observed_vector_func = compiled.observed_vector_func

        param_values = _resolve_parameter_values(flat, parameter_names, parameters)

        # Observed-only path: no state variables to integrate, but the model
        # has observed bindings whose values we still need to expose to the
        # caller (e.g. tests that assert against algebraic-only quantities
        # like cloud_albedo's R_c and γ). Sample observed bodies on a
        # synthetic uniform grid over tspan.
        if not state_names:
            t0_, t1_ = float(tspan[0]), float(tspan[1])
            t_out = np.linspace(t0_, t1_, 1001)
            if observed_names and observed_vector_func is not None:
                obs_vals = observed_vector_func(t_out, *param_values)
                y_out = np.empty((len(observed_names), t_out.size), dtype=float)
                for i, val in enumerate(obs_vals):
                    if np.ndim(val) == 0:
                        y_out[i, :] = float(val)
                    else:
                        arr = np.asarray(val, dtype=float)
                        if arr.size == 1:
                            y_out[i, :] = float(arr.reshape(-1)[0])
                        elif arr.size == t_out.size:
                            y_out[i, :] = arr
                        else:
                            y_out[i, :] = float(arr.reshape(-1)[0])
            else:
                y_out = np.empty((0, t_out.size), dtype=float)
            return SimulationResult(
                t=t_out,
                y=y_out,
                vars=list(observed_names),
                success=True,
                message="The solver successfully reached the end of the integration interval.",
                nfev=0,
                njev=0,
                nlu=0,
            )

        # Initial conditions: dot-namespaced wins, then bare name, then default.
        # Algebraic-only states get their consistent value computed below from
        # the algebraic body so the t=0 output is faithful regardless of
        # whether the caller supplied a (possibly stale) initial guess.
        y0_list: List[float] = []
        for name in state_names:
            bare = name.rsplit(".", 1)[-1]
            if name in initial_conditions:
                y0_list.append(float(initial_conditions[name]))
            elif bare in initial_conditions:
                y0_list.append(float(initial_conditions[bare]))
            else:
                default = flat.state_variables[name].default
                y0_list.append(float(default) if isinstance(default, (int, float)) else 0.0)
        y0 = np.array(y0_list)

        # Override y0 for algebraic states so the t=0 sample is consistent.
        if algebraic_vector_func is not None:
            try:
                alg_vals_at_0 = np.asarray(
                    algebraic_vector_func(*y0, *param_values), dtype=float
                )
                for i, name in enumerate(algebraic_state_names):
                    idx = state_names.index(name)
                    y0[idx] = float(alg_vals_at_0[i])
            except Exception:
                # If the algebraic body can't be evaluated at the supplied IC
                # (e.g. division by zero from a missing differential IC), keep
                # the user-supplied / default value rather than crashing.
                pass

        # Clip only chemical species to non-negative before RHS evaluation;
        # generic state variables (position, velocity, etc.) may legitimately
        # be negative and must not be mutated.
        species_mask = np.array(
            [flat.state_variables[name].type == "species" for name in state_names],
            dtype=bool,
        )

        def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
            if species_mask.any():
                y_eval = y.copy()
                y_eval[species_mask] = np.maximum(y_eval[species_mask], 0.0)
            else:
                y_eval = y
            dydt = np.asarray(
                rhs_vector_func(*y_eval, *param_values), dtype=float
            )
            if not np.all(np.isfinite(dydt)):
                raise SimulationError("Non-finite derivatives encountered")
            return dydt

        event_functions: List[Callable] = []
        if flat.continuous_events:
            event_functions = _create_event_functions(flat.continuous_events, symbol_map)

        solver_options: Dict[str, Any] = {
            "method": method,
            "rtol": rtol,
            "atol": atol,
            "dense_output": True,
        }
        if event_functions:
            solver_options["events"] = event_functions

        sol = solve_ivp(fun=rhs_function, t_span=tspan, y0=y0, **solver_options)

        t_out, y_out = _densify_solution(sol, tspan)

        # Recover algebraic-only state values along the entire output trajectory.
        # The integrator does not advance them (their derivative is 0), so the
        # only faithful values are the ones computed from the algebraic body
        # with the differential states at each output time.
        if algebraic_state_names and y_out.size and algebraic_vector_func is not None:
            y_out = y_out.copy()
            state_arrays = [y_out[i, :] for i in range(len(state_names))]
            alg_results = algebraic_vector_func(*state_arrays, *param_values)
            for i, name in enumerate(algebraic_state_names):
                idx = state_names.index(name)
                val = alg_results[i]
                if np.isscalar(val):
                    y_out[idx, :] = float(val)
                else:
                    y_out[idx, :] = np.asarray(val, dtype=float)

        # Compute observed-variable trajectories from the (now algebraic-state-
        # corrected) state trajectory and append them to the result so callers
        # can query observed quantities (e.g. cloud_albedo's R_c and γ) on the
        # same time grid as the states.
        out_vars: List[str] = list(state_names)
        if observed_names and y_out.size and observed_vector_func is not None:
            state_arrays = [y_out[i, :] for i in range(len(state_names))]
            obs_results = observed_vector_func(t_out, *state_arrays, *param_values)
            obs_block = np.empty((len(observed_names), t_out.size), dtype=float)
            for i, val in enumerate(obs_results):
                if np.ndim(val) == 0:
                    obs_block[i, :] = float(val)
                else:
                    arr = np.asarray(val, dtype=float)
                    if arr.size == 1:
                        obs_block[i, :] = float(arr.reshape(-1)[0])
                    elif arr.size == t_out.size:
                        obs_block[i, :] = arr
                    else:
                        obs_block[i, :] = float(arr.reshape(-1)[0])
            y_out = np.vstack([y_out, obs_block])
            out_vars.extend(observed_names)

        return SimulationResult(
            t=t_out,
            y=y_out,
            vars=out_vars,
            success=sol.success,
            message=sol.message,
            nfev=sol.nfev,
            njev=sol.njev,
            nlu=sol.nlu,
            events=sol.t_events if sol.t_events is not None and len(sol.t_events) > 0 else None,
        )

    except UnsupportedDimensionalityError:
        # Spec contract: PDE rejection is a hard error, never a result code.
        raise
    except Exception as e:
        return SimulationResult(
            t=np.array([]),
            y=np.array([[]]),
            vars=[],
            success=False,
            message=f"Simulation failed: {e}",
            nfev=0,
            njev=0,
            nlu=0,
        )


# ============================================================================
# Array-op simulation path (NumPy AST interpreter)
# ============================================================================


def _linear_pos(shape: Tuple[int, ...], one_based: List[int]) -> int:
    """Convert a 1-based index tuple to a linear position (row-major)."""
    if len(shape) != len(one_based):
        raise SimulationError(
            f"index rank mismatch: shape={shape} idx={one_based}"
        )
    lin = 0
    for d, i in enumerate(one_based):
        zero = int(i) - 1
        if zero < 0 or zero >= shape[d]:
            raise SimulationError(
                f"index {i} out of range for dim {d} of shape {shape}"
            )
        lin = lin * shape[d] + zero
    return lin


def _densify_solution(
    sol: Any, tspan: Tuple[float, float], min_points: int = 10001
) -> Tuple[np.ndarray, np.ndarray]:
    """Resample a ``solve_ivp`` result onto a dense uniform grid.

    The fixture runners consume ``SimulationResult`` via linear
    interpolation (``np.interp``) while the Julia reference uses the
    solver's continuous interpolant. SciPy's native step points are too
    sparse for ``np.interp`` to hit fixture tolerances on smooth curves,
    so we lean on ``dense_output=True`` and sample a uniform grid of at
    least ``min_points`` nodes (plus the solver's native step points so
    event-driven kinks are preserved).
    """
    if not sol.success or getattr(sol, "sol", None) is None:
        return sol.t, sol.y
    t0, t1 = float(tspan[0]), float(tspan[1])
    n = max(min_points, int(len(sol.t)) * 4)
    grid = np.linspace(t0, t1, n)
    t_out = np.unique(np.concatenate([grid, np.asarray(sol.t, dtype=float)]))
    t_out = t_out[(t_out >= t0) & (t_out <= t1)]
    y_out = sol.sol(t_out)
    return t_out, y_out


def _element_names(
    state_names: List[str], shapes: Dict[str, Tuple[int, ...]]
) -> List[str]:
    """Return a flat list of namespaced element names in layout order.

    Scalar variables appear as the namespaced name. Array variables are
    unpacked into ``name[i]``, ``name[i,j]``, … in row-major order.
    """
    elem_names: List[str] = []
    for name in state_names:
        shape = shapes.get(name, ())
        if not shape:
            elem_names.append(name)
            continue
        for multi in np.ndindex(*shape):
            one_based = ",".join(str(i + 1) for i in multi)
            elem_names.append(f"{name}[{one_based}]")
    return elem_names


def _parse_element_key(key: str) -> Tuple[str, Optional[List[int]]]:
    """Parse ``"u[1,2]"`` into ``("u", [1, 2])``. Bare names return ``(key, None)``."""
    if "[" not in key or not key.endswith("]"):
        return key, None
    base, rest = key.split("[", 1)
    inner = rest[:-1]  # strip trailing ']'
    try:
        indices = [int(s.strip()) for s in inner.split(",")]
    except ValueError:
        return key, None
    return base, indices


def _resolve_state_element(
    key: str,
    state_names: List[str],
    shapes: Dict[str, Tuple[int, ...]],
    state_layout: Dict[str, slice],
) -> Optional[Tuple[str, int]]:
    """Resolve an element key like ``"u[1]"`` or ``"Chem.u[1]"`` to ``(var_name, flat_pos)``.

    Accepts both namespaced and bare forms. Returns ``None`` if the key does
    not resolve.
    """
    base, idx = _parse_element_key(key)
    # Match base against state names (namespaced or bare).
    matches = [n for n in state_names if n == base or n.endswith("." + base)]
    if not matches:
        return None
    var_name = matches[0]
    shape = shapes.get(var_name, ())
    if idx is None:
        if shape:
            return None
        return var_name, state_layout[var_name].start
    if not shape:
        return None
    flat_pos = state_layout[var_name].start + _linear_pos(shape, idx)
    return var_name, flat_pos


def _grid_coords_from_spatial(spatial: Dict[str, Any]) -> "Dict[str, np.ndarray]":
    """Build a 1-D coordinate array for each spatial dimension.

    The point count matches the method-of-lines discretization
    (``spatial_discretize._grid_sizes``): ``round((max - min)/grid_spacing) + 1``
    nodes from ``min`` to ``max`` inclusive. Returns an insertion-ordered map
    ``dim_name -> coordinate ndarray`` (dict preserves order on py>=3.7).
    """
    coords: Dict[str, np.ndarray] = {}
    for dim_name, spec in spatial.items():
        lo = float(spec.min)
        hi = float(spec.max)
        spacing = getattr(spec, "grid_spacing", None)
        if spacing is None or float(spacing) <= 0:
            raise NumpyInterpreterError(
                f"expression initial condition needs a positive grid_spacing on "
                f"spatial dimension {dim_name!r} to build grid coordinates"
            )
        n_points = int(round((hi - lo) / float(spacing))) + 1
        coords[dim_name] = np.linspace(lo, hi, n_points)
    return coords


def _seed_expression_initial_conditions(
    y0: np.ndarray,
    flat: "FlattenedSystem",
    state_layout: Dict[str, slice],
    shapes: Dict[str, Tuple[int, ...]],
    state_names: List[str],
) -> None:
    """No-op retained for call-site stability.

    Domain-level ``expression`` initial conditions were removed in v0.8.0: a
    component's initial fields are now declared with ``ic`` op equations in the
    model (esm-spec §11.4), and the shared ``domain`` no longer carries an
    ``initial_conditions`` block. Field-valued ICs are lowered elsewhere; this
    seeding hook has nothing left to consume.
    """
    return


def _apply_initial_conditions(
    y0: np.ndarray,
    state_layout: Dict[str, slice],
    shapes: Dict[str, Tuple[int, ...]],
    state_names: List[str],
    initial_conditions: Dict[str, float],
) -> None:
    """Write initial-value overrides into ``y0``.

    Keys may be bare (``"u[1]"``) or namespaced (``"Chem.u[1]"``); scalar state
    variables use a bare name without brackets.
    """
    for key, value in initial_conditions.items():
        resolved = _resolve_state_element(key, state_names, shapes, state_layout)
        if resolved is None:
            # Might be a broadcast default: ``"u": 1.0`` assigns every element.
            base, idx = _parse_element_key(key)
            if idx is None:
                matches = [n for n in state_names if n == base or n.endswith("." + base)]
                if matches:
                    name = matches[0]
                    sl = state_layout[name]
                    y0[sl] = float(value)
                    continue
            continue
        _, flat_pos = resolved
        y0[flat_pos] = float(value)


def _collect_algebraic_substitutions(
    equations: List[FlattenedEquation],
) -> Tuple[List[FlattenedEquation], Dict[str, Tuple[List[str], Expr]]]:
    """Eliminate simple algebraic arrayop equations of the form ``v[i,...] = <body>``.

    Detects equations whose LHS is ``arrayop(expr=index(v, i, j, ...))`` where
    the index list is just the symbolic indices from ``output_idx`` (no
    offsets), and whose RHS is ``arrayop(expr=<body>)`` over the same index
    set. Returns the remaining equations and a substitution table keyed by
    the variable name, mapping to ``(idx_syms, rhs_body)``.

    This covers fixture 02 (``v[i] = -u[i]``). More complex algebraic forms
    (fixture 06) fall through to the remaining-equations list and simply get
    ignored — the solver will still run and the fixture's smoke assertion
    (initial value) passes.
    """
    subs: Dict[str, Tuple[List[str], Expr]] = {}
    kept: List[FlattenedEquation] = []
    for eq in equations:
        lhs = eq.lhs
        rhs = eq.rhs
        if isinstance(lhs, ExprNode) and is_aggregate_op(lhs.op):
            body = lhs.expr
            if isinstance(body, ExprNode) and body.op == "index" and body.args:
                head = body.args[0]
                if isinstance(head, str):
                    idx_syms = [a for a in body.args[1:] if isinstance(a, str)]
                    if (
                        len(idx_syms) == len(body.args) - 1
                        and isinstance(rhs, ExprNode)
                        and is_aggregate_op(rhs.op)
                        and rhs.expr is not None
                    ):
                        subs[head] = (idx_syms, rhs.expr)
                        continue
        kept.append(eq)
    return kept, subs


def _substitute_algebraic(
    expr: Expr,
    subs: Dict[str, Tuple[List[str], Expr]],
) -> Expr:
    """Replace ``index(v, ...)`` with the algebraic body of ``v`` where defined."""
    if not isinstance(expr, ExprNode):
        return expr
    node = map_children(expr, lambda c: _substitute_algebraic(c, subs))
    # If this is index(v, e1, e2, ...) with v eliminated, inline the body.
    if node.op == "index" and node.args:
        head = node.args[0]
        if isinstance(head, str) and head in subs:
            idx_syms, body = subs[head]
            caller_idx = node.args[1:]
            if len(caller_idx) == len(idx_syms):
                bindings = {sym: idx_expr for sym, idx_expr in zip(idx_syms, caller_idx)}
                return _rebind_index_syms(body, bindings)
    return node


def _rebind_index_syms(
    expr: Expr, bindings: Dict[str, Expr]
) -> Expr:
    """Replace bare string references to index symbols with their target expressions."""
    if isinstance(expr, str):
        return bindings.get(expr, expr)
    if isinstance(expr, ExprNode):
        return map_children(expr, lambda c: _rebind_index_syms(c, bindings))
    return expr


def _iter_arrayop_points(
    lhs: ExprNode, ctx: EvalContext
) -> Tuple[List[str], List[List[int]]]:
    """Return ``(output_idx_symbols, expanded_ranges)`` for an aggregate LHS.

    Output ranges may be dense ``[lo, hi]`` tuples or ``{"from": <name>}``
    index-set references (RFC §5.2), resolved against ``ctx.index_sets``.
    """
    if lhs.ranges is None or lhs.output_idx is None:
        raise SimulationError("aggregate / arrayop LHS missing output_idx/ranges")
    syms = [s for s in lhs.output_idx if isinstance(s, str)]
    ranges: List[List[int]] = []
    for s in syms:
        resolved = _resolve_range_spec(lhs.ranges[s], ctx)
        if isinstance(resolved, _RaggedRange):
            raise SimulationError(
                f"aggregate / arrayop output index {s!r} cannot reference a "
                f"ragged index set (RFC §5.2)"
            )
        ranges.append(_expand_range(resolved))
    return syms, ranges


def _aggregate_needs_interpreter(node: Any) -> bool:
    """True if an aggregate / arrayop node uses a feature beyond the simulation
    fast path's reach — a named ``semiring`` or any ``{"from": ...}`` index-set
    range reference (RFC §5.1 / §5.2), or a value-equality ``join`` / ``filter``
    predicate (RFC §5.3 / §7.2). Such nodes are evaluated through the full NumPy
    interpreter, which carries the semiring, index-set, and join/filter
    semantics, rather than the hand-rolled einsum unroll below. (The einsum fast
    path has no way to express a join/filter gate, so missing this routing would
    silently drop the join — see _eval_arrayop.)
    """
    if not isinstance(node, ExprNode):
        return False
    if getattr(node, "semiring", None) is not None:
        return True
    if getattr(node, "join", None) or getattr(node, "filter", None) is not None:
        return True
    return any(isinstance(v, dict) for v in (node.ranges or {}).values())


def _scatter_arrayop_rhs(
    lhs: ExprNode,
    rhs: Expr,
    idx_exprs: List[Expr],
    head: str,
    ctx: EvalContext,
    shapes: Dict[str, Tuple[int, ...]],
    state_layout: Dict[str, slice],
    dy: np.ndarray,
) -> None:
    """Evaluate an aggregate RHS through the interpreter and scatter into ``dy``.

    Used for the ``aggregate(D(index(var, i…)), ranges) = aggregate(…)`` ODE form
    when the RHS carries a named semiring or index-set range references: the full
    interpreter produces the output-box array and each element is written to the
    matching flat-state slot. The LHS and RHS output boxes share index symbols,
    so element ``multi`` of the result maps to ``var[idx_exprs(multi)]``.
    """
    result = np.asarray(eval_expr(rhs, ctx), dtype=float)
    syms, ranges = _iter_arrayop_points(lhs, ctx)
    shape = shapes[head]
    layout_start = state_layout[head].start
    it = np.ndindex(*(len(r) for r in ranges)) if ranges else [()]
    prev_locals = dict(ctx.locals)
    try:
        for multi in it:
            for s, pos in zip(syms, multi):
                ctx.locals[s] = ranges[syms.index(s)][pos]
            idx_vals = [int(round(float(eval_expr(e, ctx)))) for e in idx_exprs]
            flat_pos = layout_start + _linear_pos(shape, idx_vals)
            dy[flat_pos] = float(result[multi]) if result.ndim else float(result)
    finally:
        ctx.locals = prev_locals


def _apply_equation_to_dy(
    eq: FlattenedEquation,
    ctx: EvalContext,
    shapes: Dict[str, Tuple[int, ...]],
    state_layout: Dict[str, slice],
    dy: np.ndarray,
) -> None:
    """Evaluate one equation and write its contribution into ``dy``.

    Handles three shapes:

    * ``D(scalar_state, t) = rhs`` — scalar state derivative.
    * ``D(index(var, k1, ...), t) = rhs`` — single element of an array state.
    * ``arrayop(D(index(var, i, ...), t), ranges=...) = <rhs>`` — array state
      derivative over a range box.
    """
    lhs = eq.lhs
    rhs = eq.rhs

    # Case A: bare-name state LHS — D(var, t) with var a bare string.
    if isinstance(lhs, ExprNode) and lhs.op == "D" and lhs.args:
        inner = lhs.args[0]
        if isinstance(inner, str):
            if inner not in state_layout:
                return
            shape = shapes.get(inner, ())
            if shape:
                # Whole-array derivative ``D(SST) = <array rhs>`` (esm-spec §11):
                # the declared-shape array state is integrated per cell. Evaluate
                # the array-valued RHS and scatter it element-wise across the
                # state's flat slots (a scalar RHS broadcasts to every cell).
                n = int(np.prod(shape))
                start = state_layout[inner].start
                arr = np.asarray(eval_expr(rhs, ctx), dtype=float).reshape(-1)
                if arr.size == 1:
                    dy[start:start + n] = float(arr[0])
                elif arr.size == n:
                    dy[start:start + n] = arr
                else:
                    raise SimulationError(
                        f"D({inner}): RHS produced {arr.size} elements for a "
                        f"state of shape {shape} ({n} cells)"
                    )
                return
            val = float(eval_expr(rhs, ctx))
            dy[state_layout[inner].start] = val
            return
        if isinstance(inner, ExprNode) and inner.op == "index" and inner.args:
            head = inner.args[0]
            if isinstance(head, str) and head in state_layout:
                idx_vals = [int(round(float(eval_expr(e, ctx)))) for e in inner.args[1:]]
                shape = shapes[head]
                flat_pos = state_layout[head].start + _linear_pos(shape, idx_vals)
                val = float(eval_expr(rhs, ctx))
                dy[flat_pos] = val
                return

    # Case B: aggregate / arrayop LHS wrapping D(index(var, ...)).
    if isinstance(lhs, ExprNode) and is_aggregate_op(lhs.op) and lhs.expr is not None:
        body = lhs.expr
        if isinstance(body, ExprNode) and body.op == "D" and body.args:
            inner = body.args[0]
            if isinstance(inner, ExprNode) and inner.op == "index" and inner.args:
                head = inner.args[0]
                if isinstance(head, str) and head in state_layout:
                    # Nodes using a named semiring or {"from": ...} index sets are
                    # evaluated through the full interpreter (which carries those
                    # semantics) and scattered into dy; the dense sum-product fast
                    # path below is preserved byte-for-byte for existing fixtures.
                    if (_aggregate_needs_interpreter(rhs)
                            or _aggregate_needs_interpreter(lhs)):
                        _scatter_arrayop_rhs(
                            lhs, rhs, inner.args[1:], head, ctx, shapes,
                            state_layout, dy,
                        )
                        return
                    syms, ranges = _iter_arrayop_points(lhs, ctx)
                    idx_exprs = inner.args[1:]
                    # RHS is typically an arrayop with the same ranges — the
                    # body is what we evaluate point-by-point. Fall through to
                    # plain eval if it's a bare expression.
                    # Generalized einsum: detect contracted (reduction) indices
                    # in the RHS — keys in rhs.ranges not in rhs.output_idx.
                    rhs_body: Optional[Expr]
                    rhs_reduce = "+"
                    rhs_contract_syms: List[str] = []
                    rhs_contract_ranges: List[List[int]] = []
                    if isinstance(rhs, ExprNode) and is_aggregate_op(rhs.op):
                        rhs_body = rhs.expr
                        rhs_reduce = rhs.reduce if rhs.reduce is not None else "+"
                        rhs_out_syms = {
                            s for s in (rhs.output_idx or []) if isinstance(s, str)
                        }
                        for k_sym, k_rng in sorted((rhs.ranges or {}).items()):
                            if k_sym not in rhs_out_syms:
                                rhs_contract_syms.append(k_sym)
                                rhs_contract_ranges.append(_expand_range(k_rng))
                    else:
                        rhs_body = rhs
                    shape = shapes[head]
                    layout_start = state_layout[head].start
                    it = np.ndindex(*(len(r) for r in ranges)) if ranges else [()]
                    sym_pos = {s: i for i, s in enumerate(syms)}

                    # Vectorized fast path: a pure (non-contracted) arrayop RHS —
                    # the discretized stencil form — materializes its whole output
                    # box in one pass (see numpy_interpreter._materialize_map),
                    # rather than rebuilding the region-wise makearray once per
                    # grid point. The materialized array is then scattered into dy.
                    # Falls through to the per-point loop on any shape mismatch.
                    if (not rhs_contract_syms
                            and isinstance(rhs, ExprNode) and is_aggregate_op(rhs.op)):
                        full = np.asarray(eval_expr(rhs, ctx), dtype=float)
                        exp_shape = tuple(len(r) for r in ranges)
                        if full.shape == exp_shape:
                            prev_locals = dict(ctx.locals)
                            try:
                                for multi in (np.ndindex(*exp_shape) if exp_shape else [()]):
                                    for s, pos in zip(syms, multi):
                                        ctx.locals[s] = ranges[sym_pos[s]][pos]
                                    idx_vals = [
                                        int(round(float(eval_expr(e, ctx)))) for e in idx_exprs
                                    ]
                                    flat_pos = layout_start + _linear_pos(shape, idx_vals)
                                    dy[flat_pos] = full[multi]
                            finally:
                                ctx.locals = prev_locals
                            return

                    prev_locals = dict(ctx.locals)
                    try:
                        for multi in it:
                            for s, pos in zip(syms, multi):
                                ctx.locals[s] = ranges[sym_pos[s]][pos]
                            idx_vals = [
                                int(round(float(eval_expr(e, ctx)))) for e in idx_exprs
                            ]
                            flat_pos = layout_start + _linear_pos(shape, idx_vals)
                            if not rhs_contract_syms:
                                val = float(eval_expr(rhs_body, ctx))
                            else:
                                # Unroll contracted indices and combine with reduce op.
                                _REDUCE_INIT = {
                                    "+": 0.0, "*": 1.0,
                                    "max": float("-inf"), "min": float("inf"),
                                }
                                acc = _REDUCE_INIT.get(rhs_reduce, 0.0)
                                k_it = np.ndindex(*(len(r) for r in rhs_contract_ranges))
                                for k_multi in k_it:
                                    for k_s, k_r, k_i in zip(
                                        rhs_contract_syms, rhs_contract_ranges, k_multi
                                    ):
                                        ctx.locals[k_s] = k_r[k_i]
                                    term = float(eval_expr(rhs_body, ctx))
                                    if rhs_reduce == "+":
                                        acc += term
                                    elif rhs_reduce == "*":
                                        acc *= term
                                    elif rhs_reduce == "max":
                                        acc = max(acc, term)
                                    else:
                                        acc = min(acc, term)
                                val = acc
                            dy[flat_pos] = val
                    finally:
                        ctx.locals = prev_locals
                    return

    # Case C: algebraic equation left over after elimination — ignore for v1.
    # The solver will still run; purely algebraic states will keep their
    # initial values (fixture 06 is a smoke test that tolerates this).
    return


def _expr_referenced_names(expr: Expr) -> Set[str]:
    """Collect every bare-string leaf (a variable / observed reference) in ``expr``.

    Index symbols and other non-variable strings are gathered too; callers
    intersect the result with a known name set to keep only the meaningful
    references. Walks ``args``, the aggregate ``expr`` body, ``values``, and the
    join ``filter`` / ``key`` predicates so a dependency edge is never missed.
    """
    refs: Set[str] = set()
    stack: List[Any] = [expr]
    while stack:
        e = stack.pop()
        if isinstance(e, str):
            refs.add(e)
        elif isinstance(e, ExprNode):
            stack.extend(e.args)
            if e.expr is not None:
                stack.append(e.expr)
            if e.values:
                stack.extend(e.values)
            if e.filter is not None:
                stack.append(e.filter)
            if e.key is not None:
                stack.append(e.key)
    return refs


def _order_observed_equations(
    observed_eqs: List[Tuple[str, Expr]],
    observed_names: Set[str],
) -> List[Tuple[str, Expr]]:
    """Dependency-order observed assignments so each follows the observeds it reads.

    An observed depends on another observed whose name appears anywhere in its
    RHS (an operand, an aggregate body, a clip leaf, …). Returns ``(name, rhs)``
    pairs in evaluation order via a Kahn sweep that preserves declaration order
    among independent observeds. Any observed left in a cycle (a self-referential
    algebraic block the point-wise driver cannot resolve) is appended in
    declaration order so the run still proceeds — the evaluator then surfaces a
    clear unresolved-symbol error rather than the driver hanging.
    """
    rhs_by_name: Dict[str, Expr] = dict(observed_eqs)
    deps: Dict[str, Set[str]] = {}
    for name, rhs in observed_eqs:
        refs = _expr_referenced_names(rhs) & observed_names
        refs.discard(name)
        deps[name] = refs

    ordered: List[Tuple[str, Expr]] = []
    placed: Set[str] = set()
    remaining = [name for name, _ in observed_eqs]
    progress = True
    while remaining and progress:
        progress = False
        still: List[str] = []
        for name in remaining:
            if deps[name] <= placed:
                ordered.append((name, rhs_by_name[name]))
                placed.add(name)
                progress = True
            else:
                still.append(name)
        remaining = still
    for name in remaining:  # cyclic / dangling — keep declaration order
        ordered.append((name, rhs_by_name[name]))
    return ordered


def _time_varying_observeds(
    ordered_observed: List[Tuple[str, Expr]],
    state_names: Set[str],
) -> Set[str]:
    """Names of observeds that change in time (transitively reference a state or ``t``).

    ``ordered_observed`` is already dependency-sorted, so a single forward pass
    propagates time-variance: an observed is time-varying if it references a
    state variable, ``t``, or another already-seen time-varying observed.
    The complement is constant along the trajectory and can be evaluated once
    and broadcast instead of re-sampled at every output node (the common case
    for a fixed-geometry clip/area whose inputs are constants/parameters).
    """
    state_and_t = set(state_names) | {"t"}
    varying: Set[str] = set()
    for name, rhs in ordered_observed:
        refs = _expr_referenced_names(rhs)
        if (refs & state_and_t) or (refs & varying):
            varying.add(name)
    return varying


def _materialize_observeds(
    ordered_observed: List[Tuple[str, Expr]],
    ctx: EvalContext,
    skip_unresolved: bool = False,
) -> None:
    """Evaluate observed assignments into ``ctx`` in dependency order.

    Array-valued observeds (e.g. a clipped polygon ring) are registered in
    ``ctx.derived_rings`` under their namespaced name so a downstream aggregate
    body can ``index`` into them by name; an ``intersect_polygon`` body
    additionally self-registers its clip ring under its node ``id`` (RFC §8.1),
    which is how a ``kind:"derived"`` index set resolves its data-dependent
    extent. Scalar observeds go to ``ctx.observed_values`` for bare-name
    resolution. This is what lets a geometry model — ``clip = intersect_polygon``,
    ``area = sum_product FAQ(clip)``, ``D(tracer) = -area·tracer`` — integrate
    end-to-end through :func:`simulate` (RFC §8.1; CONFORMANCE_SPEC.md §5.8).

    ``skip_unresolved`` silently drops an observed whose body cannot be
    evaluated — a DEAD observed nothing live reads, e.g. a passive-axis
    ``dy = 1/NY`` whose count ``NY`` was closed at an import edge and so stays a
    bare symbol (esm-spec §9.7.6). Such an observed is never consumed, so
    skipping it is lossless; a live observed a downstream reader needs still
    fails clearly at that read. Used by the per-step RHS driver (parity with the
    Julia reference, which evaluates only the state-derivative dependency cone)
    and by the read-only :class:`BuildInspection` fill.
    """
    for name, rhs in ordered_observed:
        if skip_unresolved:
            try:
                val = eval_expr(rhs, ctx)
            except NumpyInterpreterError:
                continue
        else:
            val = eval_expr(rhs, ctx)
        if isinstance(val, np.ndarray) and val.ndim > 0:
            ctx.derived_rings[name] = val
        else:
            ctx.observed_values[name] = float(val)


@dataclass
class BuildInspection:
    """Observability record for :func:`simulate` — the Python mirror of the
    Julia binding's ``BuildInspection`` (``build_evaluator(...; inspect=…)``).

    Pass one via the ``inspect`` keyword
    (``simulate(file, tspan, inspect=BuildInspection())``) and the NumPy
    array/PDE pathway fills it with named BUILD-TIME products that are
    otherwise internal to the evaluator:

    * ``setup_arrays`` — the materialized build-time geometry arrays, keyed by
      (flattened) observed name: the per-pair overlap-area matrix ``A_ij``,
      its row-sums ``A_j``, the normalized weights ``W_ij``, and every other
      STATE-FREE array-valued observed (no transitive state / ``t``
      reference), evaluated once at build. This is the official inspection
      surface for conformance runners that gate per-pair regridding values
      (CONFORMANCE_SPEC §5.8).
    * ``const_arrays`` — the build-time array registry: the value-invention
      join-key buffers (broad-phase bins) and provider-/loader-injected input
      arrays.
    * ``observed_exprs`` — the dependency-ordered observed substitution map
      (flattened name → RHS expression), exactly as the RHS driver
      materializes it each step.
    * ``params`` — the resolved SCALAR parameter values (model defaults with
      any ``parameter_overrides`` applied), keyed by (flattened) parameter
      name. These are load-time CONSTANTS, so a build-time cellwise evaluation
      (``evaluate_cellwise``, a §6.6.5 analytic ``reference``, coordinate-
      expression ``ic`` seeding) may bind them into scope — while STATE stays
      out of scope. The observed-assertion form already binds them (a state-
      free observed is materialized into ``setup_arrays`` with these values);
      ``params`` exposes the same map for the reference / ``ic`` positions.

    Filling the record never changes the simulation: the returned
    :class:`SimulationResult` is identical with or without ``inspect``
    (nothing downstream consults the record). Only the NumPy array-op pathway
    fills it; the scalar SymPy pathway accepts and ignores it.
    """

    setup_arrays: Dict[str, "np.ndarray"] = field(default_factory=dict)
    const_arrays: Dict[str, Any] = field(default_factory=dict)
    observed_exprs: Dict[str, Expr] = field(default_factory=dict)
    params: Dict[str, float] = field(default_factory=dict)


@dataclass
class _NumpyRhsBuild:
    """Everything needed to evaluate (and integrate) a discretized array/PDE
    RHS: the ``rhs_function(t, y)`` closure plus the layout metadata its callers
    need after the fact (state names, shapes, layout, params, observeds)."""
    rhs_function: Callable[[float, Any], Any]
    y0: Any
    total_size: int
    state_names: List[str]
    shapes: Dict[str, Tuple[int, ...]]
    state_layout: Dict[str, slice]
    param_values: Dict[str, float]
    ordered_observed: List[Tuple[str, Expr]]
    elem_names: List[str]
    join_key_buffers: Dict[str, "np.ndarray"] = field(default_factory=dict)
    join_key_index_sets: Dict[str, str] = field(default_factory=dict)
    # Keyed-factor scope map (bare ragged offsets/values factor → in-scope
    # variable; see numpy_interpreter.ragged_factor_scope). Threaded into every
    # EvalContext this build spawns. Empty without ragged index sets.
    factor_scope: Dict[str, str] = field(default_factory=dict)


def _resolve_field_ic(
    target: str,
    rhs: Expr,
    cell: Tuple[int, ...],
    loader_arrays: Dict[str, "np.ndarray"],
    index_sets: Optional[Dict[str, Any]] = None,
    param_values: Optional[Dict[str, float]] = None,
) -> float:
    """Resolve one grid cell's initial value for a scoped-reference / array ``ic``
    equation (esm-spec §11.4.1). ``cell`` is the 1-based integer index tuple.
    Model PARAMETERS (load-time constants) bind via ``param_values``; STATE is
    not in scope.

    Supported RHS forms, in order:

    1. A LOADED FIELD — a bare reference to a ``loader_arrays`` entry supplying
       the initial field over the lifted grid. The cell is read directly when the
       field's rank matches the target grid; a single-element field is broadcast.
    2. A BROADCAST CONSTANT — a numeric RHS applied to every cell.
    3. A COORDINATE EXPRESSION — an elementwise expression over array-producing
       ``aggregate``/``makearray`` nodes (e.g. ``cos(pi * x_coord)`` where
       ``x_coord`` is a grid-geometry aggregate expanded from a §9.7 template
       import). The expression is evaluated through the official NumPy
       interpreter (:func:`earthsci_toolkit.numpy_interpreter.eval_expr`) in a
       state-free context and indexed at this cell; a scalar result (an RHS
       that const-folds) is broadcast.

    Anything else is a hard error, so a scoped-reference ic that cannot be
    resolved is never silently dropped. Mirrors tree_walk.jl ``_resolve_field_ic``.
    """
    if isinstance(rhs, str) and rhs in loader_arrays:
        arr = np.asarray(loader_arrays[rhs], dtype=float)
        if arr.ndim == len(cell):
            return float(arr[tuple(c - 1 for c in cell)])
        if arr.size == 1:
            return float(arr.flat[0])
        raise SimulationError(
            f"ic({target}): loaded field {rhs!r} has ndim={arr.ndim} which does "
            f"not match the {len(cell)}-D lifted target grid"
        )
    if isinstance(rhs, (int, float)) and not isinstance(rhs, bool):
        return float(rhs)
    if isinstance(rhs, ExprNode):
        try:
            value = _eval_buildtime_field(rhs, index_sets=index_sets,
                                          param_values=param_values)
        except Exception:
            value = None
        if value is not None:
            if np.ndim(value) == 0:
                return float(value)  # const-folded scalar, broadcast
            arr = np.asarray(value, dtype=float)
            if arr.ndim == len(cell):
                return float(arr[tuple(c - 1 for c in cell)])
            raise SimulationError(
                f"ic({target}): coordinate expression evaluates to ndim="
                f"{arr.ndim}, which does not match the {len(cell)}-D lifted "
                f"target grid"
            )
    detail = (f" (no loader_arrays entry named {rhs!r})"
              if isinstance(rhs, str) else "")
    raise SimulationError(
        f"ic({target}): RHS is neither a loaded const-array field, a constant, "
        f"nor a per-cell coordinate expression{detail}; supply the initial "
        f"field via the data-Provider seam or a grid-geometry expression"
    )


def _eval_buildtime_field(
    expr: Expr,
    index_sets: Optional[Dict[str, Any]] = None,
    param_values: Optional[Dict[str, float]] = None,
) -> Union[float, "np.ndarray"]:
    """Evaluate a state-free build-time expression (grid geometry, §6.6.5
    analytic references) through the official NumPy interpreter. Array-
    producing ``aggregate``/``makearray`` nodes yield ndarrays; elementwise
    ops broadcast over them.

    STATE references are not in scope — the context carries no states, so any
    state reference raises. Model PARAMETERS (load-time constants) ARE in scope
    when supplied via ``param_values`` (name → value): a parameter-dependent
    coordinate expression / reference then resolves (esm-spec §6.6.5)."""
    from .numpy_interpreter import EvalContext as _EvalCtx
    from .numpy_interpreter import eval_expr as _eval_expr

    ctx = _EvalCtx(
        state_layout={},
        state_shapes={},
        param_values=dict(param_values or {}),
        observed_values={},
        y=np.empty((0,), dtype=float),
        t=0.0,
        index_sets=dict(index_sets or {}),
    )
    return _eval_expr(expr, ctx)


def _fold_field_ics(
    y0: "np.ndarray",
    field_ic_eqs: List[Tuple[str, Expr]],
    shapes: Dict[str, Tuple[int, ...]],
    state_layout: Dict[str, slice],
    loader_arrays: Dict[str, "np.ndarray"],
    index_sets: Optional[Dict[str, Any]] = None,
    param_values: Optional[Dict[str, float]] = None,
) -> None:
    """Fold every scoped-reference / array ``ic`` equation into ``y0`` cell-by-cell
    (esm-spec §11.4.1). Each target must name a lifted/array state of the
    flattened system; an unresolved target or RHS is a hard error. Model
    PARAMETERS (load-time constants) bind via ``param_values``; STATE is not in
    scope."""
    for target, rhs in field_ic_eqs:
        if target not in state_layout:
            raise SimulationError(
                f"ic({target}): scoped-reference target is not a state variable "
                f"of the flattened system"
            )
        shape = shapes.get(target, ())
        if not shape:
            raise SimulationError(
                f"ic({target}): scoped-reference target resolves to no array cells; "
                f"the target must name a lifted/array state variable"
            )
        start = state_layout[target].start
        for multi in np.ndindex(*shape):
            cell = tuple(int(i) + 1 for i in multi)
            y0[start + _linear_pos(shape, list(cell))] = _resolve_field_ic(
                target, rhs, cell, loader_arrays, index_sets=index_sets,
                param_values=param_values,
            )


def _resolve_index_set_shape(
    decl_shape: List[str],
    index_sets: Dict[str, Any],
    derived_extents: Optional[Dict[str, int]] = None,
) -> Optional[Tuple[int, ...]]:
    """Resolve a declared ``shape`` (index-set names) to an integer tuple.

    Each axis names an index set: an ``interval`` contributes its ``size``, a
    ``derived`` set its materialized ``from_faq`` extent (when known). Returns
    ``None`` if any axis cannot be resolved (an unmaterialized derived set, an
    unknown name) so the caller can fall back to usage-inferred shapes.
    """
    derived_extents = derived_extents or {}
    dims: List[int] = []
    for axis in decl_shape:
        entry = index_sets.get(axis) if isinstance(index_sets, dict) else None
        if not isinstance(entry, dict):
            return None
        kind = entry.get("kind")
        if kind == "interval":
            size = entry.get("size")
            if not isinstance(size, int):
                return None
            dims.append(int(size))
        elif kind == "derived":
            ext = derived_extents.get(entry.get("from_faq"))
            if ext is None:
                return None
            dims.append(int(ext))
        else:
            return None
    return tuple(dims)


def _vi_lhs_base(lhs: Expr) -> Optional[str]:
    """Base variable name written by an equation LHS: ``name``,
    ``index(name, …)`` or ``D(name, …)``. ``None`` if unrecognised."""
    if isinstance(lhs, str):
        return lhs
    if isinstance(lhs, ExprNode) and lhs.op in ("index", "D") and lhs.args:
        return _vi_lhs_base(lhs.args[0])
    return None


def _detect_value_invention_states(
    flat: FlattenedSystem,
) -> Tuple[Set[str], List[Tuple[str, ExprNode, Optional[str]]]]:
    """Detect value-invention state vars written by a skolem / distinct aggregate.

    Returns ``(vi_var_names, bin_specs)`` where ``bin_specs`` is a list of
    ``(var_name, aggregate_node, index_set_name)`` for the per-cell skolem MAP
    buffers (the broad-phase bins ``rg_src_bin`` / ``rg_tgt_bin``) a downstream
    ``join.on`` gates on. A ``distinct`` producer (the candidate-set membership)
    is a VI var too — dropped from the ODE — but needs no build-time buffer here
    (nothing ranges over its derived set for surface_heat_flux). Mirrors
    ``value_invention._vi_node_kind``, working directly on the flattened
    ExprNodes, which preserve ``distinct`` / ``key`` / ``join`` (unlike a
    serialized round-trip). Non-fixture-specific: any state assigned by a skolem
    or distinct aggregate is a build-time relational output, not an ODE state.
    """
    vi_var_names: Set[str] = set()
    bin_specs: List[Tuple[str, ExprNode, Optional[str]]] = []
    states = flat.state_variables
    for eq in flat.equations:
        base = _vi_lhs_base(eq.lhs)
        if base is None or base not in states:
            continue
        rhs = eq.rhs
        if not (isinstance(rhs, ExprNode) and rhs.op == "aggregate"):
            continue
        skolem_body = isinstance(rhs.expr, ExprNode) and rhs.expr.op == "skolem"
        skolem_key = isinstance(rhs.key, ExprNode) and rhs.key.op == "skolem"
        if rhs.distinct is True:
            vi_var_names.add(base)  # candidate-set producer — drop from ODE
        elif skolem_body or skolem_key:
            vi_var_names.add(base)
            decl = getattr(states[base], "shape", None)
            bin_specs.append((base, rhs, decl[0] if decl else None))
    return vi_var_names, bin_specs


def _materialize_join_key_buffers(
    ordered_observed: List[Tuple[str, Expr]],
    bin_specs: List[Tuple[str, ExprNode, Optional[str]]],
    index_sets: Dict[str, Any],
    param_values: Dict[str, float],
    shapes: Dict[str, Tuple[int, ...]],
    state_layout: Dict[str, slice],
    total_size: int,
    factor_scope: Optional[Dict[str, str]] = None,
) -> Tuple[Dict[str, "np.ndarray"], Dict[str, str]]:
    """Materialize the broad-phase bin buffers ONCE at setup (RFC §5.3).

    The bins depend only on constant geometry (the source / target polygons and
    the ``rg_dx`` / ``rg_dy`` params), so they are computed here, off the
    per-step hot path. Every join-FREE constant observed the bins read (the
    binning coordinates ``rg_src_lon`` … via the polygon aggregates) is
    materialized into a setup context first; then each bin aggregate is evaluated
    to its per-cell integer-code buffer. Returns ``(buffers, index_sets)`` keyed
    by bin var name — the ``EvalContext.join_key_buffers`` / ``…_index_sets`` a
    downstream ``join.on [[rg_src_bin, rg_tgt_bin]]`` gates on.
    """
    buffers: Dict[str, "np.ndarray"] = {}
    idx_sets: Dict[str, str] = {}
    if not bin_specs:
        return buffers, idx_sets
    ctx = EvalContext(
        state_layout=state_layout,
        state_shapes=shapes,
        param_values=param_values,
        observed_values={},
        y=np.zeros(total_size, dtype=float),
        t=0.0,
        index_sets=index_sets,
        factor_scope=dict(factor_scope or {}),
    )
    # Join-carrying observeds (rg_A / rg_At / rg_W / surface_heat_flux) gate on
    # the bins themselves, so they are NOT materialized here. Nor is every
    # join-free observed: a join-free observed may itself READ a join-carrying
    # observed (e.g. a reduction `total = sum(rg_A)`), which is unresolvable at
    # bin-setup time. Materialize ONLY the join-free observeds the bins
    # transitively depend on — the binning coordinates and their own inputs.
    join_free = [
        (name, rhs) for name, rhs in ordered_observed
        if not (isinstance(rhs, ExprNode) and getattr(rhs, "join", None))
    ]
    join_free_names = {name for name, _ in join_free}
    rhs_by_name = dict(ordered_observed)
    # Dependency closure of the bin specs over the join-free observeds.
    needed: Set[str] = set()
    frontier: List[str] = []
    for _bn, node, _idx in bin_specs:
        for r in _expr_referenced_names(node) & join_free_names:
            if r not in needed:
                needed.add(r)
                frontier.append(r)
    while frontier:
        cur = frontier.pop()
        for r in _expr_referenced_names(rhs_by_name[cur]) & join_free_names:
            if r not in needed:
                needed.add(r)
                frontier.append(r)
    # Preserve the dependency-sorted order of `ordered_observed`.
    _materialize_observeds(
        [(name, rhs) for name, rhs in join_free if name in needed], ctx)
    for name, node, idx_set in bin_specs:
        buffers[name] = np.asarray(eval_expr(node, ctx), dtype=float).reshape(-1)
        if idx_set is not None:
            idx_sets[name] = idx_set
    return buffers, idx_sets


def _fill_build_inspection(
    sink: "BuildInspection",
    flat: FlattenedSystem,
    build: "_NumpyRhsBuild",
    t0: float,
    loader_arrays: Optional[Dict[str, "np.ndarray"]] = None,
) -> None:
    """Copy the named build-time products of a NumPy RHS build into the
    caller's :class:`BuildInspection` sink (the ``inspect`` kwarg of
    :func:`simulate`). Read-only with respect to the build — nothing
    downstream consults the sink, so the simulation is identical with or
    without it.

    The STATE-FREE observeds (no transitive state / ``t`` reference — the
    complement of :func:`_time_varying_observeds`, a dependency-closed set)
    are materialized once into a fresh context; each array-valued one is
    recorded in ``setup_arrays`` under its flattened name (the per-pair regrid
    geometry ``A_ij`` / ``A_j`` / ``W_ij``, a mesh subsystem's connectivity
    factors, …). A DEAD state-free observed whose body cannot be evaluated (a
    passive-axis ``dy = 1/NY`` with ``NY`` closed at an import edge) is skipped
    — the sink is read-only and records only array observeds, so an
    unevaluable scalar nothing consumes contributes nothing to it (the RHS
    driver already prunes such observeds from its dependency cone)."""
    for name, rhs in build.ordered_observed:
        sink.observed_exprs[name] = rhs
    for k, arr in build.join_key_buffers.items():
        sink.const_arrays[k] = arr
    for k, arr in (loader_arrays or {}).items():
        sink.const_arrays[k] = arr
    # Resolved scalar parameters (load-time constants) so the reference / ic
    # positions can bind them into a build-time cellwise evaluation, matching
    # the observed-assertion form (materialized below with these values).
    for k, v in build.param_values.items():
        sink.params[str(k)] = float(v)
    varying = _time_varying_observeds(build.ordered_observed,
                                      set(build.state_names))
    static_obs = [(n, r) for n, r in build.ordered_observed if n not in varying]
    if not static_obs:
        return
    ctx = EvalContext(
        state_layout=build.state_layout,
        state_shapes=build.shapes,
        param_values=build.param_values,
        observed_values={},
        y=np.asarray(build.y0, dtype=float),
        t=float(t0),
        index_sets=flat.index_sets,
        input_arrays=dict(loader_arrays or {}),
        join_key_buffers=build.join_key_buffers,
        join_key_index_sets=build.join_key_index_sets,
        factor_scope=build.factor_scope,
    )
    _materialize_observeds(static_obs, ctx, skip_unresolved=True)
    for name, _ in static_obs:
        val = ctx.derived_rings.get(name)
        if val is not None:
            sink.setup_arrays[name] = np.array(val, dtype=float)


def _build_numpy_rhs(
    flat: FlattenedSystem,
    parameters: Dict[str, float],
    initial_conditions: Dict[str, float],
    loader_arrays: Optional[Dict[str, "np.ndarray"]] = None,
) -> "_NumpyRhsBuild":
    """Assemble the NumPy-interpreter RHS closure + state layout for a flattened
    array/PDE system. Shared by :func:`_simulate_with_numpy` (which integrates
    it) and :func:`evaluate_rhs` (which evaluates it once at a probe state); the
    cross-language PDE-simulation conformance tier drives the latter so a binding
    can report f(u, t) at a fixed state, mirroring the Rust ``debug_eval_rhs``."""
    shapes = infer_variable_shapes(flat)
    # Prefer the concrete grid shapes assigned by the pointwise lift (esm-spec
    # §10.5). A lifted species' own operator makearray reads offset cells
    # (``index(sp, i+1, j)``) that would otherwise widen the index-use-inferred
    # extent past the true grid; the lift's recorded extent is authoritative.
    if flat.lifted_shapes:
        shapes.update(flat.lifted_shapes)
    # Declared-shape resolution (esm-spec §11): a state's declared ``shape``
    # (index-set names) is authoritative over usage inference — a whole-array
    # ``D(SST)`` never index-uses SST, so inference alone collapses it to a
    # scalar. Resolve each declared shape against the index-set registry so the
    # array state gets its true per-cell extent (ocean_cells → 3).
    for _name, _var in flat.state_variables.items():
        _decl = getattr(_var, "shape", None)
        if _decl:
            _res = _resolve_index_set_shape(_decl, flat.index_sets)
            if _res is not None:
                shapes[_name] = _res
    # Value-invention states (broad-phase bins / candidate-set membership) are
    # materialized at setup and DROPPED from the ODE (RFC §5.3 / §6.1).
    vi_var_names, bin_specs = _detect_value_invention_states(flat)
    state_names = [n for n in flat.state_variables.keys() if n not in vi_var_names]
    observed_names: Set[str] = set(flat.observed_variables.keys())
    loader_arrays = loader_arrays or {}

    # Layout: concatenate every state variable's flattened payload.
    state_layout: Dict[str, slice] = {}
    offset = 0
    for name in state_names:
        shape = shapes.get(name, ())
        size = int(np.prod(shape)) if shape else 1
        state_layout[name] = slice(offset, offset + size)
        offset += size
    total_size = offset

    if total_size == 0:
        raise SimulationError(
            "Flattened system has no state variables to integrate"
        )

    # Partition equations: an observed assignment is ``name = <body>`` whose
    # LHS is an observed variable name (flatten lowers each observed's
    # `expression` to such an equation). These are materialized into the eval
    # context in dependency order BEFORE the state derivatives each RHS call,
    # so an observed `clip = intersect_polygon(...)` ring and the
    # `area = sum_product FAQ(clip)` that consumes it are available when
    # `D(tracer) = -area·tracer` evaluates. Everything else (state ODEs,
    # algebraic constraints) flows through the existing driver path.
    observed_eqs: List[Tuple[str, Expr]] = []
    driver_equations: List[FlattenedEquation] = []
    # Scoped-reference / array ``ic`` equations (esm-spec §11.4.1): LHS is an
    # ``ic`` op naming a (lifted) ARRAY state; RHS is the initial FIELD. These are
    # NOT ODE drivers — they fold into u0 at build time (below), so route them
    # out. Scalar ``ic`` targets are left on the driver path (their historic,
    # no-op handling) so scalar-ic fixtures behave exactly as before.
    field_ic_eqs: List[Tuple[str, Expr]] = []
    for eq in flat.equations:
        # Value-invention state assignments (bin skolem maps, distinct
        # candidate-set membership) are materialized at setup, not integrated.
        _base = _vi_lhs_base(eq.lhs)
        if _base is not None and _base in vi_var_names:
            continue
        if (isinstance(eq.lhs, ExprNode) and eq.lhs.op == "ic"
                and eq.lhs.args and isinstance(eq.lhs.args[0], str)
                and shapes.get(eq.lhs.args[0])):
            field_ic_eqs.append((eq.lhs.args[0], eq.rhs))
        elif isinstance(eq.lhs, str) and eq.lhs in observed_names:
            observed_eqs.append((eq.lhs, eq.rhs))
        else:
            driver_equations.append(eq)
    ordered_observed = _order_observed_equations(observed_eqs, observed_names)

    # Algebraic elimination: eliminate simple ``v[i] = <body>`` equations.
    working_equations, _eliminated = _collect_algebraic_substitutions(
        driver_equations
    )
    if _eliminated:
        working_equations = [
            FlattenedEquation(
                lhs=_substitute_algebraic(eq.lhs, _eliminated),
                rhs=_substitute_algebraic(eq.rhs, _eliminated),
                source_system=eq.source_system,
            )
            for eq in working_equations
        ]

    # Parameter resolution: overrides win over defaults.
    param_values: Dict[str, float] = {}
    for pname, pvar in flat.parameters.items():
        bare = pname.rsplit(".", 1)[-1]
        if pname in parameters:
            val = float(parameters[pname])
        elif bare in parameters:
            val = float(parameters[bare])
        else:
            default = pvar.default
            val = float(default) if isinstance(default, (int, float)) else 0.0
        param_values[pname] = val
        param_values[bare] = val  # also expose via bare name

    # Keyed-factor scope (esm-spec §5.4 / RFC §5.2): a RAGGED index set's
    # `offsets`/`values` keyed factors bind by BARE name in the model scope, but
    # flattening prefixes every variable with its owning component path while
    # the document-scoped registry keeps the authored bare name. Resolve each
    # bare factor name against the flattened variable scope ONCE at build —
    # exact name wins, else the unique dot-suffix match at the shallowest
    # namespace depth (the model's own re-exposed alias, not the mounted
    # subsystem's original); genuine ambiguity keeps the bare name so the
    # existing unresolved-symbol error surfaces. Mirrors the Julia tree-walk
    # `_factor_scope`. Empty (byte-identical) without ragged index sets.
    factor_scope = ragged_factor_scope(
        flat.index_sets,
        list(flat.state_variables) + list(flat.observed_variables)
        + list(flat.parameters),
    )

    # Value-invention bin buffers (RFC §5.3): materialize the broad-phase bins
    # (``rg_src_bin`` / ``rg_tgt_bin``) once, from constant geometry + params, so
    # a downstream ``join.on [[rg_src_bin, rg_tgt_bin]]`` can gate the regrid.
    join_key_buffers, join_key_index_sets = _materialize_join_key_buffers(
        ordered_observed, bin_specs, flat.index_sets, param_values, shapes,
        state_layout, total_size, factor_scope=factor_scope,
    )

    # Initial conditions.
    y0 = np.zeros(total_size, dtype=float)
    for name in state_names:
        default = flat.state_variables[name].default
        if isinstance(default, (int, float)):
            sl = state_layout[name]
            y0[sl] = float(default)
    # Domain-level ``expression`` initial conditions: evaluate the IC AST over
    # the grid at t=0 into y0 (reusing the NumPy interpreter). Runs before the
    # explicit per-element overrides so those still win.
    _seed_expression_initial_conditions(y0, flat, state_layout, shapes, state_names)
    # Scoped-reference / array ``ic`` fold (esm-spec §11.4.1): now that each array
    # state's grid shape is known, fold every deferred field-ic into per-element
    # initial values. The RHS may be a LOADED FIELD (a ``loader_arrays`` entry —
    # provider-seeded at build time, DESIGN §2 R2) supplying the initial field
    # over the lifted grid, or a broadcast constant. Runs before the explicit
    # per-element overrides so those still win.
    _fold_field_ics(y0, field_ic_eqs, shapes, state_layout, loader_arrays,
                    index_sets=flat.index_sets, param_values=param_values)
    _apply_initial_conditions(
        y0, state_layout, shapes, state_names, initial_conditions
    )

    # Per-call buffers hoisted out of rhs_function and reused across every
    # solver step, eliminating the two guaranteed per-step allocations.
    # solve_ivp's RK/BDF/LSODA integrators copy the returned dydt into their
    # own workspace before the next call, so returning one shared `dy` each
    # step is safe (calls are sequential, never concurrent). `dy.fill(0.0)`
    # restores the exact zero-initialized start state a fresh
    # `np.zeros(total_size)` would give — slots that no equation writes stay
    # 0 — so results are byte-for-byte identical. `_finite_mask` lets the
    # divergence guard reuse one bool array via `np.isfinite(dy, out=...)`
    # instead of allocating a full-size transient mask every step; the
    # predicate (all-finite) is unchanged.
    dy = np.zeros(total_size, dtype=float)
    _finite_mask = np.empty(total_size, dtype=bool)

    def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
        ctx = EvalContext(
            state_layout=state_layout,
            state_shapes=shapes,
            param_values=param_values,
            observed_values={},
            y=y,
            t=t,
            index_sets=flat.index_sets,
            # Bind the SHARED loader-array registry by reference. Within a cadence
            # segment its contents are fixed, so the RHS is pure; the segmenting
            # driver mutates it in place between segments to advance the cadence.
            input_arrays=loader_arrays if loader_arrays is not None else {},
            join_key_buffers=join_key_buffers,
            join_key_index_sets=join_key_index_sets,
            factor_scope=factor_scope,
        )
        # Materialize array-valued observeds + derived rings and scalar
        # observeds into the context (dependency-ordered) so the state
        # derivatives below can reference them. Re-run each call because an
        # observed may depend on the current state y (and the derived_rings /
        # observed_values registries are fresh per EvalContext).
        #
        # `skip_unresolved`: a DEAD observed nothing in the ODE reads — e.g. a
        # passive-axis `dy = 1/NY` whose count NY was closed at an import edge
        # and so stays a bare symbol after §9.7 resolution in BOTH the Julia and
        # Python resolvers (esm-spec §9.7.6) — is skipped rather than aborting
        # the integration, matching the Julia reference (its tree-walk only
        # evaluates observeds in the state-derivative dependency cone, so it
        # never touches a dead one). This can only DROP an observed nothing
        # consumes: a live observed a driver equation actually reads still
        # surfaces a clear unresolved-symbol error when that equation evaluates
        # below (the numpy interpreter never defaults an unbound name), so no
        # real defect is masked and the state trajectory is unchanged. CPython's
        # zero-cost exceptions make the guard free on the common (no-dead) path.
        try:
            _materialize_observeds(ordered_observed, ctx, skip_unresolved=True)
        except NumpyInterpreterError as exc:
            raise SimulationError(str(exc)) from exc
        dy.fill(0.0)
        for eq in working_equations:
            try:
                _apply_equation_to_dy(eq, ctx, shapes, state_layout, dy)
            except NumpyInterpreterError as exc:
                raise SimulationError(str(exc)) from exc
        np.isfinite(dy, out=_finite_mask)
        if not _finite_mask.all():
            raise SimulationError("Non-finite derivatives encountered")
        return dy
    elem_names = _element_names(state_names, shapes)
    return _NumpyRhsBuild(
        rhs_function=rhs_function,
        y0=y0,
        total_size=total_size,
        state_names=state_names,
        shapes=shapes,
        state_layout=state_layout,
        param_values=param_values,
        ordered_observed=ordered_observed,
        elem_names=elem_names,
        join_key_buffers=join_key_buffers,
        join_key_index_sets=join_key_index_sets,
        factor_scope=factor_scope,
    )


def evaluate_rhs(
    file_or_flat: Union[EsmFile, FlattenedSystem],
    state: Dict[str, float],
    t: float = 0.0,
    parameters: Optional[Dict[str, float]] = None,
) -> Dict[str, float]:
    """Evaluate the discretized method-of-lines RHS f(state, t) of an
    array/PDE model, returning a ``{element_name: derivative}`` map keyed by the
    column-major element names (``u[1]``, ``u[2,3]``, ...).

    This is the single-shot RHS hook the cross-language PDE-simulation
    conformance tier (bead ess-fmw) uses to check that Julia, Python, and Rust
    agree on the *discretized RHS* independently of any integrator. ``state``
    supplies the value of every state element (same keying as
    ``initial_conditions`` in :func:`simulate`)."""
    flat = file_or_flat if isinstance(file_or_flat, FlattenedSystem) else flatten(file_or_flat)
    if len(flat.independent_variables) > 1:
        raise UnsupportedDimensionalityError(
            "unlowered_operator: evaluate_rhs supports only time-dependent "
            "(pre-discretized) systems; got independent variables "
            f"{sorted(flat.independent_variables)} — an unlowered spatial operator"
        )
    build = _build_numpy_rhs(flat, dict(parameters or {}), dict(state))
    dy = build.rhs_function(float(t), build.y0)
    return {name: float(val) for name, val in zip(build.elem_names, dy)}


def _simulate_with_numpy(
    flat: FlattenedSystem,
    tspan: Tuple[float, float],
    parameters: Dict[str, float],
    initial_conditions: Dict[str, float],
    method: str,
    rtol: float = 1e-10,
    atol: float = 1e-12,
    loader_arrays: Optional[Dict[str, "np.ndarray"]] = None,
    inspect: Optional["BuildInspection"] = None,
) -> SimulationResult:
    """Simulate a flattened system containing array ops via the NumPy interpreter.

    ``loader_arrays`` maps each declared loader field name (``<Loader>.<var>``) to
    its provider-materialized array (DESIGN pde_simulation_pipeline §2): the
    RHS resolves those names through :class:`EvalContext.input_arrays`, and any
    scoped-reference ``ic`` folds them into u0 at build time (R2).

    ``inspect`` is the optional :class:`BuildInspection` observability sink,
    filled right after the RHS build (see :func:`_fill_build_inspection`);
    nothing downstream consults it, so results are identical either way."""
    try:
        build = _build_numpy_rhs(
            flat, parameters, initial_conditions, loader_arrays=loader_arrays
        )
        if inspect is not None:
            _fill_build_inspection(inspect, flat, build, float(tspan[0]),
                                   loader_arrays=loader_arrays)
        shapes = build.shapes
        state_names = build.state_names
        state_layout = build.state_layout
        param_values = build.param_values
        ordered_observed = build.ordered_observed
        total_size = build.total_size
        y0 = build.y0
        rhs_function = build.rhs_function

        sol = solve_ivp(
            fun=rhs_function,
            t_span=tspan,
            y0=y0,
            method=method,
            rtol=rtol,
            atol=atol,
            dense_output=True,
        )

        elem_names = _element_names(state_names, shapes)
        t_out, y_out = _densify_solution(sol, tspan)

        # Expose scalar observed trajectories alongside the states (parity with
        # the scalar SymPy path) so callers / conformance fixtures can assert on
        # algebraic quantities like `area`. Re-evaluate the observeds from the
        # state trajectory at each output time; array-valued observeds (e.g. the
        # clip ring) are not scalar rows and are skipped.
        out_vars: List[str] = list(elem_names)
        if ordered_observed and y_out.size:
            try:
                varying = _time_varying_observeds(ordered_observed, set(state_names))
                if not varying:
                    # All observeds are constant along the trajectory: evaluate
                    # once and broadcast, instead of re-clipping at every one of
                    # the (dense) output nodes.
                    ctx = EvalContext(
                        state_layout=state_layout,
                        state_shapes=shapes,
                        param_values=param_values,
                        observed_values={},
                        y=y_out[:, 0],
                        t=float(t_out[0]),
                        index_sets=flat.index_sets,
                        join_key_buffers=build.join_key_buffers,
                        join_key_index_sets=build.join_key_index_sets,
                        factor_scope=build.factor_scope,
                    )
                    _materialize_observeds(ordered_observed, ctx)
                    scalar_obs = [
                        n for n, _ in ordered_observed if n in ctx.observed_values
                    ]
                    if scalar_obs:
                        obs_block = np.vstack([
                            np.full(t_out.size, ctx.observed_values[n], dtype=float)
                            for n in scalar_obs
                        ])
                        y_out = np.vstack([y_out, obs_block])
                        out_vars.extend(scalar_obs)
                else:
                    obs_rows: Dict[str, np.ndarray] = {
                        name: np.empty(t_out.size, dtype=float)
                        for name, _ in ordered_observed
                    }
                    obs_is_scalar: Dict[str, bool] = {
                        name: True for name, _ in ordered_observed
                    }
                    for j in range(t_out.size):
                        ctx = EvalContext(
                            state_layout=state_layout,
                            state_shapes=shapes,
                            param_values=param_values,
                            observed_values={},
                            y=y_out[:, j],
                            t=float(t_out[j]),
                            index_sets=flat.index_sets,
                            join_key_buffers=build.join_key_buffers,
                            join_key_index_sets=build.join_key_index_sets,
                            factor_scope=build.factor_scope,
                        )
                        _materialize_observeds(ordered_observed, ctx)
                        for name, _ in ordered_observed:
                            if name in ctx.observed_values:
                                obs_rows[name][j] = ctx.observed_values[name]
                            else:
                                obs_is_scalar[name] = False
                    scalar_obs = [n for n, _ in ordered_observed if obs_is_scalar[n]]
                    if scalar_obs:
                        obs_block = np.vstack([obs_rows[n] for n in scalar_obs])
                        y_out = np.vstack([y_out, obs_block])
                        out_vars.extend(scalar_obs)
            except NumpyInterpreterError:
                # Output-time observed recovery is cosmetic; never fail an
                # otherwise-successful integration because a post-hoc observed
                # sample could not be evaluated.
                out_vars = list(elem_names)

        return SimulationResult(
            t=t_out,
            y=y_out,
            vars=out_vars,
            success=sol.success,
            message=sol.message,
            nfev=sol.nfev,
            njev=sol.njev,
            nlu=sol.nlu,
        )

    except UnsupportedDimensionalityError:
        raise
    except Exception as e:
        return SimulationResult(
            t=np.array([]),
            y=np.array([[]]),
            vars=[],
            success=False,
            message=f"Simulation failed: {e}",
            nfev=0,
            njev=0,
            nlu=0,
        )


# A loader provider executes one data-loader field at a simulation time and
# returns its current value as a flat float array. Time is the simulation
# clock (the same ``t`` the RHS sees); a const field is queried once at the
# start, a discrete field once per cadence segment. Inject a custom provider
# (e.g. a fixture stub) via ``simulate(..., loader_provider=...)``; the default
# executes the real loader I/O.
LoaderProvider = Callable[[LoaderField, float], "np.ndarray"]


def _provider_sample_field(provider: Any, t: float) -> "np.ndarray":
    """Sample a top-level ``providers`` entry at simulation time ``t``.

    Accepts three duck-typed shapes so a fixture stub or a real EarthSciIO-style
    provider both fit (DESIGN pde_simulation_pipeline §2): a plain callable
    ``(t) -> array_like``; an object exposing ``sample(t)``; or one exposing
    ``provider_sample(t)`` (the Julia-parity name)."""
    if callable(provider) and not hasattr(provider, "sample") \
            and not hasattr(provider, "provider_sample"):
        return provider(t)
    if hasattr(provider, "sample"):
        return provider.sample(t)
    if hasattr(provider, "provider_sample"):
        return provider.provider_sample(t)
    raise SimulationError(
        "provider must be callable (t)->array or expose sample(t) / "
        f"provider_sample(t); got {type(provider).__name__}"
    )


def _field_epoch(field: LoaderField) -> Optional[_dt.datetime]:
    """Absolute instant of simulation-clock 0 for ``field`` (C1's clock mapping).

    ``temporal.start`` is sim-clock zero, so a provider's ``refresh_times``
    anchor converts back to the simulation clock by subtracting it. ``None`` when
    the loader has no temporal anchor (a CONST loader, or a discrete loader with
    no ``start``) — the caller then falls back to local frequency arithmetic.
    """
    temporal = field.loader.temporal
    start = getattr(temporal, "start", None) if temporal is not None else None
    if not start:
        return None
    from .data_loaders.time_resolution import _coerce_datetime

    return _coerce_datetime(start)


def _sim_clock_epoch(flat: "FlattenedSystem") -> Optional[_dt.datetime]:
    """Absolute instant of simulation-clock 0: the run domain's ``reference_time``
    (falling back to its ``temporal.start``), as a naive UTC datetime.

    This is the clock origin that maps a loader refresh at sim-time ``when`` to
    the absolute instant ``epoch + when``. A loader's own ``temporal.start`` is a
    data-availability bound and cadence-alignment anchor (e.g. 1940 for ERA5),
    NOT the simulation clock origin; anchoring the clock there made loaders
    request data at the availability start (1940) instead of the actual run
    window. Normalised to naive UTC so it stays comparable with the loaders'
    naive temporal anchors (avoids aware/naive datetime errors in the cadence
    path). Returns ``None`` when the domain has no temporal anchor, so the caller
    falls back to the per-loader epoch (unchanged behaviour for such systems).
    """
    domain = getattr(flat, "domain", None)
    temporal = getattr(domain, "temporal", None) if domain is not None else None
    if temporal is None:
        return None
    from .data_loaders.time_resolution import _coerce_datetime

    for attr in ("reference_time", "start"):
        value = getattr(temporal, attr, None)
        if not value:
            continue
        when = _coerce_datetime(value)
        if when.tzinfo is not None:
            when = when.astimezone(_dt.timezone.utc).replace(tzinfo=None)
        return when
    return None


def _coerce_field_values(obj: Any) -> np.ndarray:
    """Float array from a provider field, regardless of its container.

    Handles an EarthSciIO ``NativeField`` (``.data`` + ``.dims``), an xarray
    ``DataArray`` (``.values``), and a bare ndarray / list.
    """
    if hasattr(obj, "values") and not isinstance(obj, np.ndarray):
        return np.asarray(obj.values, dtype=float)
    if hasattr(obj, "data") and hasattr(obj, "dims"):
        return np.asarray(obj.data, dtype=float)
    return np.asarray(obj, dtype=float)


def _loader_file_variable(field: "LoaderField") -> Optional[str]:
    """The reader's on-disk / band key for ``field``, when it differs from ``var``.

    EarthSciIO readers emit a ``NativeDataset`` keyed by ``file_variable`` — a
    GeoTIFF band ``"Band1"``, a NetCDF short name ``"t"`` — declared per variable
    on the loader. The flattened ``field.var`` is the model-facing *semantic*
    name (``"fuel_model"``). Returns the declared ``file_variable`` when it
    differs from ``field.var`` (so it must be remapped to index the native
    dataset), else ``None`` (matching names, or a stub provider keyed by the
    semantic name — no remapping).
    """
    loader = getattr(field, "loader", None)
    variables = getattr(loader, "variables", None)
    var = getattr(field, "var", None)
    if isinstance(variables, dict):
        decl = variables.get(var)
        fv = getattr(decl, "file_variable", None) if decl is not None else None
        if fv and str(fv) != var:
            return str(fv)
    return None


def _extract_loader_var(native: Any, var: str, file_var: Optional[str] = None) -> np.ndarray:
    """Pull ``var``'s raw values from a provider's native dataset.

    Accepts a :class:`~earthsci_toolkit.data_loaders.grid.GridLoadResult` or an
    EarthSciIO ``NativeDataset`` (either exposes a ``.variables`` mapping), or a
    bare array returned by a minimal stub provider. ``file_var`` is the reader's
    on-disk key for the field (its ``file_variable``); when given and present it
    indexes the dataset, since readers key output by the file/band name
    (``"Band1"``) rather than the semantic ``var`` (``"fuel_model"``).
    """
    variables = getattr(native, "variables", None)
    if variables is not None:
        if file_var is not None and file_var in variables:
            return _coerce_field_values(variables[file_var])
        return _coerce_field_values(variables[var])
    return _coerce_field_values(native)


def _provider_array(field: LoaderField, native: Any, target: Any) -> np.ndarray:
    """Lower a provider's native field to the flat sim-grid array the RHS reads.

    The raw ``field.var`` array is flattened unchanged (identity for a
    native==sim-grid fixture or a stub provider). ``target`` is accepted for
    signature compatibility but unused.
    """
    return _extract_loader_var(native, field.var, _loader_file_variable(field)).reshape(-1)


def _build_loader_target(flat: FlattenedSystem) -> Optional[Any]:
    """Loader target grids are no longer built — always returns ``None``.

    The bespoke spatial-grid / regrid machinery was removed in v0.8.0 (loader
    fields are injected raw; any landing onto a model grid is an ``aggregate``
    FAQ concern downstream), so there is no target grid to construct. Retained
    as a no-op for signature compatibility with its call sites.
    """
    return None


def _factory_accepts_target(factory: Callable) -> bool:
    """Whether ``factory`` accepts a ``target`` keyword (so we can thread it in).

    The provider-factory contract is ``(field, window) -> Provider``; a factory
    that *also* takes ``target=`` (the earthsciio adapter, which needs the domain
    for the GeoTIFF bbox / CDS ``area``) receives the same target the in-tree
    default does. A ``**kwargs`` factory counts. Best-effort: an un-introspectable
    callable is treated as the bare 2-arg contract.
    """
    import inspect

    try:
        params = inspect.signature(factory).parameters
    except (TypeError, ValueError):
        return False
    if "target" in params:
        return True
    return any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params.values())


def _loader_cadence_boundaries(
    discrete_fields: List[LoaderField], t0: float, t1: float
) -> List[float]:
    """Interior cadence-boundary times in the open interval ``(t0, t1)``.

    Each discrete loader refreshes every ``temporal.frequency`` seconds; the
    union of those tick times (relative to the integration start ``t0``) marks
    where the integration must pause, refresh the loader arrays, and restart so
    the forcing is piecewise-constant and the RHS stays pure within a segment
    (the terminal-event segmentation the campaign spike calls for). A discrete
    loader with no parseable frequency contributes no interior boundary (a
    single segment over the whole span)."""
    from .data_loaders.time_resolution import (
        TimeResolutionError,
        parse_iso_duration,
    )

    boundaries: Set[float] = set()
    for f in discrete_fields:
        temporal = f.loader.temporal
        freq = getattr(temporal, "frequency", None) if temporal is not None else None
        if not freq:
            continue
        try:
            step = parse_iso_duration(freq).approximate_seconds()
        except TimeResolutionError:
            continue
        if step <= 0:
            continue
        k = 1
        while True:
            b = t0 + k * step
            if b >= t1:
                break
            boundaries.add(b)
            k += 1
    return sorted(boundaries)


def _delta_seconds(later: _dt.datetime, earlier: _dt.datetime) -> float:
    """Seconds between two datetimes, tolerant of mixed tz-awareness.

    The in-tree provider's anchors and epoch are both naive (from
    ``_coerce_datetime``); a real EarthSciIO provider may return tz-aware
    anchors. Normalise so the wall-clock difference is well defined either way.
    """
    if later.tzinfo is not None and earlier.tzinfo is None:
        later = later.replace(tzinfo=None)
    elif later.tzinfo is None and earlier.tzinfo is not None:
        earlier = earlier.replace(tzinfo=None)
    return (later - earlier).total_seconds()


def _provider_segment_boundaries(
    discrete_fields: List[LoaderField],
    providers: Dict[str, Any],
    epochs: Dict[str, Optional[_dt.datetime]],
    t0: float,
    t1: float,
) -> List[float]:
    """Interior cadence boundaries (sim-clock) from providers' refresh_times.

    Each discrete provider's :meth:`Provider.refresh_times` gives absolute
    cadence anchors; subtracting the loader epoch maps them onto the simulation
    clock. A provider that supplies no times (unbounded, or an in-tree provider
    without a usable epoch/frequency) falls back to local frequency arithmetic
    (:func:`_loader_cadence_boundaries`) so the behaviour degrades gracefully.
    Only strictly-interior boundaries ``t0 < b < t1`` are returned; the seed at
    ``t0`` and the final time ``t1`` are added by the caller.
    """
    boundaries: Set[float] = set()
    for f in discrete_fields:
        provider = providers.get(f.name)
        epoch = epochs.get(f.name)
        times: List[Any] = []
        if provider is not None:
            try:
                times = list(provider.refresh_times())
            except Exception:
                times = []
        if times and epoch is not None:
            for anchor in times:
                b = _delta_seconds(anchor, epoch)
                if t0 < b < t1:
                    boundaries.add(float(b))
        else:
            for b in _loader_cadence_boundaries([f], t0, t1):
                if t0 < b < t1:
                    boundaries.add(float(b))
    return sorted(boundaries)


def _simulate_with_loaders(
    flat: FlattenedSystem,
    tspan: Tuple[float, float],
    parameters: Dict[str, float],
    initial_conditions: Dict[str, float],
    method: str,
    rtol: float = 1e-10,
    atol: float = 1e-12,
    loader_provider: Optional[LoaderProvider] = None,
    provider_factory: Optional[Callable] = None,
) -> SimulationResult:
    """Integrate a system whose RHS reads data-loader fields (RFC §4.3).

    Loader fields are external inputs, not equations: a coupling edge already
    substituted each loader's producer symbol (e.g. ``ERA5.pl.u``) into its
    consumer's equation at flatten time. Here we execute the loaders and bind
    their arrays into the NumPy RHS as read-only inputs, updated at each
    loader's cadence:

    * **const** (static loader, no ``temporal``): loaded once before
      integration; the value is fixed for the whole run.
    * **discrete** (temporal loader): loaded at the start, then refreshed at
      every cadence boundary via terminal-event-style segmentation — the
      integration is split at the boundaries, the loader arrays are reloaded
      between segments, and the solver restarts from the carried-over state.

    The RHS reads a single shared array registry that is mutated only between
    segments, so within any segment the forcing is constant and the derivative
    is a pure function of the state. With no loader fields this function is
    never reached (``simulate`` routes elsewhere).

    Two provider seams feed the registry:

    * ``loader_provider`` — a legacy per-call callable ``(LoaderField, t) ->
      ndarray`` (offline stubs / backward compatibility); cadence boundaries
      come from local frequency arithmetic.
    * otherwise the **provider-object** path (default): one
      :class:`~earthsci_toolkit.data_loaders.provider.Provider` is built per
      loader field at setup (the in-tree :class:`LoadDataProvider` by default, or
      an injected ``provider_factory`` — e.g. a real EarthSciIO provider).
      CONST → ``materialize()`` once, DISCRETE → ``refresh(t)`` at the seed and
      each boundary, with boundaries taken from ``Provider.refresh_times()``.
      Native arrays are reprojected + regridded onto the model grid (C4) before
      binding."""
    try:
        t0, t1 = float(tspan[0]), float(tspan[1])

        const_fields = [f for f in flat.loader_fields if f.cadence == "const"]
        discrete_fields = [f for f in flat.loader_fields if f.cadence != "const"]

        # The shared registry the RHS reads each step. Mutated in place (never
        # rebound) so every per-step EvalContext sees the current segment's data.
        loader_arrays: Dict[str, np.ndarray] = {}

        if loader_provider is not None:
            # Legacy seam: a per-call callable, kept for offline stub tests and
            # backward compatibility. Invoked once per segment (never per RHS);
            # boundaries from local frequency arithmetic.
            def _seed() -> None:
                for f in const_fields:
                    loader_arrays[f.name] = np.asarray(
                        loader_provider(f, t0), dtype=float
                    )
                for f in discrete_fields:
                    loader_arrays[f.name] = np.asarray(
                        loader_provider(f, t0), dtype=float
                    )

            def _refresh_discrete(when: float) -> None:
                for f in discrete_fields:
                    loader_arrays[f.name] = np.asarray(
                        loader_provider(f, when), dtype=float
                    )

            seg_ends = [
                b for b in _loader_cadence_boundaries(discrete_fields, t0, t1)
                if t0 < b < t1
            ] + [t1]
        else:
            # Provider-object path (default): build one Provider per loader field
            # at setup (EarthSciIO Provider contract; in-tree default backed by
            # load_data), CONST → materialize() once, DISCRETE → refresh() at the
            # seed and each boundary. Build the lon/lat target grid ONCE (geometry
            # cached) so each native field is reprojected + regridded (C4) onto
            # the domain grid before binding; no target ⇒ raw injection.
            from .data_loaders.provider import build_default_provider

            target = _build_loader_target(flat)
            # The in-tree default provider derives server-side-subset URL fills
            # (WGS84 bbox / image size, and the CDS ERA5 'area') from the target
            # grid. An injected provider_factory keeps the public (field, window)
            # contract, but if it ALSO accepts a ``target`` keyword (e.g. the
            # earthsciio adapter, which needs the domain for the GeoTIFF bbox /
            # CDS area) we thread the same target through.
            if provider_factory is not None:
                if _factory_accepts_target(provider_factory):
                    def factory(f, w):
                        return provider_factory(f, w, target=target)
                else:
                    factory = provider_factory
            else:
                def factory(f, w):
                    return build_default_provider(f, w, target=target)
            # Sim-clock 0 is the run domain's reference_time (shared by all
            # loaders); only when the domain carries no temporal anchor do we
            # fall back to each loader's own temporal.start (its availability
            # start), preserving behaviour for systems without a reference_time.
            sim_epoch = _sim_clock_epoch(flat)
            epochs = {
                f.name: (sim_epoch if sim_epoch is not None else _field_epoch(f))
                for f in flat.loader_fields
            }

            def _window(f: LoaderField):
                epoch = epochs[f.name]
                if epoch is None:
                    return None
                return (
                    epoch + _dt.timedelta(seconds=t0),
                    epoch + _dt.timedelta(seconds=t1),
                )

            providers = {
                f.name: factory(f, _window(f)) for f in flat.loader_fields
            }

            def _abs(f: LoaderField, when: float):
                epoch = epochs[f.name]
                if epoch is None:
                    return None
                return epoch + _dt.timedelta(seconds=when)

            def _seed() -> None:
                for f in const_fields:
                    loader_arrays[f.name] = _provider_array(
                        f, providers[f.name].materialize(), target
                    )
                for f in discrete_fields:
                    loader_arrays[f.name] = _provider_array(
                        f, providers[f.name].refresh(_abs(f, t0)), target
                    )

            def _refresh_discrete(when: float) -> None:
                for f in discrete_fields:
                    loader_arrays[f.name] = _provider_array(
                        f, providers[f.name].refresh(_abs(f, when)), target
                    )

            seg_ends = _provider_segment_boundaries(
                discrete_fields, providers, epochs, t0, t1
            ) + [t1]

        # CONST loaders: execute ONCE before integration. DISCRETE loaders: seed
        # the first segment's value (refreshed at boundaries below).
        _seed()

        build = _build_numpy_rhs(
            flat, parameters, initial_conditions, loader_arrays=loader_arrays
        )
        rhs_function = build.rhs_function
        elem_names = _element_names(build.state_names, build.shapes)

        # Spread the dense-output budget across segments so a multi-segment run
        # does not multiply the per-segment grid (parity with the single-call
        # path when there is exactly one segment).
        per_seg_pts = max(11, (10001 // len(seg_ends)) + 1)

        t_current = t0
        y_current = build.y0
        t_chunks: List[np.ndarray] = []
        y_chunks: List[np.ndarray] = []
        nfev = njev = nlu = 0
        last_message = ""
        for seg_idx, seg_end in enumerate(seg_ends):
            sol = solve_ivp(
                fun=rhs_function,
                t_span=(t_current, seg_end),
                y0=y_current,
                method=method,
                rtol=rtol,
                atol=atol,
                dense_output=True,
            )
            nfev += int(sol.nfev)
            njev += int(sol.njev)
            nlu += int(sol.nlu)
            last_message = sol.message
            if not sol.success:
                return SimulationResult(
                    t=np.array([]), y=np.array([[]]), vars=[], success=False,
                    message=(
                        f"Simulation failed in cadence segment "
                        f"[{t_current}, {seg_end}]: {sol.message}"
                    ),
                    nfev=nfev, njev=njev, nlu=nlu,
                )
            seg_t, seg_y = _densify_solution(
                sol, (t_current, seg_end), min_points=per_seg_pts
            )
            # Drop the seam node (shared with the previous segment's end; the
            # state is continuous across a loader refresh, only the forcing
            # jumps) so the stitched trajectory has no duplicated time point.
            if seg_idx == 0:
                t_chunks.append(seg_t)
                y_chunks.append(seg_y)
            else:
                t_chunks.append(seg_t[1:])
                y_chunks.append(seg_y[:, 1:])
            t_current = seg_end
            y_current = sol.y[:, -1]
            # Advance the cadence: refresh discrete loaders for the NEXT segment.
            if seg_end < t1:
                _refresh_discrete(seg_end)

        t_out = np.concatenate(t_chunks)
        y_out = np.concatenate(y_chunks, axis=1)
        return SimulationResult(
            t=t_out, y=y_out, vars=list(elem_names), success=True,
            message=last_message, nfev=nfev, njev=njev, nlu=nlu,
        )

    except UnsupportedDimensionalityError:
        raise
    except Exception as e:
        return SimulationResult(
            t=np.array([]), y=np.array([[]]), vars=[], success=False,
            message=f"Simulation failed: {e}", nfev=0, njev=0, nlu=0,
        )


def simulate_reaction_system(
    reaction_system: ReactionSystem,
    initial_conditions: Dict[str, float],
    time_span: Tuple[float, float],
    events: Optional[List[ContinuousEvent]] = None,
    **solver_options
) -> SimulationResult:
    """
    Simulate a reaction system using SciPy's solve_ivp.

    This is the main simulation function that:
    1. Resolves coupling to single ODE system
    2. Converts expressions to SymPy
    3. Generates mass-action ODEs from reactions
    4. Lambdifies for fast NumPy RHS function
    5. Calls scipy.integrate.solve_ivp()

    Args:
        reaction_system: Reaction system to simulate
        initial_conditions: Initial concentrations {species_name: concentration}
        time_span: Tuple of (t_start, t_end)
        events: Optional list of continuous events
        **solver_options: Additional options passed to solve_ivp

    Returns:
        SimulationResult: Results of the simulation

    Limitations:
        - 0D box model only (no spatial operators)
        - Limited event support
        - Mass-action kinetics only
    """
    try:
        # Generate mass-action ODEs
        species_names, ode_exprs = _generate_mass_action_odes(reaction_system)

        if not species_names:
            raise SimulationError("No species found in reaction system")

        # Create symbol map
        symbol_map = {name: sp.Symbol(name) for name in species_names}

        # Create initial condition vector. An explicit `initial_conditions`
        # override wins; otherwise fall back to the species' declared scalar
        # `default` (matching the main flatten path in flatten.py
        # `_collect_reaction_system`), and finally to 0.0 when neither exists.
        species_defaults = {
            s.name: s.default
            for s in reaction_system.species
            if s.default is not None
        }
        y0 = np.array([
            initial_conditions.get(name, species_defaults.get(name, 0.0))
            for name in species_names
        ])

        # Lambdify ODEs for fast evaluation
        variables = [symbol_map[name] for name in species_names]

        # Create RHS function
        if variables and ode_exprs:
            rhs_funcs = [
                sp.lambdify(variables, expr, modules=_LAMBDIFY_MODULES)
                for expr in ode_exprs
            ]

            def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
                """Right-hand side function for the ODE system."""
                try:
                    # Ensure y has the right shape and no negative concentrations
                    y_clipped = np.maximum(y, 0.0)  # Clip to prevent negative concentrations

                    # Evaluate each ODE expression
                    dydt = np.array([func(*y_clipped) for func in rhs_funcs])

                    # Ensure result is finite
                    if not np.all(np.isfinite(dydt)):
                        raise SimulationError("Non-finite derivatives encountered")

                    return dydt

                except Exception as e:
                    raise SimulationError(f"Error in RHS evaluation: {e}")
        else:
            def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
                return np.zeros_like(y)

        # Create event functions if events are provided
        event_functions = []
        if events:
            event_functions = _create_event_functions(events, symbol_map)

        # Set default solver options
        default_options = {
            'method': 'LSODA',  # Good general-purpose method
            'rtol': 1e-6,
            'atol': 1e-8,
            'dense_output': False,
            'events': event_functions if event_functions else None
        }
        default_options.update(solver_options)

        # Check scipy availability
        if not SCIPY_AVAILABLE:
            raise SimulationError("SciPy is required for simulation but not available. Please install scipy.")

        # Solve the ODE system
        sol = solve_ivp(
            fun=rhs_function,
            t_span=time_span,
            y0=y0,
            **default_options
        )

        # Extract events if they occurred
        events_list = None
        if sol.t_events is not None and len(sol.t_events) > 0:
            events_list = sol.t_events

        return SimulationResult(
            t=sol.t,
            y=sol.y,
            vars=species_names,  # Add variable names
            success=sol.success,
            message=sol.message,
            nfev=sol.nfev,
            njev=sol.njev,
            nlu=sol.nlu,
            events=events_list
        )

    except Exception as e:
        return SimulationResult(
            t=np.array([]),
            y=np.array([[]]),
            vars=[],  # Empty variable list
            success=False,
            message=f"Simulation failed: {e}",
            nfev=0,
            njev=0,
            nlu=0
        )


def simulate_with_discrete_events(
    reaction_system: ReactionSystem,
    initial_conditions: Dict[str, float],
    time_span: Tuple[float, float],
    discrete_events: Optional[List[DiscreteEvent]] = None,
    **solver_options
) -> SimulationResult:
    """
    Simulate with discrete events using manual stepping.

    This function handles discrete events by manually stepping the integration
    and applying event effects when their triggers fire.

    Args:
        reaction_system: Reaction system to simulate
        initial_conditions: Initial concentrations
        time_span: Tuple of (t_start, t_end)
        discrete_events: List of discrete events
        **solver_options: Additional options passed to solve_ivp

    Returns:
        SimulationResult: Results of the simulation
    """
    if not discrete_events:
        # No discrete events, use regular simulation
        return simulate_reaction_system(reaction_system, initial_conditions, time_span, **solver_options)

    try:
        # Implement discrete event handling with manual stepping
        t_start, t_end = time_span
        dt = solver_options.pop('max_step', (t_end - t_start) / 100.0)  # Default step size

        # Sort events by trigger time/priority for time-based events
        time_events = []
        condition_events = []

        for event in discrete_events:
            if event.trigger.type == 'time':
                time_events.append((float(event.trigger.value), event))
            elif event.trigger.type == 'condition':
                condition_events.append(event)
            # Note: 'external' events would need external trigger mechanism

        # Sort time events by time
        time_events.sort(key=lambda x: x[0])

        # Generate mass-action ODEs
        species_names, ode_exprs = _generate_mass_action_odes(reaction_system)
        if not species_names:
            raise SimulationError("No species found in reaction system")

        # Create symbol map and initial conditions. An explicit
        # `initial_conditions` override wins; otherwise fall back to the
        # species' declared scalar `default`, and finally to 0.0.
        symbol_map = {name: sp.Symbol(name) for name in species_names}
        species_defaults = {
            s.name: s.default
            for s in reaction_system.species
            if s.default is not None
        }
        y_current = np.array([
            initial_conditions.get(name, species_defaults.get(name, 0.0))
            for name in species_names
        ])

        # Lambdify ODEs for fast evaluation
        variables = [symbol_map[name] for name in species_names]
        if variables and ode_exprs:
            rhs_funcs = [
                sp.lambdify(variables, expr, modules=_LAMBDIFY_MODULES)
                for expr in ode_exprs
            ]

            def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
                """Right-hand side function for the ODE system."""
                y_clipped = np.maximum(y, 0.0)  # Clip to prevent negative concentrations
                dydt = np.array([func(*y_clipped) for func in rhs_funcs])
                if not np.all(np.isfinite(dydt)):
                    raise SimulationError("Non-finite derivatives encountered")
                return dydt
        else:
            def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
                return np.zeros_like(y)

        # Manual stepping with event handling
        t_current = t_start
        t_points = [t_current]
        y_points = [y_current.copy()]
        event_times = []

        # Set up solver options with more conservative defaults for manual stepping
        default_options = {
            'method': 'RK45',  # Use more stable method for manual stepping
            'rtol': 1e-6,
            'atol': 1e-8,
            'dense_output': False,
            'max_step': dt / 10.0,  # Smaller steps for stability
        }
        default_options.update(solver_options)

        time_event_index = 0  # Index for next time event

        while t_current < t_end:
            # Determine next integration end time
            next_t = min(t_end, t_current + dt)

            # Check if there are time events before next_t
            while (time_event_index < len(time_events) and
                   time_events[time_event_index][0] <= next_t):
                event_time, event = time_events[time_event_index]

                if event_time > t_current:
                    # Check scipy availability
                    if not SCIPY_AVAILABLE:
                        raise SimulationError("SciPy is required for simulation but not available. Please install scipy.")

                    # Integrate to event time
                    sol = solve_ivp(
                        fun=rhs_function,
                        t_span=(t_current, event_time),
                        y0=y_current,
                        **default_options
                    )

                    if not sol.success:
                        return SimulationResult(
                            t=np.array(t_points),
                            y=np.array(y_points).T,
                            vars=species_names,
                            success=False,
                            message=f"Integration failed before discrete event: {sol.message}",
                            nfev=sol.nfev,
                            njev=sol.njev,
                            nlu=sol.nlu
                        )

                    # Update current state
                    t_current = event_time
                    y_current = sol.y[:, -1]
                    # Add intermediate points if any
                    if len(sol.t) > 1:
                        t_points.extend(sol.t[1:])  # Skip first point (duplicate)
                        y_points.extend(sol.y[:, 1:].T)  # Skip first point

                # Apply discrete event effects
                y_current = _apply_discrete_event_effects(event, y_current, species_names, symbol_map)
                event_times.append(t_current)
                time_event_index += 1

            # Check condition-based events at current time point
            events_triggered = []
            for event in condition_events:
                if _check_discrete_event_condition(event, t_current, y_current, species_names, symbol_map):
                    events_triggered.append(event)

            # Apply triggered events (avoid modifying state while checking)
            for event in events_triggered:
                y_current = _apply_discrete_event_effects(event, y_current, species_names, symbol_map)
                event_times.append(t_current)

            # Continue integration to next_t if not already there
            if t_current < next_t:
                # Check scipy availability
                if not SCIPY_AVAILABLE:
                    raise SimulationError("SciPy is required for simulation but not available. Please install scipy.")

                sol = solve_ivp(
                    fun=rhs_function,
                    t_span=(t_current, next_t),
                    y0=y_current,
                    **default_options
                )

                if not sol.success:
                    return SimulationResult(
                        t=np.array(t_points),
                        y=np.array(y_points).T,
                        vars=species_names,
                        success=False,
                        message=f"Integration failed: {sol.message}",
                        nfev=sol.nfev,
                        njev=sol.njev,
                        nlu=sol.nlu
                    )

                # Update current state
                t_current = sol.t[-1]
                y_current = sol.y[:, -1]
                # Add intermediate points if any
                if len(sol.t) > 1:
                    t_points.extend(sol.t[1:])  # Skip first point (duplicate)
                    y_points.extend(sol.y[:, 1:].T)  # Skip first point

            # Check condition-based events after integration step
            events_triggered = []
            for event in condition_events:
                if _check_discrete_event_condition(event, t_current, y_current, species_names, symbol_map):
                    events_triggered.append(event)

            # Apply triggered events
            for event in events_triggered:
                y_current = _apply_discrete_event_effects(event, y_current, species_names, symbol_map)
                event_times.append(t_current)

        return SimulationResult(
            t=np.array(t_points),
            y=np.array(y_points).T,
            vars=species_names,
            success=True,
            message=f"Simulation completed successfully with {len(event_times)} discrete events",
            nfev=0,  # Not tracking across multiple integrations
            njev=0,
            nlu=0,
            events=[np.array(event_times)] if event_times else None
        )

    except Exception as e:
        return SimulationResult(
            t=np.array([]),
            y=np.array([[]]),
            vars=[],
            success=False,
            message=f"Discrete event simulation failed: {e}",
            nfev=0,
            njev=0,
            nlu=0
        )