"""Top-level dispatch entry point for runtime DataSource materialisation.

``load_data(data_source, ...)`` picks a per-kind loader by inspecting
``DataSource.kind``. ``resolve_files(data_source, start, end, **substitutions)``
returns the list of expanded URLs that cover the given time range without
opening anything — useful for pre-flight checks and caching.
"""

from __future__ import annotations

import datetime as _dt
import warnings
from typing import Any

from ..errors import EarthSciAstError
from ..esm_types import DataSource, DataSourceKind
from .grid import GridLoader
from .points import PointsLoader
from .static_source import StaticLoader
from .time_resolution import file_anchors_in_range
from .url_template import expand_url_template


class DataSourceDispatchError(EarthSciAstError, ValueError):
    """Raised when a DataSource cannot be dispatched to a runtime loader."""


def _warn_ignored_kwargs(kind: DataSourceKind, **maybe_ignored: Any) -> None:
    """Warn about loader-specific kwargs that don't apply to ``kind``.

    Only kwargs with a non-``None`` value are reported, so the common
    single-call-site pattern (leaving inapplicable arguments at their default)
    stays quiet while genuine caller mistakes surface.
    """
    ignored = sorted(name for name, value in maybe_ignored.items() if value is not None)
    if ignored:
        warnings.warn(
            f"load_data ignored {', '.join(ignored)} argument(s) that do not apply "
            f"to kind={kind.value!r}",
            stacklevel=3,
        )


def load_data(
    data_source: DataSource,
    *,
    bindings: Any = None,
    time: _dt.datetime | _dt.date | str | None = None,
    opener: Any | None = None,
    fetcher: Any | None = None,
    parser: Any | None = None,
    **substitutions: Any,
):
    """Dispatch on ``data_source.kind`` to the appropriate per-kind loader.

    ``bindings`` is ``{consuming parameter name -> DataSourceBinding}``: from esm
    1.0.0 a source declares no variables, so the caller supplies the bindings of
    the parameters reading it (esm-spec §8.5). Empty/absent means no remap.

    A single call site can cover all three kinds. Loader-specific arguments that
    don't apply to the dispatched kind (e.g. ``fetcher``/``parser`` for a grid
    loader, or ``opener`` for a points loader) are not forwarded; passing one
    with a non-``None`` value emits a :class:`UserWarning` so caller mistakes are
    visible instead of silently dropped.
    """
    kind = data_source.kind
    if kind == DataSourceKind.GRID:
        _warn_ignored_kwargs(kind, fetcher=fetcher, parser=parser)
        return GridLoader(data_source, bindings).load(
            time=time,
            opener=opener,
            **substitutions,
        )
    if kind == DataSourceKind.POINTS:
        _warn_ignored_kwargs(kind, opener=opener)
        return PointsLoader(data_source, bindings).load(
            time=time, fetcher=fetcher, parser=parser, **substitutions
        )
    if kind == DataSourceKind.STATIC:
        _warn_ignored_kwargs(kind, fetcher=fetcher, parser=parser)
        return StaticLoader(data_source, bindings).load(opener=opener, **substitutions)
    raise DataSourceDispatchError(f"no runtime loader registered for kind {kind!r}")


def resolve_files(
    data_source: DataSource,
    *,
    start: _dt.datetime | _dt.date | str,
    end: _dt.datetime | _dt.date | str,
    **substitutions: Any,
) -> list[str]:
    """Return the list of source URLs covering ``[start, end]``.

    Requires a temporal section with ``file_period`` set. The primary URL is
    expanded for each anchor; mirrors are not included — use
    :func:`url_template.expand_with_mirrors` per-anchor if mirror fallback
    lists are needed.
    """
    if data_source.temporal is None or not data_source.temporal.file_period:
        raise DataSourceDispatchError("resolve_files requires temporal.file_period to be set")
    anchors = file_anchors_in_range(
        start,
        end,
        file_period=data_source.temporal.file_period,
        anchor=data_source.temporal.start,
    )
    return [
        expand_url_template(
            data_source.source.url_template,
            date=anchor,
            variables=dict(substitutions),
        )
        for anchor in anchors
    ]
