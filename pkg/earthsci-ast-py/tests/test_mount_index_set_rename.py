"""Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set renaming").

The fix for EarthSciML/EarthSciAST#198 item 4. ``index_sets`` is a
DOCUMENT-scoped registry, so a document that mounts a 59-layer atmospheric
column and a 4-layer soil column — both of which spell their axis ``lev``,
because both come from the same one-dimensional column family at different
lengths — hits the §4.7 deep-equal-or-error merge and fails with
``subsystem_index_set_conflict``. That scoping is load-bearing (``shape``,
``{"from"}``, ``from_faq``, §11.2 dimensionality, §9.6.1 ``where`` constraints
and §2.1 ``coordinates`` all resolve against the one registry), so the fix is
not to re-scope it but to let the ASSEMBLER say "this mount's ``lev`` is not
that mount's ``lev``" at the edge.
"""

from __future__ import annotations

import json
import os

import pytest

from earthsci_ast import load_path
from earthsci_ast.lower_expression_templates import ExpressionTemplateError

TESTS = os.path.join(os.path.dirname(__file__), "..", "..", "..", "tests")


def _fixture(rel: str) -> str:
    return os.path.normpath(os.path.join(TESTS, rel))


def test_two_columns_with_one_axis_name_coexist_under_a_mount_rename():
    doc = load_path(_fixture("valid/mount_rename_two_columns.esm"))
    assert doc.index_sets["lev"]["size"] == 59, doc.index_sets
    assert doc.index_sets["soil_lev"]["size"] == 4, doc.index_sets


def test_mount_rename_rewrites_shape_and_range_in_the_mounted_component():
    # Transitivity (esm-spec §4.7): a `shape` list that still said `lev` would
    # resolve against the 59-layer axis and allocate 59 soil layers.
    doc = load_path(_fixture("valid/mount_rename_two_columns.esm"))
    host = doc.models["Host"]
    soil = host.subsystems["Soil"]
    assert soil.variables["Tsoil"].shape == ["soil_lev"]
    rhs = json.loads(json.dumps(soil.equations[0].rhs, default=lambda o: o.__dict__))
    assert "soil_lev" in json.dumps(rhs), rhs
    atm = host.subsystems["Atm"]
    assert atm.variables["T"].shape == ["lev"], "the un-renamed mount is untouched"


def test_without_the_rename_the_two_columns_still_collide(tmp_path):
    # The un-fixed behavior is preserved: the field is opt-in, and omitting it
    # leaves the §4.7 deep-equal-or-error merge exactly as it was.
    host = {
        "esm": "1.0.0",
        "metadata": {"name": "collide", "description": "no mount-edge rename"},
        "models": {
            "Host": {
                "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "*", "args": [-0.5, "x"]},
                    }
                ],
                "subsystems": {
                    "Atm": {"ref": _fixture("valid/mount_rename_atm_column.esm")},
                    "Soil": {"ref": _fixture("valid/mount_rename_soil_column.esm")},
                },
            }
        },
    }
    p = tmp_path / "collide.esm"
    p.write_text(json.dumps(host))
    with pytest.raises(ExpressionTemplateError) as exc:
        load_path(str(p))
    assert exc.value.code == "subsystem_index_set_conflict"
    # The sharpened diagnostic names BOTH definitions and the remedy.
    msg = str(exc.value)
    assert "size=4" in msg and "size=59" in msg, msg
    assert "index_set_rename" in msg, msg


def test_mount_rename_unknown_index_set_is_a_loud_load_error():
    # Renames never invent names — the §9.7.7 rule at a mount edge.
    with pytest.raises(ExpressionTemplateError) as exc:
        load_path(_fixture("invalid/template_imports/mount_rename_unknown_index_set.esm"))
    assert exc.value.code == "subsystem_index_set_rename_unknown_name"
    assert "celsl" in str(exc.value)


def test_two_rename_keys_onto_one_target_is_a_collision(tmp_path):
    # esm-spec §4.7 "Mount-edge index-set renaming", Checks: post-rename names
    # MUST be distinct within one edge. `subsystem_mesh_lib.esm` declares two
    # axes, so mapping both onto `merged` is the minimal violation. Without this
    # the second write would silently win and one axis would vanish from the
    # registry it was supposed to reach.
    host = {
        "esm": "1.0.0",
        "metadata": {"name": "rename_collision", "description": "two keys, one target"},
        "models": {
            "Host": {
                "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "*", "args": [-0.5, "x"]},
                    }
                ],
                "subsystems": {
                    "M": {
                        "ref": _fixture("valid/subsystem_mesh_lib.esm"),
                        "index_set_rename": {"cells": "merged", "vertices": "merged"},
                    }
                },
            }
        },
    }
    p = tmp_path / "rename_collision.esm"
    p.write_text(json.dumps(host))
    with pytest.raises(ExpressionTemplateError) as exc:
        load_path(str(p))
    assert exc.value.code == "template_import_rename_collision"
    assert "merged" in str(exc.value)
