"""Scalar-SymPy simulation pathway (0-D / non-array ODE systems).

Implements the scalar-only branch of :func:`earthsci_ast.simulation.simulate`:
the flattened system is lowered to a lambdified SymPy RHS (via
:func:`earthsci_ast.sympy_bridge._compile_flat_rhs`), integrated with
:func:`scipy.integrate.solve_ivp`, and its algebraic-only states and observed
bindings are recovered along the output trajectory. This is the pathway used
when the flattened system contains no array ops, no data-loader fields, and no
top-level provider injections. It also owns :func:`_create_event_functions`,
the scalar continuous-event helper that builds SciPy root-finding callbacks
from a system's ``continuous_events``. ``earthsci_ast.simulation`` re-exports
this module's API and routes to :func:`_simulate_scalar`.
"""
from __future__ import annotations

from typing import Any, Callable

import numpy as np
import sympy as sp

from .esm_types import ContinuousEvent
from .flatten import (
    FlattenedSystem,
    UnsupportedDimensionalityError,
)
from .simulation_array import _densify_solution
from .simulation_common import (
    SimulationResult,
    _failure_result,
    _observed_rows,
    _resolve_override,
    solve_ivp,
)
from .sympy_bridge import (
    _LAMBDIFY_MODULES,
    SimulationError,
    _compile_flat_rhs,
    _expr_to_sympy,
)


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


def _resolve_parameter_values(
    flat: FlattenedSystem,
    parameter_names: list[str],
    parameter_overrides: dict[str, float],
) -> list[float]:
    """Resolve parameter values for a scalar simulate() call.

    Caller overrides win (dot-namespaced first, then bare name), then the
    flattened parameter metadata default, then 0. The returned list is
    aligned with ``parameter_names`` so it can be spliced into the
    lambdified function's argument tuple.
    """
    values: list[float] = []
    for pname in parameter_names:
        values.append(
            _resolve_override(pname, parameter_overrides, flat.parameters[pname].default)
        )
    return values


def _simulate_scalar(
    flat: FlattenedSystem,
    tspan: tuple[float, float],
    parameters: dict[str, float],
    initial_conditions: dict[str, float],
    method: str,
    rtol: float,
    atol: float,
    cse: bool,
) -> SimulationResult:
    """Integrate a scalar (non-array) flattened system via lambdified SymPy + SciPy.

    See :func:`earthsci_ast.simulation.simulate` for the full parameter contract;
    this is the extracted scalar pathway it routes to when the system has no
    array ops / loader fields / provider injections. Behaviour (and the public
    ``simulate()`` result) is identical to the previous inline implementation.
    """
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
            # 1001-node sampling grid for this stateless path (unrelated to
            # the dense-output budget ``DENSE_OUTPUT_MIN_POINTS``).
            t_out = np.linspace(t0_, t1_, 1001)
            if observed_names and observed_vector_func is not None:
                obs_vals = observed_vector_func(t_out, *param_values)
                y_out = _observed_rows(obs_vals, t_out.size)
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
        y0_list: list[float] = []
        for name in state_names:
            y0_list.append(
                _resolve_override(name, initial_conditions, flat.state_variables[name].default)
            )
        y0 = np.array(y0_list)

        # Override y0 for algebraic states so the t=0 sample is consistent.
        if algebraic_vector_func is not None:
            try:
                alg_vals_at_0 = np.asarray(algebraic_vector_func(*y0, *param_values), dtype=float)
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
            dydt = np.asarray(rhs_vector_func(*y_eval, *param_values), dtype=float)
            if not np.all(np.isfinite(dydt)):
                raise SimulationError("Non-finite derivatives encountered")
            return dydt

        event_functions: list[Callable] = []
        if flat.continuous_events:
            event_functions = _create_event_functions(
                flat.continuous_events, symbol_map, state_names
            )

        solver_options: dict[str, Any] = {
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
        out_vars: list[str] = list(state_names)
        if observed_names and y_out.size and observed_vector_func is not None:
            state_arrays = [y_out[i, :] for i in range(len(state_names))]
            obs_results = observed_vector_func(t_out, *state_arrays, *param_values)
            obs_block = _observed_rows(obs_results, t_out.size)
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
        return _failure_result(f"Simulation failed: {e}")
