#!/usr/bin/env python3
"""Check Lean on state-free array assertions and constant-gather faults."""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFORMANCE = ROOT / "tests" / "conformance"
SPEC = importlib.util.spec_from_file_location(
    "lean_inline_tests", ROOT / "scripts" / "run-lean-inline-tests.py"
)
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)


class StaticArrayAssertions(unittest.TestCase):
    def request_static(self, model, documents):
        request = [{"test_id": "probe", "assertion_idx": 1}]
        payload = "".join(
            json.dumps({"document": document, "requests": request}) + "\n" for document in documents
        )
        proc = subprocess.run(
            [ADAPTER.BINARY, "static-assertions-jsonl", model],
            input=payload,
            text=True,
            capture_output=True,
            check=True,
        )
        return [json.loads(line) for line in proc.stdout.splitlines()]

    def check_passes(self, manifest_path, fixture):
        result = ADAPTER.run_fixture(manifest_path, fixture)
        self.assertIn("assertions", result, result)
        self.assertTrue(result["assertions"], result)
        for assertion in result["assertions"]:
            self.assertTrue(assertion["passed"], assertion)

    def test_constant_gather_bounds(self):
        manifest_path = CONFORMANCE / "const_array_gather_bounds" / "manifest.json"
        fixtures = json.loads(manifest_path.read_text())["fixtures"]
        for model in sorted({fixture["model"] for fixture in fixtures}):
            group = [fixture for fixture in fixtures if fixture["model"] == model]
            lines = []
            for fixture in group:
                path = ADAPTER.INLINE.fixture_path(manifest_path, fixture)
                authored = ADAPTER.INLINE.authored_assertions(manifest_path, fixture)
                self.assertEqual(len(authored), 1, fixture["id"])
                assertion = authored[0]
                lines.append(
                    json.dumps(
                        {
                            "document": json.loads(path.read_text()),
                            "requests": [
                                {
                                    "test_id": assertion["test_id"],
                                    "assertion_idx": assertion["assertion_idx"],
                                }
                            ],
                        }
                    )
                )
            proc = subprocess.run(
                [ADAPTER.BINARY, "static-assertions-jsonl", model],
                input="\n".join(lines) + "\n",
                text=True,
                capture_output=True,
                check=True,
            )
            results = [json.loads(line) for line in proc.stdout.splitlines()]
            self.assertEqual(len(results), len(group), proc.stdout)
            for fixture, result in zip(group, results, strict=True):
                with self.subTest(fixture=fixture["id"]):
                    if fixture["outcome"] == "pass":
                        self.assertEqual(len(result.get("values", [])), 1, result)
                        actual = ADAPTER.decode_float_bits(result["values"][0])
                        self.assertEqual(actual, fixture["expected"])
                    else:
                        self.assertEqual(result.get("error"), fixture["error_code"], result)

    def test_shaped_observations(self):
        for tier in ("shaped_observed_scalar_broadcast", "pde_inline_observed_indexed_lhs"):
            manifest_path = CONFORMANCE / tier / "manifest.json"
            for fixture in json.loads(manifest_path.read_text())["fixtures"]:
                with self.subTest(fixture=fixture["id"]):
                    self.check_passes(manifest_path, fixture)

    def test_unbound_gather_fails_closed(self):
        fixture = {
            "id": "undefined_variable_in_gather",
            "path": "invalid/undefined_variable_in_gather.esm",
            "model": "UnboundConstGatherOperand",
        }
        manifest_path = CONFORMANCE / "static_array_semantics" / "manifest.json"
        self.assertEqual(
            ADAPTER.run_fixture(manifest_path, fixture),
            {"error": "unbound: missingFactor"},
        )

    def test_lazy_cell_gather(self):
        path = ROOT / "tests/differential/shaped/pending/lazy_cell_gather.esm"
        selected = json.loads(path.read_text())
        rejected = json.loads(path.read_text())
        rejected["models"]["Probe"]["equations"][0]["rhs"]["args"][1] = 2
        success, fault = self.request_static("Probe", [selected, rejected])
        self.assertEqual([ADAPTER.decode_float_bits(v) for v in success["values"]], [7.0])
        self.assertEqual(fault, {"error": "E_TREEWALK_CONSTARRAY_OOB"})

    def test_join_side_diagnostics(self):
        sources = ROOT / "tests/invalid/faq/build_time"
        cases = {
            "self_join_index_set_key_ambiguous": "join_side_ambiguous",
            "self_join_three_ranges_ambiguous": "join_side_ambiguous",
            "self_join_syms_unknown_symbol": "join_syms_unknown_symbol",
        }
        documents = []
        for fixture in cases:
            document = json.loads((sources / f"{fixture}.esm").read_text())
            [model] = document["models"].values()
            document["models"] = {"Probe": model}
            # Use a static assertion to request the same RHS as the corpus
            # fixture. Its join scope and expected structural fault are intact.
            model["equations"][-1]["lhs"] = "count"
            model["tests"] = [
                {"id": "probe", "assertions": [{"variable": "count", "time": 0, "expected": 0}]}
            ]
            documents.append(document)
        results = self.request_static("Probe", documents)
        for (fixture, code), result in zip(cases.items(), results, strict=True):
            with self.subTest(fixture=fixture):
                self.assertEqual(result["error"].split(":", 1)[0], code)

    def test_pending_join_replays(self):
        manifest = CONFORMANCE / "static_array_semantics" / "manifest.json"
        source = ROOT / "tests/differential/shaped/pending"
        for path in sorted(source.glob("join_*.esm")):
            with self.subTest(fixture=path.name):
                self.check_passes(
                    manifest,
                    {"id": path.stem, "path": str(path), "model": "Probe"},
                )

    def test_static_faq(self):
        fixture = {
            "id": "min_reduction_static_shaped_document",
            "path": "valid/faq/min_reduction_static_shaped_document.esm",
            "model": "FirstLevelAbove",
        }
        self.check_passes(CONFORMANCE / "simulate_faq" / "manifest.json", fixture)

    def test_shape_operators_and_parameter_overrides(self):
        def node(op, *args, **fields):
            return {"op": op, "args": list(args), **fields}

        expressions = {
            "linear": node("const", value=[1, 2, 3, 4, 5, 6]),
            "matrix": node("reshape", "linear", shape=[2, 3]),
            "transposed": node("transpose", "matrix"),
            "concatenated": node("concat", "matrix", "matrix", axis=1),
            "made": node("makearray", regions=[[[1, 2]], [[2, 3]], [[5, 5]]], values=[4, 9, 7]),
            "with_empty_region": node(
                "makearray",
                regions=[[[1, 1]], [[101, 100]], [[3, 3]]],
                values=[4, node("index", node("const", value=[0]), 2), 7],
            ),
            "explicit": node("broadcast", "matrix", node("reshape", "p", shape=[2, 1]), fn="+"),
            "unary_broadcast": node("broadcast", "p", fn="-"),
            "implicit": node("+", "matrix", 2),
            "gather": node("index", "implicit", 2, 2),
            "cube": node("reshape", "linear", shape=[2, 1, 3]),
            "trailing_slice": node("index", "cube", 2),
            "literal_slice": node("index", node("const", value=[[[1, 2]], [[3, 4]]]), 2),
            "slice_or_scalar": node(
                "ifelse", 0, node("index", node("reshape", "linear", shape=[2, 1, 3]), 2), 7
            ),
            "index_scalar": node("index", 9),
            "bound": "p",
            "from_default_array": "q",
            "named_broadcast": node("broadcast", "q", "c", fn="+"),
            "named_union": node("*", "q", "c"),
            "gather_named_union": node("index", node("+", "q", "c"), 1, 2),
            "mixed_broadcast": node("+", "q", node("const", value=[[100], [200], [300]])),
            "named_matrix": node("const", value=[[1, 2], [3, 4], [5, 6]]),
            "named_reordered": "named_matrix",
            "unused_fault": node("index", node("const", value=[0]), 2),
            "lazy_dependency": node("ifelse", 0, "unused_fault", 7),
        }
        variables = {name: {"type": "unknown", "units": "1"} for name in expressions}
        variables["p"] = {"type": "parameter", "units": "1", "shape": ["rows"], "default": 2}
        variables["q"] = {"type": "parameter", "units": "1", "shape": ["rows"], "default": [5, 8]}
        variables["c"] = {
            "type": "parameter",
            "units": "1",
            "shape": ["cols"],
            "default": [3, 10, 20],
        }
        variables["bound"]["shape"] = ["rows"]
        variables["from_default_array"]["shape"] = ["rows"]
        variables["named_broadcast"]["shape"] = ["cols", "rows"]
        variables["mixed_broadcast"]["shape"] = ["cols", "rows"]
        variables["named_matrix"]["shape"] = ["cols", "rows"]
        variables["named_reordered"]["shape"] = ["rows", "cols"]
        variables["lhs_shell"] = {"type": "unknown", "units": "1", "shape": ["rows"]}
        lhs_shell = {
            "lhs": node(
                "faq",
                output_idx=["i"],
                ranges={"i": {"from": "rows"}},
                expr=node("index", "lhs_shell", "i"),
            ),
            "rhs": node("*", 2, "i"),
        }

        def assertion(variable, expected, **fields):
            return {"variable": variable, "time": 0, "expected": expected, **fields}

        doc = {
            "esm": "2.3.0",
            "metadata": {
                "name": "StaticArrayShapeOperators",
                "description": "Array observations and shaped parameter overrides.",
                "authors": ["EarthSciML Authors and Contributors"],
            },
            "index_sets": {
                "rows": {"kind": "interval", "size": 2},
                "cols": {"kind": "interval", "size": 3},
            },
            "models": {
                "M": {
                    "variables": variables,
                    "equations": [
                        {"lhs": name, "rhs": expression} for name, expression in expressions.items()
                    ]
                    + [lhs_shell],
                    "tests": [
                        {
                            "id": "shape_operators",
                            "time_span": {"start": 0, "end": 1},
                            "assertions": [
                                assertion("matrix[1,2]", 3),
                                assertion("transposed[2,1]", 3),
                                assertion("concatenated[2,5]", 4),
                                assertion("made[2]", 9),
                                assertion("made[4]", 0),
                                assertion("with_empty_region[2]", 0),
                                assertion("with_empty_region[3]", 7),
                                assertion("explicit[2,3]", 8),
                                assertion("unary_broadcast[2]", -2),
                                assertion("gather", 6),
                                assertion("trailing_slice[1,3]", 6),
                                assertion("literal_slice[1,2]", 4),
                                assertion("slice_or_scalar[1,3]", 7),
                                assertion("index_scalar", 9),
                                assertion("bound[2]", 2),
                                assertion("from_default_array[2]", 8),
                                assertion("named_broadcast[3,2]", 28),
                                assertion("named_union[2,2]", 80),
                                assertion("gather_named_union", 15),
                                assertion("mixed_broadcast[3,2]", 308),
                                assertion("named_reordered[1,2]", 3),
                                assertion("lazy_dependency", 7),
                                assertion("lhs_shell[2]", 4),
                            ],
                        },
                        {
                            "id": "overrides",
                            "time_span": {"start": 0, "end": 1},
                            "parameter_overrides": {"p": [22, 29], "M.q": 12},
                            "assertions": [
                                assertion("bound", 22, coords={"rows": 1.5}),
                                assertion("bound", 29, coords={"rows": 1.75}),
                                assertion("bound", 25.5, reduce="mean"),
                                assertion("from_default_array", 12, reduce="min"),
                            ],
                        },
                    ],
                }
            },
        }
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / "arrays.esm"
            path.write_text(json.dumps(doc))
            manifest_path = directory / "manifest.json"
            fixture = {"id": "arrays", "path": path.name, "model": "M"}
            self.check_passes(manifest_path, fixture)
            variables["named_broadcast"]["shape"] = ["rows"]
            path.write_text(json.dumps(doc))
            result = ADAPTER.run_fixture(manifest_path, fixture)
            self.assertEqual(result.get("code"), "array_shape_mismatch", result)
            variables["named_broadcast"]["shape"] = ["cols", "rows"]
            expressions["unary_broadcast"]["fn"] = "reshape"
            path.write_text(json.dumps(doc))
            result = ADAPTER.run_fixture(manifest_path, fixture)
            self.assertEqual(result.get("code"), "invalid_broadcast_fn", result)
            expressions["unary_broadcast"].update(
                fn="+", args=[node("const", value=[1, 2]), node("const", value=[3, 4, 5])]
            )
            path.write_text(json.dumps(doc))
            result = ADAPTER.run_fixture(manifest_path, fixture)
            self.assertEqual(result.get("status"), "refused", result)
            self.assertEqual(result.get("code"), "array_shape_mismatch", result)

    def test_array_conditionals(self):
        def node(op, *args, **fields):
            return {"op": op, "args": list(args), **fields}

        def const(values):
            return node("const", value=values)

        mask = const([1, 0])
        guarded_gather = node(
            "faq",
            output_idx=["i"],
            ranges={"i": [1, 2]},
            expr=node("index", const([0, 9]), node("+", "i", 1)),
        )
        expressions = {
            "explicit": node("broadcast", mask, 11, 22, fn="ifelse"),
            "bare": node("ifelse", mask, node("+", 1, const([3, 4])), const([5, 6])),
            "guarded": node("ifelse", mask, guarded_gather, 7),
            "source": const([1, 2, 3]),
            "replicated": node("+", 2, node("ifelse", 0, "source", 5)),
            "shaped": node("ifelse", 0, node("reshape", const([1, 2]), shape=[2, 1]), 4),
        }
        assertions = {
            "explicit[1]": 11,
            "explicit[2]": 22,
            "bare[1]": 4,
            "bare[2]": 6,
            "guarded[1]": 9,
            "guarded[2]": 7,
            "replicated[3]": 7,
            "shaped[2,1]": 4,
        }
        doc = {
            "models": {
                "M": {
                    "variables": {name: {"type": "unknown"} for name in expressions},
                    "equations": [{"lhs": name, "rhs": rhs} for name, rhs in expressions.items()],
                    "tests": [
                        {
                            "id": "conditionals",
                            "assertions": [
                                {"variable": name, "time": 0, "expected": value}
                                for name, value in assertions.items()
                            ],
                        }
                    ],
                }
            }
        }
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / "conditionals.esm"
            path.write_text(json.dumps(doc))
            fixture = {"id": "conditionals", "path": path.name, "model": "M"}
            self.check_passes(directory / "manifest.json", fixture)

    def test_faq_scan_order_and_empty_cells(self):
        def node(op, *args, **fields):
            return {"op": op, "args": list(args), **fields}

        def faq(output, body, **fields):
            return node("faq", output_idx=output, expr=body, **fields)

        axis = {"from": "x"}
        ranges = {"i": axis, "j": axis}
        contribution = node("index", "signal", "j")
        expressions = {
            "signal": node("const", value=[1e16, 1, -1e16, 1]),
            "mask": node("const", value=[1, 0, 0, 0]),
            "terms": node("const", value=[[1e16, 1], [-1e16, 1]]),
            "two_contracts": faq(
                [], node("index", "terms", "a", "z"), ranges={"z": [1, 2], "a": [1, 2]}
            ),
            "reverse": faq(["i"], contribution, ranges=ranges, filter=node("<=", "i", "j")),
            "nested": faq(
                ["i"],
                faq([], contribution, ranges={"j": axis}, filter=node("<=", "i", "j")),
                ranges={"i": axis},
            ),
            "min_window": faq(
                ["i"], contribution, ranges=ranges, semiring="min_sum", filter=node(">", "j", "i")
            ),
            "max_window": faq(
                ["i"], contribution, ranges=ranges, semiring="max_sum", filter=node(">", "j", "i")
            ),
            "min_identity": node("min", node("index", "min_window", 4), 7),
            "max_identity": node("max", node("index", "max_window", 4), 7),
            "pointwise": faq(
                [1, "i"],
                node("index", "signal", node("+", "i", 2)),
                filter=node("index", "mask", "i"),
            ),
            "strided": faq(["i"], "i", ranges={"i": [1, 2, 5]}),
            "implicit_filtered": faq([], contribution, filter=node("<", "j", 1)),
            "faulting_observed": node("index", node("const", value=[0]), 2),
            "implicit_guarded": faq(
                [], node("index", "faulting_observed", "j"), filter=node("<", "j", 1)
            ),
            "fuel_position": faq(["i"], "i", ranges={"i": {"from": "fuels"}}),
        }
        assertions = [
            ("two_contracts", 1),
            ("reverse[1]", 0),
            ("nested[1]", 1),
            ("min_identity", 7),
            ("max_identity", 7),
            ("pointwise[1,1]", -1e16),
            ("pointwise[1,4]", 0),
            ("strided[3]", 5),
            ("implicit_filtered", 0),
            ("implicit_guarded", 0),
            ("fuel_position[3]", 3),
        ]
        doc = {
            "index_sets": {
                "x": {"kind": "interval", "size": 4},
                "fuels": {"kind": "categorical", "members": ["gas", "diesel", "coal"]},
            },
            "models": {
                "M": {
                    "variables": {
                        **{name: {"type": "unknown"} for name in expressions},
                        "faulting_observed": {"type": "unknown", "shape": ["x"]},
                        "fuel_position": {"type": "unknown", "shape": ["fuels"]},
                    },
                    "equations": [{"lhs": name, "rhs": rhs} for name, rhs in expressions.items()],
                    "tests": [
                        {
                            "id": "faq",
                            "assertions": [
                                {"variable": name, "time": 0, "expected": value}
                                for name, value in assertions
                            ],
                        }
                    ],
                }
            },
        }
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / "faq.esm"
            path.write_text(json.dumps(doc))
            self.check_passes(
                directory / "manifest.json", {"id": "faq", "path": path.name, "model": "M"}
            )


if __name__ == "__main__":
    unittest.main()
