"""Legacy scalar reaction-system simulation pathway.

Implements the original 0-D box-model stack —
:func:`simulate_reaction_system` (mass-action ODEs lowered to SymPy and
lambdified for :func:`scipy.integrate.solve_ivp`) and
:func:`simulate_with_discrete_events` (manual stepping with discrete-event
handling) — together with the scalar event helpers they are built from.
:func:`_create_event_functions` is also used by the scalar branch of
:func:`earthsci_ast.simulation.simulate` for continuous events.
``earthsci_ast.simulation`` re-exports this module's API.
"""
from __future__ import annotations

from typing import Callable

import numpy as np
import sympy as sp

from .esm_types import (
    AffectEquation,
    ContinuousEvent,
    DiscreteEvent,
    Expr,
    ExprNode,
    FunctionalAffect,
    ReactionSystem,
)
from .reactions import lower_reactions_to_equations
from .simulation_common import (
    SCIPY_AVAILABLE,
    SimulationResult,
    _failure_result,
    _resolve_override,
    solve_ivp,
)
from .sympy_bridge import (
    _LAMBDIFY_MODULES,
    SimulationError,
    _expr_to_sympy,
)


def _generate_mass_action_odes(reaction_system: ReactionSystem) -> tuple[list[str], list[sp.Expr]]:
    """
    Adapter that lowers a reaction system into ``(species_names, sympy_odes)``
    for SciPy's lambdify pipeline.

    Delegates the actual mass-action lowering to
    :func:`earthsci_ast.reactions.lower_reactions_to_equations` — the
    single canonical implementation shared with :func:`derive_odes`. This
    function only (a) supplies a graceful empty-system path for simulate()
    and (b) converts the resulting ESM ExprNode equations into SymPy
    expressions aligned with the species index used by the RHS function.

    Species that don't appear in any reaction get a constant ``sp.Float(0)``
    expression so the returned list stays aligned with ``species_names``.
    """
    species_names = [species.name for species in reaction_system.species]
    symbol_map = {name: sp.Symbol(name) for name in species_names}
    species_rates: dict[str, sp.Expr] = {name: sp.Float(0) for name in species_names}

    if species_names and reaction_system.reactions:
        equations = lower_reactions_to_equations(reaction_system.reactions, reaction_system.species)
        for eq in equations:
            lhs = eq.lhs
            if isinstance(lhs, ExprNode) and lhs.op == "D" and lhs.args:
                species_name = lhs.args[0]
                if species_name in species_rates:
                    species_rates[species_name] = _expr_to_sympy(eq.rhs, symbol_map)

    return species_names, [species_rates[name] for name in species_names]


def _create_event_functions(
    events: list[ContinuousEvent],
    symbol_map: dict[str, sp.Symbol],
    state_names: list[str],
) -> list[Callable]:
    """
    Create event functions for SciPy integration.

    Args:
        events: List of continuous events
        symbol_map: Mapping from variable names to SymPy symbols
        state_names: State/species names in the order they appear in the solver's
            ``y`` vector. Each condition symbol is resolved to the value of the
            state with the SAME NAME via this ordering — never positionally,
            since ``sympy.free_symbols`` iteration order is arbitrary.

    Returns:
        List of event functions
    """
    event_functions = []
    # Name -> index in the solver state vector ``y``. A condition symbol is bound
    # to ``y[state_index[name]]``; a symbol that names no state (a stray
    # parameter) contributes 0.0, matching the historic default-to-zero fallback.
    state_index = {name: i for i, name in enumerate(state_names)}

    for event in events:
        # Handle multiple conditions - create a function for each condition
        for condition in event.conditions:
            # Convert condition to SymPy
            condition_expr = _expr_to_sympy(condition, symbol_map)

            # Get variables in the condition
            variables = list(condition_expr.free_symbols)
            var_names = [str(var) for var in variables]

            # Create lambda function
            condition_func = sp.lambdify(variables, condition_expr, modules=_LAMBDIFY_MODULES)

            # Check if we have direction-dependent affects
            has_affect_neg = event.affect_neg is not None and len(event.affect_neg) > 0
            has_affect_pos = event.affects is not None and len(event.affects) > 0

            # One closure factory for every crossing flavour: the event bodies are
            # identical (evaluate the condition at the current state), differing only
            # in the SciPy ``direction`` and which ``affects`` list they carry.
            def _make_event_function(
                direction, affects, condition_func, var_names, event, state_index
            ):
                def event_function(
                    t,
                    y,
                    condition_func=condition_func,
                    var_names=var_names,
                    event=event,
                    state_index=state_index,
                ):
                    # Resolve each condition symbol to the value of the state with
                    # that NAME (via ``state_index``), so the lambdified condition
                    # sees the correct state regardless of free-symbol order.
                    var_values = [
                        y[state_index[name]]
                        if name in state_index and state_index[name] < len(y)
                        else 0.0
                        for name in var_names
                    ]
                    return condition_func(*var_values) if var_values else condition_func()

                event_function.terminal = True
                event_function.direction = direction
                event_function.affects = affects
                event_function.event_name = event.name
                return event_function

            if has_affect_neg and has_affect_pos:
                # Separate event functions for positive- and negative-going crossings.
                event_functions.append(
                    _make_event_function(
                        1, event.affects, condition_func, var_names, event, state_index
                    )
                )
                event_functions.append(
                    _make_event_function(
                        -1, event.affect_neg, condition_func, var_names, event, state_index
                    )
                )
            else:
                # Original behavior for events without affect_neg: detect all
                # zero crossings (direction 0).
                event_functions.append(
                    _make_event_function(
                        0,
                        event.affects if has_affect_pos else [],
                        condition_func,
                        var_names,
                        event,
                        state_index,
                    )
                )

    return event_functions


def _apply_discrete_event_effects(
    event: DiscreteEvent, y: np.ndarray, species_names: list[str], symbol_map: dict[str, sp.Symbol]
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
                expr_value = _evaluate_expression_at_state(
                    affect.rhs, y_modified, species_names, symbol_map
                )
                y_modified[species_indices[affect.lhs]] = max(
                    0.0, expr_value
                )  # Ensure non-negative

        elif isinstance(affect, FunctionalAffect):
            # A FunctionalAffect dispatches a registered handler (by ``handler_id``,
            # reading ``read_vars`` / ``read_params`` and writing ``modified_params``)
            # — there is no handler registry in this legacy 0-D box-model path, so it
            # cannot be applied here. Raising (rather than silently skipping an
            # intended state change, or AttributeError-ing on fields FunctionalAffect
            # never had) surfaces the limitation as a clear failure result via the
            # caller's error handling.
            raise SimulationError(
                f"FunctionalAffect (handler_id={affect.handler_id!r}) is not supported "
                f"by the legacy discrete-event path; only AffectEquation assignments "
                f"can be applied here"
            )

    return y_modified


def _check_discrete_event_condition(
    event: DiscreteEvent,
    t: float,
    y: np.ndarray,
    species_names: list[str],
    symbol_map: dict[str, sp.Symbol],
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
    if event.trigger.type != "condition":
        return False

    try:
        # Evaluate the condition expression
        condition_value = _evaluate_expression_at_state(
            event.trigger.value, y, species_names, symbol_map
        )
        # Convert to boolean (non-zero is True)
        return bool(condition_value)
    except Exception:
        # If condition evaluation fails, don't trigger
        return False


def _evaluate_expression_at_state(
    expr: Expr, y: np.ndarray, species_names: list[str], symbol_map: dict[str, sp.Symbol]
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
    # Constant expression
    return float(sympy_expr)


def _prepare_reaction_rhs(
    reaction_system: ReactionSystem,
    initial_conditions: dict[str, float],
) -> tuple[list[str], dict[str, sp.Symbol], np.ndarray, Callable[[float, np.ndarray], np.ndarray]]:
    """Shared mass-action RHS setup for both scalar reaction-system entry points.

    Lowers the reaction system to mass-action ODEs, resolves the initial-condition
    vector (explicit override > species ``default`` > 0.0, matching the flatten
    path in flatten.py ``_collect_reaction_system``), and lambdifies the ODE
    bodies into a clipped, non-finite-guarded ``rhs_function(t, y)``. Returns
    ``(species_names, symbol_map, y0, rhs_function)``; raises
    :class:`SimulationError` when the system has no species. Consolidates the
    setup that :func:`simulate_reaction_system` and
    :func:`simulate_with_discrete_events` previously duplicated verbatim.
    """
    species_names, ode_exprs = _generate_mass_action_odes(reaction_system)
    if not species_names:
        raise SimulationError("No species found in reaction system")

    symbol_map = {name: sp.Symbol(name) for name in species_names}
    species_defaults = {
        s.name: s.default for s in reaction_system.species if s.default is not None
    }
    y0 = np.array(
        [
            _resolve_override(name, initial_conditions, species_defaults.get(name))
            for name in species_names
        ]
    )

    variables = [symbol_map[name] for name in species_names]
    if variables and ode_exprs:
        rhs_funcs = [
            sp.lambdify(variables, expr, modules=_LAMBDIFY_MODULES) for expr in ode_exprs
        ]

        def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
            """Right-hand side function for the ODE system."""
            # Clip to prevent negative concentrations before evaluating rates.
            y_clipped = np.maximum(y, 0.0)
            dydt = np.array([func(*y_clipped) for func in rhs_funcs])
            if not np.all(np.isfinite(dydt)):
                raise SimulationError("Non-finite derivatives encountered")
            return dydt
    else:

        def rhs_function(t: float, y: np.ndarray) -> np.ndarray:
            return np.zeros_like(y)

    return species_names, symbol_map, y0, rhs_function


def _fire_condition_events(
    condition_events: list[DiscreteEvent],
    t_current: float,
    y_current: np.ndarray,
    species_names: list[str],
    symbol_map: dict[str, sp.Symbol],
    event_times: list[float],
) -> np.ndarray:
    """Fire every condition-triggered discrete event that holds at the current state.

    The full check sweep runs against the pre-application state (so events do not
    see each other's mid-sweep mutations), then the triggered events are applied
    in order, each recording its fire time in ``event_times``. Returns the
    (possibly updated) state vector. Consolidates the check/apply block that
    appeared twice verbatim in :func:`simulate_with_discrete_events`.
    """
    triggered = [
        event
        for event in condition_events
        if _check_discrete_event_condition(event, t_current, y_current, species_names, symbol_map)
    ]
    for event in triggered:
        y_current = _apply_discrete_event_effects(event, y_current, species_names, symbol_map)
        event_times.append(t_current)
    return y_current


def simulate_reaction_system(
    reaction_system: ReactionSystem,
    initial_conditions: dict[str, float],
    time_span: tuple[float, float],
    events: list[ContinuousEvent] | None = None,
    **solver_options,
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
        # Shared mass-action RHS setup (ODE gen, y0 resolution, lambdified rhs).
        species_names, symbol_map, y0, rhs_function = _prepare_reaction_rhs(
            reaction_system, initial_conditions
        )

        # Create event functions if events are provided
        event_functions = []
        if events:
            event_functions = _create_event_functions(events, symbol_map, species_names)

        # Set default solver options
        default_options = {
            "method": "LSODA",  # Good general-purpose method
            "rtol": 1e-6,
            "atol": 1e-8,
            "dense_output": False,
            "events": event_functions if event_functions else None,
        }
        default_options.update(solver_options)

        # Check scipy availability
        if not SCIPY_AVAILABLE:
            raise SimulationError(
                "SciPy is required for simulation but not available. Please install scipy."
            )

        # Solve the ODE system
        sol = solve_ivp(fun=rhs_function, t_span=time_span, y0=y0, **default_options)

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
            events=events_list,
        )

    except Exception as e:
        return _failure_result(f"Simulation failed: {e}")


def simulate_with_discrete_events(
    reaction_system: ReactionSystem,
    initial_conditions: dict[str, float],
    time_span: tuple[float, float],
    discrete_events: list[DiscreteEvent] | None = None,
    **solver_options,
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
        return simulate_reaction_system(
            reaction_system, initial_conditions, time_span, **solver_options
        )

    try:
        # Implement discrete event handling with manual stepping
        t_start, t_end = time_span
        dt = solver_options.pop("max_step", (t_end - t_start) / 100.0)  # Default step size

        # Sort events by trigger time/priority for time-based events
        time_events = []
        condition_events = []

        for event in discrete_events:
            if event.trigger.type == "time":
                time_events.append((float(event.trigger.value), event))
            elif event.trigger.type == "condition":
                condition_events.append(event)
            # Note: 'external' events would need external trigger mechanism

        # Sort time events by time
        time_events.sort(key=lambda x: x[0])

        # Shared mass-action RHS setup (ODE gen, y0 resolution, lambdified rhs).
        species_names, symbol_map, y_current, rhs_function = _prepare_reaction_rhs(
            reaction_system, initial_conditions
        )

        # Manual stepping with event handling
        t_current = t_start
        t_points = [t_current]
        y_points = [y_current.copy()]
        event_times = []

        # Set up solver options with more conservative defaults for manual stepping
        default_options = {
            "method": "RK45",  # Use more stable method for manual stepping
            "rtol": 1e-6,
            "atol": 1e-8,
            "dense_output": False,
            "max_step": dt / 10.0,  # Smaller steps for stability
        }
        default_options.update(solver_options)

        time_event_index = 0  # Index for next time event

        while t_current < t_end:
            # Determine next integration end time
            next_t = min(t_end, t_current + dt)

            # Check if there are time events before next_t
            while (
                time_event_index < len(time_events) and time_events[time_event_index][0] <= next_t
            ):
                event_time, event = time_events[time_event_index]

                if event_time > t_current:
                    # Check scipy availability
                    if not SCIPY_AVAILABLE:
                        raise SimulationError(
                            "SciPy is required for simulation but not available. Please install scipy."
                        )

                    # Integrate to event time
                    sol = solve_ivp(
                        fun=rhs_function,
                        t_span=(t_current, event_time),
                        y0=y_current,
                        **default_options,
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
                            nlu=sol.nlu,
                        )

                    # Update current state
                    t_current = event_time
                    y_current = sol.y[:, -1]
                    # Add intermediate points if any
                    if len(sol.t) > 1:
                        t_points.extend(sol.t[1:])  # Skip first point (duplicate)
                        y_points.extend(sol.y[:, 1:].T)  # Skip first point

                # Apply discrete event effects
                y_current = _apply_discrete_event_effects(
                    event, y_current, species_names, symbol_map
                )
                event_times.append(t_current)
                time_event_index += 1

            # Check + apply condition-based events at the current time point.
            y_current = _fire_condition_events(
                condition_events, t_current, y_current, species_names, symbol_map, event_times
            )

            # Continue integration to next_t if not already there
            if t_current < next_t:
                # Check scipy availability
                if not SCIPY_AVAILABLE:
                    raise SimulationError(
                        "SciPy is required for simulation but not available. Please install scipy."
                    )

                sol = solve_ivp(
                    fun=rhs_function, t_span=(t_current, next_t), y0=y_current, **default_options
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
                        nlu=sol.nlu,
                    )

                # Update current state
                t_current = sol.t[-1]
                y_current = sol.y[:, -1]
                # Add intermediate points if any
                if len(sol.t) > 1:
                    t_points.extend(sol.t[1:])  # Skip first point (duplicate)
                    y_points.extend(sol.y[:, 1:].T)  # Skip first point

            # Check + apply condition-based events after the integration step.
            y_current = _fire_condition_events(
                condition_events, t_current, y_current, species_names, symbol_map, event_times
            )

        return SimulationResult(
            t=np.array(t_points),
            y=np.array(y_points).T,
            vars=species_names,
            success=True,
            message=f"Simulation completed successfully with {len(event_times)} discrete events",
            nfev=0,  # Not tracking across multiple integrations
            njev=0,
            nlu=0,
            events=[np.array(event_times)] if event_times else None,
        )

    except Exception as e:
        return _failure_result(f"Discrete event simulation failed: {e}")
