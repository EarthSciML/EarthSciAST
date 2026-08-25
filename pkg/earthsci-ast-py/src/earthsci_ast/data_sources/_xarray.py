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


#: The pip extra that installs the xarray + netcdf4 reader stack. Named once so
#: the two guards below and any future one cannot drift apart.
DATA_EXTRA_HINT = (
    'install the data-loading extra with `pip install "earthsci-ast[data]"`, '
    "or pass an explicit `opener=` to the loader"
)


def _default_xarray_opener():
    """Build the default opener, or fail with an actionable message.

    The xarray import is deferred to HERE — the point of use — so that the base
    install (which does not ship xarray; see ``pyproject.toml``) can still
    import :mod:`earthsci_ast.data_sources` and use everything that does not
    open a netCDF file: URL templates, time resolution, mirror fallback, the
    cache index, unit conversion and the ``points`` loader.
    """
    try:
        import xarray as xr
    except ImportError as exc:
        raise XarrayLoaderError(
            "the default data-loader opener needs `xarray`, which is not "
            f"installed. This is an OPTIONAL dependency: {DATA_EXTRA_HINT}."
        ) from exc

    def _open(url: str):
        try:
            return xr.open_dataset(url)
        except ValueError as exc:
            # xarray raises a bare ValueError when it can find no backend engine
            # for the URL. The overwhelmingly common cause is a base install:
            # xarray present (some other package pulled it in) but `netcdf4`,
            # the engine it needs for a netCDF source, absent. Re-raise as a
            # loader error that names the extra instead of leaving the caller
            # with xarray's engine-list dump.
            if not _is_missing_engine(exc):
                raise
            raise XarrayLoaderError(
                f"xarray cannot open {url!r}: no backend engine is installed "
                "for this source. A netCDF source needs the `netcdf4` engine, "
                "which ships in the same OPTIONAL extra as xarray: "
                f"{DATA_EXTRA_HINT}."
            ) from exc

    return _open


def _is_missing_engine(exc: BaseException) -> bool:
    """True when an xarray ``ValueError`` is its "no usable engine" complaint.

    Matched on the message because xarray raises a plain ``ValueError`` here
    rather than a typed error, and has done across every release this package
    supports. Kept deliberately narrow so an unrelated ``ValueError`` from
    inside a real read propagates untouched.
    """
    text = str(exc).lower()
    return "engine" in text and (
        "did not find a match" in text
        or "found no match" in text
        or "no backend" in text
        or "install" in text
    )


def _ds_to_mapping(ds: Any) -> Mapping[str, Any]:
    if hasattr(ds, "data_vars"):
        return {name: ds[name] for name in ds.data_vars}
    if isinstance(ds, Mapping):
        return ds
    raise XarrayLoaderError(
        f"opener must return an xarray.Dataset or mapping; got {type(ds).__name__}"
    )
