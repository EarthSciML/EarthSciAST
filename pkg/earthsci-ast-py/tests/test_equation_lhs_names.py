"""esm-spec §6.3.1 "What a left-hand side may name" (user rulings 2026-09-29).

* ``equation_defines_parameter``: an equation whose left-hand side names a
  parameter — bare, indexed, inside a ``faq``, or through a scoped reference
  into a subsystem — is invalid, in validation and at build. No pathway may
  drop the equation or let it override the parameter.
* ``unbound_index_symbol``: a string subscript on a left-hand side that no
  ``faq`` binds (on the left, or the right-hand side's ``output_idx`` for the
  bare-index definition) is invalid.

Both are pinned by ``tests/invalid/`` fixtures in
``tests/invalid/expected_errors.json``.
"""

import copy
import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import esm_problem, flatten, load_document
from earthsci_ast.sympy_bridge import SimulationError
from earthsci_ast.validation import validate_text

EXPECTED = json.loads((FIXTURES_ROOT / "invalid" / "expected_errors.json").read_text())


def _findings(result, code):
    return [(e.path, e.details) for e in result.structural_errors if e.code == code]


@pytest.mark.parametrize(
    "name,code",
    [
        ("equation_defines_parameter.esm", "equation_defines_parameter"),
        ("unbound_index_symbol.esm", "unbound_index_symbol"),
    ],
)
def test_fixture_pins_the_code(name, code):
    result = validate_text((FIXTURES_ROOT / "invalid" / name).read_text())
    assert not result.is_valid
    assert result.schema_errors == []
    want = [
        (e["path"], e["details"]) for e in EXPECTED[name]["structural_errors"] if e["code"] == code
    ]
    assert _findings(result, code) == want


def _param_doc(lhs):
    return {
        "esm": "1.1.0",
        "metadata": {"name": "p"},
        "index_sets": {"c": {"kind": "interval", "size": 2}},
        "models": {
            "M": {
                "variables": {
                    "k": {"type": "parameter", "units": "1", "shape": ["c"], "default": 1.0},
                    "y": {"type": "unknown", "units": "1", "default": 0.0},
                },
                "equations": [
                    {"lhs": lhs, "rhs": 2.0},
                    {"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": 1.0},
                ],
            }
        },
    }


@pytest.mark.parametrize(
    "lhs",
    [
        {"op": "index", "args": ["k", 1]},
        {
            "op": "faq",
            "args": [],
            "output_idx": ["i"],
            "ranges": {"i": {"from": "c"}},
            "expr": {"op": "index", "args": ["k", "i"]},
        },
    ],
)
def test_an_indexed_parameter_definition_is_invalid(lhs):
    result = validate_text(json.dumps(_param_doc(lhs)))
    assert _findings(result, "equation_defines_parameter") == [
        ("/models/M/equations/0/lhs", {"variable": "k"})
    ]


def test_a_derivative_or_ic_lhs_is_not_a_definition():
    doc = _param_doc({"op": "index", "args": ["k", 1]})
    doc["models"]["M"]["equations"][0]["lhs"] = {"op": "ic", "args": ["y"]}
    result = validate_text(json.dumps(doc))
    assert _findings(result, "equation_defines_parameter") == []


def test_the_bare_index_definition_binds_through_the_right_hand_side():
    doc = {
        "esm": "1.1.0",
        "metadata": {"name": "b"},
        "index_sets": {"c": {"kind": "interval", "size": 2}},
        "models": {
            "M": {
                "variables": {"w": {"type": "unknown", "units": "1", "shape": ["c"]}},
                "equations": [
                    {
                        "lhs": {"op": "index", "args": ["w", "k"]},
                        "rhs": {
                            "op": "faq",
                            "args": [],
                            "output_idx": ["k"],
                            "ranges": {"k": {"from": "c"}},
                            "expr": {"op": "*", "args": [2.0, "k"]},
                        },
                    }
                ],
            }
        },
    }
    assert _findings(validate_text(json.dumps(doc)), "unbound_index_symbol") == []


@pytest.mark.parametrize("compiler", ["interpreter", "native"])
def test_esm_problem_refuses_a_parameter_definition(compiler):
    path = FIXTURES_ROOT / "invalid" / "equation_defines_parameter.esm"
    doc = json.loads(path.read_text())
    with pytest.raises(Exception) as exc:
        esm_problem(doc, (0.0, 1.0), compiler=compiler)
    assert "equation_defines_parameter" in str(exc.value) or any(
        c == "equation_defines_parameter" for c, _ in getattr(exc.value, "findings", [])
    )
    # A caller-flattened system never passed through `validate`; the front door
    # refuses it by name too rather than build with the equation dropped.
    valid = copy.deepcopy(doc)
    valid["models"]["Top"]["equations"] = valid["models"]["Top"]["equations"][2:]
    flat = flatten(load_document(valid))
    bad = copy.deepcopy(flat.equations[0])
    bad.lhs = "Top.sub.L"
    flat.equations.append(bad)
    with pytest.raises(SimulationError, match="equation_defines_parameter"):
        esm_problem(flat, (0.0, 1.0), compiler=compiler)
