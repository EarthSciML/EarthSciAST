"""Conformance: ``from.records_per_sample`` (esm-spec §8.5.1).

Consumes ``tests/conformance/records_per_sample/manifest.json``. A valid case
must load, validate, and flatten with every data-fed parameter's
``loader_fields`` entry reporting the EFFECTIVE value (the parameter's own,
else the source's ``temporal.records_per_sample``, else 1), and with flatten
carrying ``update.from.records_per_sample`` as written. An ``invalid`` case
must be refused by structural validation with exactly one
``records_per_sample_invalid`` at the pinned pointer. A ``flatten_invalid``
case must load clean and be refused by ``flatten`` with that code at that
pointer. A ``refused`` case may be refused by either stage.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast.flatten import RecordsPerSampleInvalidError, flatten
from earthsci_ast.parse import load_path
from earthsci_ast.serialize import to_json
from earthsci_ast.structural_checks import StructuralValidationError

_TIER = CONFORMANCE_DIR / "records_per_sample"
_MANIFEST = json.loads((_TIER / "manifest.json").read_text())
_VALID = [c for c in _MANIFEST["cases"] if c["expect"] == "valid"]
_INVALID = [c for c in _MANIFEST["cases"] if c["expect"] == "invalid"]
_FLATTEN_INVALID = [c for c in _MANIFEST["cases"] if c["expect"] == "flatten_invalid"]
_REFUSED = [c for c in _MANIFEST["cases"] if c["expect"] == "refused"]


@pytest.mark.parametrize("case", _VALID, ids=[c["id"] for c in _VALID])
def test_valid_case_reports_effective_records(case):
    doc = load_path(str(_TIER / case["path"]))
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


@pytest.mark.parametrize("case", _VALID, ids=[c["id"] for c in _VALID])
def test_valid_case_round_trips_the_field(case):
    raw = json.loads((_TIER / case["path"]).read_text())
    emitted = json.loads(to_json(load_path(str(_TIER / case["path"]))))

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


@pytest.mark.parametrize("case", _INVALID, ids=[c["id"] for c in _INVALID])
def test_invalid_case_is_refused(case):
    with pytest.raises(StructuralValidationError) as err:
        load_path(str(_TIER / case["path"]))
    records = [r for r in err.value.records if r["code"] == case["code"]]
    assert [r["path"] for r in records] == [case["pointer"]]


@pytest.mark.parametrize("case", _FLATTEN_INVALID, ids=[c["id"] for c in _FLATTEN_INVALID])
def test_flatten_invalid_case_is_refused_by_flatten(case):
    doc = load_path(str(_TIER / case["path"]))
    with pytest.raises(RecordsPerSampleInvalidError) as err:
        flatten(doc)
    assert err.value.code == case["code"]
    assert err.value.pointer == case["pointer"]
    assert case["pointer"] in str(err.value)


@pytest.mark.parametrize("case", _REFUSED, ids=[c["id"] for c in _REFUSED])
def test_refused_case_is_refused_by_validation_or_flatten(case):
    try:
        doc = load_path(str(_TIER / case["path"]))
    except StructuralValidationError as err:
        records = [r for r in err.records if r["code"] == case["code"]]
        assert [r["path"] for r in records] == [case["pointer"]]
        return
    with pytest.raises(RecordsPerSampleInvalidError) as err:
        flatten(doc)
    assert err.value.code == case["code"]
    assert err.value.pointer == case["pointer"]


def _write_index_sets_from_mount(tmp_path, f_k_shape, mount=True):
    """A root whose param_to_var target is inline but whose index sets
    ``rec`` and ``x`` are declared only by a component mounted by ref."""
    component = {
        "esm": "1.3.0",
        "metadata": {"name": "Grid"},
        "index_sets": {
            "rec": {"kind": "interval", "size": 2},
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
                            "from": {"file_variable": "K", "records_per_sample": 2},
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


def test_index_set_declared_only_by_a_mount_is_refused_at_flatten(tmp_path):
    doc = load_path(_write_index_sets_from_mount(tmp_path, ["x", "rec"]))
    with pytest.raises(RecordsPerSampleInvalidError) as err:
        flatten(doc)
    assert err.value.pointer == "/models/Met/variables/K/update"


def test_undeclared_index_set_without_a_mount_is_refused_at_validation(tmp_path):
    with pytest.raises(StructuralValidationError) as err:
        load_path(_write_index_sets_from_mount(tmp_path, ["rec", "x"], mount=False))
    records = [r for r in err.value.records if r["code"] == "records_per_sample_invalid"]
    assert [r["path"] for r in records] == ["/models/Met/variables/K/update"]
