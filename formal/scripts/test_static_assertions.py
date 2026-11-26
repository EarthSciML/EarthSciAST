#!/usr/bin/env python3
"""Regression cases for the Lean scalar and expression adapters."""

import json
import math
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

BINARY = Path(__file__).resolve().parents[1] / ".lake" / "build" / "bin" / "esm-lean"
ROOT = Path(__file__).resolve().parents[2]


class StaticAssertions(unittest.TestCase):
    def test_override_resolution_and_unsupported_scalar_features(self):
        parameter = {"type": "parameter", "default": 90}
        test = {
            "id": "probe",
            "parameter_overrides": {"M.theta": 2},
            "assertions": [{"variable": "result", "time": 0}],
        }
        equation = {"lhs": "result", "rhs": "theta"}
        model = {
            "variables": {"theta": parameter, "result": {"type": "unknown"}},
            "equations": [equation],
            "tests": [test],
        }
        doc = {"models": {"M": model}}
        requests = [{"test_id": "probe", "assertion_idx": 1}]

        def evaluate():
            result = subprocess.run(
                [BINARY, "static-assertions-jsonl", "M"],
                input=json.dumps({"document": doc, "requests": requests}) + "\n",
                capture_output=True,
                text=True,
                check=True,
            )
            return json.loads(result.stdout)

        self.assertEqual(evaluate(), {"values": [str(0x4000000000000000)]})
        test["parameter_overrides"]["theta"] = 3
        self.assertIn("duplicate parameter override", evaluate()["error"])
        test["parameter_overrides"] = {"Other.theta": 2}
        self.assertIn("unknown parameter override Other.theta", evaluate()["error"])
        test["parameter_overrides"] = {"theta": 2}
        doc["domain"] = {"element_type": "Float32"}
        self.assertIn("float32_unsupported: domain.element_type", evaluate()["error"])
        del doc["domain"]
        parameter["element_type"] = "Float32"
        self.assertIn("float32_unsupported: variable theta", evaluate()["error"])
        del parameter["element_type"]
        equation["rhs"] = {"op": "sin", "args": ["theta"]}
        parameter["units"] = "rad"
        self.assertIn("values", evaluate())
        parameter["units"] = "degree"
        self.assertIn("unsupported_construct: angle units degree", evaluate()["error"])
        del parameter["units"]
        equation["rhs"]["args"] = [{"op": "const", "args": [], "value": 90, "units": "deg"}]
        self.assertIn("unsupported_construct: angle units deg", evaluate()["error"])

    def test_scalar_boolean_faqs_in_template_mode(self):
        fixture = ROOT / "tests/conformance/bool_and_or_reductions/fixtures/scalar_bool_and_or.esm"
        doc = json.loads(fixture.read_text())
        model = doc["models"]["scalar_bool_and_or"]
        model["equations"].insert(
            0,
            {
                "lhs": "dependent",
                "rhs": {
                    "op": "faq",
                    "args": [],
                    "output_idx": [],
                    "ranges": {},
                    "semiring": "bool_and_or",
                    "expr": "any_hot",
                },
            },
        )
        initial = model["variables"]["u"]["default"]
        with tempfile.TemporaryDirectory() as d:
            fixture_path = Path(d) / "scalar.esm"
            fixture_path.write_text(json.dumps(doc))
            case_path = Path(d) / "case.json"
            case_path.write_text(json.dumps({"const_arrays": {"u": initial}}))
            result = subprocess.run(
                [BINARY, "templates", fixture_path, "scalar_bool_and_or", case_path],
                capture_output=True,
                text=True,
                check=True,
            )
        rows = {row["name"]: row for row in json.loads(result.stdout)["results"]}
        for name, expected in {"any_hot": 1, "spread": 1, "never": 0, "dependent": 1}.items():
            self.assertEqual(rows[name].get("value"), expected, rows[name])

    def test_semiring_domain_and_shaped_boolean_refusal(self):
        def faq(semiring, ranges, expr, output_idx=()):
            return {
                "op": "faq",
                "args": [],
                "output_idx": list(output_idx),
                "semiring": semiring,
                "ranges": ranges,
                "expr": expr,
            }

        empty = faq("max_product", {"i": [1, 0]}, "i")
        zero_product = {"op": "*", "args": [0, empty]}
        expressions = {
            "signed": faq("max_product", {"i": [1, 3]}, {"op": "*", "args": ["i", -1]}),
            "zero_times_empty": zero_product,
            "positive_times_empty": {
                "op": "max",
                "args": [{"op": "*", "args": [empty, 2]}, -7],
            },
            "negative_times_empty": {
                "op": "min",
                "args": [{"op": "*", "args": [empty, -2]}, 7],
            },
            "nan_term_is_true": faq("bool_and_or", {"j": [1, 2]}, zero_product),
            "shaped_boolean": {
                "op": "index",
                "args": [faq("bool_and_or", {"i": [1, 2], "j": [1, 2]}, 1, ("i",)), 1],
            },
        }
        model = {
            "variables": {name: {"type": "unknown"} for name in expressions},
            "equations": [{"lhs": name, "rhs": rhs} for name, rhs in expressions.items()],
            "tests": [
                {
                    "id": "semiring",
                    "assertions": [{"variable": name, "time": 0} for name in expressions],
                }
            ],
        }
        doc = {"models": {"M": model}}
        requests = [
            {
                "document": doc,
                "requests": [{"test_id": "semiring", "assertion_idx": idx} for idx in indices],
            }
            for indices in ([1, 2, 3, 4, 5], [6])
        ]
        result = subprocess.run(
            [BINARY, "static-assertions-jsonl", "M"],
            input="".join(json.dumps(request) + "\n" for request in requests),
            capture_output=True,
            text=True,
            check=True,
        )
        values, refusal = map(json.loads, result.stdout.splitlines())
        signed, zero_value, positive_product, negative_product, nan_term = [
            struct.unpack(">d", int(bits).to_bytes(8, "big"))[0] for bits in values["values"]
        ]
        self.assertEqual(signed, -1)
        self.assertTrue(math.isnan(zero_value))
        self.assertEqual(positive_product, -7)
        self.assertEqual(negative_product, 7)
        self.assertEqual(nan_term, 1)
        self.assertEqual(
            refusal["error"], "unsupported_construct: array-valued bool_and_or reduction"
        )

    def test_expression_reader_rejects_overflow_in_expression_and_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            paths = [Path(d) / name for name in ("finite.json", "literal.json", "metadata.json")]
            paths[0].write_text("1.7976931348623157e308")
            paths[1].write_text("1e309")
            paths[2].write_text('{"op":"const","args":[],"attrs":{"limit":1e309}}')
            result = subprocess.run(
                [BINARY, "expressions", *paths],
                capture_output=True,
                text=True,
                check=True,
            )
        rows = json.loads(result.stdout)
        self.assertTrue(rows["finite.json"]["ok"])
        for name in ("literal.json", "metadata.json"):
            self.assertFalse(rows[name]["ok"])
            self.assertIn("outside the finite binary64 range", rows[name]["error"])

    def test_rounding_and_lazy_scalar_evaluation(self):
        midpoint = "1.00000000000000011102230246251565404236316680908203125"
        above_midpoint = midpoint + "1"
        nan = {"op": "sqrt", "args": [-1]}
        negative_zero = {"op": "-", "args": ["zero"]}
        expressions = {
            "tie": "MIDPOINT",
            "above": "p",
            "subnormal": "SUBNORMAL",
            "fold": {"op": "+", "args": [1e16, -1e16, 1]},
            "lazy": {
                "op": "ifelse",
                "args": [
                    1,
                    42,
                    {"op": "index", "args": [{"op": "const", "args": [], "value": [7]}, 2]},
                ],
            },
            "min_nan": {"op": "min", "args": [3, nan, 4]},
            "max_nan": {"op": "max", "args": [nan, 3, 4]},
            "min_positive_first": {"op": "min", "args": ["zero", negative_zero]},
            "min_negative_first": {"op": "min", "args": [negative_zero, "zero"]},
            "max_positive_first": {"op": "max", "args": ["zero", negative_zero]},
            "max_negative_first": {"op": "max", "args": [negative_zero, "zero"]},
            "zeros_equal": {"op": "==", "args": [negative_zero, "zero"]},
            "zeros_less": {"op": "<", "args": [negative_zero, "zero"]},
        }
        names = list(expressions)
        expected_values = [1, 1.0000000000000002, 5e-324, 1, 42, 0, 0, -0.0, -0.0, 0.0, 0.0, 1, 0]
        doc = {
            "esm": "2.4.0",
            "metadata": {"name": "Static edges"},
            "models": {
                "M": {
                    "variables": {
                        "p": {"type": "parameter", "default": 1},
                        "zero": {"type": "parameter", "default": 0},
                        **{name: {"type": "unknown"} for name in names},
                    },
                    "equations": [{"lhs": name, "rhs": expressions[name]} for name in names],
                    "tests": [
                        {
                            "id": "edges",
                            "parameter_overrides": {"p": "ABOVE_MIDPOINT"},
                            "time_span": {"start": 0, "end": 1},
                            "assertions": [
                                {"variable": name, "time": 0, "expected": expected}
                                for name, expected in zip(names, expected_values)
                            ],
                        }
                    ],
                }
            },
        }
        source = (
            json.dumps(doc)
            .replace('"MIDPOINT"', midpoint)
            .replace('"ABOVE_MIDPOINT"', above_midpoint)
            .replace('"SUBNORMAL"', "5e-324")
        )
        keys = [{"test_id": "edges", "assertion_idx": idx} for idx in range(1, len(names) + 1)]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "static.esm"
            path.write_text(source, encoding="utf-8")
            result = subprocess.run(
                [BINARY, "static-assertions", path, "M"],
                input=json.dumps(keys),
                text=True,
                capture_output=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        bits = list(map(int, json.loads(result.stdout)))
        self.assertEqual(
            bits[:5],
            [0x3FF0000000000000, 0x3FF0000000000001, 1, 0x3FF0000000000000, 0x4045000000000000],
        )
        self.assertEqual(len(bits), len(names))
        for value in bits[5:7]:
            self.assertGreater(value & 0x7FFFFFFFFFFFFFFF, 0x7FF0000000000000)
        self.assertEqual(bits[7:], [1 << 63, 1 << 63, 0, 0, 0x3FF0000000000000, 0])


if __name__ == "__main__":
    unittest.main()
