"""Loader-segmented simulation pathway (data-loader cadence segmentation).

Implements the data-loader execution path of
:func:`earthsci_ast.simulation.simulate` — provider sampling / epoch
mapping / value-coercion helpers, cadence-boundary computation, and
:func:`_simulate_with_loaders`, which integrates a system in
piecewise-constant forcing segments, refreshing the loader arrays between
segments (RFC pure-io-data-loaders §4.3).
``earthsci_ast.simulation`` re-exports this module's API.
"""
from __future__ import annotations

import datetime as _dt
from typing import Any, Callable

import numpy as np

from .flatten import (
    FlattenedSystem,
    LoaderField,
    UnsupportedDimensionalityError,
)
from .simulation_array import (
    _build_numpy_rhs,
    _densify_solution,
    _element_names,
    _fill_build_inspection,
)
from .simulation_common import (
    DENSE_OUTPUT_MIN_POINTS,
    SimulationResult,
    _failure_result,
    solve_ivp,
)
from .sympy_bridge import SimulationError

# A loader provider executes one data-loader field at a simulation time and
# returns its current value as a flat float array. Time is the simulation
# clock (the same ``t`` the RHS sees); a const field is queried once at the
# start, a discrete field once per cadence segment. Inject a custom provider
# (e.g. a fixture stub) via ``simulate(..., loader_provider=...)``; the default
# executes the real loader I/O.
LoaderProvider = Callable[[LoaderField, float], "np.ndarray"]


def _provider_sample_field(provider: Any, t: float) -> np.ndarray:
    """Sample a top-level ``providers`` entry at simulation time ``t``.

    Accepts four duck-typed shapes so a fixture stub or a real EarthSciIO
    ``Provider`` both fit with no per-script glue (DESIGN pde_simulation_pipeline
    §2): a plain callable ``(t) -> array_like``; an object exposing ``sample(t)``;
    one exposing ``provider_sample(t)`` (the Julia-parity name); or a real
    EarthSciIO ``Provider`` (``materialize()`` / ``refresh()`` →
    ``NativeDataset``, plus ``refresh_times()``).

    The EarthSciIO branch is duck-typed on the ``materialize`` + ``refresh_times``
    contract so ESS keeps NO hard ``earthsciio`` import — the Python analog of the
    Julia weakdep extension (``EarthSciASTEarthSciIOExt``), keeping the
    two rigs decoupled (see ``data_loaders/esio_provider.py``). The ``providers=``
    seam samples ONCE at build time, so ``materialize()`` is the right entry
    (CONST reads the single file; DISCRETE primes at the window start), and the
    provider's native array is returned UNREORDERED — ESS is agnostic to
    dimension order and any [lat,lon]→[x,y] reconciliation is the model's job.
    One provider is bound per consumer variable, so exactly one data variable is
    expected; a multi-variable sample is a binding error the caller must split."""
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
    if hasattr(provider, "materialize") and hasattr(provider, "refresh_times"):
        # One provider is bound per consumer variable, so exactly one data
        # variable is expected; the single-variable extraction / error is shared
        # with the DISCRETE refresh path (:func:`_single_var_array`).
        return _single_var_array(provider.materialize())
    raise SimulationError(
        "provider must be callable (t)->array, expose sample(t) / "
        "provider_sample(t), or be an EarthSciIO Provider (materialize/"
        f"refresh_times); got {type(provider).__name__}"
    )


def _field_epoch(field: LoaderField) -> _dt.datetime | None:
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


def _sim_clock_epoch(flat: FlattenedSystem) -> _dt.datetime | None:
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


def _loader_file_variable(field: LoaderField) -> str | None:
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


def _extract_loader_var(native: Any, var: str, file_var: str | None = None) -> np.ndarray:
    """Pull ``var``'s raw values from a provider's native dataset.

    Accepts a :class:`~earthsci_ast.data_loaders.grid.GridLoadResult` or an
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


def _build_loader_target(flat: FlattenedSystem) -> Any | None:
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
    discrete_fields: list[LoaderField], t0: float, t1: float
) -> list[float]:
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

    boundaries: set[float] = set()
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
    discrete_fields: list[LoaderField],
    providers: dict[str, Any],
    epochs: dict[str, _dt.datetime | None],
    t0: float,
    t1: float,
) -> list[float]:
    """Interior cadence boundaries (sim-clock) from providers' refresh_times.

    Each discrete provider's :meth:`Provider.refresh_times` gives absolute
    cadence anchors; subtracting the loader epoch maps them onto the simulation
    clock. A provider that supplies no times (unbounded, or an in-tree provider
    without a usable epoch/frequency) falls back to local frequency arithmetic
    (:func:`_loader_cadence_boundaries`) so the behaviour degrades gracefully.
    Only strictly-interior boundaries ``t0 < b < t1`` are returned; the seed at
    ``t0`` and the final time ``t1`` are added by the caller.
    """
    boundaries: set[float] = set()
    for f in discrete_fields:
        provider = providers.get(f.name)
        epoch = epochs.get(f.name)
        times: list[Any] = []
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


def _run_cadence_segmented_solve(
    flat: FlattenedSystem,
    parameters: dict[str, float],
    initial_conditions: dict[str, float],
    method: str,
    rtol: float,
    atol: float,
    t0: float,
    seg_ends: list[float],
    loader_arrays: dict[str, np.ndarray],
    refresh_fn: Callable[[float], None],
    inspect: Any | None = None,
) -> SimulationResult:
    """The ONE discrete-cadence segmented solve — both the ``providers=`` seam
    (:func:`_simulate_with_discrete_providers`) and the ``loader_fields`` seam
    (:func:`_simulate_with_loaders`) route through this, so there is a single
    segmentation implementation rather than two parallel copies.

    ``loader_arrays`` is pre-seeded with the CONST loader fields; ``refresh_fn(when)``
    updates its DISCRETE entries to the cadence record covering the segment that
    starts at ``when`` seconds (idempotent at ``t0`` — a caller that already seeded
    the discrete fields simply re-seeds them). For each segment we call ``refresh_fn``
    and then REBUILD the RHS. Rebuilding is correct whether or not the NumPy build
    hoists a state-free, loader-derived regrid into build-once static geometry: a
    hoisted ``Era5Regrid.*_xy`` captures its loader input at build time, so a reused
    RHS with an in-place-mutated buffer would freeze it, whereas a rebuild always
    reflects the current segment's data (the Python analog of the Julia ``live_param``
    taint that defers the regrid off the const-setup partition). State is threaded
    across boundaries — continuous; only the forcing jumps. The build inspection, if
    given, is filled from the seed (t0) build."""
    per_seg_pts = max(11, (DENSE_OUTPUT_MIN_POINTS // len(seg_ends)) + 1)
    t_current = t0
    y_current: np.ndarray | None = None
    elem_names: list[str] = []
    t_chunks: list[np.ndarray] = []
    y_chunks: list[np.ndarray] = []
    nfev = njev = nlu = 0
    last_message = ""
    # Persist the loader-INVARIANT build products (join-key bins + the const regrid
    # GEOMETRY A_ij/A_j/W_ij) across segment rebuilds: only the loader-VOLATILE
    # observeds (the regrid APPLY W·field) change per segment, so the expensive
    # const geometry is materialized once at the seed build and reused, not
    # re-clipped every hour. Seeded on the seg-0 build; read on every later build.
    static_cache: dict[str, Any] = {}
    for seg_idx, seg_end in enumerate(seg_ends):
        # Refresh the discrete forcing to the hour covering this segment start,
        # then REBUILD the RHS so a const-hoisted regrid picks up the slice.
        refresh_fn(t_current)
        build = _build_numpy_rhs(
            flat,
            parameters,
            initial_conditions,
            loader_arrays=loader_arrays,
            static_cache=static_cache,
        )
        if seg_idx == 0:
            y_current = build.y0
            elem_names = _element_names(build.state_names, build.shapes)
            if inspect is not None:
                _fill_build_inspection(inspect, flat, build, t0, loader_arrays=loader_arrays)
        sol = solve_ivp(
            fun=build.rhs_function,
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
            return _failure_result(
                f"Simulation failed in cadence segment "
                f"[{t_current}, {seg_end}]: {sol.message}",
                nfev=nfev,
                njev=njev,
                nlu=nlu,
            )
        seg_t, seg_y = _densify_solution(sol, (t_current, seg_end), min_points=per_seg_pts)
        # Drop the seam node (shared with the previous segment's end; state is
        # continuous across a refresh, only the forcing jumps).
        if seg_idx == 0:
            t_chunks.append(seg_t)
            y_chunks.append(seg_y)
        else:
            t_chunks.append(seg_t[1:])
            y_chunks.append(seg_y[:, 1:])
        t_current = seg_end
        y_current = sol.y[:, -1]

    return SimulationResult(
        t=np.concatenate(t_chunks),
        y=np.concatenate(y_chunks, axis=1),
        vars=list(elem_names),
        success=True,
        message=last_message,
        nfev=nfev,
        njev=njev,
        nlu=nlu,
    )


def _simulate_with_loaders(
    flat: FlattenedSystem,
    tspan: tuple[float, float],
    parameters: dict[str, float],
    initial_conditions: dict[str, float],
    method: str,
    rtol: float = 1e-10,
    atol: float = 1e-12,
    loader_provider: LoaderProvider | None = None,
    provider_factory: Callable | None = None,
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
      :class:`~earthsci_ast.data_loaders.provider.Provider` is built per
      loader field at setup (the in-tree :class:`LoadDataProvider` by default, or
      an injected ``provider_factory`` — e.g. a real EarthSciIO provider).
      CONST → ``materialize()`` once, DISCRETE → ``refresh(t)`` at the seed and
      each boundary, with boundaries taken from ``Provider.refresh_times()``.
      Native arrays are bound RAW (on their native grid); any native→sim regrid
      is an in-model coupling expression the RHS evaluates (the obsolete regrid
      seam was removed in v0.8.0), not a bind-time transform."""
    try:
        t0, t1 = float(tspan[0]), float(tspan[1])

        const_fields = [f for f in flat.loader_fields if f.cadence == "const"]
        discrete_fields = [f for f in flat.loader_fields if f.cadence != "const"]

        # The shared registry the RHS reads each step. Mutated in place (never
        # rebound) so every per-step EvalContext sees the current segment's data.
        loader_arrays: dict[str, np.ndarray] = {}

        if loader_provider is not None:
            # Legacy seam: a per-call callable, kept for offline stub tests and
            # backward compatibility. Invoked once per segment (never per RHS);
            # boundaries from local frequency arithmetic.
            def _seed_const() -> None:
                for f in const_fields:
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
            # seed and each boundary. Native fields are bound RAW (on their native
            # grid); any native→sim regrid is an in-model coupling expression the
            # RHS evaluates (the obsolete regrid seam was removed in v0.8.0). The
            # `target` below is the data-FETCH domain (server-side subset bbox /
            # CDS area), NOT a regrid target.
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

            def _seed_const() -> None:
                for f in const_fields:
                    loader_arrays[f.name] = _provider_array(
                        f, providers[f.name].materialize(), target
                    )

            def _refresh_discrete(when: float) -> None:
                for f in discrete_fields:
                    loader_arrays[f.name] = _provider_array(
                        f, providers[f.name].refresh(_abs(f, when)), target
                    )

            seg_ends = _provider_segment_boundaries(discrete_fields, providers, epochs, t0, t1) + [
                t1
            ]

        # CONST loaders: execute ONCE before integration. The DISCRETE loaders are
        # seeded per segment by the shared core (via `_refresh_discrete`, starting
        # at t0), so they are read once per segment and never double-seeded.
        _seed_const()

        # One segmented driver for both loader seams: `_seed()` above already
        # materialized the CONST fields into `loader_arrays`; the shared core
        # re-seeds the DISCRETE fields per segment via `_refresh_discrete` and
        # rebuilds the RHS so a const-hoisted regrid tracks the current record.
        return _run_cadence_segmented_solve(
            flat,
            parameters,
            initial_conditions,
            method,
            rtol,
            atol,
            t0,
            seg_ends,
            loader_arrays,
            _refresh_discrete,
        )

    except UnsupportedDimensionalityError:
        raise
    except Exception as e:
        return _failure_result(f"Simulation failed: {e}")


# --------------------------------------------------------------------------- #
# Cadence-aware ``providers=`` path (top-level ``data_loaders`` injection seam).
#
# The plain ``providers=`` seam (``simulation.simulate``) materializes EVERY
# provider ONCE at t0 and integrates in a single shot — correct for a static
# loader (terrain, fuel), but a DISCRETE provider (hourly ERA5 met) then stays
# frozen at the ignition hour. The helpers below make that seam cadence-aware:
# CONST providers still materialize once, but a DISCRETE provider is re-sampled
# (its cadence record — the hour's ``valid_time`` slice) at every refresh
# boundary and the integration is segmented on those boundaries. This is the
# Python counterpart of the ESS-Julia ``simulate`` discrete-provider seam
# (``simulate.jl``): there a discrete provider is seeded into a LIVE
# ``param_arrays`` buffer and refreshed by the solver callback; here we rebuild
# the NumPy RHS per segment (see :func:`_simulate_with_discrete_providers`).
# --------------------------------------------------------------------------- #


def _provider_is_discrete(provider: Any) -> bool:
    """True if a ``providers=`` entry refreshes on a cadence (is DISCRETE).

    The definitive signal is a non-empty :meth:`Provider.refresh_times` (the
    EarthSciIO DISCRETE contract): a CONST provider (``is_const`` / no
    ``temporal``) returns ``[]``, and a plain callable / ``sample`` / bare stub
    exposes no ``refresh_times`` at all — so both stay on the materialize-once
    path and existing const runs are byte-for-byte unchanged.
    """
    if not (hasattr(provider, "refresh_times") and hasattr(provider, "refresh")):
        return False
    if getattr(provider, "is_const", False):
        return False
    try:
        return len(list(provider.refresh_times())) > 0
    except Exception:
        return False


def _provider_refresh_field(provider: Any, when: _dt.datetime) -> np.ndarray:
    """One DISCRETE provider's single data variable at absolute time ``when``.

    :meth:`Provider.refresh` snaps ``when`` to the loader cadence anchor and
    slices that record off the ``time_dim`` axis (the hour's ``valid_time`` for
    ERA5), so the returned native array is one lower rank than the multi-record
    file — e.g. ``[valid_time, pressure_level, lat, lon]`` → ``[pressure_level,
    lat, lon]``, matching the model's 3-D ``[era5_lev, era5_y, era5_x]`` field.
    One provider is bound per consumer variable, so a multi-variable dataset is a
    binding error (mirrors :func:`_provider_sample_field`).
    """
    nds = provider.refresh(when)
    return _single_var_array(nds)


def _single_var_array(nds: Any) -> np.ndarray:
    """The single data variable of a provider sample as a float array (raising if
    the sample carries more than one — one provider is bound per consumer var)."""
    names = (
        nds.variable_names()
        if hasattr(nds, "variable_names")
        else list(getattr(nds, "variables", {}) or {})
    )
    if len(names) != 1:
        raise SimulationError(
            f"EarthSciIO provider yields {len(names)} data variables "
            f"{sorted(names)}; bind one provider per consumer variable "
            "(providers={'Loader.var': provider}) so each sample is a single field"
        )
    return np.asarray(nds[names[0]].data, dtype=float)


def _provider_epoch(provider: Any, t0: float) -> _dt.datetime | None:
    """Absolute instant of simulation-clock ``t0`` for a DISCRETE provider.

    Sim-clock 0 is the run start; the runner anchors the provider ``window`` start
    at that instant (the ignition hour), so the epoch that maps a refresh anchor
    onto the sim clock is ``window[0] - t0``. Falls back to the first refresh
    anchor when the provider carries no window. Normalised to naive UTC so it
    compares cleanly with the (naive) cadence anchors.
    """
    win = getattr(provider, "window", None)
    anchor = win[0] if (win is not None and win[0] is not None) else None
    if anchor is None:
        try:
            times = list(provider.refresh_times())
        except Exception:
            times = []
        anchor = times[0] if times else None
    if anchor is None:
        return None
    if getattr(anchor, "tzinfo", None) is not None:
        anchor = anchor.astimezone(_dt.timezone.utc).replace(tzinfo=None)
    return anchor - _dt.timedelta(seconds=float(t0))


def _simulate_with_discrete_providers(
    flat: FlattenedSystem,
    tspan: tuple[float, float],
    parameters: dict[str, float],
    initial_conditions: dict[str, float],
    method: str,
    rtol: float,
    atol: float,
    providers: dict[str, Any],
    inspect: Any | None = None,
) -> SimulationResult:
    """Cadence-aware ``providers=`` integration: segment on the DISCRETE
    providers' refresh boundaries so a time-varying loader changes in-sim.

    CONST providers (terrain, fuel) are sampled ONCE (``materialize``) and bound
    as fixed loader arrays; each DISCRETE provider (hourly ERA5 met) is seeded at
    ``t0`` and re-sampled — its cadence record, the hour's ``valid_time`` slice —
    at every refresh boundary. Boundaries are the union of the discrete
    providers' :meth:`Provider.refresh_times`, mapped onto the sim clock through
    the provider epoch (:func:`_provider_epoch`).

    Because the NumPy build HOISTS a state-free, loader-derived regrid into the
    build-once static geometry (``_time_varying_observeds`` keys only off state /
    ``t``, never off a loader array), mutating the loader buffer in place would
    NOT refresh a hoisted ``Era5Regrid.*_xy``. So the RHS is **rebuilt per
    segment** with the refreshed loader arrays — the const-hoisted regrid then
    reflects the current hour, and the fire behaviour stack (EMC / MidflameWind /
    Rothermel) it feeds varies over the run. This is the Python analog of the
    Julia ``live_param`` taint that defers the regrid off the const setup
    partition. The build inspection is filled from the seed (t0) build, so
    ``setup_arrays`` still exposes the ignition-hour geometry the const path did.

    With no discrete provider the caller never routes here (it takes the
    materialize-once path), so existing const runs are unaffected.
    """
    try:
        t0, t1 = float(tspan[0]), float(tspan[1])

        discrete_names = [n for n, p in providers.items() if _provider_is_discrete(p)]
        const_names = [n for n in providers if n not in discrete_names]

        # Sim-clock ↔ datetime epoch. Prefer the run domain's reference_time
        # (shared by all loaders); else derive it per discrete provider from its
        # run window (the runner anchors the window start at the ignition hour =
        # the instant of sim-clock t0).
        sim_epoch = _sim_clock_epoch(flat)
        epochs: dict[str, _dt.datetime | None] = {
            n: (sim_epoch if sim_epoch is not None else _provider_epoch(providers[n], t0))
            for n in discrete_names
        }

        # Interior segment boundaries: the union of the discrete providers'
        # refresh anchors (hourly for ERA5) mapped onto the sim clock; only
        # strictly-interior (t0, t1) anchors split the integration.
        boundaries: set[float] = set()
        for n in discrete_names:
            epoch = epochs[n]
            if epoch is None:
                continue
            try:
                anchors = list(providers[n].refresh_times())
            except Exception:
                anchors = []
            for anchor in anchors:
                b = _delta_seconds(anchor, epoch)
                if t0 < b < t1:
                    boundaries.add(float(b))
        seg_ends = sorted(boundaries) + [t1]

        # Shared loader-array registry. CONST providers: materialized ONCE.
        # DISCRETE providers: seeded / refreshed by _refresh_discrete per segment.
        loader_arrays: dict[str, np.ndarray] = {}
        for n in const_names:
            loader_arrays[n] = np.asarray(_provider_sample_field(providers[n], t0), dtype=float)

        def _refresh_discrete(when_seconds: float) -> None:
            for n in discrete_names:
                epoch = epochs[n]
                if epoch is None:
                    # No epoch anchor → treat as const (materialize once at t0).
                    loader_arrays[n] = np.asarray(
                        _provider_sample_field(providers[n], t0), dtype=float
                    )
                else:
                    # A linear-interpolation loader returns the TWO bracketing
                    # records (size-2 leading time axis); it binds RAW to the
                    # consumer's 2-record loader field through this same path — the
                    # model derives its own interpolation weight from the fixed
                    # cadence (ERA5 t_interp_ref / dt_interp), so no timestamp
                    # injection is needed here.
                    abs_time = epoch + _dt.timedelta(seconds=float(when_seconds))
                    loader_arrays[n] = _provider_refresh_field(providers[n], abs_time)

        return _run_cadence_segmented_solve(
            flat,
            parameters,
            initial_conditions,
            method,
            rtol,
            atol,
            t0,
            seg_ends,
            loader_arrays,
            _refresh_discrete,
            inspect,
        )

    except UnsupportedDimensionalityError:
        raise
    except Exception as e:
        return _failure_result(f"Simulation failed: {e}")
