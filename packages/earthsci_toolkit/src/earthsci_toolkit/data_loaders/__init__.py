"""Runtime data loaders for the STAC-like DataLoader schema.

Dispatches on DataLoader.kind (grid/points/static) and implements URL template
expansion, mirror fallback, time->file resolution, variable remapping with
unit conversion, and regridding onto target grids.
"""

from .url_template import (
    UrlTemplateError,
    expand_url_template,
    expand_with_mirrors,
    template_placeholders,
)
from .time_resolution import (
    TimeResolutionError,
    parse_iso_duration,
    file_anchor_for_time,
    file_anchors_in_range,
    records_for_file,
)
from .mirror import (
    MirrorFallbackError,
    open_with_fallback,
)
from .cache import (
    CacheMiss,
    cache_path_for_url,
    cached_fetcher,
    cached_opener,
    resolve_data_dir,
)
from .variables import (
    UnitConversionError,
    apply_variable_mapping,
    apply_unit_conversion,
)
from .regrid import (
    RegriddingError,
    regrid_latlon_to_target,
)
from .reproject import (
    ReprojectionError,
    parse_proj_string,
    lcc_forward,
    lcc_inverse,
    reproject_xy_to_lonlat,
)
from .regrid_kernels import (
    RegridKernelError,
    locate_1d,
    bspline_regrid_linear_1d,
    bspline_regrid_cubic_1d,
    bspline_regrid_bilinear_2d,
    overlap_area_matrix,
    conservative_regrid,
    cell_average_regrid,
)
from .regrid_driver import (
    RegridDriverError,
    TargetGrid,
    build_target_grid,
    lev_min_reduce,
    regrid_field,
    regrid_loader_field,
    extract_source_coords,
)
from .grid import (
    GridLoaderError,
    GridLoader,
    load_grid,
)
from .points import (
    PointsLoaderError,
    PointsLoader,
    load_points,
)
from .static_loader import (
    StaticLoaderError,
    StaticLoader,
    load_static,
)
from .runtime import (
    DataLoaderDispatchError,
    load_data,
    resolve_files,
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
    "RegriddingError",
    "regrid_latlon_to_target",
    "ReprojectionError",
    "parse_proj_string",
    "lcc_forward",
    "lcc_inverse",
    "reproject_xy_to_lonlat",
    "RegridKernelError",
    "locate_1d",
    "bspline_regrid_linear_1d",
    "bspline_regrid_cubic_1d",
    "bspline_regrid_bilinear_2d",
    "overlap_area_matrix",
    "conservative_regrid",
    "cell_average_regrid",
    "RegridDriverError",
    "TargetGrid",
    "build_target_grid",
    "lev_min_reduce",
    "regrid_field",
    "regrid_loader_field",
    "extract_source_coords",
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
