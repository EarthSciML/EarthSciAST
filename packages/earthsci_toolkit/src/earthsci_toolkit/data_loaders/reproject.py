"""Coordinate reprojection for the C4 regrid driver.

The horizontal regridder (:mod:`.regrid_driver`) bins source and target cells
by **lon/lat**: it is CRS-agnostic and consumes geometry already in a shared
geographic frame. A *projected* target domain (e.g. a Lambert Conformal Conic
``camp_fire_surface`` grid in metres) must therefore have its ``(x, y)`` lattice
converted to ``(lon, lat)`` before regridding.

This module supplies that conversion declaratively, mirroring the ESD
reprojection rules (``reprojection/longlat.esm`` identity and
``reprojection/lambert_conformal.esm`` / the ``lambert_conformal_construction``
corner inverse). Both are **spherical** closed-form transforms (Snyder, *Map
Projections — A Working Manual*, USGS PP 1395, §15) built from elementary ops —
no ``pyproj``/PROJ runtime dependency. The supported projections match the
``GridCRS.projection`` enum that has a backing rule today: ``longlat`` and
``lambert_conformal``. Other CRS values (``mercator``, ``polar_stereographic``,
``rotated_pole``) have no ESD rule yet and raise.

The transforms are spherical; a ``+datum=WGS84`` domain carries no radius, so a
spherical Earth radius is assumed (the sub-grid positional error this incurs at
camp-fire resolution is small — see the C4 spike's fidelity note). The
forward/inverse pair is self-consistent for any radius, so the projected
``(x, y)`` lattice round-trips exactly regardless of the assumed ``R``.
"""

from __future__ import annotations

import math
from typing import Any, Dict, Optional, Tuple

# Spherical Earth radius assumed for a ``+datum=WGS84`` / unspecified-radius
# projected CRS. 6371.0 km (the WGS84 mean / authalic radius rounded to the
# value used across atmospheric-model LCC grids). Only affects absolute scale,
# never the forward∘inverse round-trip.
DEFAULT_SPHERE_RADIUS_M = 6_370_997.0

_DEG2RAD = math.pi / 180.0
_RAD2DEG = 180.0 / math.pi


class ReprojectionError(ValueError):
    """Raised when a CRS cannot be reprojected to lon/lat."""


def _require_numpy():
    try:
        import numpy as _np

        return _np
    except ImportError as exc:  # pragma: no cover - numpy is a hard dep here
        raise ReprojectionError(
            "reprojection requires numpy; install numpy to use this helper"
        ) from exc


def parse_proj_string(spatial_ref: str) -> Dict[str, Any]:
    """Parse a PROJ.4 ``spatial_ref`` string into a parameter dict.

    Handles the ``+key=value`` / bare ``+flag`` token grammar (e.g.
    ``"+proj=lcc +lat_1=30.0 +lat_2=60.0 +lat_0=39.0 +lon_0=-97.0 +datum=WGS84
    +units=m +no_defs"``). Numeric values are coerced to ``float``; everything
    else stays a string; bare flags map to ``True``. Unknown keys are preserved
    verbatim so callers can inspect them.
    """
    if not isinstance(spatial_ref, str):
        raise ReprojectionError(
            f"spatial_ref must be a PROJ string; got {type(spatial_ref).__name__}"
        )
    out: Dict[str, Any] = {}
    for token in spatial_ref.split():
        if not token.startswith("+"):
            continue
        body = token[1:]
        if "=" not in body:
            if body:
                out[body] = True
            continue
        key, _, value = body.partition("=")
        try:
            out[key] = float(value)
        except ValueError:
            out[key] = value
    return out


def _sphere_radius(params: Dict[str, Any]) -> float:
    """Resolve the spherical radius from a parsed PROJ param dict."""
    if "R" in params:
        return float(params["R"])
    if "a" in params:
        return float(params["a"])
    return DEFAULT_SPHERE_RADIUS_M


def _lcc_cone(params: Dict[str, Any]) -> Tuple[float, float, float, float, float]:
    """Snyder LCC cone constants ``(n, RF, rho0, lon_0, R)`` from CRS params.

    Reproduces ``reprojection/lambert_conformal.esm``: the standard-parallel
    cone constant ``n`` (with the tangent-cone ``lat_1 == lat_2`` limit), the
    radius scale ``RF = R*F`` and the latitude-of-origin polar distance
    ``rho0``. ``lat_*`` are degrees.
    """
    lat_1 = params.get("lat_1")
    if lat_1 is None:
        raise ReprojectionError("lambert_conformal CRS requires +lat_1")
    lat_2 = params.get("lat_2", lat_1)
    lat_0 = params.get("lat_0", lat_1)
    lon_0 = params.get("lon_0", 0.0)
    radius = _sphere_radius(params)

    phi1 = float(lat_1) * _DEG2RAD
    phi2 = float(lat_2) * _DEG2RAD
    phi0 = float(lat_0) * _DEG2RAD
    t1 = math.tan(math.pi / 4.0 + phi1 / 2.0)
    t2 = math.tan(math.pi / 4.0 + phi2 / 2.0)
    t0 = math.tan(math.pi / 4.0 + phi0 / 2.0)
    if abs(phi1 - phi2) < 1e-12:
        n = math.sin(phi1)
    else:
        n = math.log(math.cos(phi1) / math.cos(phi2)) / math.log(t2 / t1)
    if n == 0.0:
        raise ReprojectionError("degenerate LCC cone constant n == 0")
    big_f = math.cos(phi1) * t1 ** n / n
    rf = radius * big_f
    rho0 = rf / t0 ** n
    return n, rf, rho0, float(lon_0), radius


def lcc_forward(lon, lat, params: Dict[str, Any]):
    """Spherical LCC forward: ``(lon, lat)`` degrees → projected ``(x, y)`` m."""
    np = _require_numpy()
    n, rf, rho0, lon_0, _ = _lcc_cone(params)
    lon_a = np.asarray(lon, dtype=float)
    lat_a = np.asarray(lat, dtype=float)
    phi = lat_a * _DEG2RAD
    tphi = np.tan(np.pi / 4.0 + phi / 2.0)
    rho = rf / tphi ** n
    theta = n * ((lon_a - lon_0) * _DEG2RAD)
    x = rho * np.sin(theta)
    y = rho0 - rho * np.cos(theta)
    return x, y


def lcc_inverse(x, y, params: Dict[str, Any]):
    """Spherical LCC inverse: projected ``(x, y)`` m → ``(lon, lat)`` degrees.

    Closed form (Snyder 15-5/15-7/15-8/15-9), matching the
    ``lambert_conformal_construction`` corner inverse rule.
    """
    np = _require_numpy()
    n, rf, rho0, lon_0, _ = _lcc_cone(params)
    x_a = np.asarray(x, dtype=float)
    y_a = np.asarray(y, dtype=float)
    rho0_my = rho0 - y_a
    rho_inv = math.copysign(1.0, n) * np.sqrt(x_a * x_a + rho0_my * rho0_my)
    theta_inv = np.arctan2(x_a, rho0_my)
    lon = lon_0 + (theta_inv / n) * _RAD2DEG
    lat = (2.0 * np.arctan((rf / rho_inv) ** (1.0 / n)) - np.pi / 2.0) * _RAD2DEG
    return lon, lat


def reproject_xy_to_lonlat(x, y, spatial_ref: Optional[str]):
    """Convert a projected ``(x, y)`` lattice to ``(lon, lat)`` per ``spatial_ref``.

    ``spatial_ref`` is the domain's PROJ string. ``+proj=longlat`` (and a
    missing/empty ``spatial_ref``) is the identity — the lattice is already
    geographic, so ``(lon, lat) = (x, y)``. ``+proj=lcc`` applies the spherical
    LCC inverse. Any other projection has no backing reproject rule and raises.
    """
    np = _require_numpy()
    if not spatial_ref:
        return np.asarray(x, dtype=float), np.asarray(y, dtype=float)
    params = parse_proj_string(spatial_ref)
    proj = params.get("proj", "longlat")
    if proj in ("longlat", "latlong", "lonlat"):
        return np.asarray(x, dtype=float), np.asarray(y, dtype=float)
    if proj == "lcc":
        return lcc_inverse(x, y, params)
    raise ReprojectionError(
        f"no reprojection rule for +proj={proj!r}; supported: longlat, lcc"
    )
