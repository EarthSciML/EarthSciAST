"""Conformance: record axes and the deprecated ``records_per_sample``
(esm-spec §8.5.1).

Consumes ``tests/conformance/records_per_sample/manifest.json``. A valid case
must load, validate with none of the manifest's ``record_codes``, and flatten,
with every listed ``loader_fields`` entry reporting the number of records its
parameter receives (two exactly when its record shape begins with an interval
index set carrying ``"records": true``), with flatten carrying
``update.from.records_per_sample`` as written, with the index sets' ``records``
flag and the deprecated field surviving emit then load, and with
:func:`deprecated_records_per_sample_sites` returning ``deprecated_fields``
(loading warns once exactly when that list is non-empty). An ``invalid`` case
must be refused by structural validation with exactly one diagnostic from
``record_codes``: ``code`` at ``pointer``. A ``flatten_invalid`` case must load
clean and be refused by ``flatten`` with that code at that pointer. A
``refused`` case may be refused by either stage.
"""

from __future__ import annotations

import json
import warnings

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import deprecated_records_per_sample_sites
from earthsci_ast.flatten import RecordAxisError, flatten
from earthsci_ast.parse import EsmDeprecationWarning, load_path, load_string
from earthsci_ast.serialize import to_json
from earthsci_ast.structural_checks import StructuralValidationError

_TIER = CONFORMANCE_DIR / "records_per_sample"
_MANIFEST = json.loads((_TIER / "manifest.json").read_text())
_RECORD_CODES = set(_MANIFEST["record_codes"])
_WARNING = _MANIFEST["deprecation_warning"]
_VALID = [c for c in _MANIFEST["cases"] if c["expect"] == "valid"]
_INVALID = [c for c in _MANIFEST["cases"] if c["expect"] == "invalid"]
_FLATTEN_INVALID = [c for c in _MANIFEST["cases"] if c["expect"] == "flatten_invalid"]
_REFUSED = [c for c in _MANIFEST["cases"] if c["expect"] == "refused"]


def _load_counting_warnings(load):
    """``(file, n)``: the loaded file and how many ``deprecated_records_per_sample``
    warnings the load issued."""
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        file = load()
    n = sum(
        1
        for w in caught
        if issubclass(w.category, EsmDeprecationWarning) and str(w.message).startswith(_WARNING)
    )
    return file, n


def _record_findings(records):
    return [(r["code"], r["path"]) for r in records if r["code"] in _RECORD_CODES]


@pytest.mark.parametrize("case", _VALID, ids=[c["id"] for c in _VALID])
def test_valid_case_reports_its_record_count(case):
    doc, n_warnings = _load_counting_warnings(lambda: load_path(str(_TIER / case["path"])))
    assert deprecated_records_per_sample_sites(doc) == case["deprecated_fields"]
    assert n_warnings == (1 if case["deprecated_fields"] else 0)
    flat = flatten(doc)
    got = {
        lf.name: {
            "name": lf.name,
            "source": lf.subkey,
            "file_variable": lf.var,
            "cadence": lf.cadence,
            "records_per_sample": lf.records_per_sample,
        }
        for lf in flat.loader_fields
    }
    for want in case["loader_fields"]:
        assert got.get(want["name"]) == want
    for name, written in case.get("flattened_from_records_per_sample", {}).items():
        update = flat.parameters[name].update
        assert update is not None and not isinstance(update, list)
        assert update.from_source.records_per_sample == written
    raw = json.loads((_TIER / case["path"]).read_text())
    for name, iset in (raw.get("index_sets") or {}).items():
        assert flat.index_sets[name].get("records") == iset.get("records")


@pytest.mark.parametrize("case", _VALID, ids=[c["id"] for c in _VALID])
def test_valid_case_round_trips_the_field_and_the_flag(case):
    raw = json.loads((_TIER / case["path"]).read_text())
    emitted_text = to_json(load_path(str(_TIER / case["path"])))
    emitted = json.loads(emitted_text)

    def bindings(doc):
        out = {}
        for mname, model in doc.get("models", {}).items():
            for vname, var in model.get("variables", {}).items():
                upd = var.get("update")
                if isinstance(upd, dict) and isinstance(upd.get("from"), dict):
                    out[f"{mname}.{vname}"] = upd["from"].get("records_per_sample")
        temporal = {
            k: (v.get("temporal") or {}).get("records_per_sample")
            for k, v in doc.get("data_sources", {}).items()
        }
        return out, temporal

    assert bindings(emitted) == bindings(raw)
    for name, iset in (raw.get("index_sets") or {}).items():
        assert emitted["index_sets"][name].get("records") == iset.get("records")
    reloaded = load_string(emitted_text, base_path=str((_TIER / case["path"]).parent))
    assert deprecated_records_per_sample_sites(reloaded) == case["deprecated_fields"]
    for name, iset in (raw.get("index_sets") or {}).items():
        assert reloaded.index_sets[name].get("records") == iset.get("records")


@pytest.mark.parametrize("case", _INVALID, ids=[c["id"] for c in _INVALID])
def test_invalid_case_is_refused(case):
    with pytest.raises(StructuralValidationError) as err:
        load_path(str(_TIER / case["path"]))
    assert _record_findings(err.value.records) == [(case["code"], case["pointer"])]


@pytest.mark.parametrize("case", _FLATTEN_INVALID, ids=[c["id"] for c in _FLATTEN_INVALID])
def test_flatten_invalid_case_is_refused_by_flatten(case):
    doc = load_path(str(_TIER / case["path"]))
    with pytest.raises(RecordAxisError) as err:
        flatten(doc)
    assert err.value.code == case["code"]
    assert err.value.pointer == case["pointer"]
    assert case["pointer"] in str(err.value)


@pytest.mark.parametrize("case", _REFUSED, ids=[c["id"] for c in _REFUSED])
def test_refused_case_is_refused_by_validation_or_flatten(case):
    try:
        doc = load_path(str(_TIER / case["path"]))
    except StructuralValidationError as err:
        assert _record_findings(err.records) == [(case["code"], case["pointer"])]
        return
    with pytest.raises(RecordAxisError) as err:
        flatten(doc)
    assert err.value.code == case["code"]
    assert err.value.pointer == case["pointer"]


def _write_index_sets_from_mount(tmp_path, f_k_shape, mount=True, written=None):
    """A root whose param_to_var target is inline but whose index sets
    ``rec`` (a record axis) and ``x`` are declared only by a component mounted
    by ref. ``written`` is a deprecated ``from.records_per_sample`` on ``K``."""
    component = {
        "esm": "1.3.0",
        "metadata": {"name": "Grid"},
        "index_sets": {
            "rec": {"kind": "interval", "size": 2, "records": True},
            "x": {"kind": "interval", "size": 4},
        },
        "models": {
            "Grid": {
                "variables": {"g": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["g"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["g"]},
                    }
                ],
            }
        },
    }
    root = {
        "esm": "1.3.0",
        "metadata": {"name": "IndexSetsFromMount"},
        "data_sources": {
            "met_source": {
                "kind": "grid",
                "source": {"url_template": "file:///data/met/met_{date:%Y%m%d}.nc"},
                "temporal": {
                    "start": "2024-05-01T00:00:00Z",
                    "frequency": "PT1H",
                    "file_period": "P1D",
                    "records_per_file": 24,
                },
            }
        },
        "models": {
            "Met": {
                "variables": {
                    "K": {
                        "type": "parameter",
                        "units": "1/s",
                        "default": 0.1,
                        "update": {
                            "kind": "data",
                            "source": "met_source",
                            "from": {"file_variable": "K"},
                        },
                    }
                },
                "equations": [],
            },
            "Box": {
                "variables": {
                    "c": {"type": "unknown", "units": "1", "default": 1.0},
                    "F_k": {
                        "type": "parameter",
                        "units": "1/s",
                        "shape": f_k_shape,
                        "default": 0.1,
                    },
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                        "rhs": {
                            "op": "*",
                            "args": [
                                {"op": "-", "args": [{"op": "index", "args": ["F_k", 1, 1]}]},
                                "c",
                            ],
                        },
                    }
                ],
            },
        },
        "coupling": [
            {"type": "variable_map", "from": "Met.K", "to": "Box.F_k", "transform": "param_to_var"}
        ],
    }
    if written is not None:
        root["models"]["Met"]["variables"]["K"]["update"]["from"]["records_per_sample"] = written
    if mount:
        (tmp_path / "grid.esm").write_text(json.dumps(component))
        root["models"]["Grid"] = {"ref": "./grid.esm"}
    else:
        root["index_sets"] = {"x": {"kind": "interval", "size": 4}}
    path = tmp_path / "root.esm"
    path.write_text(json.dumps(root))
    return str(path)


def test_index_set_declared_only_by_a_mount_is_valid(tmp_path):
    flat = flatten(load_path(_write_index_sets_from_mount(tmp_path, ["rec", "x"])))
    assert {lf.name: lf.records_per_sample for lf in flat.loader_fields} == {"Met.K": 2}


def test_index_set_declared_only_by_a_mount_agrees_with_a_written_2(tmp_path):
    flat = flatten(load_path(_write_index_sets_from_mount(tmp_path, ["rec", "x"], written=2)))
    assert {lf.name: lf.records_per_sample for lf in flat.loader_fields} == {"Met.K": 2}


def test_index_set_declared_only_by_a_mount_is_refused_at_flatten(tmp_path):
    doc = load_path(_write_index_sets_from_mount(tmp_path, ["x", "rec"]))
    with pytest.raises(RecordAxisError) as err:
        flatten(doc)
    assert err.value.code == "record_axis_misplaced"
    assert err.value.pointer == "/models/Met/variables/K/update"


def test_a_written_2_disagreeing_behind_a_mount_is_refused_at_flatten(tmp_path):
    doc = load_path(_write_index_sets_from_mount(tmp_path, ["x", "x"], written=2))
    with pytest.raises(RecordAxisError) as err:
        flatten(doc)
    assert err.value.code == "records_per_sample_invalid"
    assert err.value.pointer == "/models/Met/variables/K/update"


def test_undeclared_index_set_without_a_mount_is_refused_at_validation(tmp_path):
    path = _write_index_sets_from_mount(tmp_path, ["rec", "x"], mount=False, written=2)
    with pytest.raises(StructuralValidationError) as err:
        load_path(path)
    assert _record_findings(err.value.records) == [
        ("records_per_sample_invalid", "/models/Met/variables/K/update")
    ]


def test_a_nested_load_does_not_warn_twice(tmp_path):
    """The deprecated field written in the root, with a component mounted by
    ref: one warning for the one load call."""
    path = _write_index_sets_from_mount(tmp_path, ["rec", "x"], written=2)
    _doc, n = _load_counting_warnings(lambda: load_path(path))
    assert n == 1
