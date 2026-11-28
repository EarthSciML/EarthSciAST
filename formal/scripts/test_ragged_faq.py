#!/usr/bin/env python3
"""Exercise ragged range scheduling and gathers through the Lean inline adapter."""

import json
import tempfile
import unittest
from pathlib import Path

from test_static_array_assertions import ADAPTER, CONFORMANCE


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
        (model,) = doc["models"]
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / "ragged.esm"
            path.write_text(json.dumps(doc), encoding="utf-8")
            return ADAPTER.run_fixture(
                directory / "manifest.json", {"id": "ragged", "path": path.name, "model": model}
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

    def value_invention_document(self):
        path = CONFORMANCE / "static_array_semantics/fixtures/ragged_distinct_extent.esm"
        doc = json.loads(path.read_text())
        model = doc["models"]["RaggedDistinctStatic"]
        return doc, model

    def test_distinct_members_and_derived_shape(self):
        doc, model = self.value_invention_document()
        doc["index_sets"]["found"]["member_factor"] = "found_ids"
        doc["index_sets"]["selected"] = {"kind": "derived", "from_faq": "selected_ids"}
        model["variables"]["found_ids"] = {"type": "parameter", "shape": ["found"]}
        model["variables"]["rank"] = {"type": "unknown", "shape": ["found"]}
        model["variables"]["selected_mask"] = {"type": "unknown", "shape": ["selected"]}
        model["variables"]["num_selected"] = {"type": "unknown"}
        from_found = {"z": {"from": "found"}}
        member = node("index", "found_ids", "z")
        model["equations"][:0] = [
            {
                "lhs": "rank",
                "rhs": node("faq", output_idx=["z"], ranges=from_found, expr="z"),
            },
            {
                "lhs": node("index", "selected_mask", "i"),
                "rhs": node(
                    "faq",
                    id="selected_ids",
                    semiring="bool_and_or",
                    distinct=True,
                    output_idx=["i"],
                    ranges=from_found,
                    key=member,
                    filter=node(">", member, 3),
                    expr=node("true"),
                ),
            },
            {
                "lhs": "num_selected",
                "rhs": node("faq", output_idx=[], ranges={"i": {"from": "selected"}}, expr=1),
            },
        ]
        extra_assertions = [
            ("found_ids[1]", 3),
            ("found_ids[2]", 4),
            ("found_ids[3]", 9),
            ("rank[3]", 3),
            ("num_selected", 2),
        ]
        model["tests"][0]["assertions"].extend(
            {"variable": name, "expected": expected, "time": 0}
            for name, expected in extra_assertions
        )
        result = self.run_document(doc)
        self.assertIn("assertions", result, result)
        self.assertEqual(len(result["assertions"]), 6)
        for assertion in result["assertions"]:
            self.assertTrue(assertion["passed"], assertion)

    def test_all_empty_ragged_producer_materializes_zero_extent(self):
        doc, model = self.value_invention_document()
        model["variables"]["lengths"].update(type="parameter", default=[0, 0, 0])
        model["equations"] = [eq for eq in model["equations"] if eq["lhs"] != "lengths"]
        model["tests"][0]["assertions"][0]["expected"] = 0
        result = self.run_document(doc)
        self.assertIn("assertions", result, result)
        self.assertTrue(result["assertions"][0]["passed"], result)

    def test_missing_backing_factor_is_not_an_empty_derived_set(self):
        doc, model = self.value_invention_document()
        model["equations"] = [eq for eq in model["equations"] if eq["lhs"] != "members"]
        result = self.run_document(doc)
        self.assertIn("derived_index_set_unmaterialized", str(result))
        self.assertIn("members", str(result))

    def test_noninteger_ragged_key_names_the_producing_node(self):
        doc, model = self.value_invention_document()
        members = next(eq["rhs"] for eq in model["equations"] if eq["lhs"] == "members")
        members["value"][0][0] = 3.5
        result = self.run_document(doc)
        self.assertIn("value_invention_key_out_of_range", str(result))
        self.assertIn("unique_neighbors", str(result))


if __name__ == "__main__":
    unittest.main()
