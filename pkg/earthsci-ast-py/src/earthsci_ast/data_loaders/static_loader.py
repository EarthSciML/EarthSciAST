"""Runtime loader for ``kind=static`` DataLoaders.

Static loaders describe time-invariant sources — elevation, fuel model codes,
etc. No ``{date}`` expansion is performed; the URL is opened as-is through the
configured opener. Variable remapping and unit conversion still apply.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from ..esm_types import DataLoader, DataLoaderKind
from .grid import GridLoaderError, _default_xarray_opener, _ds_to_mapping
from .mirror import open_with_fallback
from .url_template import expand_with_mirrors
from .variables import apply_variable_mapping


class StaticLoaderError(RuntimeError):
    """Raised when a static source cannot be loaded."""


@dataclass
class StaticLoadResult:
    """Result of a single ``StaticLoader.load`` call."""

    urls_tried: List[str]
    dataset: Any
    variables: Dict[str, Any]


class StaticLoader:
    """Materialise a ``kind=static`` DataLoader."""

    def __init__(self, data_loader: DataLoader) -> None:
        if data_loader.kind != DataLoaderKind.STATIC:
            raise StaticLoaderError(f"StaticLoader requires kind=static; got {data_loader.kind}")
        self.dl = data_loader

    def load(
        self,
        *,
        opener: Optional[Any] = None,
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
        try:
            ds = open_with_fallback(urls, opener)
        except GridLoaderError as exc:
            raise StaticLoaderError(str(exc)) from exc
        raw = _ds_to_mapping(ds)
        remapped = apply_variable_mapping(raw, self.dl.variables, strict=True)
        return StaticLoadResult(urls_tried=urls, dataset=ds, variables=remapped)


def load_static(
    data_loader: DataLoader,
    *,
    opener: Optional[Any] = None,
    **substitutions: Any,
) -> StaticLoadResult:
    """Convenience wrapper: instantiate and call ``StaticLoader.load``."""
    return StaticLoader(data_loader).load(opener=opener, **substitutions)
