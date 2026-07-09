"""Runtime data loaders for the STAC-like DataLoader schema.

Dispatches on DataLoader.kind (grid/points/static) and implements URL template
expansion, mirror fallback, time->file resolution, and variable remapping with
unit conversion.
"""
from __future__ import annotations

from .cache import (
    CacheMiss,
    cache_path_for_url,
    cached_fetcher,
    cached_opener,
    resolve_data_dir,
)
from .grid import (
    GridLoader,
    GridLoaderError,
    load_grid,
)
from .mirror import (
    MirrorFallbackError,
    open_with_fallback,
)
from .points import (
    PointsLoader,
    PointsLoaderError,
    load_points,
)
from .runtime import (
    DataLoaderDispatchError,
    load_data,
    resolve_files,
)
from .static_loader import (
    StaticLoader,
    StaticLoaderError,
    load_static,
)
from .time_resolution import (
    TimeResolutionError,
    file_anchor_for_time,
    file_anchors_in_range,
    parse_iso_duration,
    records_for_file,
)
from .url_template import (
    UrlTemplateError,
    expand_url_template,
    expand_with_mirrors,
    template_placeholders,
)
from .variables import (
    UnitConversionError,
    apply_unit_conversion,
    apply_variable_mapping,
)

__all__ = [
    "UrlTemplateError",
    "expand_url_template",
    "expand_with_mirrors",
    "template_placeholders",
    "TimeResolutionError",
    "parse_iso_duration",
    "file_anchor_for_time",
    "file_anchors_in_range",
    "records_for_file",
    "MirrorFallbackError",
    "open_with_fallback",
    "CacheMiss",
    "cache_path_for_url",
    "cached_fetcher",
    "cached_opener",
    "resolve_data_dir",
    "UnitConversionError",
    "apply_variable_mapping",
    "apply_unit_conversion",
    "GridLoaderError",
    "GridLoader",
    "load_grid",
    "PointsLoaderError",
    "PointsLoader",
    "load_points",
    "StaticLoaderError",
    "StaticLoader",
    "load_static",
    "DataLoaderDispatchError",
    "load_data",
    "resolve_files",
]
