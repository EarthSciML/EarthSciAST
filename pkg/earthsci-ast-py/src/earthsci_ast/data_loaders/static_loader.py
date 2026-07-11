"""Runtime loader for ``kind=static`` DataLoaders.

Static loaders describe time-invariant sources — elevation, fuel model codes,
etc. No ``{date}`` expansion is performed; the URL is opened as-is through the
configured opener. Variable remapping and unit conversion still apply.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from ..esm_types import DataLoader, DataLoaderKind
from ._xarray import XarrayLoaderError, _default_xarray_opener, _ds_to_mapping
from .mirror import open_with_fallback
from .url_template import expand_with_mirrors
from .variables import apply_variable_mapping


class StaticLoaderError(XarrayLoaderError):
    """Raised when a static source cannot be loaded.

    Subclasses :class:`XarrayLoaderError` (mirroring ``GridLoaderError`` in
    ``grid.py``) so callers can catch either loader's failures on the shared
    base, and so a propagating xarray-opener error keeps its type instead of
    being flattened to a string.
    """


@dataclass
class StaticLoadResult:
    """Result of a single ``StaticLoader.load`` call."""

    urls_tried: list[str]
    dataset: Any
    variables: dict[str, Any]


class StaticLoader:
    """Materialise a ``kind=static`` DataLoader."""

    def __init__(self, data_loader: DataLoader) -> None:
        if data_loader.kind != DataLoaderKind.STATIC:
            raise StaticLoaderError(f"StaticLoader requires kind=static; got {data_loader.kind}")
        self.dl = data_loader

    def load(
        self,
        *,
        opener: Any | None = None,
        **substitutions: Any,
    ) -> StaticLoadResult:
        urls = expand_with_mirrors(
            self.dl.source.url_template,
            self.dl.source.mirrors,
            date=None,
            variables=dict(substitutions),
        )
        if opener is None:
            opener = _default_xarray_opener()
        # Let opener / mirror-fallback errors propagate with their own type
        # (mirroring GridLoader.load); XarrayLoaderError subclasses flow through
        # unchanged rather than being stringified into a StaticLoaderError.
        ds = open_with_fallback(urls, opener)
        raw = _ds_to_mapping(ds)
        remapped = apply_variable_mapping(raw, self.dl.variables, strict=True)
        return StaticLoadResult(urls_tried=urls, dataset=ds, variables=remapped)


def load_static(
    data_loader: DataLoader,
    *,
    opener: Any | None = None,
    **substitutions: Any,
) -> StaticLoadResult:
    """Convenience wrapper: instantiate and call ``StaticLoader.load``."""
    return StaticLoader(data_loader).load(opener=opener, **substitutions)
