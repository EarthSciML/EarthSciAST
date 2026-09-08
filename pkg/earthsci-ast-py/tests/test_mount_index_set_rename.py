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


def _join_leaf() -> dict:
    """A leaf whose `aggregate` joins on a loop symbol against an index set.

    Modelled on ``tests/valid/aggregate/join_moves_running_exhaust.esm``: each
    ``on`` pair is ``[loop symbol, index set]``, which is exactly the mix the
    rename rule has to tell apart.
    """
    return {
        "esm": "1.0.0",
        "metadata": {"name": "join_leaf", "description": "aggregate join on an axis"},
        "index_sets": {
            "sourceType": {"kind": "categorical", "members": ["onroad", "nonroad"]},
        },
        "models": {
            "Leaf": {
                "variables": {
                    "e": {"type": "unknown", "units": "1", "shape": ["sourceType"], "default": 1.0}
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["e"], "wrt": "t"},
                        "rhs": {
                            "op": "aggregate",
                            "args": [],
                            "output_idx": ["src"],
                            "semiring": "sum_product",
                            "reduce": "+",
                            "ranges": {"src": {"from": "sourceType"}},
                            "join": [{"on": [["src", "sourceType"]]}],
                            "expr": {
                                "op": "*",
                                "args": [-1.0, {"op": "index", "args": ["e", "src"]}],
                            },
                        },
                    }
                ],
            }
        },
    }


def test_mount_rename_rewrites_a_join_on_axis_but_not_its_loop_symbol(tmp_path):
    # esm-spec §4.7 transitivity list / §9.7.7: an `aggregate` `join` clause's
    # `on` key column follows the rename IFF it names a renamed index set. An
    # `on` pair here is [loop symbol, index set]: `src` is bound by the node's
    # own `ranges` and must stay, `sourceType` is the axis and must move. Left
    # unrewritten, the join would key against an axis the merged registry no
    # longer holds.
    leaf = tmp_path / "join_leaf.esm"
    leaf.write_text(json.dumps(_join_leaf()))
    host = {
        "esm": "1.0.0",
        "metadata": {"name": "join_host", "description": "renames the joined axis"},
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
                    "L": {
                        "ref": str(leaf),
                        "index_set_rename": {"sourceType": "atm_sourceType"},
                    }
                },
            }
        },
    }
    p = tmp_path / "join_host.esm"
    p.write_text(json.dumps(host))

    doc = load_path(str(p))
    assert "atm_sourceType" in doc.index_sets
    assert "sourceType" not in doc.index_sets

    sub = doc.models["Host"].subsystems["L"]
    assert sub.variables["e"].shape == ["atm_sourceType"]
    rhs = json.loads(json.dumps(sub.equations[0].rhs, default=lambda o: o.__dict__))
    emitted = json.dumps(rhs)
    # The axis moved; the loop symbol did not.
    assert '"atm_sourceType"' in emitted
    assert '"sourceType"' not in emitted.replace('"atm_sourceType"', "")
    assert '"src"' in emitted
