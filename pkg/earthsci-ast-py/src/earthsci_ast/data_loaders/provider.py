"""The cadence-aware **Provider** the loader-consumer driver builds and queries.

This is the ESS-side realisation of the EarthSciIO **Provider** contract
(earthsciio bead ``esio-9nb.3``): a per-loader object that ``simulate()``'s
segmented driver constructs **once at setup** and queries at cadence
boundaries —

* :meth:`Provider.materialize` — CONST loader, read once;
* :meth:`Provider.refresh` — DISCRETE loader, snap a time to the cadence anchor
  and return that record's native arrays;
* :meth:`Provider.refresh_times` — the cadence anchors over the run window, i.e.
  the solver tstops.

ESS does **not** import EarthSciIO (the rigs are decoupled — cross-repo
dependencies are tracked in beads, not in code). Instead the consumer accepts
any object conforming to the :class:`Provider` protocol. The in-tree
:class:`LoadDataProvider` — backed by :func:`data_loaders.runtime.load_data` —
is the default, and a real EarthSciIO ``Provider`` (whose
``materialize`` / ``refresh`` / ``refresh_times`` signatures match this protocol
exactly, per the ``esio-9nb.3`` gate) can be dropped in via
``simulate(..., provider_factory=...)`` with no change to ESS code.

The provider returns **raw native-grid data**; variable-name remap and regrid
stay in ESS (the C4 driver runs in the consumer, between the provider's native
output and the RHS registry — see :func:`simulation._provider_array`). For the
in-tree provider that native dataset is a
:class:`~earthsci_ast.data_loaders.grid.GridLoadResult`; for a real
EarthSciIO provider it is a ``NativeDataset``. The consumer bridges either
shape, so this module never needs the EarthSciIO container types.
"""

from __future__ import annotations

import datetime as _dt
import math
import os
from typing import TYPE_CHECKING, Any, Callable, Optional

try:  # Protocol is stdlib from 3.8; guard keeps the import defensive.
    from typing import Protocol, runtime_checkable
except ImportError:  # pragma: no cover - 3.7 fallback
    Protocol = object  # type: ignore[assignment]

    def runtime_checkable(cls):  # type: ignore[misc]
        return cls


if TYPE_CHECKING:  # avoid a runtime import cycle with flatten/simulation.
    from ..flatten import LoaderField

#: A run window ``(start, end)`` of absolute datetimes bounding
#: :meth:`Provider.refresh_times` (and priming a DISCRETE :meth:`materialize`).
Window = tuple[_dt.datetime, _dt.datetime]


@runtime_checkable
class Provider(Protocol):
    """Structural type for a loader-bound, cadence-aware data source.

    Matches the EarthSciIO ``Provider`` (``esio-9nb.3``) method surface the
    consumer relies on. ``materialize`` / ``refresh`` return a *native dataset*
    (a ``GridLoadResult`` from the in-tree provider, or a ``NativeDataset`` from
    a real EarthSciIO provider); :func:`simulation._provider_array` extracts the
    requested variable from either shape.
    """

    def materialize(self) -> Any:
        """Read a CONST loader's data once and return it."""

    def refresh(self, t: _dt.datetime) -> Any:
        """Return the native arrays for the cadence anchor at time ``t``."""

    def refresh_times(self) -> list[_dt.datetime]:
        """The cadence anchors (absolute datetimes) over the run window."""


#: A factory the consumer calls once per loader field at setup to build its
#: provider, given the field and its absolute run window (``None`` for CONST).
ProviderFactory = Callable[["LoaderField", Optional[Window]], Provider]


class LoadDataProvider:
    """In-tree default :class:`Provider` backed by ``runtime.load_data``.

    Conforms to the EarthSciIO ``Provider`` contract so the same consumer code
    path serves both the in-tree loaders and an injected EarthSciIO provider.
    Holds no decoded buffer of its own — ``load_data`` is the I/O — but exposes
    :meth:`refresh_times` computed from the loader's ``temporal`` cadence so the
    segmented driver's boundaries come from the provider, not local frequency
    arithmetic in the driver.
    """

    def __init__(
        self,
        field: LoaderField,
        window: Window | None = None,
        *,
        opener: Callable[[str], Any] | None = None,
        fetcher: Callable[[str], bytes] | None = None,
        use_cache: bool = False,
        url_substitutions: dict | None = None,
    ) -> None:
        self.field = field
        self.window = window
        # Constant + domain-derived url_template fills (version/product, and the
        # WGS84 bbox / image size for server-side-subsetting loaders like the
        # LANDFIRE / USGS 3DEP ArcGIS ImageServers). Passed verbatim into
        # load_data so StaticLoader/GridLoader can expand their url_template.
        self._url_substitutions = dict(url_substitutions or {})
        # Explicitly-injected opener/fetcher for the loader DI seam (highest
        # precedence). ``None`` + ``use_cache`` routes reads/writes through the
        # EARTHSCIDATADIR content-addressed cache, built lazily in
        # :meth:`_resolve_io` so merely constructing the provider (e.g. for
        # :meth:`refresh_times`) needs no I/O backend.
        self._opener = opener
        self._fetcher = fetcher
        self._use_cache = use_cache

    def _resolve_io(self):
        """Opener/fetcher for a read, built lazily. Explicit injection wins;
        else the EARTHSCIDATADIR cache when ``use_cache``; else the un-cached
        default (``None`` ⇒ the loader's own opener)."""
        if self._opener is not None or self._fetcher is not None:
            return self._opener, self._fetcher
        if self._use_cache:
            from .cache import cached_fetcher, cached_opener

            return cached_opener(), cached_fetcher()
        return None, None

    @property
    def _temporal(self) -> Any:
        return self.field.loader.temporal

    def _epoch(self) -> _dt.datetime | None:
        """Absolute instant of simulation-clock 0 for this loader, or ``None``.

        Mirrors C1's clock mapping (``temporal.start`` is sim-clock zero), so a
        ``refresh_times`` anchor converts back to sim-clock by subtracting it.
        """
        temporal = self._temporal
        start = getattr(temporal, "start", None) if temporal is not None else None
        if not start:
            return None
        from .time_resolution import _coerce_datetime

        return _coerce_datetime(start)

    @property
    def is_const(self) -> bool:
        return self._temporal is None

    def materialize(self) -> Any:
        """CONST: read the single file once (sim time is irrelevant)."""
        from .runtime import load_data

        opener, fetcher = self._resolve_io()
        return load_data(
            self.field.loader, time=None, opener=opener, fetcher=fetcher, **self._url_substitutions
        )

    def refresh(self, t: _dt.datetime | None) -> Any:
        """Load the file covering absolute time ``t`` (``None`` ⇒ unanchored)."""
        from .runtime import load_data

        opener, fetcher = self._resolve_io()
        return load_data(
            self.field.loader, time=t, opener=opener, fetcher=fetcher, **self._url_substitutions
        )

    def refresh_times(self) -> list[_dt.datetime]:
        """Cadence anchors in the run window — the solver tstops.

        Empty for a CONST loader, or when the window/epoch/frequency cannot be
        resolved (the consumer then falls back to local frequency arithmetic).
        Anchors are aligned to the loader epoch (``temporal.start``) and lie in
        ``[max(window.start, epoch), window.end)``, matching the EarthSciIO
        ``Provider.refresh_times`` semantics.
        """
        temporal = self._temporal
        freq = getattr(temporal, "frequency", None) if temporal is not None else None
        epoch = self._epoch()
        if not freq or epoch is None or self.window is None:
            return []
        from .time_resolution import TimeResolutionError, parse_iso_duration

        try:
            step = parse_iso_duration(freq).approximate_seconds()
        except TimeResolutionError:
            return []
        if step <= 0:
            return []
        delta = _dt.timedelta(seconds=step)
        lower = max(self.window[0], epoch)
        upper = self.window[1]
        # First aligned anchor at or after ``lower`` (ceil of the elapsed steps).
        elapsed = (lower - epoch).total_seconds()
        k = max(0, math.ceil(elapsed / step))
        anchor = epoch + k * delta
        out: list[_dt.datetime] = []
        while anchor < upper:
            out.append(anchor)
            anchor = anchor + delta
        return out


#: Fallback native cell size (WGS84 degrees) for a ``{bbox…}`` loader that
#: declares neither ``url_defaults.resolution_deg`` nor
#: ``metadata.native_resolution_deg.lon`` — one arc-second (the LANDFIRE /
#: USGS 3DEP native grid).
_DEFAULT_RESOLUTION_DEG = 1.0 / 3600.0

#: Clamp on a derived ArcGIS ImageServer output dimension (pixels) when the
#: loader's ``url_defaults`` does not set ``size_cap``.
_DEFAULT_IMAGE_SIZE_CAP = 4000


def _bbox_image_substitutions(target: Any, meta: dict, defaults: dict) -> dict:
    """WGS84 request box + output image size for a ``{bbox…}`` template, derived
    from the ``target`` grid's lon/lat envelope.

    A port of EarthSciData.jl ``_domain_bbox_wgs84`` / ``LANDFIREFileSet``: pad
    the envelope by one resolution cell, size = ceil(span_deg / resolution_deg)
    clamped to ``[1, size_cap]``. Resolution defaults to
    ``metadata.native_resolution_deg.lon`` (then :data:`_DEFAULT_RESOLUTION_DEG`),
    the cap to :data:`_DEFAULT_IMAGE_SIZE_CAP`. Both placeholder spellings
    (``bbox_west``/``bbox_west_deg``, ``width``/``image_width``) are emitted so
    either loader's template fills.
    """
    import numpy as np

    lon = np.asarray(target.center_lon)
    lat = np.asarray(target.center_lat)
    native = meta.get("native_resolution_deg") or {}
    res_deg = float(defaults.get("resolution_deg") or native.get("lon") or _DEFAULT_RESOLUTION_DEG)
    cap = int(defaults.get("size_cap", _DEFAULT_IMAGE_SIZE_CAP))
    west, east = float(lon.min()) - res_deg, float(lon.max()) + res_deg
    south, north = float(lat.min()) - res_deg, float(lat.max()) + res_deg
    width = max(1, min(cap, math.ceil((east - west) / res_deg)))
    height = max(1, min(cap, math.ceil((north - south) / res_deg)))
    return {
        "bbox_west": west,
        "bbox_west_deg": west,
        "bbox_south": south,
        "bbox_south_deg": south,
        "bbox_east": east,
        "bbox_east_deg": east,
        "bbox_north": north,
        "bbox_north_deg": north,
        "width": width,
        "image_width": width,
        "height": height,
        "image_height": height,
    }


def _static_url_substitutions(loader: Any, target: Any) -> dict:
    """url_template fills for a server-side-subsetting loader (e.g. the LANDFIRE /
    USGS 3DEP ArcGIS ImageServers).

    Constant fills (``version``/``product`` and the optional ``resolution_deg`` /
    ``size_cap``) come from the loader's structured ``metadata.url_defaults``.
    When the template has a ``{bbox…}`` placeholder and a ``target`` grid is
    available, the WGS84 request box and output image size are appended by
    :func:`_bbox_image_substitutions`.
    """
    meta = getattr(loader, "metadata", None) or {}
    defaults = meta.get("url_defaults") or {}
    # constant scalar fills (e.g. version, product) — skip the sizing knobs
    subs = {
        k: v
        for k, v in defaults.items()
        if k not in ("resolution_deg", "size_cap") and not isinstance(v, (dict, list))
    }
    url = getattr(getattr(loader, "source", None), "url_template", "") or ""
    if target is None or "{bbox" not in url:
        return subs
    subs.update(_bbox_image_substitutions(target, meta, defaults))
    return subs


def build_default_provider(
    field: LoaderField, window: Window | None = None, *, target: Any = None
) -> Provider:
    """Default :data:`ProviderFactory`: the in-tree :class:`LoadDataProvider`.

    When a cache root is configured — ``EARTHSCIDATADIR`` is set, or
    ``EARTHSCI_OFFLINE`` is truthy — the provider reads (and, online, writes)
    through the content-addressed disk cache (:func:`cached_opener` /
    :func:`cached_fetcher`), so loads consult ``EARTHSCIDATADIR`` instead of
    always hitting the network. With neither set the loaders' un-cached default
    opener is used unchanged (so e.g. OPeNDAP direct opens still work).
    """
    from .cache import DATADIR_ENV, _offline_enabled

    use_cache = bool(os.environ.get(DATADIR_ENV)) or _offline_enabled(None)
    url_substitutions = _static_url_substitutions(field.loader, target)
    return LoadDataProvider(field, window, use_cache=use_cache, url_substitutions=url_substitutions)
