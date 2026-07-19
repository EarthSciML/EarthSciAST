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
from __future__ import annotations

from typing import Any, Callable

import numpy as np

from .esm_types import (
    EsmFile,
)
from .flatten import (
    FlattenedSystem,
    UnsupportedDimensionalityError,
    _has_array_op,
    flatten,
)
from .simulation_array import (  # noqa: F401
    BuildInspection,
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
    _NumpyRhsBuild,
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

# Optional scipy import - only needed for actual simulation. The guard lives
# in simulation_common (shared by every pathway); the names are re-exported
# here so ``from earthsci_ast.simulation import SCIPY_AVAILABLE`` (and
# ``solve_ivp``) keep working.
from .simulation_common import (  # noqa: F401
    DENSE_OUTPUT_MIN_POINTS,
    SCIPY_AVAILABLE,
    SimulationResult,
    _failure_result,
    _observed_rows,
    _resolve_override,
    solve_ivp,
)

# ---------------------------------------------------------------------------
# Pathway submodules. simulation.py is the facade: it re-exports the full API
# (public and underscore-private) of the pathway submodules so every name
# historically importable from ``earthsci_ast.simulation`` keeps working.
# Import direction is acyclic: the submodules never import this module.
# ---------------------------------------------------------------------------
from .simulation_loaders import (  # noqa: F401
    LoaderProvider,
    _coerce_field_values,
    _delta_seconds,
    _extract_loader_var,
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
from .simulation_scalar import (  # noqa: F401
    _create_event_functions,
    _resolve_parameter_values,
    _simulate_scalar,
)
from .sympy_bridge import (
    SimulationError,  # noqa: F401 — re-exported (earthsci_ast.__init__ imports it here)
)


def simulate(
    file_or_flat: EsmFile | FlattenedSystem,
    tspan: tuple[float, float],
    parameters: dict[str, float] | None = None,
    initial_conditions: dict[str, float] | None = None,
    method: str = "LSODA",
    rtol: float = 1e-10,
    atol: float = 1e-14,
    cse: bool = True,
    loader_provider: LoaderProvider | None = None,
    provider_factory: Callable | None = None,
    providers: dict[str, Any] | None = None,
    inspect: BuildInspection | None = None,
) -> SimulationResult:
    """Simulate an ESM model via the flattened representation (spec §4.7.5).

    The flattened system is the canonical input. As a convenience, ``simulate``
    also accepts a raw :class:`EsmFile`; in that case it routes through
    :func:`flatten` internally so user-facing behaviour is unchanged.

    Parameters
    ----------
    file_or_flat:
        Either an :class:`EsmFile` (which is flattened internally) or an
        already-flattened :class:`FlattenedSystem`.
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
        return _failure_result("SciPy is required for simulation but not available.")

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

    # Scalar-only models: route to the scalar-SymPy pathway submodule
    # (:mod:`simulation_scalar`). No array ops, loader fields, or provider
    # injections reach here, so this is the plain lambdified-RHS + SciPy path.
    return _simulate_scalar(
        flat, tspan, parameters, initial_conditions, method, rtol, atol, cse
    )
