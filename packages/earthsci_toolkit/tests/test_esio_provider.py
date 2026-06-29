"""The opt-in EarthSciIO provider adapter (gap G8).

Skipped unless ``earthsciio`` is importable (it is an optional dependency that
ESS does not pull in on the default path).
"""
import datetime as _dt
import pathlib

import pytest

esio = pytest.importorskip("earthsciio")

from earthsci_toolkit.data_loaders.esio_provider import (  # noqa: E402
    esio_provider_factory,
    to_esio_loader,
    _esio_format,
)
from earthsci_toolkit.esm_types import (  # noqa: E402
    DataLoader, DataLoaderKind, DataLoaderSource, DataLoaderTemporal, DataLoaderVariable,
)
from earthsci_toolkit.flatten import LoaderField  # noqa: E402


def _field(url, *, temporal=None, fmt_meta=None, variables=("u",), name="ERA5.pl",
           file_vars=None):
    file_vars = file_vars or {v: v for v in variables}
    dl = DataLoader(
        name=name,
        kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template=url),
        variables={v: DataLoaderVariable(file_variable=file_vars[v], units="1")
                   for v in variables},
        temporal=temporal,
        metadata=fmt_meta or {},
    )
    var0 = variables[0]
    return LoaderField(name=f"{name}.{var0}", owner=name.split(".")[0],
                       subkey=name.split(".")[-1], var=var0,
                       loader=dl, cadence="discrete" if temporal else "const")


class _Target:
    """A minimal stand-in for the simulation lon/lat target grid (center_*)."""

    def __init__(self, lons, lats):
        import numpy as np

        self.center_lon = np.asarray(lons, dtype=float)
        self.center_lat = np.asarray(lats, dtype=float)


# A LANDFIRE-like ArcGIS ImageServer GeoTIFF loader (server-side subset).
_LANDFIRE_URL = (
    "https://lfps.usgs.gov/arcgis/rest/services/Landfire_{version}/"
    "{version}_{product}_CONUS/ImageServer/exportImage?bbox={bbox_west_deg},"
    "{bbox_south_deg},{bbox_east_deg},{bbox_north_deg}&bboxSR=4326&imageSR=4326&"
    "size={image_width},{image_height}&format=tiff&f=image"
)
_LANDFIRE_META = {
    "url_defaults": {"version": "LF2022", "product": "FBFM13", "size_cap": 4000},
    "native_resolution_deg": {"lon": 0.00027778, "lat": 0.00027778},
}


def test_format_inferred_from_url_suffix():
    assert _esio_format(_field("https://x/era5_{date:%Y}_{date:%m}.nc").loader) == "netcdf"
    assert _esio_format(_field("https://x/points.csv").loader) == "csv"


def test_to_esio_loader_maps_url_vars_and_temporal():
    t = DataLoaderTemporal(start="2018-11-08T00:00:00Z", frequency="PT1H",
                           file_period="P1M", time_variable="time")
    edl = to_esio_loader(_field("https://x/era5_{date:%Y}_{date:%m}.nc",
                                temporal=t, variables=("t", "u")))
    assert edl.format == "netcdf"
    assert list(edl.variables) == ["t", "u"]
    # url is a per-anchor resolver expanding the ESS template
    assert edl.url(_dt.datetime(2018, 11, 8)).endswith("era5_2018_11.nc")
    # temporal converted to naive-UTC start + timedelta cadence
    assert edl.temporal is not None
    assert edl.temporal.frequency == _dt.timedelta(hours=1)
    assert edl.temporal.start.tzinfo is None


def test_factory_builds_a_real_esio_provider():
    t = DataLoaderTemporal(start="2018-11-08T00:00:00Z", frequency="PT1H", file_period="P1M")
    field = _field("https://x/era5_{date:%Y}_{date:%m}.nc", temporal=t)
    window = (_dt.datetime(2018, 11, 8), _dt.datetime(2018, 11, 9))
    prov = esio_provider_factory(field, window)
    assert isinstance(prov, esio.Provider)
    assert not prov.is_const
    assert len(prov.refresh_times()) == 24  # hourly over a day


def test_geotiff_loader_resolves_bbox_and_builds_provider():
    """gap G3 + G1: a LANDFIRE GeoTIFF loader now maps to esio's `geotiff` reader,
    and the domain target fills the ArcGIS {bbox…}/size placeholders."""
    field = _field(_LANDFIRE_URL, fmt_meta=_LANDFIRE_META, variables=("fuel_model",),
                   file_vars={"fuel_model": "Band1"}, name="LANDFIRE.fuel")
    target = _Target([-121.6, -121.4], [39.7, 39.9])

    edl = to_esio_loader(field, target=target)
    assert edl.format == "geotiff"                       # was an unregistered "tiff"
    assert list(edl.variables) == ["Band1"]

    url = edl.url(_dt.datetime(2018, 11, 8))
    assert "{" not in url and "}" not in url             # every placeholder filled
    assert "Landfire_LF2022/LF2022_FBFM13_CONUS" in url
    assert "bbox=-121.6002" in url                        # envelope + one-cell pad
    assert "size=722,722" in url                          # ceil(span/res), capped

    # construction resolves the geotiff reader — no BackendNotRegistered now
    prov = esio_provider_factory(field, None, target=target)
    assert isinstance(prov, esio.Provider)


def test_truly_unregistered_format_still_raises():
    """The BackendNotRegistered path is intact for a format esio lacks (e.g. grib)."""
    field = _field("https://x/data.bin", fmt_meta={"esio_format": "grib"})
    with pytest.raises(esio.BackendNotRegistered):
        esio_provider_factory(field, None)


def test_cds_loader_builds_era5_request_url(monkeypatch):
    """gap G7: a metadata.cds ERA5 loader resolves to a real cds:// request URL
    (area from the domain, short→long variable names, trimmed pressure levels)."""
    from earthsciio.era5 import era5_area_from_bbox

    t = DataLoaderTemporal(start="2018-11-08T00:00:00Z", frequency="PT1H",
                           file_period="P1M", time_variable="valid_time")
    meta = {"cds": {"dataset": "reanalysis-era5-pressure-levels",
                    "format": "netcdf", "pressure_levels": [1000]}}
    field = _field("https://data.earthsci.dev/era5/era5_pl_{date:%Y}_{date:%m}.nc",
                   temporal=t, fmt_meta=meta, variables=("u", "t"))
    target = _Target([-121.6, -121.4], [39.7, 39.9])

    edl = to_esio_loader(field, target=target)
    assert edl.format == "netcdf"                         # downloaded asset is NetCDF
    assert list(edl.variables) == ["u", "t"]              # on-disk short names kept

    url = edl.url(_dt.datetime(2018, 11, 8, 14))
    dataset, request = esio.decode_cds_url(url)
    assert dataset == "reanalysis-era5-pressure-levels"
    assert request["area"] == era5_area_from_bbox(-121.6, 39.7, -121.4, 39.9)
    assert request["pressure_level"] == ["1000"]          # trimmed via metadata
    assert sorted(request["variable"]) == ["temperature", "u_component_of_wind"]
    assert request["year"] == ["2018"] and request["month"] == ["11"]

    # the cds transport is registered, so a provider builds without a network hit
    window = (_dt.datetime(2018, 11, 8), _dt.datetime(2018, 11, 9))
    prov = esio_provider_factory(field, window, target=target)
    assert isinstance(prov, esio.Provider)


def test_cds_loader_window_trims_to_calendar_month_and_days():
    """GAP-E: with a simulation window the CDS request covers only the window's
    CALENDAR month + days — not the whole month — and is robust to a drifting
    provider anchor (ERA5's P1M file period, approximated as fixed seconds from
    the 1940 availability start, can resolve a November time to an October
    anchor; the window's calendar month must win)."""
    t = DataLoaderTemporal(start="1940-01-01T00:00:00Z", frequency="PT1H",
                           file_period="P1M", time_variable="valid_time")
    meta = {"cds": {"dataset": "reanalysis-era5-pressure-levels",
                    "format": "netcdf", "pressure_levels": [1000]}}
    field = _field("https://data.earthsci.dev/era5/x.nc", temporal=t,
                   fmt_meta=meta, variables=("u", "t"))
    target = _Target([-121.6, -121.4], [39.7, 39.9])
    window = (_dt.datetime(2018, 11, 8, 14, 30), _dt.datetime(2018, 11, 9, 6, 30))

    edl = to_esio_loader(field, target=target, window=window)
    # Even when handed a DRIFTED October anchor, the window's calendar month wins.
    _, request = esio.decode_cds_url(edl.url(_dt.datetime(2018, 10, 25, 0)))
    assert request["month"] == ["11"]             # calendar month of the window
    assert request["day"] == ["08", "09"]         # only the window's days, not 1-30
    assert request["pressure_level"] == ["1000"]  # surface-only trim


def test_cds_loader_needs_a_target():
    """Without a domain target there is no CDS `area` — fail loud, not silently."""
    meta = {"cds": {"dataset": "reanalysis-era5-pressure-levels"}}
    field = _field("https://x/era5_{date:%Y}_{date:%m}.nc",
                   temporal=DataLoaderTemporal(start="2018-11-08T00:00:00Z",
                                               frequency="PT1H", file_period="P1M"),
                   fmt_meta=meta, variables=("u",))
    with pytest.raises(ValueError):
        to_esio_loader(field, target=None)


@pytest.mark.skipif(not (pathlib.Path.home() / ".cdsapirc").exists(),
                    reason="no ~/.cdsapirc credentials present")
def test_cds_credentials_resolve():
    """gap G7: the ERA5 path authenticates via ~/.cdsapirc (no network)."""
    assert esio.cds_api_key()                              # non-empty token
    assert esio.cds_api_url().startswith("https://")
