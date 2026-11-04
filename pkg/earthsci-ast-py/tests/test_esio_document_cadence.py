"""providers_from_document over a time-varying esm source: esm URL templates,
a bound custom substitution, a mirror, and a calendar-month cadence (EarthSciIO
spec/esm-sources.md). Skipped unless an ``earthsciio`` with ``source_from_esm``
is importable."""

from __future__ import annotations

import datetime as _dt
import json

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
        # Fixed-size, not unlimited: classic NetCDF allows an unlimited
        # dimension only first, and `NOX_T` puts it last.
        ds.createDimension("TSTEP", 1)
        ds.createDimension("ROW", 2)
        v = ds.createVariable("NOX", "f4", ("TSTEP", "ROW"))
        v[:] = np.array([[month * 10.0, month * 10.0 + 1]], dtype="f4")
        # The same values with the time dimension LAST, as some files store it.
        w = ds.createVariable("NOX_T", "f4", ("ROW", "TSTEP"))
        w[:] = np.array([[month * 10.0], [month * 10.0 + 1]], dtype="f4")


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
    doc = _doc(tmp_path)
    doc["index_sets"] = {
        "rec": {"kind": "interval", "size": 2},
        "row": {"kind": "interval", "size": 2},
    }
    nox = doc["models"]["Emis"]["variables"]["nox"]
    nox["shape"] = ["rec", "row"]
    nox["update"]["from"]["records_per_sample"] = 2
    provs = providers_from_document(
        doc,
        cache_root=str(tmp_path / "cache"),
        substitutions={"NEI": {"sector": "agr"}},
        window=window,
    )
    got = provs["Emis.nox"].sample(_ts(2016, 2, 15))
    np.testing.assert_array_equal(got, [[40.0, 42.0], [60.0, 62.0]])


def _two_record_doc(tmp_path, *, source_rps=None, file_variable="NOX", select=None):
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
        frm = {"file_variable": file_variable}
        if rps is not None:
            frm["records_per_sample"] = rps
        if select is not None:
            frm["select"] = {"axes": list(select)}
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


_WINDOW = (_dt.datetime(2016, 1, 1, tzinfo=UTC), _dt.datetime(2016, 4, 1, tzinfo=UTC))


def _providers(tmp_path, doc, **kw):
    return providers_from_document(
        doc,
        cache_root=str(tmp_path / "cache"),
        substitutions={"NEI": {"sector": "agr"}},
        window=_WINDOW,
        **kw,
    )


def _two_record_providers(tmp_path, **kw):
    return _providers(tmp_path, _two_record_doc(tmp_path, **kw))


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


def test_a_run_time_option_that_contradicts_the_document_is_refused(tmp_path):
    with pytest.raises(ValueError) as err:
        _providers(tmp_path, _two_record_doc(tmp_path), records_per_sample={"Emis.pair": 1})
    msg = str(err.value)
    assert "'Emis.pair'" in msg
    assert "gives parameter 'Emis.pair' 1" in msg and "effective value is 2" in msg
    assert "update.from.records_per_sample" in msg


def test_a_run_time_option_equal_to_the_document_is_accepted(tmp_path):
    provs = _providers(
        tmp_path,
        _two_record_doc(tmp_path),
        records_per_sample={"Emis.pair": 2, "Emis.single": 1, "Emis.inherited": 1.0},
    )
    np.testing.assert_array_equal(
        provs["Emis.pair"].sample(_ts(2016, 2, 15)), [[20.0, 21.0], [30.0, 31.0]]
    )
    np.testing.assert_array_equal(provs["Emis.single"].sample(_ts(2016, 2, 15)), [20.0, 21.0])


def test_an_integral_float_records_per_sample_is_accepted(tmp_path):
    doc = _two_record_doc(tmp_path)
    doc["models"]["Emis"]["variables"]["pair"]["update"]["from"]["records_per_sample"] = 2.0
    provs = _providers(tmp_path, doc)
    np.testing.assert_array_equal(
        provs["Emis.pair"].sample(_ts(2016, 2, 15)), [[20.0, 21.0], [30.0, 31.0]]
    )


@pytest.mark.parametrize("bad", [1.5, "2", True, 3, 0, -2, 1e300])
def test_a_records_per_sample_that_is_not_the_number_1_or_2_is_refused(tmp_path, bad):
    doc = _two_record_doc(tmp_path)
    doc["models"]["Emis"]["variables"]["pair"]["update"]["from"]["records_per_sample"] = bad
    with pytest.raises(ValueError) as err:
        _providers(tmp_path, doc)
    msg = str(err.value)
    assert "'Emis.pair'" in msg and "from update.from" in msg and repr(bad) in msg


def test_a_bad_source_default_is_refused_naming_the_source(tmp_path):
    with pytest.raises(ValueError, match=r"'Emis.inherited'.*data_sources\.NEI\.temporal"):
        _two_record_providers(tmp_path, source_rps=1.5)


def test_a_bad_run_time_value_is_refused(tmp_path):
    with pytest.raises(
        ValueError, match="'Emis.pair'.*'2' from the run-time records_per_sample option"
    ):
        _providers(tmp_path, _two_record_doc(tmp_path), records_per_sample={"Emis.pair": "2"})


def test_two_records_from_a_filtered_source_are_refused(tmp_path):
    doc = _two_record_doc(tmp_path)
    doc["data_sources"]["NEI"]["record_filter"] = {"require_finite": ["NOX"]}
    with pytest.raises(ValueError, match="'Emis.pair'.*'NEI'.*filtered or coded"):
        _providers(tmp_path, doc)


def _startless_doc(tmp_path):
    doc = _two_record_doc(tmp_path)
    del doc["data_sources"]["NEI"]["temporal"]["start"]
    return doc


def test_two_records_from_a_source_with_no_temporal_start_are_refused(tmp_path):
    with pytest.raises(ValueError, match="'Emis.pair'.*'NEI'.*time-invariant"):
        _providers(tmp_path, _startless_doc(tmp_path))


def test_the_validator_refuses_two_records_from_a_source_with_no_temporal_start(tmp_path):
    from earthsci_ast.parse import load_path
    from earthsci_ast.structural_checks import StructuralValidationError

    doc = _startless_doc(tmp_path)
    doc["metadata"] = {"name": "startless"}
    doc["models"]["Emis"]["equations"] = []
    path = tmp_path / "startless.esm"
    path.write_text(json.dumps(doc))
    with pytest.raises(StructuralValidationError) as err:
        load_path(str(path))
    records = [r for r in err.value.records if r["code"] == "records_per_sample_invalid"]
    assert [r["path"] for r in records] == ["/models/Emis/variables/pair/update"]


@pytest.mark.parametrize("file_variable", ["NOX", "NOX_T"])
def test_a_declared_select_skips_the_time_and_record_axes(tmp_path, file_variable):
    # The select covers the file variable's non-time dims (here ROW), wherever
    # the file puts its time dimension; the record axis comes first.
    provs = _two_record_providers(tmp_path, file_variable=file_variable, select=[{"fixed": 1}])
    pair = provs["Emis.pair"].sample(_ts(2016, 2, 15))
    assert pair.shape == (2,)
    np.testing.assert_array_equal(pair, [21.0, 31.0])
    single = provs["Emis.single"].sample(_ts(2016, 2, 15))
    assert single.shape == ()
    np.testing.assert_array_equal(single, 21.0)


def test_the_record_axis_is_first_when_the_file_puts_time_last(tmp_path):
    provs = _two_record_providers(tmp_path, file_variable="NOX_T")
    np.testing.assert_array_equal(
        provs["Emis.pair"].sample(_ts(2016, 2, 15)), [[20.0, 21.0], [30.0, 31.0]]
    )
    np.testing.assert_array_equal(provs["Emis.single"].sample(_ts(2016, 2, 15)), [20.0, 21.0])


@pytest.mark.parametrize("file_variable", ["NOX", "NOX_T"])
def test_a_gated_selection_reads_the_records_at_t(tmp_path, file_variable):
    provs = _two_record_providers(tmp_path, file_variable=file_variable)
    pair = provs["Emis.pair"]
    assert pair.supports_selection
    # February's and March's records; the first entry addresses the record axis.
    np.testing.assert_array_equal(pair.sample(_ts(2016, 2, 15), ["all", [1]]), [[21.0], [31.0]])
    np.testing.assert_array_equal(pair.sample(_ts(2016, 2, 15), [[1], "all"]), [[30.0, 31.0]])
    np.testing.assert_array_equal(
        provs["Emis.single"].sample(_ts(2016, 2, 15), [[1, 0]]), [21.0, 20.0]
    )
