"""Loader-segmented simulation pathway (data-loader cadence segmentation).

Implements the data-loader execution path of
:func:`earthsci_toolkit.simulation.simulate` — provider sampling / epoch
mapping / value-coercion helpers, cadence-boundary computation, and
:func:`_simulate_with_loaders`, which integrates a system in
piecewise-constant forcing segments, refreshing the loader arrays between
segments (RFC pure-io-data-loaders §4.3).
``earthsci_toolkit.simulation`` re-exports this module's API.
"""

import datetime as _dt
import numpy as np
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

from .flatten import (
    FlattenedSystem,
    LoaderField,
    UnsupportedDimensionalityError,
)
from .sympy_bridge import SimulationError
from .simulation_common import (
    DENSE_OUTPUT_MIN_POINTS,
    SimulationResult,
    solve_ivp,
)
from .simulation_array import (
    _build_numpy_rhs,
    _densify_solution,
    _element_names,
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
    if (
        callable(provider)
        and not hasattr(provider, "sample")
        and not hasattr(provider, "provider_sample")
    ):
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
                    loader_arrays[f.name] = np.asarray(loader_provider(f, t0), dtype=float)
                for f in discrete_fields:
                    loader_arrays[f.name] = np.asarray(loader_provider(f, t0), dtype=float)

            def _refresh_discrete(when: float) -> None:
                for f in discrete_fields:
                    loader_arrays[f.name] = np.asarray(loader_provider(f, when), dtype=float)

            seg_ends = [
                b for b in _loader_cadence_boundaries(discrete_fields, t0, t1) if t0 < b < t1
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

            providers = {f.name: factory(f, _window(f)) for f in flat.loader_fields}

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

            seg_ends = _provider_segment_boundaries(discrete_fields, providers, epochs, t0, t1) + [
                t1
            ]

        # CONST loaders: execute ONCE before integration. DISCRETE loaders: seed
        # the first segment's value (refreshed at boundaries below).
        _seed()

        build = _build_numpy_rhs(flat, parameters, initial_conditions, loader_arrays=loader_arrays)
        rhs_function = build.rhs_function
        elem_names = _element_names(build.state_names, build.shapes)

        # Spread the dense-output budget across segments so a multi-segment run
        # does not multiply the per-segment grid (parity with the single-call
        # path when there is exactly one segment).
        per_seg_pts = max(11, (DENSE_OUTPUT_MIN_POINTS // len(seg_ends)) + 1)

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
                    t=np.array([]),
                    y=np.array([[]]),
                    vars=[],
                    success=False,
                    message=(
                        f"Simulation failed in cadence segment "
                        f"[{t_current}, {seg_end}]: {sol.message}"
                    ),
                    nfev=nfev,
                    njev=njev,
                    nlu=nlu,
                )
            seg_t, seg_y = _densify_solution(sol, (t_current, seg_end), min_points=per_seg_pts)
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
            t=t_out,
            y=y_out,
            vars=list(elem_names),
            success=True,
            message=last_message,
            nfev=nfev,
            njev=njev,
            nlu=nlu,
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
