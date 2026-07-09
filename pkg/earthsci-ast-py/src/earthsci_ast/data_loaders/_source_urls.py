"""Shared source-URL resolution for time-aware data loaders.

``grid`` and ``points`` loaders resolve the same way: snap the requested time
to the ``temporal.file_period`` anchor (or the bare date), then expand the URL
template across the primary source and its mirrors. Extracted here so both
loaders call one function instead of carrying byte-identical copies.
"""

from __future__ import annotations

import datetime as _dt
from collections.abc import Mapping
from typing import Any

from ..esm_types import DataLoader
from .time_resolution import file_anchor_for_time
from .url_template import expand_with_mirrors


def resolve_source_urls(
    data_loader: DataLoader,
    *,
    time: _dt.datetime | _dt.date | str | None,
    substitutions: Mapping[str, Any],
) -> list[str]:
    """Expand ``data_loader``'s source URL (plus mirrors) for ``time``.

    ``time`` is snapped to the ``temporal.file_period`` anchor when a temporal
    section with a file period is present; otherwise a ``datetime``/``date`` is
    used as-is and anything else yields no date anchor.
    """
    anchor: _dt.datetime | None
    if time is not None and data_loader.temporal and data_loader.temporal.file_period:
        anchor = file_anchor_for_time(
            time,
            file_period=data_loader.temporal.file_period,
            start=data_loader.temporal.start,
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
        data_loader.source.url_template,
        data_loader.source.mirrors,
        date=anchor,
        variables=dict(substitutions),
    )
