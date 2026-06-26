"""Horizontal regridding kernels mirroring the ESD ``regridding/*`` rules.

The C4 driver (:mod:`.regrid_driver`) selects one of these by the per-variable
:class:`~earthsci_toolkit.esm_types.RegridSpec` ``method``. Each kernel is the
numeric realisation of an ESD declarative rule — there is no Python
``build_evaluator``/``const_arrays`` simulate path (that is Julia-only), so the
driver reproduces the rule arithmetic directly:

* ``bspline`` → ``regridding/bspline_regrid.esm`` (degree-1 ``Linear1D`` /
  ``Bilinear2D`` tensor product and degree-3 ``Cubic1D``). The fold order below
  matches the rule AST exactly so the result is byte-identical to the ESD
  conformance golden.
* ``conservative`` → ``regridding/conservative_regrid_overlap_join.esm``: the
  overlap-area matrix ``A_ij = area(src_i ∩ tgt_j)``, column sums
  ``A_j = Σ_i A_ij`` and the partition-of-unity apply
  ``F_tgt[j] = (1/A_j)·Σ_i A_ij·F_src[i]``. Conservation and partition-of-unity
  hold by construction for any manifold.
* ``cell_average`` → ``regridding/point_cell_average_regrid.esm``: bin scattered
  points into target cells and average, emitting ``missing_value`` for empty
  cells.
"""

from __future__ import annotations

from typing import List, Optional, Sequence, Tuple

import numpy as np

from ..geometry import close_ring, intersect_polygon, polygon_area


class RegridKernelError(ValueError):
    """Raised when a regrid kernel receives inconsistent inputs."""


# --------------------------------------------------------------------------
# Source-grid location: target query -> (1-based base node, fractional offset s)
# --------------------------------------------------------------------------


def locate_1d(query, nodes, *, clamp: bool = True) -> Tuple[np.ndarray, np.ndarray]:
    """Locate ``query`` points within ascending 1-D ``nodes``.

    Returns ``(base, s)`` where ``base`` is the **1-based** index of the lower
    bracketing node and ``s`` the fractional offset into ``[node[base],
    node[base+1])`` — the ``base``/``s`` host inputs the ``bspline_regrid`` rule
    consumes. With ``clamp`` (the bilinear-default extrapolation), out-of-range
    queries clamp ``s`` to ``[0, 1]`` so edge values are held.
    """
    q = np.asarray(query, dtype=float)
    nd = np.asarray(nodes, dtype=float)
    if nd.size < 2:
        raise RegridKernelError("locate_1d needs at least 2 source nodes")
    # Lower bracketing node, 0-based, clamped to [0, n-2].
    idx = np.searchsorted(nd, q, side="right") - 1
    idx = np.clip(idx, 0, nd.size - 2)
    x0 = nd[idx]
    x1 = nd[idx + 1]
    s = np.where(x1 != x0, (q - x0) / (x1 - x0), 0.0)
    if clamp:
        s = np.clip(s, 0.0, 1.0)
    return idx + 1, s  # 1-based base


# --------------------------------------------------------------------------
# bspline_regrid.esm — byte-exact fold order
# --------------------------------------------------------------------------


def bspline_regrid_linear_1d(F_src, base, s) -> np.ndarray:
    """``BSplineRegridLinear1D``: ``(1-s)·F[base] + s·F[base+1]`` (1-based base)."""
    F = np.asarray(F_src, dtype=float)
    b0 = np.asarray(base, dtype=int) - 1
    s = np.asarray(s, dtype=float)
    t0 = (1.0 - s) * F[b0]
    t1 = s * F[b0 + 1]
    return t0 + t1


def bspline_regrid_cubic_1d(F_src, base, s) -> np.ndarray:
    """``BSplineRegridCubic1D``: degree-3 Lagrange cardinal sum over 4 nodes.

    Reproduces the rule's flat n-ary fold: each weight product is
    ``((coeff·f1)·f2)·f3`` and the four terms sum left-to-right.
    """
    F = np.asarray(F_src, dtype=float)
    b0 = np.asarray(base, dtype=int) - 1
    s = np.asarray(s, dtype=float)

    def term(coeff: float, factors: Sequence[np.ndarray], k: int) -> np.ndarray:
        wp = coeff
        for f in factors:
            wp = wp * f
        return wp * F[b0 + k]

    t0 = term(-1.0 / 6.0, [s, s - 1.0, s - 2.0], 0)
    t1 = term(1.0 / 2.0, [s + 1.0, s - 1.0, s - 2.0], 1)
    t2 = term(-1.0 / 2.0, [s + 1.0, s, s - 2.0], 2)
    t3 = term(1.0 / 6.0, [s + 1.0, s, s - 1.0], 3)
    return ((t0 + t1) + t2) + t3


def bspline_regrid_bilinear_2d(F_src, base_x, base_y, s_x, s_y) -> np.ndarray:
    """``BSplineRegridBilinear2D``: degree-1 tensor product over a ``[x, y]`` grid.

    ``F_src`` is indexed ``[x_index, y_index]``; ``base_x``/``base_y`` are
    1-based. Term and factor order match the rule AST.
    """
    F = np.asarray(F_src, dtype=float)
    bx = np.asarray(base_x, dtype=int) - 1
    by = np.asarray(base_y, dtype=int) - 1
    sx = np.asarray(s_x, dtype=float)
    sy = np.asarray(s_y, dtype=float)
    t0 = ((1.0 - sx) * (1.0 - sy)) * F[bx, by]
    t1 = (sx * (1.0 - sy)) * F[bx + 1, by]
    t2 = ((1.0 - sx) * sy) * F[bx, by + 1]
    t3 = (sx * sy) * F[bx + 1, by + 1]
    return ((t0 + t1) + t2) + t3


# --------------------------------------------------------------------------
# conservative_regrid_overlap_join.esm — geometry-derived overlap assembly
# --------------------------------------------------------------------------


def overlap_area_matrix(
    src_rings: Sequence[np.ndarray],
    tgt_rings: Sequence[np.ndarray],
    *,
    manifold: str = "planar",
    atol: float = 0.0,
) -> np.ndarray:
    """Build ``A_ij = area(src_i ∩ tgt_j)`` via the ESS geometry kernels.

    Each ring is a ``[verts, 2]`` lon/lat polygon. Overlap areas at or below
    ``atol`` are dropped to exactly ``0`` (the rule's ``filter: A_ij > atol``
    sliver gate). Returns the dense ``[n_src, n_tgt]`` raw-area matrix.
    """
    n_s = len(src_rings)
    n_t = len(tgt_rings)
    A = np.zeros((n_s, n_t), dtype=float)
    for i in range(n_s):
        ring_i = src_rings[i]
        for j in range(n_t):
            clip = intersect_polygon(ring_i, tgt_rings[j], manifold)
            if clip.shape[0] < 3:
                continue
            area = polygon_area(close_ring(clip), manifold)
            if area > atol:
                A[i, j] = area
    return A


def conservative_regrid(
    F_src,
    src_rings: Sequence[np.ndarray],
    tgt_rings: Sequence[np.ndarray],
    *,
    manifold: str = "planar",
    atol: float = 0.0,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """First-order conservative remap of cell values ``F_src`` src→tgt.

    Returns ``(F_tgt, A, A_j)`` where ``A`` is the overlap-area matrix, ``A_j``
    the target-cell areas (column sums = the ``dst_areas`` denominator) and
    ``F_tgt[j] = (1/A_j)·Σ_i A_ij·F_src[i]``. Empty target cells (``A_j == 0``)
    yield ``0``. Mass is conserved (``Σ_j A_j·F_tgt = Σ_ij A_ij·F_src``) and the
    weights ``A_ij/A_j`` partition unity over each covered target cell.
    """
    F = np.asarray(F_src, dtype=float)
    A = overlap_area_matrix(src_rings, tgt_rings, manifold=manifold, atol=atol)
    if F.shape[0] != A.shape[0]:
        raise RegridKernelError(
            f"F_src length {F.shape[0]} != source cell count {A.shape[0]}"
        )
    A_j = A.sum(axis=0)
    num = A.T @ F
    F_tgt = np.where(A_j > 0.0, num / np.where(A_j > 0.0, A_j, 1.0), 0.0)
    return F_tgt, A, A_j


# --------------------------------------------------------------------------
# point_cell_average_regrid.esm — scattered-point binning + cell average
# --------------------------------------------------------------------------


def cell_average_regrid(
    station_val,
    station_lon,
    station_lat,
    cell_lon,
    cell_lat,
    *,
    dx: float,
    dy: float,
    missing_value: float = float("nan"),
) -> np.ndarray:
    """Average scattered station values into target cells by integer bin.

    Mirrors ``PointCellAverageRegrid``: a station and a cell match when their
    ``(floor(lon/dx), floor(lat/dy))`` bins are equal; the cell value is the
    mean of its matched stations, or ``missing_value`` when no station lands in
    it.
    """
    val = np.asarray(station_val, dtype=float)
    s_lon = np.asarray(station_lon, dtype=float)
    s_lat = np.asarray(station_lat, dtype=float)
    c_lon = np.asarray(cell_lon, dtype=float)
    c_lat = np.asarray(cell_lat, dtype=float)
    s_bin_x = np.floor(s_lon / dx).astype(int)
    s_bin_y = np.floor(s_lat / dy).astype(int)
    c_bin_x = np.floor(c_lon / dx).astype(int)
    c_bin_y = np.floor(c_lat / dy).astype(int)
    out = np.empty(c_lon.shape[0], dtype=float)
    for j in range(c_lon.shape[0]):
        match = (s_bin_x == c_bin_x[j]) & (s_bin_y == c_bin_y[j])
        count = int(np.count_nonzero(match))
        out[j] = float(val[match].sum() / count) if count > 0 else missing_value
    return out
