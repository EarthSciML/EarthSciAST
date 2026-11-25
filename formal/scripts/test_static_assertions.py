#!/usr/bin/env python3
"""Regression cases for static evaluation and decimal input rounding."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

BINARY = Path(__file__).resolve().parents[1] / ".lake" / "build" / "bin" / "esm-lean"


class StaticAssertions(unittest.TestCase):
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
