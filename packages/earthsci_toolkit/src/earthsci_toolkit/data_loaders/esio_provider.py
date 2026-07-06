"""Adapter: serve an ESS ``LoaderField`` through a real EarthSciIO ``Provider``.

ESS keeps its in-tree :class:`~earthsci_toolkit.data_loaders.provider.LoadDataProvider`
as the default and does **not** import ``earthsciio`` on that path (the rigs are
deliberately decoupled — see provider.py). This module is the opt-in bridge:
:func:`esio_provider_factory` matches the ESS ``provider_factory`` contract
``(LoaderField, window) -> Provider`` and returns a real ``earthsciio.Provider``,
so a caller can run the loader seam through EarthSciIO's transport + content-
addressed cache (+ CDS, etc.)::

    from earthsci_toolkit.data_loaders.esio_provider import esio_provider_factory
    simulate(flat, tspan, provider_factory=esio_provider_factory)

It is intentionally NOT the default factory: EarthSciIO is an optional dependency
and currently registers readers only for ``netcdf`` / ``csv`` (a loader whose
format it lacks — e.g. the LANDFIRE / USGS 3DEP GeoTIFFs — raises
``BackendNotRegistered`` at construction). Wiring it unconditionally would couple
ESS to EarthSciIO and regress those formats, so it stays caller-selected.
"""

from __future__ import annotations

import datetime as _dt
from typing import Any, Optional, Tuple

Window = Tuple[_dt.datetime, _dt.datetime]


def _esio_format(dl: Any) -> str:
    """Infer the EarthSciIO format-registry key for an ESS DataLoader."""
    meta = getattr(dl, "metadata", None) or {}
    if meta.get("esio_format"):
        return str(meta["esio_format"])
    url = getattr(getattr(dl, "source", None), "url_template", "") or ""
    path = url.split("?", 1)[0].lower()
    if path.endswith((".nc", ".nc4", ".netcdf", ".cdf")):
        return "netcdf"
    if path.endswith((".csv", ".txt")):
        return "csv"
    if "format=tiff" in url.lower() or path.endswith((".tif", ".tiff")):
        return "geotiff"
    ff = str(meta.get("file_format", "")).lower()
    if "netcdf" in ff:
        return "netcdf"
    if "tiff" in ff or "geotiff" in ff:
        return "geotiff"
    if "csv" in ff:
        return "csv"
    raise ValueError(
        f"cannot infer an EarthSciIO format for loader {getattr(dl, 'name', '?')!r}; "
        f"set metadata.esio_format (e.g. 'netcdf')"
    )


def _to_esio_temporal(temporal: Any) -> Any:
    """Convert an ESS ``DataLoaderTemporal`` to an ``earthsciio.LoaderTemporal``
    (``None`` for a CONST loader)."""
    if temporal is None:
        return None
    import earthsciio as esio

    from .time_resolution import _coerce_datetime, parse_iso_duration

    start = getattr(temporal, "start", None)
    if not start:
        return None  # no anchor ⇒ treat as CONST

    def _dur(spec):
        return (
            _dt.timedelta(seconds=parse_iso_duration(spec).approximate_seconds()) if spec else None
        )

    freq = _dur(getattr(temporal, "frequency", None))
    file_period = _dur(getattr(temporal, "file_period", None)) or freq
    if freq is None:
        freq = file_period
    if freq is None or file_period is None:
        raise ValueError(
            "EarthSciIO temporal needs frequency + file_period; "
            f"loader temporal has frequency={getattr(temporal, 'frequency', None)!r} "
            f"file_period={getattr(temporal, 'file_period', None)!r}"
        )
    kwargs = dict(start=_coerce_datetime(start), frequency=freq, file_period=file_period)
    end = getattr(temporal, "end", None)
    if end:
        kwargs["end"] = _coerce_datetime(end)
    time_var = getattr(temporal, "time_variable", None)
    if time_var:
        kwargs["time_dim"] = time_var
    return esio.LoaderTemporal(**kwargs)


def _cds_metadata(dl: Any) -> Optional[dict]:
    """The loader's ``metadata.cds`` block (a CDS dataset descriptor), or ``None``.

    A loader opts into the CDS request path by carrying ``metadata.cds`` with a
    ``dataset`` id (e.g. ``reanalysis-era5-pressure-levels``) — parallel to the
    ``metadata.url_defaults`` that drives the ArcGIS bbox fills. ESS stays generic
    (it does not hard-code ERA5); it only sees "this loader resolves to CDS
    dataset X", and the esio-side ``era5`` request builder fills in the rest.
    """
    meta = getattr(dl, "metadata", None) or {}
    cds = meta.get("cds")
    if isinstance(cds, dict) and cds.get("dataset"):
        return cds
    return None


def _bbox_from_target(target: Any) -> Tuple[float, float, float, float]:
    """``(min_lon, min_lat, max_lon, max_lat)`` of the target grid's lon/lat env."""
    import numpy as np

    lon = np.asarray(getattr(target, "center_lon"))
    lat = np.asarray(getattr(target, "center_lat"))
    return float(lon.min()), float(lat.min()), float(lon.max()), float(lat.max())


def _window_bounds(window: Any) -> Tuple[Any, Any]:
    """``(start, end)`` datetimes from a ``simulate`` loader window — a
    ``(start, end)`` tuple/list or an object exposing ``.start``/``.end`` — or
    ``(None, None)`` when absent."""
    if window is None:
        return None, None
    if isinstance(window, (tuple, list)) and len(window) == 2:
        return window[0], window[1]
    return getattr(window, "start", None), getattr(window, "end", None)


def _to_esio_cds_loader(field: Any, target: Any, window: Any = None) -> Any:
    """Project a ``metadata.cds`` loader onto a CDS-backed ``earthsciio.DataLoader``.

    Builds a per-anchor ``cds://<dataset>?<request>`` URL resolver via the esio
    ``era5`` request builder: the ``area`` comes from the simulation domain
    (``target``), the variable list maps the loader's NetCDF short names to CDS
    long names, and the pressure levels come from ``metadata.cds.pressure_levels``
    (else the full ERA5 set). The downloaded asset is NetCDF, so ``format`` is
    ``netcdf`` and the registered ``cds`` transport performs the submit/poll/
    download against ``~/.cdsapirc`` credentials.
    """
    import calendar

    import earthsciio as esio
    from earthsciio import era5 as esio_era5

    dl = field.loader
    cds = _cds_metadata(dl)
    dataset = cds["dataset"]
    if dataset != esio_era5.ERA5_DATASET:
        raise NotImplementedError(
            f"no CDS request builder for dataset {dataset!r}; only "
            f"{esio_era5.ERA5_DATASET!r} is wired (earthsciio.era5)."
        )
    if target is None:
        raise ValueError(
            f"CDS loader {getattr(dl, 'name', field.name)!r} needs a spatial target "
            "to build the CDS 'area'; pass provider_factory with target= "
            "(simulate threads it from the domain)."
        )

    # NetCDF short names (what the file/reader carries) -> CDS long request names.
    short_to_long = {short: long for long, short in esio_era5.ERA5_VARIABLES.items()}
    file_vars = [getattr(v, "file_variable", None) for v in dl.variables.values()]
    file_vars = [v for v in file_vars if v]
    long_vars = [short_to_long[v] for v in file_vars if v in short_to_long]
    if not long_vars:
        raise ValueError(
            f"no CDS variables resolved from loader file_variables {file_vars!r}; "
            f"known ERA5 short names: {sorted(short_to_long)}"
        )

    min_lon, min_lat, max_lon, max_lat = _bbox_from_target(target)
    area = esio_era5.era5_area_from_bbox(min_lon, min_lat, max_lon, max_lat)
    levels = [int(p) for p in (cds.get("pressure_levels") or esio_era5.ERA5_PRESSURE_LEVELS_HPA)]

    # Calendar-correct months + day-trim from the simulation WINDOW when it is
    # available. This both (a) trims the request to the days actually simulated —
    # the whole-month request (all days × 24 h × 37 levels × 16 vars) blows past
    # the CDS cost limit — and (b) fixes a month error: the esio Provider's
    # file-period anchor drifts off calendar for ERA5's 1940 availability start
    # (P1M is approximated as a fixed-seconds period), so a November sim time can
    # resolve to an October anchor. era5_months_in_span computes the months from
    # the window by the calendar, ±3 h buffer. Without a window we fall back to
    # the anchor's whole month (the legacy path; used by unit tests).
    w_start, w_end = _window_bounds(window)
    months = (
        esio_era5.era5_months_in_span(w_start, w_end)
        if (w_start is not None and w_end is not None)
        else None
    )

    def url(anchor: _dt.datetime) -> str:
        # ERA5 files are monthly (one cds:// per (year, month) → one CDS job +
        # cached blob). With a window, request only its calendar month(s)/days;
        # pick the window month nearest the (possibly drifting) provider anchor.
        if months:
            year, month, days = min(
                months,
                key=lambda ym: abs((ym[0] * 12 + ym[1]) - (anchor.year * 12 + anchor.month)),
            )
        else:
            year, month = anchor.year, anchor.month
            days = list(range(1, calendar.monthrange(year, month)[1] + 1))
        return esio_era5.era5_cds_url(year, month, days, long_vars, levels, area)

    return esio.DataLoader(
        name=getattr(dl, "name", field.name),
        format=str(cds.get("format", "netcdf")),
        url=url,
        variables=file_vars,
        temporal=_to_esio_temporal(getattr(dl, "temporal", None)),
    )


def to_esio_loader(field: Any, target: Any = None, window: Any = None) -> Any:
    """Project an ESS ``LoaderField`` onto an ``earthsciio.DataLoader``.

    ``target`` is the simulation's lon/lat target grid; when present it fills the
    domain-derived URL parameters — the ArcGIS ImageServer ``{bbox…}``/image-size
    placeholders for the GeoTIFF loaders (LANDFIRE / USGS 3DEP), and the CDS
    ``area`` for a ``metadata.cds`` loader (ERA5). ``window`` is the simulation's
    absolute ``(start, end)`` time window; a CDS loader uses it to request only
    the calendar months/days actually simulated. A ``metadata.cds`` loader takes
    the CDS branch (:func:`_to_esio_cds_loader`); everything else expands its
    ``source.url_template`` directly.
    """
    if _cds_metadata(field.loader) is not None:
        return _to_esio_cds_loader(field, target, window)

    import earthsciio as esio

    from .provider import _static_url_substitutions
    from .url_template import expand_with_mirrors

    dl = field.loader
    src = dl.source
    template = src.url_template
    mirrors = list(getattr(src, "mirrors", []) or [])
    # constant url fills (version/product) + the domain-derived WGS84 bbox/image
    # size for the server-side-subsetting GeoTIFF loaders (now readable: gap G3).
    consts = _static_url_substitutions(dl, target=target)

    def url(anchor: _dt.datetime) -> str:
        return expand_with_mirrors(template, mirrors, date=anchor, variables=consts)[0]

    variables = [
        v.file_variable for v in dl.variables.values() if getattr(v, "file_variable", None)
    ]
    return esio.DataLoader(
        name=getattr(dl, "name", field.name),
        format=_esio_format(dl),
        url=url,
        variables=variables,
        temporal=_to_esio_temporal(getattr(dl, "temporal", None)),
    )


def esio_provider_factory(
    field: Any, window: Optional[Window] = None, *, target: Any = None
) -> Any:
    """A ``provider_factory`` building a real ``earthsciio.Provider`` for ``field``.

    Pass to ``simulate(..., provider_factory=esio_provider_factory)``. ``simulate``
    threads the domain ``target`` in (it introspects this ``target`` kwarg), which
    the loader projection needs for the GeoTIFF bbox / ERA5 CDS ``area``. Requires
    ``earthsciio`` installed; the EarthSciIO ``Cache`` honours ``EARTHSCIDATADIR``
    and the ``cds`` transport reads ``~/.cdsapirc`` for ERA5.
    """
    import earthsciio as esio

    esio.register_format_readers()  # idempotent; netcdf/csv/geotiff available
    return esio.Provider(to_esio_loader(field, target=target, window=window), esio.Cache(), window)
