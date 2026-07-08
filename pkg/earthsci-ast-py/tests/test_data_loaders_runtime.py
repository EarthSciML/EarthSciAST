"""Tests for the runtime data loaders package (earthsci_ast.data_loaders).

Covers URL template expansion, time->file resolution, mirror fallback,
variable remapping with unit conversion, regridding, and the top-level
load_data dispatcher. Uses in-memory fake datasets so the tests do not
require xarray/netCDF installs to pass.
"""

from __future__ import annotations

import datetime as dt
from typing import List

import pytest

from earthsci_ast import (
    DataLoader,
    DataLoaderKind,
    DataLoaderSource,
    DataLoaderTemporal,
    DataLoaderVariable,
    DataLoaderDispatchError,
    ExprNode,
    GridLoader,
    MirrorFallbackError,
    PointsLoader,
    StaticLoader,
    TimeResolutionError,
    UrlTemplateError,
    apply_unit_conversion,
    apply_variable_mapping,
    expand_url_template,
    expand_with_mirrors,
    file_anchor_for_time,
    file_anchors_in_range,
    load_data,
    open_with_fallback,
    parse_iso_duration,
    records_for_file,
    resolve_files,
    template_placeholders,
)


# ---------------------------------------------------------------------------
# URL template expansion
# ---------------------------------------------------------------------------


class TestUrlTemplate:
    def test_date_format_substitution(self):
        tpl = "https://s3/{date:%Y}/{date:%m}/{date:%Y%m%d}.nc"
        url = expand_url_template(tpl, date=dt.datetime(2024, 3, 5))
        assert url == "https://s3/2024/03/20240305.nc"

    def test_accepts_iso_string_for_date(self):
        tpl = "{date:%Y-%m-%d}.nc"
        assert expand_url_template(tpl, date="2024-03-05T00:00:00Z") == "2024-03-05.nc"

    def test_named_substitutions(self):
        tpl = "emissions/{species}/{sector}/{var}.nc"
        url = expand_url_template(tpl, variables={"species": "SO2"}, sector="ENE", var="emi")
        assert url == "emissions/SO2/ENE/emi.nc"

    def test_missing_placeholder_raises(self):
        with pytest.raises(UrlTemplateError, match="unfilled placeholder"):
            expand_url_template("{species}.nc")

    def test_date_required_raises(self):
        with pytest.raises(UrlTemplateError, match="requires a date"):
            expand_url_template("{date:%Y}.nc")

    def test_template_placeholders(self):
        tpl = "{date:%Y}/{species}/{sector}.nc"
        assert template_placeholders(tpl) == {"date", "species", "sector"}

    def test_expand_with_mirrors_returns_fallback_list(self):
        urls = expand_with_mirrors(
            "https://primary/{date:%Y}.nc",
            ["https://mirror1/{date:%Y}.nc", "https://mirror2/{date:%Y}.nc"],
            date=dt.datetime(2024, 1, 1),
        )
        assert urls == [
            "https://primary/2024.nc",
            "https://mirror1/2024.nc",
            "https://mirror2/2024.nc",
        ]

    def test_bad_mirror_is_skipped(self):
        urls = expand_with_mirrors(
            "https://primary/{date:%Y}.nc",
            ["https://mirror/{species}.nc"],
            date=dt.datetime(2024, 1, 1),
        )
        assert urls == ["https://primary/2024.nc"]


# ---------------------------------------------------------------------------
# Time resolution
# ---------------------------------------------------------------------------


class TestTimeResolution:
    def test_parse_duration_day(self):
        d = parse_iso_duration("P1D")
        assert d.days == 1 and d.seconds == 0.0

    def test_parse_duration_three_hours(self):
        d = parse_iso_duration("PT3H")
        assert d.seconds == pytest.approx(3 * 3600)

    def test_parse_duration_fifty_years(self):
        d = parse_iso_duration("P50Y")
        assert d.years == 50

    def test_parse_duration_invalid(self):
        with pytest.raises(TimeResolutionError):
            parse_iso_duration("bogus")

    def test_parse_duration_all_zero(self):
        with pytest.raises(TimeResolutionError):
            parse_iso_duration("P0D")

    def test_anchor_daily_period(self):
        t = dt.datetime(2024, 3, 5, 18, 0)
        assert file_anchor_for_time(t, file_period="P1D") == dt.datetime(2024, 3, 5)

    def test_anchor_monthly_period(self):
        t = dt.datetime(2024, 3, 5)
        assert file_anchor_for_time(t, file_period="P1M") == dt.datetime(2024, 3, 1)

    def test_anchor_three_hour_period(self):
        t = dt.datetime(2024, 3, 5, 7, 0)
        out = file_anchor_for_time(t, file_period="PT3H")
        assert out == dt.datetime(2024, 3, 5, 6, 0)

    def test_anchor_with_start(self):
        out = file_anchor_for_time(
            dt.datetime(1975, 6, 15),
            file_period="P50Y",
            start="1750-01-01",
        )
        assert out == dt.datetime(1950, 1, 1)

    def test_anchors_in_range(self):
        anchors = file_anchors_in_range(
            dt.datetime(2024, 3, 5),
            dt.datetime(2024, 3, 8, 23, 59),
            file_period="P1D",
        )
        assert anchors == [
            dt.datetime(2024, 3, 5),
            dt.datetime(2024, 3, 6),
            dt.datetime(2024, 3, 7),
            dt.datetime(2024, 3, 8),
        ]

    def test_records_per_file_int(self):
        assert records_for_file(8) == 8

    def test_records_per_file_auto(self):
        n = records_for_file("auto", file_period="P1D", frequency="PT3H")
        assert n == 8

    def test_records_per_file_none(self):
        assert records_for_file(None) is None


# ---------------------------------------------------------------------------
# Mirror fallback
# ---------------------------------------------------------------------------


class TestMirrorFallback:
    def test_first_success_wins(self):
        calls: List[str] = []

        def opener(url: str) -> str:
            calls.append(url)
            return f"opened-{url}"

        result = open_with_fallback(["a", "b", "c"], opener)
        assert result == "opened-a" and calls == ["a"]

    def test_fallback_on_oserror(self):
        calls: List[str] = []

        def opener(url: str) -> str:
            calls.append(url)
            if url != "c":
                raise OSError(f"fail {url}")
            return "ok"

        assert open_with_fallback(["a", "b", "c"], opener) == "ok"
        assert calls == ["a", "b", "c"]

    def test_all_fail_raises(self):
        def opener(_url: str) -> str:
            raise OSError("nope")

        with pytest.raises(MirrorFallbackError) as excinfo:
            open_with_fallback(["a", "b"], opener)
        assert excinfo.value.urls == ["a", "b"]
        assert len(excinfo.value.errors) == 2


# ---------------------------------------------------------------------------
# Unit conversion + variable mapping
# ---------------------------------------------------------------------------


class TestUnitConversion:
    def test_numeric_scale(self):
        out = apply_unit_conversion([1.0, 2.0], 2.0, variable_name="x")
        assert list(out) == [2.0, 4.0]

    def test_identity_when_none(self):
        vals = [1.0, 2.0, 3.0]
        assert apply_unit_conversion(vals, None, variable_name="x") is vals

    def test_constant_expression(self):
        expr = ExprNode(op="*", args=[1e-9, 3.0])
        out = apply_unit_conversion([1.0, 2.0], expr, variable_name="x")
        assert list(out) == [pytest.approx(3e-9), pytest.approx(6e-9)]

    def test_open_expression(self):
        expr = ExprNode(op="+", args=["x", 273.15])
        out = apply_unit_conversion([0.0, 100.0], expr, variable_name="T")
        assert list(out) == [pytest.approx(273.15), pytest.approx(373.15)]

    def test_apply_variable_mapping_renames_and_converts(self):
        variables = {
            "o3": DataLoaderVariable(
                file_variable="O3_concentration",
                units="ppb",
                unit_conversion=1000.0,
            ),
        }
        raw = {"O3_concentration": [1.0, 2.0]}
        out = apply_variable_mapping(raw, variables)
        assert "o3" in out and "O3_concentration" not in out
        assert list(out["o3"]) == [1000.0, 2000.0]

    def test_strict_missing_raises(self):
        variables = {
            "o3": DataLoaderVariable(file_variable="O3", units="ppb"),
        }
        with pytest.raises(KeyError):
            apply_variable_mapping({}, variables, strict=True)

    def test_non_strict_skips(self):
        variables = {
            "o3": DataLoaderVariable(file_variable="O3", units="ppb"),
        }
        assert apply_variable_mapping({}, variables, strict=False) == {}


# ---------------------------------------------------------------------------
# GridLoader (fake xarray-like dataset)
# ---------------------------------------------------------------------------


class FakeDataArray:
    def __init__(self, values):
        self.values = values

    def __mul__(self, other):
        import numpy as np  # noqa: PLC0415

        return np.asarray(self.values) * other


class FakeDataset:
    def __init__(self, data_vars, coords):
        self._data = {k: FakeDataArray(v) for k, v in data_vars.items()}
        self.coords = {k: FakeDataArray(v) for k, v in coords.items()}

    @property
    def data_vars(self):
        return list(self._data.keys())

    def __getitem__(self, name):
        return self._data[name]


def _make_grid_loader(
    tpl: str = "mem://{date:%Y%m%d}.nc",
    variables=None,
    temporal=None,
) -> DataLoader:
    return DataLoader(
        name="fake",
        kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template=tpl),
        variables=variables
        or {
            "u": DataLoaderVariable(file_variable="U", units="m/s"),
        },
        temporal=temporal or DataLoaderTemporal(file_period="P1D"),
    )


class TestGridLoader:
    def test_load_applies_variable_mapping(self):
        import numpy as np  # noqa: PLC0415

        dl = _make_grid_loader(
            variables={
                "u": DataLoaderVariable(file_variable="U", units="m/s", unit_conversion=2.0),
            },
        )
        ds = FakeDataset(
            data_vars={"U": np.array([[1.0, 2.0], [3.0, 4.0]])},
            coords={"lon": [0.0, 1.0], "lat": [0.0, 1.0]},
        )

        def opener(url: str):
            assert url == "mem://20240305.nc"
            return ds

        result = GridLoader(dl).load(
            time=dt.datetime(2024, 3, 5, 12, 0),
            opener=opener,
        )
        assert result.urls_tried == ["mem://20240305.nc"]
        assert np.allclose(result.variables["u"], [[2.0, 4.0], [6.0, 8.0]])

    def test_fallback_on_open_error(self):
        import numpy as np  # noqa: PLC0415

        dl = DataLoader(
            name="fake",
            kind=DataLoaderKind.GRID,
            source=DataLoaderSource(
                url_template="mem://primary/{date:%Y}.nc",
                mirrors=["mem://mirror/{date:%Y}.nc"],
            ),
            variables={"u": DataLoaderVariable(file_variable="U", units="m/s")},
            temporal=DataLoaderTemporal(file_period="P1Y"),
        )
        ds = FakeDataset(
            data_vars={"U": np.array([1.0, 2.0])},
            coords={"lon": [0.0, 1.0], "lat": [0.0]},
        )

        def opener(url: str):
            if "primary" in url:
                raise OSError("primary down")
            return ds

        result = GridLoader(dl).load(time=dt.datetime(2024, 1, 1), opener=opener)
        assert result.urls_tried == [
            "mem://primary/2024.nc",
            "mem://mirror/2024.nc",
        ]

    def test_snaps_time_to_file_anchor(self):
        import numpy as np  # noqa: PLC0415

        dl = _make_grid_loader(tpl="mem://{date:%Y-%m-%d}.nc")
        ds = FakeDataset(
            data_vars={"U": np.array([1.0])},
            coords={"lon": [0.0], "lat": [0.0]},
        )
        seen: List[str] = []

        def opener(url: str):
            seen.append(url)
            return ds

        GridLoader(dl).load(time=dt.datetime(2024, 3, 5, 18, 30), opener=opener)
        assert seen == ["mem://2024-03-05.nc"]


# ---------------------------------------------------------------------------
# PointsLoader
# ---------------------------------------------------------------------------


class TestPointsLoader:
    def _dl(self) -> DataLoader:
        return DataLoader(
            name="fake_points",
            kind=DataLoaderKind.POINTS,
            source=DataLoaderSource(
                url_template="mem://points?species={species}&date={date:%Y-%m-%d}"
            ),
            variables={
                "value": DataLoaderVariable(file_variable="value", units="ppb"),
            },
            temporal=DataLoaderTemporal(file_period="PT1H"),
        )

    def test_json_payload(self):
        dl = self._dl()
        body = b'{"results": [{"value": 1.0}, {"value": 2.0}]}'
        result = PointsLoader(dl).load(
            time=dt.datetime(2024, 3, 5, 12, 0),
            species="o3",
            fetcher=lambda _url: body,
        )
        assert result.urls_tried == ["mem://points?species=o3&date=2024-03-05"]
        assert result.variables["value"] == [1.0, 2.0]

    def test_csv_payload(self):
        dl = self._dl()
        body = b"value,station\n1.0,A\n2.0,B\n"
        result = PointsLoader(dl).load(
            time=dt.datetime(2024, 3, 5, 0, 0),
            species="o3",
            fetcher=lambda _url: body,
        )
        assert result.variables["value"] == ["1.0", "2.0"]

    def test_explicit_parser(self):
        dl = self._dl()
        parsed = [{"value": 42.0}]
        result = PointsLoader(dl).load(
            time=dt.datetime(2024, 3, 5, 0, 0),
            species="o3",
            fetcher=lambda _url: b"ignored",
            parser=lambda _body: parsed,
        )
        assert result.variables["value"] == [42.0]


# ---------------------------------------------------------------------------
# StaticLoader
# ---------------------------------------------------------------------------


class TestStaticLoader:
    def test_no_date_substitution(self):
        import numpy as np  # noqa: PLC0415

        dl = DataLoader(
            name="elev",
            kind=DataLoaderKind.STATIC,
            source=DataLoaderSource(url_template="mem://elevation.tif"),
            variables={
                "elevation": DataLoaderVariable(file_variable="elev", units="m"),
            },
        )
        ds = FakeDataset(
            data_vars={"elev": np.array([[100.0, 110.0]])},
            coords={"lon": [0.0, 1.0], "lat": [0.0]},
        )
        result = StaticLoader(dl).load(opener=lambda _url: ds)
        assert result.urls_tried == ["mem://elevation.tif"]
        assert np.allclose(result.variables["elevation"].values, [[100.0, 110.0]])


# ---------------------------------------------------------------------------
# Dispatch + resolve_files
# ---------------------------------------------------------------------------


class TestDispatch:
    def test_dispatches_grid(self):
        import numpy as np  # noqa: PLC0415

        dl = _make_grid_loader()
        ds = FakeDataset(
            data_vars={"U": np.array([1.0])},
            coords={"lon": [0.0], "lat": [0.0]},
        )
        result = load_data(dl, time=dt.datetime(2024, 3, 5), opener=lambda _u: ds)
        assert result.variables["u"] is not None

    def test_resolve_files_daily(self):
        dl = _make_grid_loader(tpl="mem://{date:%Y-%m-%d}.nc")
        urls = resolve_files(
            dl,
            start=dt.datetime(2024, 3, 5),
            end=dt.datetime(2024, 3, 7),
        )
        assert urls == [
            "mem://2024-03-05.nc",
            "mem://2024-03-06.nc",
            "mem://2024-03-07.nc",
        ]

    def test_resolve_files_for_real_fixture(self):
        import json
        from pathlib import Path
        from earthsci_ast import load

        fixture = Path(__file__).parent / "fixtures" / "data_loaders" / "geosfp.esm"
        raw = json.loads(fixture.read_text())
        raw.pop("_comment", None)
        esm = load(json.dumps(raw))
        dl = esm.data_loaders["GEOSFP"]
        urls = resolve_files(
            dl,
            start=dt.datetime(2024, 3, 5),
            end=dt.datetime(2024, 3, 7),
        )
        assert len(urls) == 3
        assert all("20240305" in urls[0] or "GEOSFP" in u for u in urls)
        assert "20240305" in urls[0]
        assert "20240307" in urls[-1]

    def test_resolve_files_requires_file_period(self):
        dl = DataLoader(
            name="x",
            kind=DataLoaderKind.GRID,
            source=DataLoaderSource(url_template="mem://static.nc"),
            variables={"v": DataLoaderVariable(file_variable="V", units="m/s")},
        )
        with pytest.raises(DataLoaderDispatchError):
            resolve_files(dl, start="2024-01-01", end="2024-01-02")
