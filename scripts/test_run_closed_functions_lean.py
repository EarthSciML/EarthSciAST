#!/usr/bin/env python3
"""The Lean scorer's own test: the template tier's model selection and
tolerance resolution, against a stub `esm-lean` that prints canned results.

    python3 scripts/test_run_closed_functions_lean.py
"""

import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("run_cf_lean", HERE / "run-closed-functions-lean.py")
lean = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lean)

STUB = """#!/usr/bin/env python3
import json, pathlib, sys
here = pathlib.Path(__file__).parent
(here / "argv.json").write_text(json.dumps(sys.argv[1:]))
print((here / "results.json").read_text())
"""


def result(name, value):
    return {"name": name, "value": value, "bits": lean.bits(value)}


def model(tests, tolerance=None):
    m = {"variables": {}, "equations": [], "tests": tests}
    if tolerance is not None:
        m["tolerance"] = tolerance
    return m


class TemplateDocs(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        stub = self.dir / "esm-lean"
        stub.write_text(STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        self.old_binary, lean.BINARY = lean.BINARY, stub
        self.manifest = self.dir / "manifest.json"

    def tearDown(self):
        lean.BINARY = self.old_binary
        for p in self.dir.iterdir():
            p.unlink()
        os.rmdir(self.dir)

    def run_doc(self, models, results, fx_model="__name__"):
        (self.dir / "doc.esm").write_text(json.dumps({"models": models}))
        (self.dir / "results.json").write_text(json.dumps({"results": results}))
        fx = {"id": "f", "path": "doc.esm"}
        if fx_model is not None:
            fx["model"] = next(iter(models)) if fx_model == "__name__" else fx_model
        passed, failed, _, msgs = lean.check_template_doc(self.manifest, fx)
        return passed, failed, msgs

    def test_array_entries_match_by_coords_and_skips_count(self):
        tests = [
            {
                "id": "t",
                "assertions": [
                    {"variable": "A", "expected": 0.5, "coords": {"s": 1, "u": 2}},
                    {"variable": "A", "expected": 1.0, "coords": {"s": 2, "u": 1}},
                    {"variable": "G", "expected": 7.0, "coords": {"s": 1, "u": 1}},
                ],
            }
        ]
        (self.dir / "doc.esm").write_text(
            json.dumps({"models": {"m": model(tests, {"rel": 0, "abs": 0})}})
        )
        res = [
            {**result("A", 0.5), "coords": {"s": 1, "u": 2}},
            {**result("A", 9.0), "coords": {"s": 2, "u": 1}},
            {"name": "G", "skipped": "faq with join"},
        ]
        (self.dir / "results.json").write_text(json.dumps({"results": res}))
        passed, failed, skipped, msgs = lean.check_template_doc(
            self.manifest, {"id": "f", "path": "doc.esm", "model": "m"}
        )
        self.assertEqual((passed, failed, skipped), (1, 1, 1), msgs)
        self.assertIn("A{'s': 2, 'u': 1}", msgs[0])

    def argv(self):
        return json.loads((self.dir / "argv.json").read_text())

    def test_tolerance_resolves_assertion_then_test_then_model(self):
        tests = [
            {
                "id": "t1",
                "assertions": [
                    # the assertion's own band admits 1e-6 off
                    {"variable": "a", "expected": 1.0, "tolerance": {"abs": 1e-3}},
                    # nothing at assertion level: model rel 0 / abs 0 is exact
                    {"variable": "b", "expected": 2.0},
                ],
            },
            # the test's band admits 1e-6 off
            {
                "id": "t2",
                "tolerance": {"rel": 1e-3},
                "assertions": [
                    {"variable": "c", "expected": 3.0},
                ],
            },
        ]
        res = [result("a", 1.000001), result("b", 2.0), result("c", 3.000003)]
        passed, failed, msgs = self.run_doc({"m": model(tests, {"rel": 0, "abs": 0})}, res)
        self.assertEqual((passed, failed), (3, 0), msgs)

    def test_tolerance_resolves_per_field(self):
        # the assertion pins only abs = 0; rel is inherited from the model
        tests = [
            {"id": "t", "assertions": [{"variable": "a", "expected": 1.0, "tolerance": {"abs": 0}}]}
        ]
        passed, failed, msgs = self.run_doc(
            {"m": model(tests, {"rel": 1e-3})}, [result("a", 1.0001)]
        )
        self.assertEqual((passed, failed), (1, 0), msgs)

    def test_exact_band_compares_bits(self):
        tests = [{"id": "t", "assertions": [{"variable": "a", "expected": 0.0}]}]
        passed, failed, msgs = self.run_doc(
            {"m": model(tests, {"rel": 0, "abs": 0})}, [result("a", -0.0)]
        )
        self.assertEqual((passed, failed), (0, 1))
        self.assertIn("t#1 a", msgs[0])

    def test_named_model_of_several_is_scored_and_passed_to_the_adapter(self):
        tests = [{"id": "t", "assertions": [{"variable": "x", "expected": 5.0}]}]
        models = {
            "other": model(
                [{"id": "u", "assertions": [{"variable": "x", "expected": 9.0}]}],
                {"rel": 0, "abs": 0},
            ),
            "mine": model(tests, {"rel": 0, "abs": 0}),
        }
        passed, failed, msgs = self.run_doc(models, [result("x", 5.0)], fx_model="mine")
        self.assertEqual((passed, failed), (1, 0), msgs)
        self.assertEqual(self.argv(), ["templates", str((self.dir / "doc.esm").resolve()), "mine"])

    def test_sole_model_is_used_when_the_fixture_names_none(self):
        tests = [{"id": "t", "assertions": [{"variable": "x", "expected": 5.0}]}]
        passed, failed, msgs = self.run_doc(
            {"only": model(tests, {"rel": 0, "abs": 0})}, [result("x", 5.0)], fx_model=None
        )
        self.assertEqual((passed, failed), (1, 0), msgs)
        self.assertEqual(self.argv()[-1], "only")

    def test_several_models_and_no_name_is_a_fixture_failure(self):
        tests = [{"id": "t", "assertions": [{"variable": "x", "expected": 5.0}]}]
        passed, failed, msgs = self.run_doc(
            {"a": model(tests), "b": model(tests)}, [], fx_model=None
        )
        self.assertEqual((passed, failed), (0, 1))
        self.assertIn("names no `model` and the document has 2 models", msgs[0])

    def test_unknown_model_is_a_fixture_failure(self):
        tests = [{"id": "t", "assertions": [{"variable": "x", "expected": 5.0}]}]
        passed, failed, msgs = self.run_doc({"a": model(tests)}, [], fx_model="zzz")
        self.assertEqual((passed, failed), (0, 1))
        self.assertIn("has no model 'zzz'", msgs[0])


if __name__ == "__main__":
    unittest.main()
