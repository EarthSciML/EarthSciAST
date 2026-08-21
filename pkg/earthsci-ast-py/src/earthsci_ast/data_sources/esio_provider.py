"""Adapter: serve an ESS ``LoaderField`` through a real EarthSciIO ``Provider``.

ESS keeps its in-tree :class:`~earthsci_ast.data_sources.provider.LoadDataProvider`
as the default and does **not** import ``earthsciio`` on that path (the rigs are
deliberately decoupled — see provider.py). This module is the opt-in bridge:
:func:`esio_provider_factory` matches the ESS ``provider_factory`` contract
``(LoaderField, window) -> Provider`` and returns a real ``earthsciio.Provider``,
so a caller can run the loader seam through EarthSciIO's transport + content-
addressed cache (+ CDS, etc.)::

    from earthsci_ast.data_sources.esio_provider import esio_provider_factory
    simulate(flat, tspan, provider_factory=esio_provider_factory)

It is intentionally NOT the default factory: EarthSciIO is an optional dependency
and currently registers readers only for ``netcdf`` / ``csv`` (a loader whose
format it lacks — e.g. the LANDFIRE / USGS 3DEP GeoTIFFs — raises
``BackendNotRegistered`` at construction). Wiring it unconditionally would couple
ESS to EarthSciIO and regress those formats, so it stays caller-selected.
"""

from __future__ import annotations

import datetime as _dt
import sys
import threading
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

import numpy as np

from ..pushdown_rewrite import parse_select_axes
from .variables import apply_unit_conversion, parse_unit_conversion

Window = tuple[_dt.datetime, _dt.datetime]


if TYPE_CHECKING:  # structural contract only — no runtime import of earthsciio/ESS.
    from collections.abc import Mapping, Sequence
    from typing import Protocol

    class SourceLike(Protocol):
        """The ESS ``DataSourceLocation`` attribute surface this adapter reads."""

        url_template: str
        mirrors: Sequence[str]

    class VariableLike(Protocol):
        """The ESS ``DataSourceBinding`` attribute surface this adapter reads."""

        file_variable: str | None

    class TemporalLike(Protocol):
        """The ESS ``DataSourceTemporal`` attribute surface this adapter reads."""

        start: str | None
        end: str | None
        file_period: str | None
        frequency: str | None
        time_variable: str | None

    class LoaderLike(Protocol):
        """The ESS ``DataSource`` attribute surface this adapter reads. It has no
        ``variables`` map from 1.0.0: the per-variable binding lives on the
        consuming parameter, which is what a ``LoaderField`` describes."""

        name: str
        metadata: Mapping[str, Any]
        source: SourceLike
        temporal: TemporalLike | None

    class FieldLike(Protocol):
        """The ESS ``LoaderField`` attribute surface this adapter reads."""

        name: str
        var: str
        data_source: LoaderLike


def _esio_format(dl: LoaderLike) -> str:
    """Infer the EarthSciIO format-registry key for an ESS DataSource."""
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


def _temporal_field(temporal: Any, name: str) -> Any:
    """One field of a temporal block, whether it arrives as a typed object or as
    the raw JSON mapping ``providers_from_document`` works in.

    Both shapes reach :func:`_to_esio_temporal`. Reading only attributes made a
    mapping answer ``None`` to everything, so a declared cadence silently
    degraded to CONST rather than raising — the failure mode this whole function
    exists to avoid.
    """
    from collections.abc import Mapping as _Mapping  # runtime: the module-level
    # `Mapping` import is TYPE_CHECKING-only and would NameError here.

    if isinstance(temporal, _Mapping):
        return temporal.get(name)
    return getattr(temporal, name, None)


def _to_esio_temporal(temporal: TemporalLike | Mapping | None) -> Any:
    """Convert an ESS ``DataSourceTemporal`` to an ``earthsciio.SourceTemporal``
    (``None`` for a CONST loader)."""
    if temporal is None:
        return None
    import earthsciio as esio

    from .time_resolution import _coerce_datetime, parse_iso_duration

    start = _temporal_field(temporal, "start")
    if not start:
        return None  # no anchor ⇒ treat as CONST

    def _dur(spec):
        return (
            _dt.timedelta(seconds=parse_iso_duration(spec).approximate_seconds()) if spec else None
        )

    freq = _dur(_temporal_field(temporal, "frequency"))
    file_period = _dur(_temporal_field(temporal, "file_period")) or freq
    if freq is None:
        freq = file_period
    if freq is None or file_period is None:
        raise ValueError(
            "EarthSciIO temporal needs frequency + file_period; "
            f"loader temporal has frequency={_temporal_field(temporal, 'frequency')!r} "
            f"file_period={_temporal_field(temporal, 'file_period')!r}"
        )
    kwargs = {"start": _coerce_datetime(start), "frequency": freq, "file_period": file_period}
    end = _temporal_field(temporal, "end")
    if end:
        kwargs["end"] = _coerce_datetime(end)
    time_var = _temporal_field(temporal, "time_variable")
    if time_var:
        kwargs["time_dim"] = time_var
    return esio.SourceTemporal(**kwargs)


def _cds_metadata(dl: LoaderLike) -> dict | None:
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


def _bbox_from_target(target: Any) -> tuple[float, float, float, float]:
    """``(min_lon, min_lat, max_lon, max_lat)`` of the target grid's lon/lat env."""
    import numpy as np

    lon = np.asarray(target.center_lon)
    lat = np.asarray(target.center_lat)
    return float(lon.min()), float(lat.min()), float(lon.max()), float(lat.max())


def _window_bounds(window: Window | None) -> tuple[Any, Any]:
    """``(start, end)`` datetimes from a ``simulate`` loader window — a
    ``(start, end)`` tuple/list or an object exposing ``.start``/``.end`` — or
    ``(None, None)`` when absent."""
    if window is None:
        return None, None
    if isinstance(window, (tuple, list)) and len(window) == 2:
        return window[0], window[1]
    return getattr(window, "start", None), getattr(window, "end", None)


def _to_esio_cds_loader(field: FieldLike, target: Any, window: Window | None = None) -> Any:
    """Project a ``metadata.cds`` loader onto a CDS-backed ``earthsciio.DataSource``.

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

    dl = field.data_source
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
    # ONE field, one file variable: from 1.0.0 the binding is the consuming
    # parameter's, so a provider reads exactly the variable that parameter names.
    short_to_long = {short: long for long, short in esio_era5.ERA5_VARIABLES.items()}
    file_vars = [v for v in [getattr(field, "var", None)] if v]
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

    return esio.DataSource(
        name=getattr(dl, "name", field.name),
        format=str(cds.get("format", "netcdf")),
        url=url,
        variables=file_vars,
        temporal=_to_esio_temporal(getattr(dl, "temporal", None)),
    )


def to_esio_loader(field: FieldLike, target: Any = None, window: Window | None = None) -> Any:
    """Project an ESS ``LoaderField`` onto an ``earthsciio.DataSource``.

    ``target`` is the simulation's lon/lat target grid; when present it fills the
    domain-derived URL parameters — the ArcGIS ImageServer ``{bbox…}``/image-size
    placeholders for the GeoTIFF loaders (LANDFIRE / USGS 3DEP), and the CDS
    ``area`` for a ``metadata.cds`` loader (ERA5). ``window`` is the simulation's
    absolute ``(start, end)`` time window; a CDS loader uses it to request only
    the calendar months/days actually simulated. A ``metadata.cds`` loader takes
    the CDS branch (:func:`_to_esio_cds_loader`); everything else expands its
    ``source.url_template`` directly.
    """
    if _cds_metadata(field.data_source) is not None:
        return _to_esio_cds_loader(field, target, window)

    import earthsciio as esio

    from .provider import _static_url_substitutions
    from .url_template import expand_with_mirrors

    dl = field.data_source
    src = dl.source
    template = src.url_template
    mirrors = list(getattr(src, "mirrors", []) or [])
    # constant url fills (version/product) + the domain-derived WGS84 bbox/image
    # size for the server-side-subsetting GeoTIFF loaders (now readable: gap G3).
    consts = _static_url_substitutions(dl, target=target)

    def url(anchor: _dt.datetime) -> str:
        return expand_with_mirrors(template, mirrors, date=anchor, variables=consts)[0]

    variables = [v for v in [getattr(field, "var", None)] if v]
    return esio.DataSource(
        name=getattr(dl, "name", field.name),
        format=_esio_format(dl),
        url=url,
        variables=variables,
        temporal=_to_esio_temporal(getattr(dl, "temporal", None)),
    )


# --------------------------------------------------------------------------- #
# The DECLARED loader semantics (esm-spec §8.9) this module honours:
# ``reader_options`` (handed to the reader verbatim), a per-variable ``codes``
# map, a loader ``record_filter``, a per-axis ``select`` and the loader's own
# ``extent``. Everything here is read off the DOCUMENT — none of it is a
# caller-side transform any more. Mirrors the Rust
# ``earthsci_ast::esio_provider`` and the Julia EarthSciIO extension.
# --------------------------------------------------------------------------- #


@dataclass
class _CodeMap:
    """A loader variable's declared string→number code map (``codes``)."""

    map: dict[str, float]
    case_insensitive: bool = False
    #: ``"drop"`` (drop the whole RECORD), ``"error"``, or a substitute number.
    unmapped: Any = "error"

    def lookup(self, raw: Any, var: str) -> float | None:
        """The code for one raw cell, or ``None`` when it is unmapped and the
        declared policy is to drop the record."""
        key = str(raw).strip()
        if self.case_insensitive:
            key = key.upper()
        if key in self.map:
            return self.map[key]
        if self.unmapped == "drop":
            return None
        if self.unmapped == "error":
            raise ValueError(
                f"loader variable {var!r}: value {str(raw)!r} is not in its declared "
                f'`codes` map (set codes.unmapped to "drop" or a number to accept it)'
            )
        return float(self.unmapped)


@dataclass
class _ColumnSpec:
    """One column of a record-table loader: where it comes from and how its
    cells become numbers."""

    name: str
    file_variable: str
    codes: _CodeMap | None = None
    #: The declared ``unit_conversion`` (esm-spec §8.5), parsed; ``None`` when
    #: the variable declares none.
    unit_conversion: Any = None


def _is_text(arr: Any) -> bool:
    """Whether a decoded column carries text (the FF10 POLID case) rather than
    numbers — the distinction ``codes`` exists for."""
    a = np.asarray(arr)
    if a.dtype.kind in ("U", "S"):
        return True
    return a.dtype.kind == "O" and a.size > 0 and isinstance(a.reshape(-1)[0], (str, bytes))


def _widen(name: str, data: Any) -> np.ndarray:
    """Widen one numeric column to float64.

    A text column with NO ``codes`` map is a modelling mistake, not a silent
    drop: a loader wired to feed a model variable from a text column should
    fail at the boundary, never as an absent forcing much later
    (FORMAT-08-A-007).
    """
    if _is_text(data):
        raise ValueError(
            f"loader variable {name!r} decoded as strings; a model forcing must be "
            f"numeric (declare a `codes` map for it)"
        )
    return np.asarray(data, dtype=float)


class _RecordTable:
    """A record-table loader's decode, SHARED by its per-variable providers.

    A loader that declares a ``record_filter`` or a ``codes`` map is a TABLE,
    not a bag of independent arrays: which rows survive is a property of the
    whole RECORD, so every column must be filtered by the same mask or the
    columns silently misalign. That forces one decode — this object — rather
    than one per variable, which also means the 69 MB FF10 zip is unzipped and
    parsed once for all eight of its columns instead of eight times.

    Decoded lazily on first use and then held: ``prepare`` samples the
    providers one after another, and the second one must not re-read.
    """

    def __init__(
        self,
        loader_name: str,
        loader: Any,
        cache: Any,
        columns: list[_ColumnSpec],
        require_finite: list[str],
    ) -> None:
        self.loader_name = loader_name
        self.loader = loader
        self.cache = cache
        self.columns = list(columns)
        self.require_finite = list(require_finite)
        self._lock = threading.Lock()
        self._decoded: dict[str, np.ndarray] | None = None

    def column(self, name: str) -> np.ndarray:
        """The filtered column for loader variable ``name``."""
        cols = self._materialize()
        if name not in cols:
            raise ValueError(
                f"loader {self.loader_name!r} has no column {name!r} "
                f"(declared: {sorted(cols)})"
            )
        return cols[name]

    def _materialize(self) -> dict[str, np.ndarray]:
        with self._lock:
            if self._decoded is None:
                self._decoded = self._decode()
            return self._decoded

    def _decode(self) -> dict[str, np.ndarray]:
        import earthsciio as esio

        nds = esio.Provider(self.loader, self.cache).materialize()

        # Raw columns (unfiltered), plus the per-record keep mask the `codes`
        # drops and the finite requirement build up.
        raw: dict[str, np.ndarray] = {}
        keep: np.ndarray | None = None
        nrec: int | None = None
        for spec in self.columns:
            if spec.file_variable not in nds:
                raise ValueError(
                    f"loader {self.loader_name!r}: the reader returned no column "
                    f"{spec.file_variable!r} for variable {spec.name!r}"
                )
            f = nds[spec.file_variable]
            if len(f.shape) != 1:
                raise ValueError(
                    f"loader {self.loader_name!r} declares a record filter, but "
                    f"variable {spec.name!r} is rank {len(f.shape)} "
                    f"({list(f.shape)}); a record filter needs a single record axis"
                )
            n = int(f.shape[0])
            if nrec is None:
                nrec, keep = n, np.ones(n, dtype=bool)
            elif nrec != n:
                raise ValueError(
                    f"loader {self.loader_name!r}: column {spec.name!r} has {n} "
                    f"records but an earlier column has {nrec}; the reader did not "
                    f"return one aligned table"
                )
            assert keep is not None  # sized with the first column
            if spec.codes is None:
                raw[spec.name] = _widen(spec.name, f.data)
                continue
            if not _is_text(f.data):
                raise ValueError(
                    f"loader {self.loader_name!r} variable {spec.name!r} declares "
                    f"`codes`, but the column decoded as "
                    f"{np.asarray(f.data).dtype}; a code map maps a TEXT column "
                    f"to numbers"
                )
            values = np.empty(n, dtype=float)
            for i, cell in enumerate(f.data):
                code = spec.codes.lookup(cell, spec.name)
                if code is None:
                    keep[i] = False
                    values[i] = np.nan
                else:
                    values[i] = code
            raw[spec.name] = values

        n = nrec or 0
        if keep is None:
            keep = np.ones(0, dtype=bool)
        # `require_finite` names FILE variables (esm-spec §8.9): from 1.0.0 a
        # source declares no variables of its own, so the filter is stated in the
        # reader's vocabulary. Resolve it there -- through a bound parameter's
        # already-decoded column when one reads it, and straight from the reader
        # otherwise, since a source may filter on a column no parameter reads.
        by_file: dict[str, np.ndarray] = {}
        for spec in self.columns:
            by_file.setdefault(spec.file_variable, raw[spec.name])
        for name in self.require_finite:
            if name in by_file:
                col = by_file[name]
            elif name in nds:
                col = _widen(name, nds[name].data)
            else:
                raise ValueError(
                    f"loader {self.loader_name!r}: record_filter.require_finite "
                    f"names file variable {name!r}, which the source does not "
                    f"deliver"
                )
            if len(col) != n:
                raise ValueError(
                    f"loader {self.loader_name!r}: record_filter.require_finite "
                    f"column {name!r} has {len(col)} records but the table has {n}"
                )
            keep &= np.isfinite(col)

        kept = int(keep.sum())
        out = {name: col[keep] for name, col in raw.items()}
        if kept != n:
            # The record count IS the loader's extent, so say what was dropped.
            print(
                f"  [esio] loader {self.loader_name!r}: {n} records read, {kept} "
                f"kept by its declared record filter",
                file=sys.stderr,
                flush=True,
            )
        return out


def _apply_axes(key: str, arr: np.ndarray, axes: list[Any]) -> np.ndarray:
    """Apply a declared ``select`` to an already-materialized array: take each
    axis's indices, then DROP the ``fixed`` axes (which come back length 1)."""
    if len(axes) != arr.ndim:
        raise ValueError(
            f"provider {key!r}: the declared select has {len(axes)} axes but the "
            f"array is rank {arr.ndim} ({list(arr.shape)})"
        )
    out = arr
    for i, ax in enumerate(axes):
        if ax == "all":
            continue
        if "gated_by" in ax:
            raise ValueError(
                f"provider {key!r}: axis {i} gates on {ax['gated_by']!r}, which is "
                f"resolved by value-invention inside prepare, not by an eager sample"
            )
        if "fixed" in ax:
            idx = [int(ax["fixed"])]
        else:
            r = ax["range"]
            idx = list(range(r["start"], r["stop"], r["step"]))
        dim = out.shape[i]
        over = [g for g in idx if g >= dim]
        if over:
            raise ValueError(
                f"provider {key!r}: the declared select reaches index {over[0]} on "
                f"axis {i}, whose native length is {dim}"
            )
        out = np.take(out, idx, axis=i)
    drop = {i for i, ax in enumerate(axes) if isinstance(ax, dict) and "fixed" in ax}
    if not drop:
        return out
    # Fixed axes are length-1 by construction now; drop them.
    return out.reshape(tuple(s for i, s in enumerate(out.shape) if i not in drop))


def _to_reader_select(axes: list[Any]) -> dict[str, Any]:
    """The reader-side spelling of a declared ``select`` carrying no ``gated_by``
    axis — what a store-backed reader can fetch pre-sliced."""
    out: list[Any] = []
    for ax in axes:
        if ax == "all":
            out.append("all")
        elif "fixed" in ax:
            out.append({"indices": [int(ax["fixed"])]})
        elif "range" in ax:
            r = ax["range"]
            out.append({"slice": [r["start"], r["stop"], r["step"]]})
        else:  # unreachable: a gated axis defers, it is never pushed eagerly
            out.append("all")
    return {"axes": out}


def _neutral_to_native(selection: list[Any]) -> dict[str, Any]:
    """The engine's neutral per-axis selection (``"all"`` | 0-based index list),
    in EarthSciIO's native ``{"axes": [...]}`` spelling."""
    return {
        "axes": [
            "all" if ax == "all" else {"indices": [int(i) for i in ax]}
            for ax in selection
        ]
    }


def _single_field(key: str, nds: Any) -> np.ndarray:
    """The single data variable of a sample (one provider per fed variable)."""
    names = sorted(nds.variables)
    if len(names) != 1:
        raise ValueError(
            f"provider {key!r} expects exactly one field per provider, got {names}; "
            f"construct one provider per variable (providers_from_document does)"
        )
    return _widen(names[0], nds.variables[names[0]].data)


class EsioDocumentProvider:
    """One document-declared loader VARIABLE, served through EarthSciIO.

    The Python peer of the Rust ``EsioProvider``: it carries the loader's
    declared §8.9 semantics so that ``prepare`` sees a plain array, already
    decoded (``reader_options``), coded (``codes``), filtered (``record_filter``)
    and selected (``select``) — and can ask it for the metaparameter its own
    delivered extent binds.

    Duck-typed onto the ESS provider seam (``sample(t)`` /
    ``sample(t, selection=…)`` / ``supports_selection`` / ``gate_spec`` /
    ``extent_metaparameter``) rather than onto EarthSciIO's ``Provider``, so the
    engine's gated fetch reaches THIS object and its declared select is honoured
    exactly once.
    """

    def __init__(
        self,
        key: str,
        inner: Any,
        *,
        table: _RecordTable | None = None,
        column: str | None = None,
        declared: list[Any] | None = None,
        extent_metaparameter: str | None = None,
        unit_conversion: Any = None,
    ) -> None:
        self.key = key
        self._inner = inner
        self._table = table
        self._column = column
        #: The variable's declared ``unit_conversion`` (esm-spec §8.5), parsed.
        #: ``None`` for a variable that declares none — in which case delivery
        #: is bit-for-bit what it was before this existed.
        self._unit_conversion = unit_conversion
        #: The metaparameter this provider's delivered extent BINDS (``extent``).
        self.extent_metaparameter = extent_metaparameter
        self._reader_select: dict[str, Any] | None = None
        self._drop_axes: tuple[int, ...] = ()
        self._engine_axes: list[Any] | None = None
        if declared is not None:
            # Where a declared select is applied is an OPTIMIZATION, not a
            # semantic (esm-spec §8.9.2): pushed to the reader when the reader
            # can fetch pre-sliced and no rows are filtered first, else applied
            # engine-side after the decode. Both deliver the same array. A
            # `gated_by` axis always defers — it is resolved by value-invention,
            # which has not run yet.
            gated = any(isinstance(a, dict) and "gated_by" in a for a in declared)
            if not gated and table is None and bool(inner.supports_selection):
                self._reader_select = _to_reader_select(declared)
                self._drop_axes = tuple(
                    i for i, a in enumerate(declared)
                    if isinstance(a, dict) and "fixed" in a
                )
            else:
                self._engine_axes = list(declared)

    # -- introspection ------------------------------------------------------ #

    @property
    def supports_selection(self) -> bool:
        """Whether a per-axis selection can be pushed to the bound reader.

        A record-table column never can: its rows are chosen by the loader's
        declared filter AFTER the decode, so an index pushed to the reader would
        address raw rows rather than the delivered ones.
        """
        return self._table is None and bool(self._inner.supports_selection)

    @property
    def is_const(self) -> bool:
        return bool(getattr(self._inner, "is_const", True))

    @property
    def gate_spec(self) -> dict[str, Any] | None:
        """A declared ``select`` carrying a ``gated_by`` axis IS a
        provider-declared gate: ``prepare`` defers it past value-invention and
        fetches it pre-sliced to the materialised members."""
        axes = self._engine_axes
        if axes is None or not any(
            isinstance(a, dict) and "gated_by" in a for a in axes
        ):
            return None
        return {"axes": list(axes), "applies_to": [self.key.rsplit(".", 1)[-1]]}

    def refresh_times(self) -> list:
        return list(self._inner.refresh_times())

    # -- sampling ----------------------------------------------------------- #

    def sample(self, t: float = 0.0, selection: list[Any] | None = None) -> np.ndarray:
        """This variable's delivered array.

        ``selection`` is the engine's resolved gated selection (pushdown hook 2);
        it IS the whole selection for this fetch, so the declared select is not
        applied a second time on top of it.
        """
        if selection is not None:
            nds = self._inner.materialize(select=_neutral_to_native(selection))
            return self._convert_units(_single_field(self.key, nds))
        if self._table is not None:
            arr = self._table.column(str(self._column))
        else:
            arr = _single_field(self.key, self._inner.materialize(select=self._reader_select))
        return self._convert_units(self._apply_declared(arr))

    def refresh(self, when: Any) -> np.ndarray:
        """The DISCRETE cadence entry (delegated), under the same declared
        select. ``providers_from_document`` builds CONST loaders today, so this
        exists for shape rather than for a live caller."""
        if self._table is not None:
            raise ValueError(
                f"provider {self.key!r} serves a filtered record table, which has "
                f"no cadence to refresh on"
            )
        nds = self._inner.refresh(when, select=self._reader_select)
        return self._convert_units(self._apply_declared(_single_field(self.key, nds)))

    def _convert_units(self, arr: np.ndarray) -> np.ndarray:
        """Produce the values in the variable's DECLARED ``units``.

        esm-spec §8.5 is normative: ``unit_conversion`` "is either a plain
        multiplicative factor or a full Expression AST (§4); the runtime applies
        it when producing values in the declared ``units``". Applied at
        DELIVERY, after the loader's decode / codes / record filter / select —
        so the filter still reasons about the raw column (a conversion cannot
        turn a dropped record into a kept one) and every axis of the delivered
        array is converted exactly once, whether it arrived through the table,
        the reader-pushed select, or the engine's gated fetch.

        A variable with no declared conversion returns ``arr`` unchanged: adding
        this is a no-op for every document that does not declare one.
        """
        if self._unit_conversion is None:
            return arr
        out = apply_unit_conversion(
            arr, self._unit_conversion, variable_name=self.key
        )
        return np.asarray(out, dtype=float)

    def _apply_declared(self, arr: np.ndarray) -> np.ndarray:
        if self._engine_axes is not None:
            return _apply_axes(self.key, arr, self._engine_axes)
        if self._drop_axes:
            # The reader already sliced; only the `fixed` axes still need dropping.
            axes = [
                {"fixed": 0} if i in self._drop_axes else "all" for i in range(arr.ndim)
            ]
            return _apply_axes(self.key, arr, axes)
        return arr


def _resolve_range_bounds(doc: Any, ctx: str, ax: Any) -> Any:
    """Replace any metaparameter-NAMED ``range`` bound with its document default.

    So a loader can say ``W[0:N_SRC]`` in the model's own terms instead of
    repeating 52411 and drifting from the index set sized by the same
    metaparameter (esm-spec §8.9.2).
    """
    if not isinstance(ax, dict) or not isinstance(ax.get("range"), dict):
        return ax
    out = dict(ax["range"])
    mps = doc.get("metaparameters") if isinstance(doc, dict) else None
    for bound in ("start", "stop", "step"):
        name = out.get(bound)
        if not isinstance(name, str):
            continue
        entry = mps.get(name) if isinstance(mps, dict) else None
        default = entry.get("default") if isinstance(entry, dict) else None
        if not isinstance(default, int) or isinstance(default, bool):
            raise ValueError(
                f"{ctx}.select: range.{bound} names {name!r}, which is not a "
                f"metaparameter with an integer default"
            )
        out[bound] = int(default)
    return {"range": out}


def _parse_declared_select(doc: Any, ctx: str, node: Any) -> list[Any] | None:
    """A ``select.axes`` declaration on a data source or on one of the parameter
    bindings that reads it."""
    sel = node.get("select") if isinstance(node, dict) else None
    if sel is None:
        return None
    axes = sel.get("axes") if isinstance(sel, dict) else None
    if not isinstance(axes, list):
        raise ValueError(f'{ctx}.select needs an "axes" array')
    resolved = [_resolve_range_bounds(doc, ctx, ax) for ax in axes]
    return parse_select_axes(f"{ctx}.select", resolved)


def _parse_codes(ctx: str, vd: Any) -> _CodeMap | None:
    """A data-source binding's ``codes`` map (text column → number)."""
    codes = vd.get("codes") if isinstance(vd, dict) else None
    if codes is None:
        return None
    mapping = codes.get("map") if isinstance(codes, dict) else None
    if not isinstance(mapping, dict):
        raise ValueError(f'{ctx}.codes needs a "map" object')
    case_insensitive = bool(codes.get("case_insensitive", False))
    unmapped = codes.get("unmapped", "error")
    if unmapped not in ("drop", "error"):
        if isinstance(unmapped, bool) or not isinstance(unmapped, (int, float)):
            raise ValueError(
                f'{ctx}.codes.unmapped must be "drop", "error" or a number'
            )
        unmapped = float(unmapped)
    out: dict[str, float] = {}
    for k, v in mapping.items():
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise ValueError(f"{ctx}.codes.map[{str(k)!r}] must be a number")
        out[str(k).upper() if case_insensitive else str(k)] = float(v)
    return _CodeMap(map=out, case_insensitive=case_insensitive, unmapped=unmapped)


def _document_bindings(doc: dict) -> dict[str, list[tuple[str, str, dict]]]:
    """``{data_sources key -> [(flattened parameter name, local name, binding)]}``.

    From 1.0.0 a data source declares no variables: the CONSUMING PARAMETER
    carries `update: {kind: "data", source, from: {file_variable, ...}}` and owns
    the units (esm-spec §8.5). This is the inversion of the 0.x
    `data_loaders[l].variables` map, and it is where the provider path now reads
    what to decode.

    The flattened name is the parameter's namespaced path
    (``"Ingest.lon"``, ``"Parent.Child.lon"``), which is what keys the provider:
    it is the only spelling that names one parameter and every parameter. Neither
    half of the source-qualified alternative works -- two parameters may read one
    `file_variable` differently (the ingest fixture's `W` / `src_W` / `emis_W`
    all read `Grid`'s `W`), and two models may declare the same parameter name
    against one source.

    Parameters are collected across every model and nested subsystem, walked in
    sorted order, so the constructed provider set -- and therefore the
    diagnostics -- are deterministic.
    """
    out: dict[str, list[tuple[str, str, dict]]] = {}

    def visit(model: Any, prefix: str) -> None:
        if not isinstance(model, dict):
            return
        for vname in sorted((model.get("variables") or {}).keys()):
            vdef = (model.get("variables") or {})[vname]
            if not isinstance(vdef, dict) or vdef.get("type") != "parameter":
                continue
            update = vdef.get("update")
            rules = update if isinstance(update, list) else [update]
            for rule in rules:
                if not isinstance(rule, dict) or rule.get("kind") != "data":
                    continue
                binding = rule.get("from")
                source = rule.get("source")
                if not isinstance(binding, dict) or not isinstance(source, str):
                    continue
                key = f"{prefix}.{vname}" if prefix else str(vname)
                out.setdefault(source, []).append((key, str(vname), binding))
                break  # the FIRST data rule of an `update` (esm-spec §5.4)
        for sname in sorted((model.get("subsystems") or {}).keys()):
            sub = (model.get("subsystems") or {})[sname]
            visit(sub, f"{prefix}.{sname}" if prefix else str(sname))

    for mname in sorted((doc.get("models") or {}).keys()):
        visit((doc.get("models") or {})[mname], str(mname))
    for entries in out.values():
        entries.sort(key=lambda kv: kv[0])
    return out


def providers_from_document(
    doc: Any,
    *,
    cache_root: str,
    loaders: Any = None,
    url_overrides: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Document-declared provider construction (Phase 3 clean consolidation) —
    the Python mirror of the Julia EarthSciIO extension's
    ``providers_from_document``. The document's ``data_sources`` say WHAT to read
    (``source.url_template``) and ``metadata.esio_format`` says HOW (the
    EarthSciIO format-registry name); the PARAMETERS say which ``file_variable``
    each consumer wants and how to convert it. The runner no longer
    hand-constructs providers — it asks the document.

    One provider PER CONSUMING PARAMETER (keyed ``"<Source>.<parameter>"``),
    matching (a) ``prepare``'s providers contract (one provider per consumer
    variable), (b) the single-variable sample the provider seam expects, and (c)
    the per-key gate the record-derived pushdown path attaches. All of a source's
    providers share one ``Cache`` (a per-source subdir under ``cache_root``) so a
    store's metadata objects are fetched once.

    ``doc`` is a raw document dict or a path to one. ``loaders`` restricts to the
    named sources (each MUST be constructible — a missing ``metadata.esio_format``
    raises); an unrestricted sweep skips format-less sources. ``url_overrides``
    maps a source name to a replacement URL (e.g. a local ``file://`` mirror of
    the canonical source).
    """
    import json
    import os as _os

    import earthsciio as esio

    if isinstance(doc, (str, bytes)):
        with open(doc) as fh:
            doc = json.load(fh)
    dss = doc.get("data_sources") if isinstance(doc, dict) else None
    if not isinstance(dss, dict):
        raise ValueError("providers_from_document: the document declares no data_sources")
    esio.register_format_readers()
    want = None if loaders is None else {str(x) for x in loaders}
    overrides = url_overrides or {}
    bindings = _document_bindings(doc)
    out: dict[str, Any] = {}
    # Deterministic construction (and therefore deterministic diagnostics) —
    # the Rust peer sorts its provider list for the same reason.
    for lname in sorted(map(str, dss)):
        ld = dss[lname]
        if want is not None and lname not in want:
            continue
        if not isinstance(ld, dict):
            continue
        md = ld.get("metadata")
        fmt = md.get("esio_format") if isinstance(md, dict) else None
        if fmt is None:
            if want is None:
                continue
            raise ValueError(
                f"providers_from_document: data_sources.{lname} declares no "
                f"metadata.esio_format — cannot construct a provider for it"
            )
        src = ld.get("source")
        url = overrides.get(
            lname, src.get("url_template") if isinstance(src, dict) else None
        )
        if not isinstance(url, str):
            raise ValueError(
                f"providers_from_document: data_sources.{lname} has no "
                f"source.url_template (and no url_overrides entry)"
            )
        consumers = bindings.get(lname) or []
        if not consumers:
            continue
        cache = esio.Cache(root=_os.path.join(str(cache_root), lname))

        # ---- the source's DECLARED decode semantics (esm-spec §8.9) --------
        reader_options = ld.get("reader_options") or {}
        if not isinstance(reader_options, dict):
            raise ValueError(
                f"providers_from_document: data_sources.{lname}.reader_options "
                f"must be an object of format-specific decode options"
            )
        source_select = _parse_declared_select(doc, f"data_sources.{lname}", ld)
        extent = ld.get("extent")
        extent_mp = extent.get("metaparameter") if isinstance(extent, dict) else None
        extent_mp = str(extent_mp) if isinstance(extent_mp, str) else None
        rfilter = ld.get("record_filter")
        require_finite = (
            [str(v) for v in (rfilter.get("require_finite") or [])]
            if isinstance(rfilter, dict)
            else []
        )

        specs = [
            _ColumnSpec(
                # The column's identity is the CONSUMING PARAMETER's flattened
                # name: two models may bind a same-named parameter to one source
                # with different `file_variable`s, and the decoded columns must
                # not collide.
                name=key,
                file_variable=str(binding.get("file_variable", vname)),
                codes=_parse_codes(f"{key}.update.from", binding),
                unit_conversion=parse_unit_conversion(
                    binding.get("unit_conversion"), variable_name=key
                ),
            )
            for key, vname, binding in consumers
        ]

        # The source's declared cadence, converted once. Without this the loader
        # was built with no `temporal` at all, so EarthSciIO saw CONST for every
        # source no matter what the document said: an hourly source read its
        # first file once and served it forever, with no warning (esm-spec §8.9).
        # It is also load-bearing for caching — EarthSciIO treats an absent
        # `temporal` as IMMUTABLE and will never revalidate it, so silently
        # dropping a declared cadence here does not merely ignore it, it pins
        # stale bytes in the cache permanently.
        declared_temporal = _to_esio_temporal(ld.get("temporal"))

        def _loader(
            vars_: list[str], _l=lname, _f=fmt, _u=url, _o=reader_options,
            _t=declared_temporal,
        ):
            return esio.DataSource(
                name=_l, format=str(_f), url=_u, variables=vars_,
                reader_kwargs=dict(_o), temporal=_t,
            )

        # A record filter or a code map makes the source a TABLE: one decode,
        # one keep mask, columns that stay aligned.
        table = None
        if require_finite or any(s.codes is not None for s in specs):
            table = _RecordTable(
                lname,
                # A `require_finite` column no parameter reads is still
                # needed to compute the mask, so it is fetched alongside.
                _loader(sorted({s.file_variable for s in specs} | set(require_finite))),
                cache,
                specs,
                require_finite,
            )

        for spec, (key, _vname, binding) in zip(specs, consumers):
            declared = _parse_declared_select(doc, f"{key}.update.from", binding)
            if declared is None and source_select is not None:
                declared = list(source_select)
            # Resolving the reader NOW (rather than mid-solve) is also what
            # rejects an unrecognised `reader_options` key: EarthSciIO checks
            # the declared decode options against the bound reader at Provider
            # construction (spec/registries.md §2.1, FORMAT-08-A-006).
            inner = esio.Provider(_loader([spec.file_variable]), cache)
            out[key] = EsioDocumentProvider(
                key,
                inner,
                table=table,
                column=spec.name,
                declared=declared,
                extent_metaparameter=extent_mp,
                unit_conversion=spec.unit_conversion,
            )
    return out


def esio_provider_factory(
    field: FieldLike, window: Window | None = None, *, target: Any = None
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
