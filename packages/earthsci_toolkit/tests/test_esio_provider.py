"""The opt-in EarthSciIO provider adapter (gap G8).

Skipped unless ``earthsciio`` is importable (it is an optional dependency that
ESS does not pull in on the default path).
"""
import datetime as _dt

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


def _field(url, *, temporal=None, fmt_meta=None, variables=("u",)):
    dl = DataLoader(
        name="ERA5.pl",
        kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template=url),
        variables={v: DataLoaderVariable(file_variable=v, units="1") for v in variables},
        temporal=temporal,
        metadata=fmt_meta or {},
    )
    return LoaderField(name="ERA5.pl.u", owner="ERA5", subkey="pl", var="u",
                       loader=dl, cadence="discrete" if temporal else "const")


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


def test_unsupported_format_raises_at_construction():
    # an ArcGIS exportImage (GeoTIFF) loader: EarthSciIO has no reader for it
    field = _field("https://x/exportImage?format=tiff&f=image")
    with pytest.raises(esio.BackendNotRegistered):
        esio_provider_factory(field, None)
