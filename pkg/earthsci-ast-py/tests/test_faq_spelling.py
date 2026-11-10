"""The `faq` node's spelling at the wire boundary.

`aggregate`, the pre-1.1.0 alias of `faq`, is removed at esm 2.0.0 and `arrayop`
at 0.8.0: both are rejected BY NAME with `removed_op`, in the root and in a
`{ref}`-loaded child, never left to the open rewrite-target tier. `faq` itself
arrives at esm 1.1.0. See CONFORMANCE_SPEC §7 and
`docs/content/rfcs/faq-node-rename.md`.
"""

import json

import pytest

from earthsci_ast import load_path
from earthsci_ast.errors import ParseError

from conftest import CONFORMANCE_DIR, INVALID_DIR

CONF = CONFORMANCE_DIR / "deprecated_op_alias"


def _faq_doc(op: str = "faq", esm: str = "1.3.0") -> dict:
    return {
        "esm": esm,
        "metadata": {"name": "faq_spelling"},
        "index_sets": {"cells": {"kind": "interval", "size": 3}},
        "models": {
            "M": {
                "variables": {
                    "x": {"type": "unknown", "default": 0.0, "units": "1"},
                    "v": {"type": "parameter", "shape": ["cells"], "default": 1.0, "units": "1"},
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {
                            "op": op,
                            "args": ["v"],
                            "output_idx": [],
                            "ranges": {"i": {"from": "cells"}},
                            "expr": {"op": "index", "args": ["v", "i"]},
                        },
                    }
                ],
            }
        },
    }


def _write(tmp_path, doc, name="doc.esm"):
    out = tmp_path / name
    out.write_text(json.dumps(doc), encoding="utf-8")
    return out


def test_the_aggregate_alias_is_removed_op(tmp_path):
    with pytest.raises(ParseError, match="removed_op") as excinfo:
        load_path(str(_write(tmp_path, _faq_doc("aggregate"))))
    assert excinfo.value.code == "removed_op"
    assert '"op": "aggregate"' in str(excinfo.value)
    assert "python -m earthsci_ast.migrate" in str(excinfo.value)


def test_the_aggregate_alias_in_a_referenced_child_is_removed_op(tmp_path):
    child = _write(tmp_path, _faq_doc("aggregate"), "child.esm")
    parent = _faq_doc()
    parent["models"]["M"]["subsystems"] = {"C": {"ref": child.name}}
    with pytest.raises(ParseError, match="removed_op"):
        load_path(str(_write(tmp_path, parent)))


def test_the_canonical_spelling_loads(tmp_path):
    load_path(str(_write(tmp_path, _faq_doc())))


def test_arrayop_is_rejected_by_name_not_left_to_the_open_tier():
    # `arrayop` matches the `op` pattern, so without a by-name rejection it
    # would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
    # much later as `unlowered_operator`.
    with pytest.raises(ParseError, match="removed_op"):
        load_path(str(INVALID_DIR / "faq" / "arrayop_op_removed.esm"))


def test_arrayop_in_a_referenced_child_is_rejected():
    with pytest.raises(ParseError, match="removed_op"):
        load_path(str(CONF / "ref_parent_arrayop.esm"))


def test_faq_below_v11_is_rejected(tmp_path):
    # `faq` arrives at 1.1.0, the same gate the top-level `solver` block uses.
    with pytest.raises(ParseError, match="faq_version_too_old"):
        load_path(str(_write(tmp_path, _faq_doc(esm="1.0.0"))))
