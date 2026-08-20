"""Runtime loader for ``kind=grid`` data sources.

Opens a gridded source file via xarray (falling back to netCDF4 for raw
netCDF) and applies variable name remapping + unit conversion.
"""

from __future__ import annotations

import datetime as _dt
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from ..esm_types import DataSource, DataSourceKind
from ._source_urls import resolve_source_urls
from ._xarray import XarrayLoaderError, _default_xarray_opener, _ds_to_mapping
from .mirror import open_with_fallback
from .variables import apply_variable_mapping


class GridLoaderError(XarrayLoaderError):
    """Raised when grid data cannot be loaded."""


@dataclass
class GridLoadResult:
    """Result of a single ``GridLoader.load`` call.

    ``dataset`` is the raw (pre-remap) xarray.Dataset; ``variables`` maps
    schema-side variable names to unit-converted DataArrays (or raw arrays if
    xarray is unavailable).
    """

    urls_tried: list[str]
    dataset: Any
    variables: dict[str, Any]


class GridLoader:
    """Materialise a ``kind=grid`` DataSource at a given time.

    ``bindings`` is ``{consuming parameter name -> DataSourceBinding}``. From esm
    1.0.0 a source declares no variables — the per-variable binding lives on the
    PARAMETER that reads it (esm-spec §8.5) — so the caller that knows the
    consumers supplies them here. Empty means no remap: the raw file variables
    come back under their own names.
    """

    def __init__(
        self, data_source: DataSource, bindings: Mapping[str, Any] | None = None
    ) -> None:
        if data_source.kind != DataSourceKind.GRID:
            raise GridLoaderError(f"GridLoader requires kind=grid; got {data_source.kind}")
        self.dl = data_source
        self.bindings = dict(bindings or {})

    def _resolve_urls(
        self,
        *,
        time: _dt.datetime | _dt.date | str | None,
        substitutions: Mapping[str, Any],
    ) -> list[str]:
        return resolve_source_urls(self.dl, time=time, substitutions=substitutions)

    def load(
        self,
        *,
        time: _dt.datetime | _dt.date | str | None = None,
        opener: Any | None = None,
        **substitutions: Any,
    ) -> GridLoadResult:
        """Open and decode a grid file.

        Parameters
        ----------
        time:
            Target timestamp used to expand ``{date:...}`` placeholders. Snapped
            to the file_period anchor when ``temporal`` is set.
        opener:
            Callable ``(url) -> xarray.Dataset``. Defaults to
            ``xarray.open_dataset``.
        **substitutions:
            Extra url template kwargs (``var``, ``species``, ``sector``, etc.).
        """
        urls = self._resolve_urls(time=time, substitutions=substitutions)
        if opener is None:
            opener = _default_xarray_opener()
        ds = open_with_fallback(urls, opener)
        raw_vars = _ds_to_mapping(ds)
        remapped = (
            apply_variable_mapping(raw_vars, self.bindings, strict=True)
            if self.bindings
            else dict(raw_vars)
        )
        return GridLoadResult(urls_tried=urls, dataset=ds, variables=remapped)


def load_grid(
    data_source: DataSource,
    *,
    bindings: Mapping[str, Any] | None = None,
    time: _dt.datetime | _dt.date | str | None = None,
    opener: Any | None = None,
    **substitutions: Any,
) -> GridLoadResult:
    """Convenience wrapper: instantiate a GridLoader and call ``load``."""
    return GridLoader(data_source, bindings).load(
        time=time,
        opener=opener,
        **substitutions,
    )
