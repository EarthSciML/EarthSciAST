"""Top-level dispatch entry point for runtime DataLoader materialisation.

``load_data(data_loader, ...)`` picks a per-kind loader by inspecting
``DataLoader.kind``. ``resolve_files(data_loader, start, end, **substitutions)``
returns the list of expanded URLs that cover the given time range without
opening anything — useful for pre-flight checks and caching.
"""

from __future__ import annotations

import datetime as _dt
from typing import Any, List, Optional, Union

from ..esm_types import DataLoader, DataLoaderKind
from .grid import GridLoader
from .points import PointsLoader
from .static_loader import StaticLoader
from .time_resolution import file_anchors_in_range
from .url_template import expand_url_template


class DataLoaderDispatchError(ValueError):
    """Raised when a DataLoader cannot be dispatched to a runtime loader."""


def load_data(
    data_loader: DataLoader,
    *,
    time: Optional[Union[_dt.datetime, _dt.date, str]] = None,
    opener: Optional[Any] = None,
    fetcher: Optional[Any] = None,
    parser: Optional[Any] = None,
    **substitutions: Any,
):
    """Dispatch on ``data_loader.kind`` to the appropriate per-kind loader.

    Unsupported arguments for the chosen kind are silently ignored so that
    callers can write a single call site that covers all three kinds.
    """
    kind = data_loader.kind
    if kind == DataLoaderKind.GRID:
        return GridLoader(data_loader).load(
            time=time,
            opener=opener,
            **substitutions,
        )
    if kind == DataLoaderKind.POINTS:
        return PointsLoader(data_loader).load(
            time=time, fetcher=fetcher, parser=parser, **substitutions
        )
    if kind == DataLoaderKind.STATIC:
        return StaticLoader(data_loader).load(opener=opener, **substitutions)
    raise DataLoaderDispatchError(f"no runtime loader registered for kind {kind!r}")


def resolve_files(
    data_loader: DataLoader,
    *,
    start: Union[_dt.datetime, _dt.date, str],
    end: Union[_dt.datetime, _dt.date, str],
    **substitutions: Any,
) -> List[str]:
    """Return the list of source URLs covering ``[start, end]``.

    Requires a temporal section with ``file_period`` set. The primary URL is
    expanded for each anchor; mirrors are not included — use
    :func:`url_template.expand_with_mirrors` per-anchor if mirror fallback
    lists are needed.
    """
    if data_loader.temporal is None or not data_loader.temporal.file_period:
        raise DataLoaderDispatchError("resolve_files requires temporal.file_period to be set")
    anchors = file_anchors_in_range(
        start,
        end,
        file_period=data_loader.temporal.file_period,
        anchor=data_loader.temporal.start,
    )
    return [
        expand_url_template(
            data_loader.source.url_template,
            date=anchor,
            variables=dict(substitutions),
        )
        for anchor in anchors
    ]
