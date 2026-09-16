"""A string bound to a template parameter that an `enum` op's argument spells.

Substitution is position-blind (esm-spec §9.6.3 constraint 5), so the bound
string lands as the enum symbol, and a document is valid iff its expansion is
(§9.6.9). The raw-stage reference check must not read it as an undeclared
variable. The shared fixture `tests/valid/enums_symbol_template_binding.esm`
pins the verdict across bindings; this file pins Python's lowered values and the
two neighbouring cases.
"""

from __future__ import annotations

import json
import os

import pytest

from earthsci_ast import load_path
from earthsci_ast.parse import SchemaValidationError

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FIXTURE = os.path.join(REPO, "tests", "valid", "enums_symbol_template_binding.esm")

ENUMS = {"activity_unit": {"g_per_hp_hr": 1, "g_per_gallon": 2}}


def _rhs(model, lhs):
    return next(eq.rhs for eq in model.equations if eq.lhs == lhs)


def _write(path, doc):
    path.write_text(json.dumps(doc))
    return str(path)


def test_string_bound_enum_symbol_lowers_to_the_member_value():
    m = load_path(FIXTURE).models["EnumsSymbolTemplateBinding"]
    assert _rhs(m, "templateCode").op == "const"
    assert _rhs(m, "templateCode").value == 2
    assert _rhs(m, "callerCode").value == 2


def test_string_bound_enum_symbol_through_a_template_import(tmp_path):
    _write(
        tmp_path / "lib.esm",
        {
            "esm": "1.0.0",
            "metadata": {"name": "lib"},
            "enums": ENUMS,
            "expression_templates": {
                "activity_code": {
                    "params": ["sym"],
                    "body": {"op": "enum", "args": ["activity_unit", "sym"]},
                }
            },
        },
    )
    importer = _write(
        tmp_path / "importer.esm",
        {
            "esm": "1.0.0",
            "metadata": {"name": "importer"},
            "enums": ENUMS,
            "models": {
                "Consumer": {
                    "expression_template_imports": [{"ref": "./lib.esm"}],
                    "variables": {"code": {"type": "unknown", "units": "1"}},
                    "equations": [
                        {
                            "lhs": "code",
                            "rhs": {
                                "op": "apply_expression_template",
                                "args": [],
                                "name": "activity_code",
                                "bindings": {"sym": "g_per_gallon"},
                            },
                        }
                    ],
                }
            },
        },
    )
    m = load_path(importer).models["Consumer"]
    assert _rhs(m, "code").op == "const"
    assert _rhs(m, "code").value == 2


def test_string_bound_param_also_used_as_a_reference_must_be_declared(tmp_path):
    # `sym` spells the enum symbol AND is a variable reference in the same body,
    # so the expansion references `g_per_gallon` as a variable, which is undeclared.
    doc = _write(
        tmp_path / "both.esm",
        {
            "esm": "1.0.0",
            "metadata": {"name": "both"},
            "enums": ENUMS,
            "models": {
                "M": {
                    "expression_templates": {
                        "mixed": {
                            "params": ["sym"],
                            "body": {
                                "op": "+",
                                "args": ["sym", {"op": "enum", "args": ["activity_unit", "sym"]}],
                            },
                        }
                    },
                    "variables": {"y": {"type": "unknown", "units": "1"}},
                    "equations": [
                        {
                            "lhs": "y",
                            "rhs": {
                                "op": "apply_expression_template",
                                "args": [],
                                "name": "mixed",
                                "bindings": {"sym": "g_per_gallon"},
                            },
                        }
                    ],
                }
            },
        },
    )
    with pytest.raises(SchemaValidationError, match="g_per_gallon"):
        load_path(doc)
