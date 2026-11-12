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


# --- review fixes for PR #697 -------------------------------------------------


def _grid_leaf(gf_t: dict) -> dict:
    return {
        "esm": "1.3.0",
        "metadata": {"name": "Leaf"},
        "index_sets": {"gf_t": gf_t},
        "models": {
            "Leaf": {
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


def _root_mounting_leaf(tmp_path, root_gf_t: dict, leaf_gf_t: dict) -> str:
    (tmp_path / "leaf.esm").write_text(json.dumps(_grid_leaf(leaf_gf_t)))
    root = {
        "esm": "1.3.0",
        "metadata": {"name": "Root"},
        "index_sets": {"gf_t": root_gf_t},
        "models": {"Leaf": {"ref": "./leaf.esm"}},
    }
    path = tmp_path / "root.esm"
    path.write_text(json.dumps(root))
    return str(path)


def test_mount_merge_refuses_a_records_flag_the_root_does_not_declare(tmp_path):
    """Index-set merge equality includes ``records``: a mounted record axis
    colliding with the root's plain interval of the same size is a conflict,
    not a silent drop of the flag."""
    path = _root_mounting_leaf(
        tmp_path,
        {"kind": "interval", "size": 2},
        {"kind": "interval", "size": 2, "records": True},
    )
    with pytest.raises(Exception) as excinfo:
        load_path(path)
    assert "subsystem_index_set_conflict" in str(excinfo.value)


@pytest.mark.parametrize(
    ("root_extra", "leaf_extra"),
    [({}, {"records": False}), ({"records": False}, {}), ({"records": True}, {"records": True})],
)
def test_mount_merge_reads_records_false_as_absent(tmp_path, root_extra, leaf_extra):
    path = _root_mounting_leaf(
        tmp_path,
        {"kind": "interval", "size": 2, **root_extra},
        {"kind": "interval", "size": 2, **leaf_extra},
    )
    doc = load_path(path)
    assert (doc.index_sets["gf_t"].get("records") is True) == (root_extra.get("records") is True)


def test_template_import_merge_reads_records_false_as_absent():
    from earthsci_ast.lower_expression_templates import ExpressionTemplateError
    from earthsci_ast.template_imports import _merge_named

    dst = {"gf_t": {"kind": "interval", "size": 2}}
    _merge_named(
        dst,
        "gf_t",
        {"kind": "interval", "size": 2, "records": False},
        "template_import_index_set_conflict",
        "index set",
        "lib",
    )
    with pytest.raises(ExpressionTemplateError):
        _merge_named(
            dst,
            "gf_t",
            {"kind": "interval", "size": 2, "records": True},
            "template_import_index_set_conflict",
            "index set",
            "lib",
        )


def _static_source() -> dict:
    """A time-invariant source: no ``temporal`` block, so no successor record."""
    return {"kind": "grid", "source": {"url_template": "file:///data/static.nc"}}


def _box(f_shape: list[str]) -> dict:
    return {
        "variables": {
            "c": {"type": "unknown", "units": "1", "default": 1.0},
            "F": {"type": "parameter", "units": "1/s", "shape": f_shape, "default": 0.1},
        },
        "equations": [
            {
                "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                "rhs": {"op": "-", "args": ["c"]},
            }
        ],
    }


def test_validation_judges_reachable_targets_when_one_is_behind_a_ref():
    """A shapeless data-fed parameter with one inline ``param_to_var`` target
    shaped ``[rec, cells]`` and one behind an unmounted ref: the reachable
    target decides two records, so a time-invariant source is refused at
    validation rather than left undecided."""
    from earthsci_ast.structural_checks import _validate_structural

    raw = {
        "esm": "1.3.0",
        "metadata": {"name": "ReachableTargets"},
        "index_sets": {
            "rec": {"kind": "interval", "size": 2, "records": True},
            "cells": {"kind": "interval", "size": 4},
        },
        "data_sources": {"static": _static_source()},
        "models": {
            "Met": {
                "variables": {
                    "K": {
                        "type": "parameter",
                        "units": "1/s",
                        "default": 0.1,
                        "update": {
                            "kind": "data",
                            "source": "static",
                            "from": {"file_variable": "K"},
                        },
                    }
                },
                "equations": [],
            },
            "Box": _box(["rec", "cells"]),
            "Far": {"ref": "./far.esm"},
        },
        "coupling": [
            {"type": "variable_map", "from": "Met.K", "to": "Box.F", "transform": "param_to_var"},
            {"type": "variable_map", "from": "Met.K", "to": "Far.F", "transform": "param_to_var"},
        ],
    }
    with pytest.raises(StructuralValidationError) as err:
        _validate_structural(raw)
    assert _record_findings(err.value.records) == [
        ("record_axis_time_invariant_source", "/models/Met/variables/K/update")
    ]


def _reaction_system_doc(t_shape, written=None, temporal=True) -> dict:
    source = {
        "kind": "grid",
        "source": {"url_template": "file:///data/met_{date:%Y%m%d}.nc"},
    }
    if temporal:
        source["temporal"] = {
            "start": "2024-05-01T00:00:00Z",
            "frequency": "PT1H",
            "file_period": "P1D",
            "records_per_file": 24,
        }
        if written is not None:
            source["temporal"]["records_per_sample"] = written
    return {
        "esm": "1.3.0",
        "metadata": {"name": "ReactionSystemRecords"},
        "index_sets": {
            "rec": {"kind": "interval", "size": 2, "records": True},
            "cells": {"kind": "interval", "size": 4},
        },
        "data_sources": {"met": source},
        "reaction_systems": {
            "Chem": {
                "species": {"A": {"units": "mol/mol", "default": 1.0}},
                "parameters": {
                    "T": {
                        "units": "K",
                        "default": 298.0,
                        "shape": t_shape,
                        "update": {
                            "kind": "data",
                            "source": "met",
                            "from": {"file_variable": "t2m"},
                        },
                    }
                },
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": None,
                        "rate": 0.1,
                    }
                ],
            }
        },
    }


def test_reaction_system_written_records_per_sample_must_agree_with_the_shape():
    from earthsci_ast.structural_checks import _validate_structural

    with pytest.raises(StructuralValidationError) as err:
        _validate_structural(_reaction_system_doc(["cells"], written=2))
    assert _record_findings(err.value.records) == [
        ("records_per_sample_invalid", "/reaction_systems/Chem/parameters/T/update")
    ]


def test_reaction_system_record_axis_needs_a_time_varying_source():
    from earthsci_ast.structural_checks import _validate_structural

    with pytest.raises(StructuralValidationError) as err:
        _validate_structural(_reaction_system_doc(["rec", "cells"], temporal=False))
    assert _record_findings(err.value.records) == [
        ("record_axis_time_invariant_source", "/reaction_systems/Chem/parameters/T/update")
    ]


def test_reaction_system_record_axis_agreeing_with_a_written_2_is_valid():
    from earthsci_ast.structural_checks import _validate_structural

    _validate_structural(_reaction_system_doc(["rec", "cells"], written=2))


def test_flatten_rechecks_reaction_system_record_shapes():
    """The flatten re-check covers reaction-system parameters too: one whose
    record shape names the record axis second is refused there."""
    from earthsci_ast.flatten import _check_record_shapes

    doc = load_string(json.dumps(_reaction_system_doc(["cells"])))
    doc.reaction_systems["Chem"].parameters[0].shape = ["cells", "rec"]
    with pytest.raises(RecordAxisError) as err:
        _check_record_shapes(doc, list(doc.coupling or []))
    assert err.value.code == "record_axis_misplaced"
    assert err.value.pointer == "/reaction_systems/Chem/parameters/T/update"
