"""Shared xarray opener helpers for the file-backed data loaders.

``grid`` and ``static`` loaders both open a source file through xarray and turn
the resulting ``Dataset`` into a plain ``{name: DataArray}`` mapping. The
helpers here (and the :class:`XarrayLoaderError` base they raise) live in a
neutral module so neither loader has to reach into the other's internals.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from ..errors import EarthSciAstError


class XarrayLoaderError(EarthSciAstError, RuntimeError):
    """Base error raised by the shared xarray opener helpers.

    Kind-specific loader errors (``GridLoaderError``, ``StaticLoaderError``)
    subclass or catch this so they can share the opener without coupling to one
    another.
    """


def _default_xarray_opener():
    try:
        import xarray as xr
    except ImportError as exc:
        raise XarrayLoaderError(
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
    raise XarrayLoaderError(
        f"opener must return an xarray.Dataset or mapping; got {type(ds).__name__}"
    )
