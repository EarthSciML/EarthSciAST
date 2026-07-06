"""Runtime loader for ``kind=grid`` DataLoaders.

Opens a gridded source file via xarray (falling back to netCDF4 for raw
netCDF) and applies variable name remapping + unit conversion.
"""

from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Union

from ..esm_types import DataLoader, DataLoaderKind
from .mirror import open_with_fallback
from .time_resolution import file_anchor_for_time
from .url_template import expand_with_mirrors
from .variables import apply_variable_mapping


class GridLoaderError(RuntimeError):
    """Raised when grid data cannot be loaded."""


@dataclass
class GridLoadResult:
    """Result of a single ``GridLoader.load`` call.

    ``dataset`` is the raw (pre-remap) xarray.Dataset; ``variables`` maps
    schema-side variable names to unit-converted DataArrays (or raw arrays if
    xarray is unavailable).
    """

    urls_tried: List[str]
    dataset: Any
    variables: Dict[str, Any]


class GridLoader:
    """Materialise a ``kind=grid`` DataLoader at a given time."""

    def __init__(self, data_loader: DataLoader) -> None:
        if data_loader.kind != DataLoaderKind.GRID:
            raise GridLoaderError(f"GridLoader requires kind=grid; got {data_loader.kind}")
        self.dl = data_loader

    def _resolve_urls(
        self,
        *,
        time: Optional[Union[_dt.datetime, _dt.date, str]],
        substitutions: Mapping[str, Any],
    ) -> List[str]:
        anchor: Optional[_dt.datetime]
        if time is not None and self.dl.temporal and self.dl.temporal.file_period:
            anchor = file_anchor_for_time(
                time,
                file_period=self.dl.temporal.file_period,
                start=self.dl.temporal.start,
            )
        elif isinstance(time, (_dt.datetime, _dt.date)):
            anchor = (
                time
                if isinstance(time, _dt.datetime)
                else _dt.datetime(time.year, time.month, time.day)
            )
        else:
            anchor = None
        return expand_with_mirrors(
            self.dl.source.url_template,
            self.dl.source.mirrors,
            date=anchor,
            variables=dict(substitutions),
        )

    def load(
        self,
        *,
        time: Optional[Union[_dt.datetime, _dt.date, str]] = None,
        opener: Optional[Any] = None,
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
        remapped = apply_variable_mapping(raw_vars, self.dl.variables, strict=True)
        return GridLoadResult(urls_tried=urls, dataset=ds, variables=remapped)


def load_grid(
    data_loader: DataLoader,
    *,
    time: Optional[Union[_dt.datetime, _dt.date, str]] = None,
    opener: Optional[Any] = None,
    **substitutions: Any,
) -> GridLoadResult:
    """Convenience wrapper: instantiate a GridLoader and call ``load``."""
    return GridLoader(data_loader).load(
        time=time,
        opener=opener,
        **substitutions,
    )


def _default_xarray_opener():
    try:
        import xarray as xr
    except ImportError as exc:
        raise GridLoaderError(
            "grid loader default opener requires xarray; install xarray "
            "or pass an explicit `opener`"
        ) from exc

    def _open(url: str):
        return xr.open_dataset(url)

    return _open


def _ds_to_mapping(ds: Any) -> Mapping[str, Any]:
    if hasattr(ds, "data_vars"):
        return {name: ds[name] for name in ds.data_vars}
    if isinstance(ds, Mapping):
        return ds
    raise GridLoaderError(
        f"opener must return an xarray.Dataset or mapping; got {type(ds).__name__}"
    )
