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
Discretized PDEs simulate through this entry point too: once spatial
operators are rewritten to `arrayop` stencils, the spatial axis folds
into array dimensions (`independent_variables == ["t"]`) and the array pathway
integrates the system. The guard rejects only *undiscretized* spatial operators,
not PDEs. Remaining limitation: limited event support.
This enables atmospheric chemistry and discretized-PDE simulation in Python.
"""

import numpy as np
from typing import Dict, List, Tuple, Optional, Union, Any, Callable

# Optional scipy import - only needed for actual simulation. The guard lives
# in simulation_common (shared by every pathway); the names are re-exported
# here so ``from earthsci_ast.simulation import SCIPY_AVAILABLE`` (and
# ``solve_ivp``) keep working.
from .simulation_common import (  # noqa: F401
    DENSE_OUTPUT_MIN_POINTS,
    SCIPY_AVAILABLE,
    SimulationResult,
    solve_ivp,
)

from .esm_types import (
    ReactionSystem,
    ContinuousEvent,
    EsmFile,
)
from .flatten import (
    FlattenedSystem,
    UnsupportedDimensionalityError,
    _has_array_op,
    flatten,
)
from .sympy_bridge import (
    SimulationError,
    _compile_flat_rhs,
)

# ---------------------------------------------------------------------------
# Pathway submodules. simulation.py is the facade: it re-exports the full API
# (public and underscore-private) of the pathway submodules so every name
# historically importable from ``earthsci_ast.simulation`` keeps working.
# Import direction is acyclic: the submodules never import this module.
# ---------------------------------------------------------------------------
from .simulation_legacy import (  # noqa: F401
    _apply_discrete_event_effects,
    _check_discrete_event_condition,
    _create_event_functions,
    _evaluate_expression_at_state,
    _generate_mass_action_odes,
    simulate_reaction_system,
    simulate_with_discrete_events,
)
from .simulation_array import (  # noqa: F401
    BuildInspection,
    _NumpyRhsBuild,
    _aggregate_needs_interpreter,
    _apply_equation_to_dy,
    _apply_initial_conditions,
    _build_numpy_rhs,
    _collect_algebraic_substitutions,
    _densify_solution,
    _detect_value_invention_states,
    _element_names,
    _eval_buildtime_field,
    _expr_referenced_names,
    _fill_build_inspection,
    _fold_field_ics,
    _grid_coords_from_spatial,
    _iter_arrayop_points,
    _linear_pos,
    _materialize_join_key_buffers,
    _materialize_observeds,
    _order_observed_equations,
    _parse_element_key,
    _rebind_index_syms,
    _resolve_field_ic,
    _resolve_index_set_shape,
    _resolve_state_element,
    _scatter_arrayop_rhs,
    _simulate_with_numpy,
    _substitute_algebraic,
    _time_varying_observeds,
    _vi_lhs_base,
    evaluate_rhs,
)
from .simulation_loaders import (  # noqa: F401
    LoaderProvider,
    _build_loader_target,
    _coerce_field_values,
    _delta_seconds,
    _extract_loader_var,
    _factory_accepts_target,
    _field_epoch,
    _loader_cadence_boundaries,
    _loader_file_variable,
    _provider_array,
    _provider_epoch,
    _provider_is_discrete,
    _provider_refresh_field,
    _provider_sample_field,
    _provider_segment_boundaries,
    _sim_clock_epoch,
    _simulate_with_discrete_providers,
    _simulate_with_loaders,
)


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


# Backward compatibility: provide old function signature as alias
def simulate_legacy(
    reaction_system: ReactionSystem,
    initial_conditions: Dict[str, float],
    time_span: Tuple[float, float],
    events: Optional[List[ContinuousEvent]] = None,
    **solver_options,
) -> SimulationResult:
    """Legacy simulate function for backward compatibility."""
    return simulate_reaction_system(
        reaction_system, initial_conditions, time_span, events, **solver_options
    )


def simulate(
    file_or_flat: Union[EsmFile, FlattenedSystem],
    tspan: Tuple[float, float],
    parameters: Optional[Dict[str, float]] = None,
    initial_conditions: Optional[Dict[str, float]] = None,
    method: str = "LSODA",
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
        SciPy ODE solver method (default ``'LSODA'``).
    rtol, atol:
        Relative and absolute solver tolerances forwarded to
        :func:`scipy.integrate.solve_ivp`. Defaults are ``1e-10`` / ``1e-14``,
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
        :class:`~earthsci_ast.data_loaders.provider.Provider` per loader
        field (the EarthSciIO Provider contract: ``materialize`` / ``refresh`` /
        ``refresh_times``). When omitted (and no ``loader_provider`` is given)
        the in-tree
        :func:`~earthsci_ast.data_loaders.provider.build_default_provider`
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
        If the flattened system still has a spatial independent variable — a
        spatial operator that was never discretized into an ``arrayop`` stencil
        (spec §4.7.6.12). Discretized PDEs fold the spatial axis into array
        dimensions, leaving ``independent_variables == ["t"]``,
        and simulate normally through the array pathway.

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
            f"unlowered_operator: simulate() integrates systems whose only "
            f"independent variable is time (['t']), but the flattened system "
            f"still has spatial independent variables {spatial} — a spatial "
            f"operator that was not discretized. Apply the discretization "
            f"template (an `expression_templates` `match` rewrite) that lowers "
            f"it to an `arrayop` stencil, then simulate; discretized "
            f"PDEs run natively here."
        )

    parameters = parameters or {}
    initial_conditions = initial_conditions or {}

    if not SCIPY_AVAILABLE:
        return SimulationResult(
            t=np.array([]),
            y=np.array([[]]),
            vars=[],
            success=False,
            message="SciPy is required for simulation but not available.",
            nfev=0,
            njev=0,
            nlu=0,
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
        # Cadence-aware injection: if any provider is DISCRETE (non-empty
        # ``refresh_times``), segment the integration on its refresh boundaries so
        # a time-varying loader (hourly ERA5 met) changes in-sim, re-sampling the
        # provider's cadence record per segment. With NO discrete provider this is
        # byte-for-byte the historic materialize-once path (CONST providers only).
        if any(_provider_is_discrete(prov) for prov in providers.values()):
            return _simulate_with_discrete_providers(
                flat,
                tspan,
                parameters,
                initial_conditions,
                method,
                rtol,
                atol,
                providers,
                inspect,
            )
        loaded_arrays = {
            name: np.asarray(_provider_sample_field(prov, t0), dtype=float)
            for name, prov in providers.items()
        }
        return _simulate_with_numpy(
            flat,
            tspan,
            parameters,
            initial_conditions,
            method,
            rtol=rtol,
            atol=atol,
            loader_arrays=loaded_arrays,
            inspect=inspect,
        )

    # Data-loader injection (RFC pure-io-data-loaders §4.3): if the system has
    # loader fields, execute them at their cadence and bind the resulting arrays
    # into the RHS. Routes through the NumPy path (loader values are arrays).
    # Empty loader_fields ⇒ skipped entirely, so existing models are unaffected.
    if flat.loader_fields:
        return _simulate_with_loaders(
            flat,
            tspan,
            parameters,
            initial_conditions,
            method,
            rtol=rtol,
            atol=atol,
            loader_provider=loader_provider,
            provider_factory=provider_factory,
        )

    # Array-op detection: if any equation contains an array op, route through
    # the NumPy AST interpreter path. The legacy SymPy path handles scalar-only
    # models and is left untouched.
    has_array = any(_has_array_op(eq.lhs) or _has_array_op(eq.rhs) for eq in flat.equations)
    if has_array:
        return _simulate_with_numpy(
            flat,
            tspan,
            parameters,
            initial_conditions,
            method,
            rtol=rtol,
            atol=atol,
            inspect=inspect,
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
            # 1001-node sampling grid for this stateless path (unrelated to
            # the dense-output budget ``DENSE_OUTPUT_MIN_POINTS``).
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
