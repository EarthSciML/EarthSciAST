"""The loader-ingest surface of esm-spec §8.9, executed: ``reader_options``,
``codes``, ``record_filter``, ``extent`` and ``select`` served by
``providers_from_document`` + ``prepare``, over real local fixtures (an FF10
zip and a Zarr v2 store, both over the ``file`` transport — no network).

The Python peer of ``pkg/earthsci-ast-rs/tests/loader_ingest_and_select.rs``:
the document under test is the same committed fixture
``tests/valid/data_sources_ingest_and_select.esm``, with only its two
``url_template``s patched onto the temporary fixtures — so what the validation
sweep checks and what this file runs are the same declaration, in both
bindings.

What each property BUYS, since that is what the tests are really pinning:

* ``reader_options`` — the zip member glob and the asserted header row come
  from the document, so no caller injects a configured reader
  (FORMAT-08-A-006);
* ``codes`` + ``record_filter`` — the POLID text column becomes the pollutant
  enum and the unrecognised / uncoordinated records disappear, ONCE, for every
  variable of the loader at the same time (FORMAT-08-A-007, -008);
* ``extent`` — the surviving count binds ``N_REC``, so no caller counts rows
  (FORMAT-08-A-010);
* ``select`` — ``W[0:N_SRC]`` is a second variable over the same on-disk array,
  so no caller samples the grid twice to slice a prefix (FORMAT-08-A-009).

Together they are the difference between a document a general-purpose runner
can run and a document only a model-aware runner can run.
"""

from __future__ import annotations

import json
import struct
import zipfile

import numpy as np
import pytest

esio = pytest.importorskip("earthsciio")


def _requires_zarr_store() -> None:
    """Skip a test that READS the Zarr grid source.

    Writing the store is raw bytes (:func:`_write_grid_store`), so only the read
    path needs the library — and earthsciio's backend imports `zarr.abc.store`,
    which is zarr v3. Gating per-test rather than per-module keeps the FF10
    table half running wherever `earthsciio` is importable.
    """
    zarr = pytest.importorskip("zarr")
    version = getattr(zarr, "__version__", "0")
    try:
        major = int(str(version).split(".", 1)[0])
    except ValueError:  # a dev/unparseable version: let the test try
        return
    if major < 3:
        pytest.skip(f"earthsciio's zarr backend needs zarr v3 (found {version})")

from conftest import VALID_DIR  # noqa: E402

from earthsci_ast.data_sources.esio_provider import (  # noqa: E402
    providers_from_document,
)
from earthsci_ast.prepare import prepare  # noqa: E402
from earthsci_ast.sympy_bridge import SimulationError  # noqa: E402

# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #

# The FF10 point schema's 77 columns, by the indices this fixture writes.
C_POLID, C_ANN, C_LON, C_LAT, N_COL = 12, 13, 23, 24, 77

_HEADER = ",".join(
    [
        "country_cd",
        "region_cd",
        "tribal_code",
        "facility_id",
        "unit_id",
        "rel_point_id",
        "process_id",
        "agy_facility_id",
        "agy_unit_id",
        "agy_rel_point_id",
        "agy_process_id",
        "scc",
        "polid",
        "ann_value",
    ]
    + [f"col{i}" for i in range(14, N_COL)]
)


def _ff10_row(polid: str, ann: str, lon: str, lat: str) -> str:
    row = [""] * N_COL
    row[0], row[1] = "US", "01001"
    row[C_POLID], row[C_ANN], row[C_LON], row[C_LAT] = polid, ann, lon, lat
    return ",".join(row)


def _write_ff10_zip(dirpath) -> str:
    """An EPA-2016fd-shaped zip: a ``#`` comment block + a ``country_cd,…``
    header line per member, two ``*egu*`` members and one the glob must exclude.

    The ``*egu*`` rows, in the order the reader concatenates them (member name
    ascending), and what the document's declarations do to each:

    ===== ==== ==== ==============================================
    POLID ann  lon  fate
    ===== ==== ==== ==============================================
    NOX   100  -90  kept, code 36
    CO     50  -91  DROPPED — not in the ``codes`` map
    SO2    25       DROPPED — blank longitude is not finite
    nox     7  -92  kept, code 36 (``case_insensitive``)
    VOC     3  -93  kept, code 1
    ===== ==== ==== ==============================================
    """
    path = dirpath / "2016fd_inputs_point.zip"
    members = {
        "point/egu_alpha.csv": [
            _ff10_row("NOX", "100.0", "-90.0", "40.0"),
            _ff10_row("CO", "50.0", "-91.0", "41.0"),
            _ff10_row("SO2", "25.0", "", "42.0"),
        ],
        "point/egu_beta.csv": [
            _ff10_row("nox", "7.0", "-92.0", "43.0"),
            _ff10_row("VOC", "3.0", "-93.0", "44.0"),
        ],
        "point/ptnonipm.csv": [_ff10_row("NOX", "999.0", "-94.0", "45.0")],
    }
    with zipfile.ZipFile(path, "w") as zf:
        for name, rows in members.items():
            body = "\n".join(rows)
            zf.writestr(name, f"#FORMAT=FF10_POINT\n{_HEADER}\n{body}\n")
    return f"file://{path}"


def _write_grid_store(dirpath, n: int) -> str:
    """A Zarr v2 store with one uncompressed 1-D ``W`` array, ``W[i] = 100 + i``."""
    arr = dirpath / "grid.zarr" / "W"
    arr.mkdir(parents=True)
    (arr / ".zarray").write_text(
        json.dumps(
            {
                "zarr_format": 2,
                "shape": [n],
                "chunks": [n],
                "dtype": "<f8",
                "compressor": None,
                "fill_value": 0.0,
                "order": "C",
                "filters": None,
            }
        )
    )
    (arr / ".zattrs").write_text(json.dumps({"_ARRAY_DIMENSIONS": ["cell"]}))
    (arr / "0").write_bytes(b"".join(struct.pack("<d", 100.0 + i) for i in range(n)))
    return f"file://{dirpath / 'grid.zarr'}/"


@pytest.fixture()
def document(tmp_path):
    """The committed fixture with its two placeholder URLs pointed at ``tmp_path``."""
    doc = json.loads((VALID_DIR / "data_sources_ingest_and_select.esm").read_text())
    doc["data_sources"]["EGU_Emis"]["source"]["url_template"] = _write_ff10_zip(tmp_path)
    doc["data_sources"]["Grid"]["source"]["url_template"] = _write_grid_store(tmp_path, 10)
    return doc


def _providers(doc, tmp_path):
    return providers_from_document(doc, cache_root=str(tmp_path / "cache"))


def _sample(doc, tmp_path, key):
    return list(np.asarray(_providers(doc, tmp_path)[key].sample(0.0), dtype=float))


def _binding(doc, key):
    """The ``update.from`` binding of the parameter a provider key names.

    From esm 1.0.0 the data binding lives on the CONSUMER: ``codes``, ``select``
    and ``unit_conversion`` are fields of the reading parameter's
    ``update.from``, not of a variable the source declares -- a source declares
    none (esm-spec §8.5)."""
    model, param = key.split(".", 1)
    return doc["models"][model]["variables"][param]["update"]["from"]


def _source_of(doc, key):
    """The ``data_sources`` key the parameter a provider key names reads."""
    model, param = key.split(".", 1)
    return doc["models"][model]["variables"][param]["update"]["source"]


def _field(prep, name):
    return np.asarray(prep.observed_field(name), dtype=float)


# --------------------------------------------------------------------------- #
# U1 — the ingest is the loader's, not the caller's
# --------------------------------------------------------------------------- #


def test_the_document_alone_decodes_maps_and_filters_the_ff10_table(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    # reader_options selected the two *egu* members and dropped their header
    # lines; codes mapped POLID; record_filter removed the unmapped CO record
    # and the SO2 record with no longitude. All of it from the declaration.
    assert _sample(doc, tmp_path, "Ingest.pollutant") == [36.0, 36.0, 1.0]
    assert _sample(doc, tmp_path, "Ingest.annual") == [100.0, 7.0, 3.0]
    assert _sample(doc, tmp_path, "Ingest.lon") == [-90.0, -92.0, -93.0]
    assert _sample(doc, tmp_path, "Ingest.lat") == [40.0, 43.0, 44.0]


def test_an_unrecognised_reader_option_is_refused_at_construction(doc_and_tmp):
    """FORMAT-08-A-006: a mis-typed decode option cannot quietly select nothing."""
    doc, tmp_path = doc_and_tmp
    doc["data_sources"]["EGU_Emis"]["reader_options"]["member_filter"] = "*egu*"
    with pytest.raises(esio.errors.UnknownReaderOption) as e:
        _providers(doc, tmp_path)
    assert "member_filter" in str(e.value)
    assert "member_glob" in str(e.value)  # names what it DOES accept


def test_reader_options_are_load_bearing_not_decorative(doc_and_tmp):
    """Without the declared glob the loader reads the WRONG members — which is
    why an ignored option is a defect rather than a nicety."""
    doc, tmp_path = doc_and_tmp
    doc["data_sources"]["EGU_Emis"]["reader_options"] = {}
    with pytest.raises(Exception):  # noqa: B017 - a whole-zip read cannot decode
        _sample(doc, tmp_path, "Ingest.annual")


def test_every_parameter_fed_by_a_filtered_source_declares_the_same_extent(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    providers = _providers(doc, tmp_path)
    assert providers
    for key, prov in providers.items():
        declared = prov.extent_metaparameter
        # `extent` is the SOURCE's, inherited by every parameter that reads it. A
        # provider key names the consuming parameter, so the source comes from
        # that parameter's own `update` rather than from a prefix on the key.
        if _source_of(doc, key) == "EGU_Emis":
            assert declared == "N_REC", f"{key} must bind the source's extent"
        else:
            assert declared is None, f"{key} declares no extent"


def test_prepare_discovers_n_rec_and_the_graph_is_sized_by_it(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    _requires_zarr_store()
    # NOTE the absent metaparameters: the caller passes NO N_REC. The document
    # declares that the loader knows it.
    prep = prepare(
        doc,
        providers=_providers(doc, tmp_path),
        metaparameters=None,
        pushdown_rewrite=True,
    )
    assert list(_field(prep, "is_NOx")) == [1.0, 1.0, 0.0], (
        "the observed graph is evaluated over the 3 SURVIVING records"
    )
    assert float(_field(prep, "E_NOx")) == 107.0, (
        "100 + 7 — the dropped CO/SO2 records contribute nothing because they are not records"
    )


def test_a_caller_binding_that_contradicts_the_discovered_extent_is_an_error(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    with pytest.raises(SimulationError) as e:
        prepare(
            doc,
            providers=_providers(doc, tmp_path),
            metaparameters={"N_REC": 5},  # the RAW row count, a stale guess
            pushdown_rewrite=True,
        )
    assert "N_REC" in str(e.value)
    assert "discovers 3" in str(e.value)


def test_loader_variables_that_disagree_on_the_count_are_an_error(doc_and_tmp, monkeypatch):
    """The agreement between a loader's variables IS the alignment check, so a
    disagreement names both providers rather than picking one."""
    doc, tmp_path = doc_and_tmp
    provs = _providers(doc, tmp_path)
    short = provs["Ingest.lat"]
    monkeypatch.setattr(short, "sample", lambda t=0.0, selection=None: np.zeros(2))
    with pytest.raises(SimulationError) as e:
        prepare(doc, providers=provs, pushdown_rewrite=True)
    msg = str(e.value)
    assert "Ingest.lat" in msg and "Ingest.annual" in msg
    assert "not aligned on one record axis" in msg


def test_same_named_parameters_in_two_models_keep_their_own_columns(doc_and_tmp):
    """Two models may declare the SAME parameter name against one source, bound
    to different columns. The provider key separates them (it is the flattened
    name), and so must the shared decode's column identity -- keyed by the LOCAL
    name, both resolve to one column and one model silently reads the other's
    data (and `require_finite` follows it onto the wrong column)."""
    doc, tmp_path = doc_and_tmp
    # A second model reading the same source, whose `lon` is the LATITUDE column
    # -- so a collision is visible as latitude values.
    doc["models"]["Ingest2"] = {
        "system_kind": "nonlinear",
        "equations": [],
        "variables": {
            "lon": {
                "type": "parameter",
                "units": "degree",
                "default": 0.0,
                "shape": ["emis_records"],
                "update": {
                    "kind": "data",
                    "source": "EGU_Emis",
                    "from": {"file_variable": "LATITUDE"},
                },
            }
        },
    }
    providers = _providers(doc, tmp_path)
    assert "Ingest.lon" in providers and "Ingest2.lon" in providers
    assert _sample(doc, tmp_path, "Ingest.lon") == [-90.0, -92.0, -93.0]
    assert _sample(doc, tmp_path, "Ingest2.lon") == [40.0, 43.0, 44.0]


def test_a_text_column_with_no_codes_map_is_a_boundary_error(doc_and_tmp):
    """FORMAT-08-A-007: a model forcing must be numeric, so a text column with
    no ``codes`` map fails at the loader boundary, not as an absent forcing."""
    doc, tmp_path = doc_and_tmp
    del _binding(doc, "Ingest.pollutant")["codes"]
    with pytest.raises(ValueError) as e:
        _sample(doc, tmp_path, "Ingest.pollutant")
    assert "decoded as strings" in str(e.value)
    assert "codes" in str(e.value)


def test_an_unmapped_code_can_error_or_substitute_instead_of_dropping(doc_and_tmp):
    """``unmapped`` is a three-way policy, and ``error`` is the default."""
    doc, tmp_path = doc_and_tmp
    codes = _binding(doc, "Ingest.pollutant")["codes"]

    codes["unmapped"] = "error"
    with pytest.raises(ValueError) as e:
        _sample(doc, tmp_path, "Ingest.pollutant")
    assert "'CO'" in str(e.value)

    del codes["unmapped"]  # default IS error
    with pytest.raises(ValueError):
        _sample(doc, tmp_path, "Ingest.pollutant")

    codes["unmapped"] = 0
    # The CO record now survives with code 0; only the coordinate-less SO2 row
    # is dropped, and every column keeps that same 4 records.
    assert _sample(doc, tmp_path, "Ingest.pollutant") == [36.0, 0.0, 36.0, 1.0]
    assert _sample(doc, tmp_path, "Ingest.annual") == [100.0, 50.0, 7.0, 3.0]


def test_the_record_filter_drops_the_record_from_every_variable(doc_and_tmp):
    """FORMAT-08-A-008: the mask is the LOADER's, so its columns cannot fall out
    of alignment — every variable delivers the same records, in the same order."""
    doc, tmp_path = doc_and_tmp
    lengths = {
        v: len(_sample(doc, tmp_path, f"Ingest.{v}"))
        for v in ("pollutant", "annual", "lon", "lat")
    }
    assert set(lengths.values()) == {3}, lengths
    # Relaxing the filter to `annual` alone re-admits the coordinate-less SO2
    # record — to EVERY variable at once, NaN longitude and all. The columns
    # move together or they do not move; that is the whole point of the mask
    # being the loader's.
    doc["data_sources"]["EGU_Emis"]["record_filter"]["require_finite"] = ["ANN_VALUE"]
    lon = _sample(doc, tmp_path, "Ingest.lon")
    assert lon[0] == -90.0 and np.isnan(lon[1]) and lon[2:] == [-92.0, -93.0]
    assert _sample(doc, tmp_path, "Ingest.pollutant") == [36.0, 41.0, 36.0, 1.0]
    assert _sample(doc, tmp_path, "Ingest.annual") == [100.0, 25.0, 7.0, 3.0]


# --------------------------------------------------------------------------- #
# U2 — a range select in the loader
# --------------------------------------------------------------------------- #


def test_a_range_select_delivers_a_prefix_of_the_same_on_disk_array(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    _requires_zarr_store()
    full = _sample(doc, tmp_path, "Ingest.W")
    assert len(full) == 10, "the unselected variable is unaffected"
    assert full[0] == 100.0

    # stop is the METAPARAMETER name N_SRC (default 4), not a repeated literal.
    prefix = _sample(doc, tmp_path, "Ingest.src_W")
    assert prefix == full[:4] == [100.0, 101.0, 102.0, 103.0]


def test_pushing_a_select_to_the_reader_and_applying_it_after_agree(doc_and_tmp, monkeypatch):
    """FORMAT-08-A-009: which side honours the selection is an optimization, so
    the two MUST deliver the identical array."""
    _requires_zarr_store()
    doc, tmp_path = doc_and_tmp
    pushed = _sample(doc, tmp_path, "Ingest.src_W")

    provs = _providers(doc, tmp_path)
    engine = provs["Ingest.src_W"]
    assert engine._reader_select is not None, "the zarr reader takes the pushdown"
    # Force the engine-side arm: read whole, slice after.
    monkeypatch.setattr(engine, "_reader_select", None)
    monkeypatch.setattr(engine, "_engine_axes", [{"range": {"start": 0, "stop": 4, "step": 1}}])
    assert list(np.asarray(engine.sample(0.0), dtype=float)) == pushed


def test_a_range_select_over_a_filtered_table_counts_surviving_records(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    # A loader-level select is the default for every variable of the loader —
    # which is what keeps a truncated table aligned.
    doc["data_sources"]["EGU_Emis"]["select"] = {"axes": [{"range": {"start": 0, "stop": 2}}]}
    assert _sample(doc, tmp_path, "Ingest.annual") == [100.0, 7.0], (
        "[0:2] is the first two SURVIVING records (100, 7) — never the first two "
        "raw rows (100, 50) of which one is dropped"
    )
    assert _sample(doc, tmp_path, "Ingest.pollutant") == [36.0, 36.0]
    assert _sample(doc, tmp_path, "Ingest.lon") == [-90.0, -92.0]


def test_a_truncated_table_re_discovers_its_own_smaller_extent(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    _requires_zarr_store()
    doc["data_sources"]["EGU_Emis"]["select"] = {"axes": [{"range": {"start": 0, "stop": 2}}]}
    prep = prepare(doc, providers=_providers(doc, tmp_path), pushdown_rewrite=True)
    assert float(_field(prep, "E_NOx")) == 107.0
    assert len(_field(prep, "is_NOx")) == 2, (
        "N_REC follows the DELIVERED records, so a reduced run needs no other knob"
    )


def test_the_selected_prefix_reaches_the_model_as_its_own_axis(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    _requires_zarr_store()
    prep = prepare(doc, providers=_providers(doc, tmp_path), pushdown_rewrite=True)
    w = _field(prep, "src_width")
    assert w.shape == (4,), (
        "src_W is delivered on src_cells (N_SRC), not on the full pop_cells axis"
    )
    assert list(w) == [101.0, 102.0, 103.0, 104.0]


def test_an_unrecognised_axis_selector_is_refused_at_construction(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    _binding(doc, "Ingest.src_W")["select"] = {"axes": [{"prefix": 4}]}
    with pytest.raises(Exception) as e:
        _providers(doc, tmp_path)
    assert "unrecognised axis selector keys" in str(e.value)


def test_a_range_bound_naming_an_unknown_metaparameter_is_refused(doc_and_tmp):
    doc, tmp_path = doc_and_tmp
    _binding(doc, "Ingest.src_W")["select"]["axes"][0]["range"]["stop"] = "N_NOPE"
    with pytest.raises(ValueError) as e:
        _providers(doc, tmp_path)
    assert "N_NOPE" in str(e.value)
    assert "metaparameter with an integer default" in str(e.value)


@pytest.fixture()
def doc_and_tmp(document, tmp_path):
    return document, tmp_path
