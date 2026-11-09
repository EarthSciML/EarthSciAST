"""The ``cast`` op (esm-spec §4.2, §11.3.1; CONFORMANCE_SPEC §5.18.2a): the one
conversion between binary64 and binary32.

The fixtures are shared with the other four bindings
(``tests/conformance/element_type_cast/``). This binding evaluates binary64
only, so it asserts ``casts`` (load and load → emit → load keep every cast's
``element_type``), ``binary64_values`` (a cast to Float64 is the identity, bit
for bit) and ``binary64_refusals`` (a cast to Float32, or a Float32 document,
is refused with ``float32_unsupported``, never evaluated as the identity).
``values`` and ``build_errors`` belong to the bindings in ``evaluated_by``.
"""

from __future__ import annotations

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.canonicalize import canonical_json
from earthsci_ast.codegen import _format_expr
from earthsci_ast.display import to_ascii
from earthsci_ast.errors import Float32UnsupportedError
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.expression import to_sympy
from earthsci_ast.numpy_interpreter import EvalContext, eval_expr
from earthsci_ast.parse import load_path, load_string
from earthsci_ast.parse_expression import parse_expression
from earthsci_ast.problem import esm_problem, observed_field
from earthsci_ast.serialize import to_json
from earthsci_ast.units import PINT_AVAILABLE, UnitValidator, parse_unit, unit_exact_scale

FIXTURES = FIXTURES_ROOT / "conformance" / "element_type_cast"
EXPECTED = json.loads((FIXTURES / "expected.json").read_text())


def _casts(node, out: list) -> list:
    """Every ``cast`` node's ``element_type`` in emitted JSON, in document order
    (a node before its operands)."""
    if isinstance(node, dict):
        if node.get("op") == "cast":
            out.append(node.get("element_type"))
        for value in node.values():
            _casts(value, out)
    elif isinstance(node, list):
        for value in node:
            _casts(value, out)
    return out


def _emitted(esm_file) -> dict:
    return json.loads(to_json(esm_file))


def _equation_casts(doc: dict) -> list:
    """The casts in the models' equations only (the walk order the contract
    names: models in order, equations in order)."""
    out: list = []
    for model in (doc.get("models") or {}).values():
        for eq in model.get("equations") or []:
            _casts(eq, out)
    return out


@pytest.mark.parametrize("fixture", sorted(EXPECTED["casts"]))
def test_each_fixture_loads_with_exactly_its_casts(fixture):
    doc = _emitted(load_path(str(FIXTURES / fixture)))
    assert _equation_casts(doc) == EXPECTED["casts"][fixture]


@pytest.mark.parametrize("fixture", sorted(EXPECTED["casts"]))
def test_the_casts_round_trip(fixture):
    once = _emitted(load_path(str(FIXTURES / fixture)))
    twice = _emitted(load_string(json.dumps(once)))
    assert _equation_casts(twice) == EXPECTED["casts"][fixture]
    assert twice == once


@pytest.mark.parametrize("fixture", sorted(EXPECTED["binary64_values"]))
def test_a_cast_to_float64_is_the_identity(fixture):
    prob = esm_problem(load_path(str(FIXTURES / fixture)), (0.0, 0.0))
    for name, want in EXPECTED["binary64_values"][fixture].items():
        got = float(observed_field(prob, name))
        assert got.hex() == float(want).hex(), (name, got, want)


@pytest.mark.parametrize("fixture", sorted(EXPECTED["binary64_refusals"]))
def test_a_binary32_value_is_refused(fixture):
    with pytest.raises(Float32UnsupportedError) as info:
        esm_problem(load_path(str(FIXTURES / fixture)), (0.0, 0.0))
    assert info.value.code == EXPECTED["binary64_refusals"][fixture]


# --- every evaluator path, not only the up-front build refusal ---------------

_TO32 = ExprNode(op="cast", element_type="Float32", args=["x"])
_TO64 = ExprNode(op="cast", element_type="Float64", args=["x"])


def _ctx() -> EvalContext:
    return EvalContext(
        state_layout={},
        state_shapes={},
        param_values={"x": 0.1},
        observed_values={},
        y=None,
        t=0.0,
        index_sets={},
    )


def test_the_numpy_interpreter_refuses_a_float32_cast():
    assert eval_expr(_TO64, _ctx()) == 0.1
    with pytest.raises(Float32UnsupportedError):
        eval_expr(_TO32, _ctx())


def test_the_sympy_bridge_refuses_a_float32_cast():
    assert str(to_sympy(_TO64)) == "x"
    with pytest.raises(Float32UnsupportedError):
        to_sympy(_TO32)


def test_codegen_refuses_a_float32_cast():
    raw64 = {"op": "cast", "element_type": "Float64", "args": ["x"]}
    raw32 = {"op": "cast", "element_type": "Float32", "args": ["x"]}
    for target in ("julia", "python"):
        assert _format_expr(raw64, target) == "x"
        with pytest.raises(Float32UnsupportedError):
            _format_expr(raw32, target)


def test_text_rendering_parses_back():
    text = to_ascii(_TO32)
    assert text == "cast(x, Float32)"
    assert parse_expression(text) == {"op": "cast", "args": ["x"], "element_type": "Float32"}


def test_canonical_json_keeps_the_precision():
    assert canonical_json(_TO32) == '{"args":["x"],"element_type":"Float32","op":"cast"}'
    assert canonical_json(_TO32) != canonical_json(_TO64)


@pytest.mark.skipif(not PINT_AVAILABLE, reason="pint not installed")
def test_a_cast_has_its_operands_units():
    v = UnitValidator()
    v.known_units = {"x": parse_unit("m/s")}
    typed = v._type(_TO32)
    assert typed is not None
    assert typed.scale == unit_exact_scale("m/s")
