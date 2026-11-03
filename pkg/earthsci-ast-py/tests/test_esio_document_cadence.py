"""providers_from_document over a time-varying esm source: esm URL templates,
a bound custom substitution, a mirror, and a calendar-month cadence (EarthSciIO
spec/esm-sources.md). Skipped unless an ``earthsciio`` with ``source_from_esm``
is importable."""

from __future__ import annotations

import datetime as _dt

import numpy as np
import pytest

esio = pytest.importorskip("earthsciio")
if not hasattr(esio, "source_from_esm"):
    pytest.skip("earthsciio predates source_from_esm", allow_module_level=True)
netCDF4 = pytest.importorskip("netCDF4")

from earthsci_ast.data_sources.esio_provider import providers_from_document  # noqa: E402

UTC = _dt.timezone.utc


def _month_file(path, month):
    with netCDF4.Dataset(path, "w", format="NETCDF3_CLASSIC") as ds:
        ds.createDimension("TSTEP", None)
        ds.createDimension("ROW", 2)
        v = ds.createVariable("NOX", "f4", ("TSTEP", "ROW"))
        v[:] = np.array([[month * 10.0, month * 10.0 + 1]], dtype="f4")


def _doc(tmp_path):
    mirror = tmp_path / "mirror"
    mirror.mkdir()
    for m in (1, 2, 3):
        _month_file(mirror / f"nei_agr_{m:02d}.ncf", m)
    return {
        "esm": "1.0.0",
        "data_sources": {
            "NEI": {
                "kind": "grid",
                "source": {
                    "url_template": f"file://{tmp_path}/primary/nei_{{sector}}_{{date:%m}}.ncf",
                    "mirrors": [f"file://{mirror}/nei_{{sector}}_{{date:%m}}.ncf"],
                },
                "temporal": {
                    "start": "2016-01-01T00:00:00Z",
                    "end": "2016-12-31T23:59:59Z",
                    "file_period": "P1M",
                    "frequency": "P1M",
                    "records_per_file": 1,
                    "time_variable": "TSTEP",
                },
                "metadata": {"esio_format": "netcdf"},
            }
        },
        "models": {
            "Emis": {
                "variables": {
                    "nox": {
                        "type": "parameter",
                        "units": "mol/s",
                        "shape": ["row"],
                        "update": {
                            "kind": "data",
                            "source": "NEI",
                            "from": {"file_variable": "NOX", "unit_conversion": 2.0},
                        },
                    }
                }
            }
        },
    }


def _ts(*a):
    return _dt.datetime(*a, tzinfo=UTC).timestamp()


def test_a_monthly_source_with_a_bound_sector_reads_each_month(tmp_path):
    window = (_dt.datetime(2016, 1, 1, tzinfo=UTC), _dt.datetime(2016, 4, 1, tzinfo=UTC))
    provs = providers_from_document(
        _doc(tmp_path),
        cache_root=str(tmp_path / "cache"),
        substitutions={"NEI": {"sector": "agr"}},
        window=window,
    )
    p = provs["Emis.nox"]
    assert not p.is_const
    # calendar months, not a mean month of 30.436875 days
    assert [t.timestamp() for t in p.refresh_times()] == [
        _ts(2016, 1, 1),
        _ts(2016, 2, 1),
        _ts(2016, 3, 1),
    ]
    # the primary location is missing; each month comes from its mirror,
    # converted by the declared unit_conversion
    np.testing.assert_array_equal(p.sample(_ts(2016, 2, 29, 23)), [40.0, 42.0])
    np.testing.assert_array_equal(p.sample(_ts(2016, 3, 1)), [60.0, 62.0])


def test_an_unbound_sector_is_refused(tmp_path):
    with pytest.raises(Exception, match="esm_template_unbound"):
        providers_from_document(_doc(tmp_path), cache_root=str(tmp_path / "cache"))


def test_the_two_record_bracket_is_the_consumers_choice(tmp_path):
    window = (_dt.datetime(2016, 1, 1, tzinfo=UTC), _dt.datetime(2016, 4, 1, tzinfo=UTC))
    provs = providers_from_document(
        _doc(tmp_path),
        cache_root=str(tmp_path / "cache"),
        substitutions={"NEI": {"sector": "agr"}},
        window=window,
        records_per_sample={"Emis.nox": 2},
    )
    got = provs["Emis.nox"].sample(_ts(2016, 2, 15))
    np.testing.assert_array_equal(got, [[40.0, 42.0], [60.0, 62.0]])


def _two_record_doc(tmp_path, *, source_rps=None):
    """`_doc` with three parameters reading NEI, declared with the record axis
    `rec` (an interval of size 2) first: `pair` sets
    `from.records_per_sample: 2`, `single` sets 1, and `inherited` sets
    nothing, so it takes the source's `temporal.records_per_sample`."""
    doc = _doc(tmp_path)
    doc["index_sets"] = {
        "rec": {"kind": "interval", "size": 2},
        "row": {"kind": "interval", "size": 2},
    }
    if source_rps is not None:
        doc["data_sources"]["NEI"]["temporal"]["records_per_sample"] = source_rps

    def param(shape, rps):
        frm = {"file_variable": "NOX"}
        if rps is not None:
            frm["records_per_sample"] = rps
        return {
            "type": "parameter",
            "units": "mol/s",
            "shape": shape,
            "update": {"kind": "data", "source": "NEI", "from": frm},
        }

    doc["models"]["Emis"]["variables"] = {
        "pair": param(["rec", "row"], 2),
        "single": param(["row"], 1),
        "inherited": param(["rec", "row"] if source_rps == 2 else ["row"], None),
    }
    return doc


def _two_record_providers(tmp_path, **kw):
    window = (_dt.datetime(2016, 1, 1, tzinfo=UTC), _dt.datetime(2016, 4, 1, tzinfo=UTC))
    return providers_from_document(
        _two_record_doc(tmp_path, **kw),
        cache_root=str(tmp_path / "cache"),
        substitutions={"NEI": {"sector": "agr"}},
        window=window,
    )


def test_a_two_record_parameter_gets_the_records_before_and_after_t(tmp_path):
    provs = _two_record_providers(tmp_path)
    # from.records_per_sample = 2: February's record (at or before t) and
    # March's, stacked along the first declared dimension.
    np.testing.assert_array_equal(
        provs["Emis.pair"].sample(_ts(2016, 2, 15)), [[20.0, 21.0], [30.0, 31.0]]
    )
    # The same source read with 1 record, by an explicit 1 and by default.
    np.testing.assert_array_equal(provs["Emis.single"].sample(_ts(2016, 2, 15)), [20.0, 21.0])
    np.testing.assert_array_equal(provs["Emis.inherited"].sample(_ts(2016, 2, 15)), [20.0, 21.0])


def test_the_sources_records_per_sample_is_the_default(tmp_path):
    provs = _two_record_providers(tmp_path, source_rps=2)
    np.testing.assert_array_equal(
        provs["Emis.inherited"].sample(_ts(2016, 1, 1)), [[10.0, 11.0], [20.0, 21.0]]
    )
    # A parameter's own value overrides the source's.
    np.testing.assert_array_equal(provs["Emis.single"].sample(_ts(2016, 1, 1)), [10.0, 11.0])


def test_the_run_time_option_overrides_the_document(tmp_path):
    window = (_dt.datetime(2016, 1, 1, tzinfo=UTC), _dt.datetime(2016, 4, 1, tzinfo=UTC))
    provs = providers_from_document(
        _two_record_doc(tmp_path),
        cache_root=str(tmp_path / "cache"),
        substitutions={"NEI": {"sector": "agr"}},
        window=window,
        records_per_sample={"Emis.pair": 1},
    )
    np.testing.assert_array_equal(provs["Emis.pair"].sample(_ts(2016, 2, 15)), [20.0, 21.0])
