#!/usr/bin/env python3
"""Exercise ragged range scheduling and gathers through the Lean inline adapter."""

import json
import tempfile
import unittest
from pathlib import Path

from test_static_array_assertions import ADAPTER


def node(op, *args, **fields):
    return {"op": op, "args": list(args), **fields}


def document():
    sets = {
        "rows": {"kind": "interval", "size": 3},
        "levels": {"kind": "interval", "size": 2},
        "padding": {"kind": "interval", "size": 3},
        "entries": {"kind": "interval", "size": 3},
        "members_of_cell": {
            "kind": "ragged",
            "of": ["rows", "levels"],
            "offsets": "lengths",
            "values": "members",
        },
    }
    ranges = {
        "a": {"from": "members_of_cell", "of": ["z", "m"]},
        "m": {"from": "levels"},
        "z": {"from": "rows"},
    }
    # The padding is deliberately an invalid gather index into payload.
    contribution = node("index", "payload", node("index", "members", "z", "m", "a"))
    equations = {
        "lengths": node("const", value=[[1, 0], [2, 1], [0, 2]]),
        "members": node(
            "const",
            value=[
                [[3, 99, 99], [99, 99, 99]],
                [[1, 3, 99], [2, 99, 99]],
                [[99, 99, 99], [3, 2, 99]],
            ],
        ),
        "payload": node("const", value=[10, 20, 30]),
        "row_sum": node("faq", output_idx=["z", "m"], ranges=ranges, expr=contribution),
        "all_sum": node("faq", output_idx=[], ranges=ranges, expr=contribution),
        "row_min": node(
            "faq", output_idx=["z", "m"], ranges=ranges, semiring="min_sum", expr=contribution
        ),
        "empty_control": node("min", node("index", "row_min", 1, 2), 11),
    }
    variables = {name: {"type": "unknown", "units": "1"} for name in equations}
    for name, axes in {
        "lengths": ["rows", "levels"],
        "members": ["rows", "levels", "padding"],
        "payload": ["entries"],
        "row_sum": ["rows", "levels"],
        "row_min": ["rows", "levels"],
    }.items():
        variables[name]["shape"] = axes

    return {
        "esm": "2.4.0",
        "metadata": {"name": "RaggedParentContractions"},
        "index_sets": sets,
        "models": {
            "M": {
                "variables": variables,
                "equations": [{"lhs": name, "rhs": rhs} for name, rhs in equations.items()],
                "tests": [
                    {
                        "id": "ragged",
                        "assertions": [
                            {"variable": name, "time": 0, "expected": value}
                            for name, value in [
                                ("row_sum[1,1]", 30),
                                ("row_sum[1,2]", 0),
                                ("row_sum[2,1]", 40),
                                ("row_sum[2,2]", 20),
                                ("row_sum[3,1]", 0),
                                ("row_sum[3,2]", 50),
                                ("all_sum", 140),
                                ("empty_control", 11),
                            ]
                        ],
                    }
                ],
            },
        },
    }


class RaggedFaq(unittest.TestCase):
    def run_document(self, doc):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / "ragged.esm"
            path.write_text(json.dumps(doc), encoding="utf-8")
            return ADAPTER.run_fixture(
                directory / "manifest.json", {"id": "ragged", "path": path.name, "model": "M"}
            )

    def test_parent_tuples_and_empty_rows(self):
        result = self.run_document(document())
        self.assertIn("assertions", result, result)
        self.assertEqual(len(result["assertions"]), 8)
        for assertion in result["assertions"]:
            self.assertTrue(assertion["passed"], assertion)

    def test_position_cannot_stand_in_for_member(self):
        doc = document()
        model = doc["models"]["M"]
        query = next(eq["rhs"] for eq in model["equations"] if eq["lhs"] == "all_sum")
        query["expr"] = "a"
        model["tests"][0]["assertions"] = [{"variable": "all_sum", "time": 0, "expected": 0}]
        self.assertIn("ragged_values_not_gathered", str(self.run_document(doc)))

    def test_declared_offsets_survive_nested_index_shadowing(self):
        doc = document()
        doc["index_sets"]["members_of_cell"]["offsets"] = "z"
        model = doc["models"]["M"]
        model["variables"]["z"] = model["variables"].pop("lengths")
        lengths = next(eq for eq in model["equations"] if eq["lhs"] == "lengths")
        lengths["lhs"] = "z"
        all_sum = next(eq["rhs"] for eq in model["equations"] if eq["lhs"] == "all_sum")
        model["variables"]["nested_total"] = {"type": "unknown", "units": "1"}
        model["equations"].append(
            {
                "lhs": "nested_total",
                "rhs": node("faq", output_idx=[], ranges={"z": [1, 2]}, expr=all_sum),
            }
        )
        model["tests"][0]["assertions"].append(
            {"variable": "nested_total", "time": 0, "expected": 280}
        )
        result = self.run_document(doc)
        self.assertIn("assertions", result, result)
        self.assertEqual(len(result["assertions"]), 9)
        for assertion in result["assertions"]:
            self.assertTrue(assertion["passed"], assertion)


if __name__ == "__main__":
    unittest.main()
