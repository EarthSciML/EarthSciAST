"""C4 regrid driver — reproject + horizontal regrid + ``lev=min`` (ess-2fy).

This is the ESS Python-runtime orchestration that lands a data-loader field onto
a model's projected target domain grid. It consumes the EXISTING ESD declarative
rules (it does not add an ESS primitive):

1. **Resolve the target grid.** A model ``domain`` (e.g. ``camp_fire_surface``)
   gives a projected ``(x, y)`` lattice in metres plus a ``spatial_ref`` PROJ
   string. :func:`build_target_grid` builds the lattice (``min + i·spacing`` per
   :class:`~earthsci_toolkit.esm_types.SpatialDimension`) and applies the ESD
   reprojection rule (:mod:`.reproject`) to get the lon/lat cell **centers**
   (for point/bspline sampling) and cell **corner rings** (for conservative
   overlap). The regridder bins by lon/lat, so the projected target is converted
   to lon/lat once and cached.
2. **Reduce ``lev=min`` early.** A 3-D field (``lev, lat, lon``) collapses to the
   ground surface via :func:`lev_min_reduce`, the numeric image of the ESD
   ``lev_min_surface_reduce`` rule (keep the slice at the minimum ``lev``
   coordinate).
3. **Horizontal regrid per method.** :func:`regrid_field` dispatches on the
   per-variable :class:`~earthsci_toolkit.esm_types.RegridSpec` ``method`` to a
   :mod:`.regrid_kernels` kernel — ``bspline`` (degree-1 tensor sampling of the
   source grid at the target centers), ``conservative`` (overlap-area remap of
   source cells onto target corner rings), or ``cell_average`` (scattered-point
   binning).

The output is a flat ``float`` array in the target domain's spatial-dim order
(C-order), ready to bind into the simulation eval context exactly where C1's
raw loader array would have gone.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from . import regrid_kernels as _k
from .reproject import reproject_xy_to_lonlat


class RegridDriverError(ValueError):
    """Raised when a loader field cannot be regridded onto the target domain."""


# --------------------------------------------------------------------------
# Target grid construction
# --------------------------------------------------------------------------


@dataclass
class TargetGrid:
    """A model domain's grid expressed in lon/lat for regridding.

    ``dims`` are the horizontal spatial dim names in domain order (e.g.
    ``["x", "y"]``); ``shape`` is the matching cell count per dim. ``center_lon``
    / ``center_lat`` are the ``shape``-shaped reprojected cell centers.
    ``corner_rings`` holds one closed ``[4, 2]`` lon/lat ring per cell, flattened
    in C-order over ``shape`` (cell ``(i, j)`` at flat index ``i*shape[1]+j``).
    """

    dims: List[str]
    shape: Tuple[int, ...]
    centers: Dict[str, np.ndarray]
    center_lon: np.ndarray
    center_lat: np.ndarray
    corner_rings: List[np.ndarray]


def _dim_nodes(spec: Any) -> Tuple[np.ndarray, float]:
    """Cell-center coordinates and spacing for one spatial dimension.

    Accepts a :class:`SpatialDimension` (``.min``/``.max``/``.grid_spacing``) or
    the equivalent raw dict. Node count follows ``spatial_discretize`` —
    ``round((max-min)/spacing) + 1`` — so the lattice spans ``[min, max]``.
    """
    lo = float(getattr(spec, "min", None) if not isinstance(spec, dict) else spec["min"])
    hi = float(getattr(spec, "max", None) if not isinstance(spec, dict) else spec["max"])
    sp = getattr(spec, "grid_spacing", None) if not isinstance(spec, dict) else spec.get("grid_spacing")
    if sp is None:
        raise RegridDriverError("target domain dimension needs grid_spacing")
    spacing = float(sp)
    n = int(round((hi - lo) / spacing)) + 1
    return lo + np.arange(n) * spacing, spacing


def build_target_grid(domain: Any) -> TargetGrid:
    """Build a lon/lat :class:`TargetGrid` from a model ``domain``.

    Supports a 2-D horizontal grid (the camp-fire ``x``/``y`` surface case);
    a 1-D grid is also handled (no corner rings). The ``spatial_ref`` PROJ
    string drives the projected→lon/lat conversion (``longlat`` identity or
    spherical ``lcc``).
    """
    spatial = getattr(domain, "spatial", None)
    if spatial is None and isinstance(domain, dict):
        spatial = domain.get("spatial")
    if not spatial:
        raise RegridDriverError("target domain has no spatial dimensions")
    spatial_ref = getattr(domain, "spatial_ref", None)
    if spatial_ref is None and isinstance(domain, dict):
        spatial_ref = domain.get("spatial_ref")

    dims = list(spatial.keys())
    nodes: Dict[str, np.ndarray] = {}
    spacing: Dict[str, float] = {}
    for d in dims:
        nodes[d], spacing[d] = _dim_nodes(spatial[d])
    shape = tuple(nodes[d].size for d in dims)

    if len(dims) == 1:
        d0 = dims[0]
        lon, lat = reproject_xy_to_lonlat(nodes[d0], np.zeros_like(nodes[d0]), spatial_ref)
        return TargetGrid(dims, shape, nodes, np.asarray(lon), np.asarray(lat), [])

    if len(dims) != 2:
        raise RegridDriverError(
            f"target grid build supports 1-D or 2-D domains; got dims={dims}"
        )

    d0, d1 = dims
    # Mesh in [d0, d1] order so flattening matches the C-order state layout.
    g0, g1 = np.meshgrid(nodes[d0], nodes[d1], indexing="ij")
    center_lon, center_lat = reproject_xy_to_lonlat(g0, g1, spatial_ref)
    center_lon = np.asarray(center_lon)
    center_lat = np.asarray(center_lat)

    # Cell corner rings: each center ± half-spacing, reprojected, CCW.
    h0 = spacing[d0] / 2.0
    h1 = spacing[d1] / 2.0
    rings: List[np.ndarray] = []
    for i in range(shape[0]):
        x0 = nodes[d0][i]
        for j in range(shape[1]):
            y0 = nodes[d1][j]
            cx = np.array([x0 - h0, x0 + h0, x0 + h0, x0 - h0])
            cy = np.array([y0 - h1, y0 - h1, y0 + h1, y0 + h1])
            rlon, rlat = reproject_xy_to_lonlat(cx, cy, spatial_ref)
            rings.append(np.column_stack([np.asarray(rlon), np.asarray(rlat)]))
    return TargetGrid(dims, shape, nodes, center_lon, center_lat, rings)


# --------------------------------------------------------------------------
# lev=min surface reduction (ESD lev_min_surface_reduce rule)
# --------------------------------------------------------------------------


def lev_min_reduce(field, lev_coord, *, lev_axis: int = 0) -> np.ndarray:
    """Collapse a 3-D field to the surface by keeping the minimum-``lev`` slice.

    ``lev_coord`` are the vertical coordinate values; the slice at
    ``argmin(lev_coord)`` is returned (the numeric image of the ESD
    ``lev_min_surface_reduce`` value-at-argmin rule). A unique minimum is
    assumed, matching the rule's precondition.
    """
    arr = np.asarray(field, dtype=float)
    lev = np.asarray(lev_coord, dtype=float)
    if arr.shape[lev_axis] != lev.size:
        raise RegridDriverError(
            f"lev axis size {arr.shape[lev_axis]} != lev_coord size {lev.size}"
        )
    k = int(np.argmin(lev))
    return np.take(arr, k, axis=lev_axis)


# --------------------------------------------------------------------------
# Source-cell rings (separable lat/lon grid -> per-cell corner polygons)
# --------------------------------------------------------------------------


def _edges_from_centers(centers: np.ndarray) -> np.ndarray:
    """Cell edges (n+1) bracketing ``n`` ascending centers (midpoint split)."""
    c = np.asarray(centers, dtype=float)
    mid = (c[:-1] + c[1:]) / 2.0
    first = c[0] - (mid[0] - c[0]) if c.size > 1 else c[0] - 0.5
    last = c[-1] + (c[-1] - mid[-1]) if c.size > 1 else c[-1] + 0.5
    return np.concatenate([[first], mid, [last]])


def _source_cell_rings(src_lon, src_lat) -> List[np.ndarray]:
    """One CCW ``[4, 2]`` lon/lat ring per source cell, flattened ``[lat, lon]``."""
    lon_e = _edges_from_centers(src_lon)
    lat_e = _edges_from_centers(src_lat)
    rings: List[np.ndarray] = []
    for a in range(len(src_lat)):
        y0, y1 = lat_e[a], lat_e[a + 1]
        for b in range(len(src_lon)):
            x0, x1 = lon_e[b], lon_e[b + 1]
            rings.append(np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], dtype=float))
    return rings


# --------------------------------------------------------------------------
# Horizontal regrid dispatch
# --------------------------------------------------------------------------


def regrid_field(
    field_2d,
    src_lon,
    src_lat,
    target: TargetGrid,
    method: str,
    *,
    manifold: str = "planar",
    missing_value: float = float("nan"),
    atol: float = 0.0,
) -> np.ndarray:
    """Regrid a 2-D ``(lat, lon)`` source field onto ``target`` by ``method``.

    Returns a flat array in the target's C-order cell layout. ``bspline`` samples
    the source grid bilinearly at each target center; ``conservative`` performs
    an overlap-area remap of source cells onto the target corner rings;
    ``cell_average`` bins the source nodes (treated as scattered points) into the
    target cells.
    """
    field = np.asarray(field_2d, dtype=float)
    s_lon = np.asarray(src_lon, dtype=float)
    s_lat = np.asarray(src_lat, dtype=float)
    if field.shape != (s_lat.size, s_lon.size):
        raise RegridDriverError(
            f"source field shape {field.shape} != (nlat={s_lat.size}, nlon={s_lon.size})"
        )
    tgt_lon = np.asarray(target.center_lon, dtype=float)
    tgt_lat = np.asarray(target.center_lat, dtype=float)

    if method == "bspline":
        # Degree-1 tensor sampling: locate each target center in the source grid
        # and bilinearly blend (the BSplineRegridBilinear2D image). F_src is
        # indexed [lon_index, lat_index] to match the kernel's [x, y] layout.
        base_x, s_x = _k.locate_1d(tgt_lon.reshape(-1), s_lon)
        base_y, s_y = _k.locate_1d(tgt_lat.reshape(-1), s_lat)
        f_xy = field.T  # (nlon, nlat)
        out = _k.bspline_regrid_bilinear_2d(f_xy, base_x, base_y, s_x, s_y)
        return out.reshape(-1)

    if method == "conservative":
        src_rings = _source_cell_rings(s_lon, s_lat)
        f_src = field.reshape(-1)  # [lat, lon] C-order matches _source_cell_rings
        f_tgt, _A, _Aj = _k.conservative_regrid(
            f_src, src_rings, target.corner_rings, manifold=manifold, atol=atol
        )
        return f_tgt

    if method == "cell_average":
        lon_mesh, lat_mesh = np.meshgrid(s_lon, s_lat)  # (nlat, nlon)
        # Use the target center coordinates as the destination points and a bin
        # size of the target spacing in lon/lat space.
        tlon = tgt_lon.reshape(-1)
        tlat = tgt_lat.reshape(-1)
        dx = float(np.min(np.diff(np.unique(np.round(tlon, 9)))) if tlon.size > 1 else 1.0)
        dy = float(np.min(np.diff(np.unique(np.round(tlat, 9)))) if tlat.size > 1 else 1.0)
        return _k.cell_average_regrid(
            field.reshape(-1), lon_mesh.reshape(-1), lat_mesh.reshape(-1),
            tlon, tlat, dx=dx, dy=dy, missing_value=missing_value,
        )

    raise RegridDriverError(
        f"unknown regrid method {method!r}; expected bspline|conservative|cell_average"
    )


_LON_NAMES = ("lon", "longitude", "x")
_LAT_NAMES = ("lat", "latitude", "y")
_LEV_NAMES = ("lev", "level", "plev", "pressure_level", "isobaricInhPa", "z", "height")


def _coord_lookup(ds: Any, names: Sequence[str]) -> Optional[np.ndarray]:
    coords = getattr(ds, "coords", None)
    if coords is not None:
        for n in names:
            if n in coords:
                c = coords[n]
                return np.asarray(getattr(c, "values", c), dtype=float)
    if isinstance(ds, dict):
        for n in names:
            if n in ds:
                v = ds[n]
                return np.asarray(getattr(v, "values", v), dtype=float)
    return None


def extract_source_coords(
    ds: Any, ndim: int
) -> Tuple[Optional[np.ndarray], Optional[np.ndarray], Optional[np.ndarray]]:
    """Pull ``(src_lon, src_lat, lev_coord)`` from an xarray-like dataset.

    Any coordinate not found is ``None``; ``lev_coord`` is only sought for a 3-D
    field. Used by the loader provider to decide whether a field can be regridded
    (missing horizontal coords ⇒ fall back to the raw array).
    """
    lon = _coord_lookup(ds, _LON_NAMES)
    lat = _coord_lookup(ds, _LAT_NAMES)
    lev = _coord_lookup(ds, _LEV_NAMES) if ndim >= 3 else None
    return lon, lat, lev


def regrid_loader_field(
    values,
    src_lon,
    src_lat,
    target: TargetGrid,
    method: str,
    *,
    lev_coord: Optional[Sequence[float]] = None,
    lev_axis: int = 0,
    manifold: str = "planar",
    missing_value: float = float("nan"),
    atol: float = 0.0,
) -> np.ndarray:
    """Full per-field pipeline: ``lev=min`` (if 3-D) → horizontal regrid → flat.

    ``values`` is the raw loaded field. When ``lev_coord`` is given the field is
    first collapsed to the surface, then regridded onto ``target`` by ``method``.
    """
    arr = np.asarray(values, dtype=float)
    if lev_coord is not None:
        arr = lev_min_reduce(arr, lev_coord, lev_axis=lev_axis)
    if arr.ndim != 2:
        raise RegridDriverError(
            f"regrid expects a 2-D field after lev reduction; got ndim={arr.ndim}"
        )
    return regrid_field(
        arr, src_lon, src_lat, target, method,
        manifold=manifold, missing_value=missing_value, atol=atol,
    )
