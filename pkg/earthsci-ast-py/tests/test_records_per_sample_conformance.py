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
