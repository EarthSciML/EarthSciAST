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
    url = (getattr(getattr(dl, "source", None), "url_template", "") or "")
    path = url.split("?", 1)[0].lower()
    if path.endswith((".nc", ".nc4", ".netcdf", ".cdf")):
        return "netcdf"
    if path.endswith((".csv", ".txt")):
        return "csv"
    if "format=tiff" in url.lower() or path.endswith((".tif", ".tiff")):
        return "tiff"
    ff = str(meta.get("file_format", "")).lower()
    if "netcdf" in ff:
        return "netcdf"
    if "tiff" in ff or "geotiff" in ff:
        return "tiff"
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
        return (_dt.timedelta(seconds=parse_iso_duration(spec).approximate_seconds())
                if spec else None)

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


def to_esio_loader(field: Any) -> Any:
    """Project an ESS ``LoaderField`` onto an ``earthsciio.DataLoader``."""
    import earthsciio as esio

    from .provider import _static_url_substitutions
    from .url_template import expand_with_mirrors

    dl = field.loader
    src = dl.source
    template = src.url_template
    mirrors = list(getattr(src, "mirrors", []) or [])
    # constant url fills (version/product/…); no target here ⇒ no server-side bbox
    # (the bbox-needing loaders are GeoTIFF, which EarthSciIO cannot read anyway).
    consts = _static_url_substitutions(dl, target=None)

    def url(anchor: _dt.datetime) -> str:
        return expand_with_mirrors(template, mirrors, date=anchor, variables=consts)[0]

    variables = [v.file_variable for v in dl.variables.values()
                 if getattr(v, "file_variable", None)]
    return esio.DataLoader(
        name=getattr(dl, "name", field.name),
        format=_esio_format(dl),
        url=url,
        variables=variables,
        temporal=_to_esio_temporal(getattr(dl, "temporal", None)),
    )


def esio_provider_factory(field: Any, window: Optional[Window] = None) -> Any:
    """A ``provider_factory`` building a real ``earthsciio.Provider`` for ``field``.

    Pass to ``simulate(..., provider_factory=esio_provider_factory)``. Requires
    ``earthsciio`` installed; the EarthSciIO ``Cache`` honours ``EARTHSCIDATADIR``.
    """
    import earthsciio as esio

    esio.register_format_readers()  # idempotent; ensures netcdf/csv are available
    return esio.Provider(to_esio_loader(field), esio.Cache(), window)
