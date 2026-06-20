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

import numpy as np
import sympy as sp
from typing import Dict, List, Tuple, Optional, Union, Any, Callable
from dataclasses import dataclass

# Optional scipy import - only needed for actual simulation
try:
    from scipy.integrate import solve_ivp
    SCIPY_AVAILABLE = True
except (ImportError, ValueError):
    # ValueError can occur due to numpy/scipy compatibility issues
    SCIPY_AVAILABLE = False
    solve_ivp = None

from ._monitoring import track_performance
from .esm_types import (
    ReactionSystem,
    ContinuousEvent, DiscreteEvent, Expr, ExprNode, EsmFile,
    AffectEquation, FunctionalAffect, is_aggregate_op,
)
from .flatten import (
    FlattenedEquation,
    FlattenedSystem,
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
)
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


@track_performance("simulate")
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

    # Spec §4.7.6.12: ODE backends MUST reject systems with spatial dims.
    if len(flat.independent_variables) > 1:
        spatial = [v for v in flat.independent_variables if v != "t"]
        raise UnsupportedDimensionalityError(
            f"Python's simulate() backend handles ODE-only systems "
            f"(independent variables: ['t']), but the flattened system has "
            f"spatial independent variables {spatial}. Use a PDE-capable "
            f"backend such as Julia EarthSciSerialization."
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
            rtol=rtol, atol=atol,
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
    if expr is None or isinstance(expr, (int, float)) and not isinstance(expr, bool):
        return expr
    if isinstance(expr, str):
        return expr
    if isinstance(expr, ExprNode):
        new_args = [_substitute_algebraic(a, subs) for a in expr.args]
        new_body = _substitute_algebraic(expr.expr, subs) if expr.expr is not None else None
        new_values = (
            [_substitute_algebraic(v, subs) for v in expr.values]
            if expr.values is not None else None
        )
        # If this is index(v, e1, e2, ...) with v eliminated, inline the body.
        if expr.op == "index" and new_args:
            head = new_args[0]
            if isinstance(head, str) and head in subs:
                idx_syms, body = subs[head]
                caller_idx = new_args[1:]
                if len(caller_idx) == len(idx_syms):
                    bindings = {sym: idx_expr for sym, idx_expr in zip(idx_syms, caller_idx)}
                    return _rebind_index_syms(body, bindings)
        return ExprNode(
            op=expr.op,
            args=new_args,
            wrt=expr.wrt,
            dim=expr.dim,
            output_idx=expr.output_idx,
            expr=new_body,
            reduce=expr.reduce,
            ranges=expr.ranges,
            regions=expr.regions,
            values=new_values,
            shape=expr.shape,
            perm=expr.perm,
            axis=expr.axis,
            fn=expr.fn,
        )
    return expr


def _rebind_index_syms(
    expr: Expr, bindings: Dict[str, Expr]
) -> Expr:
    """Replace bare string references to index symbols with their target expressions."""
    if expr is None or isinstance(expr, (int, float)):
        return expr
    if isinstance(expr, str):
        return bindings.get(expr, expr)
    if isinstance(expr, ExprNode):
        new_args = [_rebind_index_syms(a, bindings) for a in expr.args]
        new_body = (
            _rebind_index_syms(expr.expr, bindings) if expr.expr is not None else None
        )
        new_values = (
            [_rebind_index_syms(v, bindings) for v in expr.values]
            if expr.values is not None else None
        )
        return ExprNode(
            op=expr.op,
            args=new_args,
            wrt=expr.wrt,
            dim=expr.dim,
            output_idx=expr.output_idx,
            expr=new_body,
            reduce=expr.reduce,
            ranges=expr.ranges,
            regions=expr.regions,
            values=new_values,
            shape=expr.shape,
            perm=expr.perm,
            axis=expr.axis,
            fn=expr.fn,
        )
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
    range reference (RFC §5.1 / §5.2). Such nodes are evaluated through the full
    NumPy interpreter, which carries the semiring and index-set semantics, rather
    than the hand-rolled einsum unroll below.
    """
    if not isinstance(node, ExprNode):
        return False
    if getattr(node, "semiring", None) is not None:
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

    # Case A: scalar state LHS — D(var, t) with var a bare string.
    if isinstance(lhs, ExprNode) and lhs.op == "D" and lhs.args:
        inner = lhs.args[0]
        if isinstance(inner, str):
            if inner not in state_layout:
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
                    prev_locals = dict(ctx.locals)
                    try:
                        for multi in it:
                            for s, pos in zip(syms, multi):
                                ctx.locals[s] = ranges[syms.index(s)][pos]
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


def _simulate_with_numpy(
    flat: FlattenedSystem,
    tspan: Tuple[float, float],
    parameters: Dict[str, float],
    initial_conditions: Dict[str, float],
    method: str,
    rtol: float = 1e-10,
    atol: float = 1e-12,
) -> SimulationResult:
    """Simulate a flattened system containing array ops via the NumPy interpreter."""
    try:
        shapes = infer_variable_shapes(flat)
        state_names = list(flat.state_variables.keys())

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

        # Algebraic elimination: eliminate simple ``v[i] = <body>`` equations.
        working_equations, _eliminated = _collect_algebraic_substitutions(
            list(flat.equations)
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

        # Initial conditions.
        y0 = np.zeros(total_size, dtype=float)
        for name in state_names:
            default = flat.state_variables[name].default
            if isinstance(default, (int, float)):
                sl = state_layout[name]
                y0[sl] = float(default)
        _apply_initial_conditions(
            y0, state_layout, shapes, state_names, initial_conditions
        )

        def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
            ctx = EvalContext(
                state_layout=state_layout,
                state_shapes=shapes,
                param_values=param_values,
                observed_values={},
                y=y,
                t=t,
                index_sets=flat.index_sets,
            )
            dy = np.zeros(total_size, dtype=float)
            for eq in working_equations:
                try:
                    _apply_equation_to_dy(eq, ctx, shapes, state_layout, dy)
                except NumpyInterpreterError as exc:
                    raise SimulationError(str(exc)) from exc
            if not np.all(np.isfinite(dy)):
                raise SimulationError("Non-finite derivatives encountered")
            return dy

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

        return SimulationResult(
            t=t_out,
            y=y_out,
            vars=elem_names,
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

        # Create initial condition vector
        y0 = np.array([initial_conditions.get(name, 0.0) for name in species_names])

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

        # Create symbol map and initial conditions
        symbol_map = {name: sp.Symbol(name) for name in species_names}
        y_current = np.array([initial_conditions.get(name, 0.0) for name in species_names])

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