"""The esm-spec §9.5.3 `table_lookup` lowering ON THE EVALUATION PATH
(issue #188).

``test_function_tables_lowering.py`` proves the lowering is CORRECT, but it
does the lowering itself, inside the harness. This module proves the library
actually applies it: a document whose observed is defined by a
``table_lookup`` must evaluate through the inline-test runner and the build,
not merely validate. It also pins the two properties that constrain WHERE the
pass may run:

* §9.5.4 — the AUTHORED form round-trips. Loading, building, and re-emitting a
  document must still emit ``table_lookup`` nodes and the ``function_tables``
  block, so the pass may not run at load and may not mutate its input.
* §9.5.3a — ``out_of_bounds: "error"`` is refused by name. This binding
  implements only the required ``"clamp"`` mode, and answering in clamp mode a
  document that asked for error mode is a wrong number with nothing in the
  result to say so.
"""

from __future__ import annotations

import copy
import json

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import load_document, load_path, to_json
from earthsci_ast.error_handling import ErrorCode
from earthsci_ast.esm_types import ExprNode
from earthsci_ast.lower_table_lookup import TableLookupError, lower_table_lookups
from earthsci_ast.pde_inline_tests import run_pde_tests
from earthsci_ast.problem import esm_problem
from earthsci_ast.serialize import _serialize_expression

FIXTURES_ROOT = CONFORMANCE_DIR / "function_tables"

# A 1-axis linear table plus the `table_lookup` that reads it.
FIXTURE = {
    "esm": "1.0.0",
    "metadata": {"name": "tl", "authors": ["test"]},
    "function_tables": {
        "t_prof": {
            "axes": [{"name": "p", "values": [1.0, 2.0, 3.0, 4.0]}],
            "interpolation": "linear",
            "data": [10.0, 20.0, 30.0, 40.0],
        }
    },
    "models": {
        "M": {
            "variables": {
                "y": {"type": "unknown", "default": 0.0},
                "p": {"type": "parameter", "default": 2.5},
            },
            "equations": [
                {
                    "lhs": "y",
                    "rhs": {
                        "op": "table_lookup",
                        "table": "t_prof",
                        "axes": {"p": "p"},
                        "args": [],
                    },
                }
            ],
        }
    },
}


def _rhs(file, model="M", idx=0):
    return file.models[model].equations[idx].rhs


def _variant(**edits) -> dict:
    """A copy of :data:`FIXTURE` with ``table`` / ``lookup`` keys overridden —
    the two places a §9.5.5 defect can live."""
    doc = copy.deepcopy(FIXTURE)
    doc["function_tables"]["t_prof"].update(edits.pop("table", {}))
    doc["models"]["M"]["equations"][0]["rhs"].update(edits.pop("lookup", {}))
    assert not edits, edits
    return doc


# ---------------------------------------------------------------------------
# End to end: the inline-test runner (§6.6, the `esm test` path).
# ---------------------------------------------------------------------------


def test_inline_test_fixture_evaluates_every_table_lookup_assertion():
    """The conformance fixture that catches #188: `y` is a `table_lookup`, `z`
    is the same lookup hand-written in the lowered form, and `w` reads the same
    table above its last knot so the default `out_of_bounds: "clamp"` holds the
    last value. Before the lowering reached the build path, `y` and `w` could
    not be evaluated at all."""
    results = run_pde_tests(str(FIXTURES_ROOT / "inline_test" / "fixture.esm"))
    by_variable = {r.variable: r for r in results}
    assert set(by_variable) == {"y", "z", "w"}
    for name, expected in (("y", 25.0), ("z", 25.0), ("w", 40.0)):
        result = by_variable[name]
        assert result.passed, f"{name}: {result.message}"
        assert result.actual == pytest.approx(expected)


def test_table_lookup_observed_is_readable_from_a_build():
    """The same property one level down: the lowering happens inside
    `esm_problem`, so the observed is materialized by the build itself."""
    prob = esm_problem(load_document(FIXTURE), (0.0, 1.0))
    assert prob.flat.observed_variables  # `y` is observed, not an ODE state
    # p = 2.5 sits midway between the 2.0 and 3.0 knots.
    assert float(prob.observed_field("M.y")) == pytest.approx(25.0)


# ---------------------------------------------------------------------------
# Coverage: every expression position the evaluator reaches.
# ---------------------------------------------------------------------------

#: A `table_lookup` in each of them. A pass that reached only the equations
#: would leave the others to fail at evaluation exactly as #188 did.
LOOKUP = {"op": "table_lookup", "table": "t_prof", "axes": {"p": "p"}, "args": []}

EVERY_POSITION = {
    "esm": "1.0.0",
    "metadata": {"name": "positions", "authors": ["test"]},
    "function_tables": FIXTURE["function_tables"],
    "models": {
        "M": {
            "variables": {
                "x": {"type": "unknown", "default": 1.0},
                "p": {"type": "parameter", "default": 2.5},
                "q": {
                    "type": "parameter",
                    "default": 0.0,
                    "update": {
                        "kind": "condition",
                        "when": {"op": ">", "args": [LOOKUP, 1.0]},
                        "expression": LOOKUP,
                    },
                },
            },
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": LOOKUP}],
            "initialization_equations": [{"lhs": "x", "rhs": LOOKUP}],
            "continuous_events": [
                {
                    "name": "ce",
                    "conditions": [{"op": "-", "args": ["x", LOOKUP]}],
                    "affects": [{"lhs": "x", "rhs": LOOKUP}],
                    "affect_neg": [{"lhs": "x", "rhs": LOOKUP}],
                }
            ],
            "discrete_events": [
                {
                    "name": "de",
                    "trigger": {
                        "type": "condition",
                        "expression": {"op": ">", "args": ["x", LOOKUP]},
                    },
                    "affects": [{"lhs": "x", "rhs": LOOKUP}],
                }
            ],
            "tests": [
                {
                    "id": "t1",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {
                            "variable": "x",
                            "time": 1.0,
                            "expected": 1.0,
                            "reduce": "L2_error",
                            "reference": LOOKUP,
                        }
                    ],
                }
            ],
        }
    },
    "reaction_systems": {
        "R": {
            "species": {"A": {}, "B": {}},
            "parameters": {"p": {"default": 2.5}},
            "reactions": [
                {
                    "id": "r1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": [{"species": "B", "stoichiometry": 1}],
                    "rate": LOOKUP,
                }
            ],
            "constraint_equations": [{"lhs": "A", "rhs": LOOKUP}],
        }
    },
}


def test_every_expression_position_is_lowered():
    file = load_document(EVERY_POSITION)
    lowered = lower_table_lookups(file)
    assert "table_lookup" not in to_json(lowered)
    assert "table_lookup" in to_json(file), "the pass mutated its input"


def test_the_flat_events_view_sees_the_lowered_events():
    """`EsmFile.events` and the owning component share event objects BY
    REFERENCE, and `flatten` reads the flat view — so rebuilding one without
    the other would hand the build the un-lowered copy."""
    lowered = lower_table_lookups(load_document(EVERY_POSITION))
    model = lowered.models["M"]
    owned = model.discrete_events + model.continuous_events
    assert [id(e) for e in lowered.events] == [id(e) for e in owned]
    assert lowered.events[1].conditions[0].args[1].op == "fn"


# ---------------------------------------------------------------------------
# §9.5.4: the authored form round-trips, before AND after a build.
# ---------------------------------------------------------------------------


def test_loading_does_not_lower_and_building_does_not_mutate():
    """The pass runs on the way INTO a build, never at load, because this
    binding serializes the typed document it loaded. A `table_lookup` that
    survived `load` but not `esm_problem` would still break §9.5.4 for any
    caller that builds and then re-emits."""
    file = load_document(FIXTURE)
    assert isinstance(_rhs(file), ExprNode) and _rhs(file).op == "table_lookup"

    esm_problem(file, (0.0, 1.0))

    assert _rhs(file).op == "table_lookup", "the build mutated its input document"
    emitted = json.loads(to_json(file))
    assert emitted["models"]["M"]["equations"][0]["rhs"]["op"] == "table_lookup"
    assert emitted["function_tables"]["t_prof"]["data"] == [10.0, 20.0, 30.0, 40.0]


def test_out_of_bounds_error_fixture_loads_and_round_trips():
    """§9.5.5 lists no LOAD-time diagnostic for `out_of_bounds: "error"`, so the
    refusal below must not cost the document its ability to load or re-emit."""
    file = load_path(FIXTURES_ROOT / "out_of_bounds_error" / "fixture.esm")
    emitted = json.loads(to_json(file))
    assert emitted["models"]["M"]["equations"][0]["rhs"]["op"] == "table_lookup"
    assert emitted["function_tables"]["strict_tab"]["out_of_bounds"] == "error"


# ---------------------------------------------------------------------------
# §9.5.3a: `out_of_bounds: "error"` is refused, not silently clamped.
# ---------------------------------------------------------------------------


def test_out_of_bounds_error_is_refused_by_name():
    file = load_path(FIXTURES_ROOT / "out_of_bounds_error" / "fixture.esm")
    with pytest.raises(TableLookupError) as excinfo:
        esm_problem(file, (0.0, 1.0))
    assert excinfo.value.code == ErrorCode.TABLE_OUT_OF_BOUNDS_UNSUPPORTED.value


def test_out_of_bounds_error_is_refused_on_the_inline_test_path_too():
    file = load_path(FIXTURES_ROOT / "out_of_bounds_error" / "fixture.esm")
    with pytest.raises(TableLookupError) as excinfo:
        run_pde_tests(file)
    assert excinfo.value.code == ErrorCode.TABLE_OUT_OF_BOUNDS_UNSUPPORTED.value


# ---------------------------------------------------------------------------
# The pass itself: the §9.5.3 form, and its diagnostics.
# ---------------------------------------------------------------------------


def test_lowers_a_one_axis_linear_lookup_to_the_spec_form():
    lowered = lower_table_lookups(load_document(FIXTURE))
    assert _serialize_expression(_rhs(lowered)) == {
        "op": "fn",
        "args": [
            {"op": "const", "args": [], "value": [10.0, 20.0, 30.0, 40.0]},
            {"op": "const", "args": [], "value": [1.0, 2.0, 3.0, 4.0]},
            "p",
        ],
        "name": "interp.linear",
    }


def test_lowers_a_multi_output_bilinear_lookup_in_declared_axis_order():
    """The axis `const`s go in the table's DECLARED axis order (the order of
    `data`'s inner dimensions), the inputs follow in that same order, and
    `output` picks a row of `data`'s leading dimension — spelled either as a
    name or as an index."""
    file = lower_table_lookups(load_path(FIXTURES_ROOT / "bilinear" / "fixture.esm"))
    table = file.function_tables["F_actinic"]

    by_name = _serialize_expression(_rhs(file, idx=0))
    assert by_name["name"] == "interp.bilinear"
    assert by_name["args"][0]["value"] == table.data[0]  # output "NO2" is row 0
    assert by_name["args"][1]["value"] == table.axes[0].values
    assert by_name["args"][2]["value"] == table.axes[1].values
    assert by_name["args"][3] == "P_atm"
    assert by_name["args"][4] == "cos_sza"

    by_index = _serialize_expression(_rhs(file, idx=1))
    assert by_index["args"][0]["value"] == table.data[1]  # output 1 is row 1


def test_lowering_is_idempotent():
    once = lower_table_lookups(load_document(FIXTURE))
    twice = lower_table_lookups(once)
    assert _serialize_expression(_rhs(twice)) == _serialize_expression(_rhs(once))


def test_a_document_with_no_tables_is_not_even_walked():
    file = load_document(
        {
            "esm": "1.0.0",
            "metadata": {"name": "plain", "authors": ["test"]},
            "models": {
                "M": {
                    "variables": {"x": {"type": "unknown", "default": 1.0}},
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                            "rhs": {"op": "neg", "args": ["x"]},
                        }
                    ],
                }
            },
        }
    )
    assert lower_table_lookups(file) is file


@pytest.mark.parametrize(
    ("edits", "code"),
    [
        ({"lookup": {"table": "nope"}}, ErrorCode.TABLE_LOOKUP_UNKNOWN_TABLE),
        ({"lookup": {"axes": {"q": "p"}}}, ErrorCode.TABLE_LOOKUP_AXIS_NAME_MISMATCH),
        ({"lookup": {"output": 7}}, ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE),
        (
            {"table": {"outputs": ["a", "b"]}, "lookup": {"output": "c"}},
            ErrorCode.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
        ),
        # `outputs` declares five rows, so `output: 4` is in range — but `data`
        # carries only four, which is a table defect, not a selector one.
        (
            {"table": {"outputs": ["a", "b", "c", "d", "e"]}, "lookup": {"output": 4}},
            ErrorCode.TABLE_DATA_SHAPE_MISMATCH,
        ),
        ({"table": {"interpolation": "bilinear"}}, ErrorCode.TABLE_INTERPOLATION_AXES_MISMATCH),
        (
            {"table": {"axes": [{"name": "p", "values": [1.0, 2.0, 3.0, float("nan")]}]}},
            ErrorCode.TABLE_AXIS_NAN,
        ),
    ],
)
def test_a_malformed_lookup_raises_its_named_diagnostic(edits, code):
    """Each §9.5.5 code, raised by name — a generic error here would leave an
    author guessing which of the table, the axis map, the output selector and
    the data was wrong."""
    with pytest.raises(TableLookupError) as excinfo:
        lower_table_lookups(load_document(_variant(**edits)))
    assert excinfo.value.code == code.value
