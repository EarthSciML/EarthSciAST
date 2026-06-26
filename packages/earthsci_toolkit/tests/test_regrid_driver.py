"""C4 regrid driver conformance (campfire-e2e, bead ess-2fy).

Pins the ESS Python regrid driver against the EarthSciDiscretizations (ESD)
conformance goldens it reproduces: the spherical Lambert-Conformal-Conic
reproject (``reprojection/lambert_conformal`` + the corner-construction rule),
the ``bspline``/``conservative``/``point`` regridders and the ``lev=min``
surface reduction. The driver is pure ESS Python-runtime orchestration — it adds
no primitive — so these lock in that it applies the existing ESD rules
faithfully (LCC corners bit-exact; bspline/lev_min/point to 1e-12; conservative
via the binding-independent conservation + partition-of-unity invariants).
"""

from __future__ import annotations

from types import SimpleNamespace

import numpy as np
import pytest

from earthsci_toolkit.data_loaders.reproject import (
    lcc_forward,
    lcc_inverse,
    parse_proj_string,
    reproject_xy_to_lonlat,
)
from earthsci_toolkit.data_loaders.regrid_kernels import (
    bspline_regrid_bilinear_2d,
    bspline_regrid_cubic_1d,
    bspline_regrid_linear_1d,
    cell_average_regrid,
    conservative_regrid,
)
from earthsci_toolkit.data_loaders.regrid_driver import (
    build_target_grid,
    lev_min_reduce,
    regrid_field,
    regrid_loader_field,
)

# --- camp_fire_surface domain (verbatim from camp_fire.esm domains:481-560) ---
CAMPFIRE_SR = (
    "+proj=lcc +lat_1=30.0 +lat_2=60.0 +lat_0=39.0 +lon_0=-97.0 "
    "+x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs"
)


def _campfire_surface_domain():
    return SimpleNamespace(
        spatial={
            "x": SimpleNamespace(min=-2026020.2, max=-1990020.2, grid_spacing=2000.0),
            "y": SimpleNamespace(min=374725.0, max=414725.0, grid_spacing=2000.0),
        },
        spatial_ref=CAMPFIRE_SR,
    )


# --------------------------------------------------------------------------
# Reprojection: PROJ parse + spherical LCC forward/inverse/roundtrip
# --------------------------------------------------------------------------

_WRF = {"lat_1": 30.0, "lat_2": 60.0, "lat_0": 38.999996, "lon_0": -97.0, "R": 6370000.0}
_NEI = {"lat_1": 33.0, "lat_2": 45.0, "lat_0": 40.0, "lon_0": -97.0, "R": 6370997.0}

# reprojection/lambert_conformal forward golden (lon,lat) -> (x,y)
_REPROJ_COORDS = [
    (-97.0, 39.0), (-120.0, 35.0), (-75.0, 40.0), (-90.0, 45.0),
    (-100.0, 25.0), (-80.0, 48.0), (-110.0, 31.0), (-104.0, 42.5),
]
_REPROJ_FWD = {
    "WRF": [
        (0.0, 0.43226828519254923),
        (-2028208.5469169607, -140947.28851322923),
        (1795192.9893785124, 356152.97854254674),
        (530758.079019565, 668954.7596800169),
        (-309853.2783964032, -1541532.7554675443),
        (1213070.0930733175, 1097145.5185974697),
        (-1228247.943920761, -773888.551179463),
        (-554207.2432213802, 401411.8990695188),
    ],
    "NEI2016": [
        (0.0, -110589.55965320487),
        (-2066463.053651542, -290403.0815928243),
        (1845776.3535729724, 224515.92418459523),
        (549842.4483977046, 575299.4792623082),
        (-309377.09304183396, -1668877.3176074345),
        (1266623.2685378056, 1007635.9929630421),
        (-1239963.1270495383, -909332.8255445026),
        (-571190.8151147817, 298694.874228091),
    ],
}

# lambert_conformal_construction corner-inverse golden (x, y, lon, lat), WRF.
_CONSTRUCT_WRF = [
    (-2e6, -1.5e6, -116.10017801101773, 23.320805943967475),
    (-1e6, -1.5e6, -106.68789739792601, 24.883956953152033),
    (0.0, -1.5e6, -97.0, 25.415772540363083),
    (1e6, -1.5e6, -87.31210260207399, 24.883956953152033),
    (2e6, -1.5e6, -77.89982198898227, 23.320805943967475),
    (-2e6, -0.5e6, -118.62443079701725, 31.92388539661814),
    (-1e6, -0.5e6, -108.01300959338514, 33.76904204570805),
    (0.0, -0.5e6, -97.0, 34.39829502737979),
    (1e6, -0.5e6, -85.98699040661486, 33.76904204570805),
    (2e6, -0.5e6, -75.37556920298275, 31.92388539661814),
    (-2e6, 0.5e6, -121.89275561686046, 40.7292258345734),
    (-1e6, 0.5e6, -109.75450863032499, 42.90012555470361),
    (0.0, 0.5e6, -97.0, 43.64290686620447),
    (1e6, 0.5e6, -84.24549136967501, 42.90012555470361),
    (2e6, 0.5e6, -72.10724438313954, 40.7292258345734),
    (-2e6, 1.5e6, -126.27323349556194, 49.51039356753986),
    (-1e6, 1.5e6, -112.14243848502849, 52.06011386781491),
    (0.0, 1.5e6, -97.0, 52.93698916474947),
    (1e6, 1.5e6, -81.85756151497151, 52.06011386781491),
    (2e6, 1.5e6, -67.72676650443806, 49.51039356753986),
]


def test_parse_proj_string_campfire():
    p = parse_proj_string(CAMPFIRE_SR)
    assert p["proj"] == "lcc"
    assert p["lat_1"] == 30.0 and p["lat_2"] == 60.0
    assert p["lat_0"] == 39.0 and p["lon_0"] == -97.0
    assert p["datum"] == "WGS84" and p["no_defs"] is True


def test_lcc_inverse_matches_esd_construction_golden():
    """Corner (x,y) -> (lon,lat) reproduces the ESD construction golden exactly."""
    for x, y, glon, glat in _CONSTRUCT_WRF:
        lon, lat = lcc_inverse(x, y, _WRF)
        assert float(lon) == pytest.approx(glon, abs=1e-9)
        assert float(lat) == pytest.approx(glat, abs=1e-9)


@pytest.mark.parametrize("name,params", [("WRF", _WRF), ("NEI2016", _NEI)])
def test_lcc_forward_matches_esd_reproject_golden(name, params):
    """Forward (lon,lat) -> (x,y) matches the parameterized ESD reproject rule."""
    for (lon, lat), (gx, gy) in zip(_REPROJ_COORDS, _REPROJ_FWD[name]):
        x, y = lcc_forward(lon, lat, params)
        # ESD tolerance: forward_relative 1e-7, forward_absolute 1e-4.
        assert float(x) == pytest.approx(gx, rel=1e-7, abs=1e-4)
        assert float(y) == pytest.approx(gy, rel=1e-7, abs=1e-4)


@pytest.mark.parametrize("params", [_WRF, _NEI])
def test_lcc_roundtrip_identity(params):
    xs = np.array([-2e6, -1e6, 0.0, 1e6, 2e6])
    ys = np.array([-1.5e6, 0.0, 1.5e6, 0.5e6, -0.5e6])
    lon, lat = lcc_inverse(xs, ys, params)
    xb, yb = lcc_forward(lon, lat, params)
    assert np.allclose(xb, xs, atol=1e-6)
    assert np.allclose(yb, ys, atol=1e-6)


def test_central_meridian_invariant():
    """x == 0 inverts to exactly lon_0 for both parameterizations."""
    for params in (_WRF, _NEI):
        lon, _ = lcc_inverse(0.0, 0.5e6, params)
        assert float(lon) == pytest.approx(params["lon_0"], abs=1e-12)


def test_longlat_reproject_is_identity():
    x = np.array([10.0, 20.0, -5.0])
    y = np.array([1.0, 2.0, 3.0])
    lon, lat = reproject_xy_to_lonlat(x, y, "+proj=longlat +datum=WGS84")
    assert np.array_equal(lon, x) and np.array_equal(lat, y)
    # Empty/None spatial_ref is also identity.
    lon2, lat2 = reproject_xy_to_lonlat(x, y, None)
    assert np.array_equal(lon2, x) and np.array_equal(lat2, y)


# --------------------------------------------------------------------------
# bspline_regrid.esm — byte-level reproduction of the golden (tol 1e-12)
# --------------------------------------------------------------------------


def test_bspline_linear_golden():
    got = bspline_regrid_linear_1d(
        [2.0, 5.0, 8.0, 11.0, 14.0], [1, 2, 3, 4], [0.5, 0.5, 0.2999999999999998, 0.0]
    )
    assert np.allclose(got, [3.5, 6.5, 8.899999999999999, 11.0], atol=1e-12)


def test_bspline_cubic_golden():
    F = [2.0, 1.5, 1.0, -0.10000000000000009, -2.4000000000000004, -6.5, -13.000000000000002]
    got = bspline_regrid_cubic_1d(F, [1, 2, 3, 4], [0.5, 0.5, 0.2999999999999998, 0.0])
    assert np.allclose(
        got, [1.2875, 0.5625, -0.6367000000000003, -2.4000000000000004], atol=1e-12
    )


def test_bspline_bilinear_golden():
    F = np.array(
        [[1.0, 0.5, 0.0, -0.5], [3.0, 2.8, 2.6, 2.4],
         [5.0, 5.1, 5.2, 5.3], [7.0, 7.4, 7.8, 8.2]]
    )
    got = bspline_regrid_bilinear_2d(
        F, [1, 2, 3, 2], [1, 3, 2, 1],
        [0.5, 0.5, 0.0, 0.19999999999999996], [0.5, 0.0, 0.30000000000000004, 0.7],
    )
    assert np.allclose(got, [1.825, 3.9, 5.13, 3.3019999999999996], atol=1e-12)


# --------------------------------------------------------------------------
# conservative_regrid_overlap_join.esm — conservation + partition-of-unity
# --------------------------------------------------------------------------

_SRC_POLYS = [
    np.array([[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]),
    np.array([[1.0, 0.0], [2.0, 0.0], [2.0, 1.0], [1.0, 1.0]]),
    np.array([[2.0, 0.0], [3.0, 0.0], [3.0, 1.0], [2.0, 1.0]]),
]
_TGT_POLYS = [
    np.array([[0.0, 0.0], [1.5, 0.0], [1.5, 1.0], [0.0, 1.0]]),
    np.array([[1.5, 0.0], [2.0, 0.0], [2.0, 1.0], [1.5, 1.0]]),
    np.array([[2.0, 0.0], [3.0, 0.0], [3.0, 1.0], [2.0, 1.0]]),
]
_F_SRC = np.array([10.0, 20.0, 30.0])


def test_conservative_invariants_planar():
    """The two binding-independent physical invariants (ESD primary gate)."""
    F_tgt, A, A_j = conservative_regrid(
        _F_SRC, _SRC_POLYS, _TGT_POLYS, manifold="planar", atol=1e-15
    )
    # Partition of unity: weights over each covered target cell sum to 1.
    W = A / np.where(A_j > 0, A_j, 1.0)
    assert np.allclose(W.sum(axis=0), 1.0, atol=1e-12)
    # Global conservation: target mass == source mass.
    source_mass = float((A.sum(axis=1) * _F_SRC).sum())
    target_mass = float((A_j * F_tgt).sum())
    assert target_mass == pytest.approx(source_mass, rel=1e-12)
    # Field values (planar areas; matches the spherical golden to 5 sig figs).
    assert np.allclose(F_tgt, [40.0 / 3.0, 20.0, 30.0], atol=1e-9)


def test_conservative_spherical_golden():
    spherely = pytest.importorskip("spherely")  # noqa: F841
    F_tgt, A, A_j = conservative_regrid(
        _F_SRC, _SRC_POLYS, _TGT_POLYS, manifold="spherical", atol=1e-15
    )
    assert np.allclose(
        A_j,
        [0.00045691356105173966, 0.00015230194360827846, 0.00030460968486220217],
        rtol=1e-9,
    )
    assert np.allclose(F_tgt, [13.333319235239143, 20.0, 29.999999999999996], rtol=1e-9)
    W = A / np.where(A_j > 0, A_j, 1.0)
    assert np.allclose(W.sum(axis=0), 1.0, atol=1e-12)


def test_cell_average_point_golden():
    got = cell_average_regrid(
        [10.0, 20.0, 30.0], [0.3, 0.7, 1.5], [0.5, 0.2, 0.5],
        [0.0, 1.0, 2.0], [0.0, 0.0, 0.0], dx=1.0, dy=1.0, missing_value=-999.0,
    )
    assert list(got) == [15.0, 30.0, -999.0]


# --------------------------------------------------------------------------
# lev_min_surface_reduce.esm
# --------------------------------------------------------------------------


def test_lev_min_golden():
    F3 = np.array(
        [[[111.0, 112.0, 113.0], [121.0, 122.0, 123.0]],
         [[211.0, 212.0, 213.0], [221.0, 222.0, 223.0]]]
    )  # (x, y, lev)
    surf = lev_min_reduce(F3, [3.0, 1.0, 2.0], lev_axis=2)
    assert surf.tolist() == [[112.0, 122.0], [212.0, 222.0]]


# --------------------------------------------------------------------------
# Target grid construction + end-to-end driver onto camp_fire_surface
# --------------------------------------------------------------------------


def test_build_target_grid_campfire_surface():
    tg = build_target_grid(_campfire_surface_domain())
    assert tg.dims == ["x", "y"]
    assert tg.shape == (19, 21)
    assert len(tg.corner_rings) == 19 * 21
    assert tg.corner_rings[0].shape == (4, 2)
    # The LCC inverse lands the grid on Paradise, CA (Camp Fire, Nov 2018).
    assert -122.0 < float(tg.center_lon.min()) and float(tg.center_lon.max()) < -121.0
    assert 39.0 < float(tg.center_lat.min()) and float(tg.center_lat.max()) < 40.5


def test_regrid_pipeline_bspline_linear_exact():
    """A linear field regrids exactly through reproject + bilinear sampling."""
    tg = build_target_grid(_campfire_surface_domain())
    src_lon = np.linspace(float(tg.center_lon.min()) - 0.1, float(tg.center_lon.max()) + 0.1, 6)
    src_lat = np.linspace(float(tg.center_lat.min()) - 0.1, float(tg.center_lat.max()) + 0.1, 5)
    LON, LAT = np.meshgrid(src_lon, src_lat)
    field = 2.0 * LON + 3.0 * LAT
    out = regrid_field(field, src_lon, src_lat, tg, "bspline")
    exact = (2.0 * tg.center_lon + 3.0 * tg.center_lat).reshape(-1)
    assert out.shape == (19 * 21,)
    assert np.allclose(out, exact, atol=1e-9)


def test_regrid_pipeline_3d_levmin_then_bspline():
    tg = build_target_grid(_campfire_surface_domain())
    src_lon = np.linspace(float(tg.center_lon.min()) - 0.1, float(tg.center_lon.max()) + 0.1, 6)
    src_lat = np.linspace(float(tg.center_lat.min()) - 0.1, float(tg.center_lat.max()) + 0.1, 5)
    LON, LAT = np.meshgrid(src_lon, src_lat)
    base = 2.0 * LON + 3.0 * LAT
    F3 = np.stack([base + 100.0 * lv for lv in range(3)], axis=0)  # (lev,lat,lon), ascending
    out = regrid_loader_field(F3, src_lon, src_lat, tg, "bspline", lev_coord=[1.0, 2.0, 3.0])
    exact = (2.0 * tg.center_lon + 3.0 * tg.center_lat).reshape(-1)  # lev=min -> slice 0
    assert np.allclose(out, exact, atol=1e-9)


def test_regrid_pipeline_conservative_preserves_constant():
    tg = build_target_grid(_campfire_surface_domain())
    src_lon = np.linspace(float(tg.center_lon.min()) - 0.1, float(tg.center_lon.max()) + 0.1, 6)
    src_lat = np.linspace(float(tg.center_lat.min()) - 0.1, float(tg.center_lat.max()) + 0.1, 5)
    field = np.full((src_lat.size, src_lon.size), 288.0)
    out = regrid_field(field, src_lon, src_lat, tg, "conservative", manifold="planar")
    covered = out[out != 0.0]
    assert covered.size == out.size  # every target cell is covered
    assert np.allclose(covered, 288.0, atol=1e-9)


# --------------------------------------------------------------------------
# Provider integration glue (the simulate() seam)
# --------------------------------------------------------------------------


def _loader_field(var, method):
    from earthsci_toolkit.esm_types import RegridSpec
    from earthsci_toolkit.flatten import LoaderField

    return LoaderField(
        name=f"ERA5.pl.{var}", owner="ERA5", subkey="pl", var=var,
        loader=SimpleNamespace(temporal=None), cadence="discrete",
        regrid=RegridSpec(method=method) if method else None,
    )


def _fake_result(values, src_lon, src_lat, lev=None):
    coords = {"lon": np.asarray(src_lon), "lat": np.asarray(src_lat)}
    if lev is not None:
        coords["lev"] = np.asarray(lev)
    ds = SimpleNamespace(coords=coords)
    return SimpleNamespace(variables={"u": values, "t": values}, dataset=ds)


def test_provider_glue_regrids_loaded_field():
    from earthsci_toolkit.simulation import _regrid_loaded_field

    tg = build_target_grid(_campfire_surface_domain())
    src_lon = np.linspace(float(tg.center_lon.min()) - 0.1, float(tg.center_lon.max()) + 0.1, 6)
    src_lat = np.linspace(float(tg.center_lat.min()) - 0.1, float(tg.center_lat.max()) + 0.1, 5)
    LON, LAT = np.meshgrid(src_lon, src_lat)
    base = 2.0 * LON + 3.0 * LAT
    F3 = np.stack([base + 100.0 * lv for lv in range(3)], axis=0)
    result = _fake_result(F3, src_lon, src_lat, lev=[1.0, 2.0, 3.0])

    out = _regrid_loaded_field(_loader_field("u", "bspline"), result, tg)
    exact = (2.0 * tg.center_lon + 3.0 * tg.center_lat).reshape(-1)
    assert np.allclose(out, exact, atol=1e-9)


def test_provider_glue_falls_back_without_spec_or_coords():
    from earthsci_toolkit.simulation import _regrid_loaded_field

    tg = build_target_grid(_campfire_surface_domain())
    src_lon = np.linspace(-122.0, -121.2, 5)
    src_lat = np.linspace(39.4, 40.1, 4)
    LON, LAT = np.meshgrid(src_lon, src_lat)
    result = _fake_result(2.0 * LON + 3.0 * LAT, src_lon, src_lat)

    # No regrid method -> None (caller keeps the raw array).
    assert _regrid_loaded_field(_loader_field("u", None), result, tg) is None
    # Method set but source exposes no coords -> None.
    nocoord = SimpleNamespace(variables={"u": np.zeros((4, 5))}, dataset=SimpleNamespace(coords={}))
    assert _regrid_loaded_field(_loader_field("u", "bspline"), nocoord, tg) is None
