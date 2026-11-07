#!/usr/bin/env python3
"""The library-template generator's own test: the inputs it must refuse.

python3 formal/scripts/test_gen_lib_templates.py
"""

import decimal
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("gen_lib_templates", HERE / "gen-lib-templates.py")
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)

D = decimal.Decimal


class Literals(unittest.TestCase):
    def test_numbers(self):
        self.assertEqual(gen.lit(D("-1.5"), "x"), "(Ast.num (-15) 1)")
        self.assertEqual(gen.lit(3, "x"), "(Ast.num (3) 0)")
        self.assertEqual(gen.lit(D("0.0"), "x"), "(Ast.num (0) 1)")
        self.assertEqual(gen.lit(D("2E+2"), "x"), "(Ast.num (200) 0)")

    def test_negative_zero_is_refused(self):
        # Ast.num has an integer mantissa: a -0.0 would be written as +0.0.
        for v in (D("-0.0"), D("-0"), D("-0E+3"), D("-0.000")):
            with self.assertRaisesRegex(gen.Unsupported, "negative zero"):
                gen.lit(v, "x")

    def test_negative_zero_in_a_const_names_its_path(self):
        node = {"op": "const", "value": [D("1.0"), [D("2.0"), D("-0.0")]]}
        with self.assertRaisesRegex(gen.Unsupported, r"^t\.value\[1\]\[1\]: .*negative zero"):
            gen.ast(node, 0, "t")


class MissingFields(unittest.TestCase):
    def test_faq_without_expr(self):
        node = {"op": "+", "args": [1, {"op": "faq", "ranges": {"i": [1, 2]}}]}
        with self.assertRaisesRegex(gen.Unsupported, r"^t\.args\[1\]: faq has no expr"):
            gen.ast(node, 0, "t")

    def test_const_without_value(self):
        with self.assertRaisesRegex(gen.Unsupported, "const node has no value"):
            gen.ast({"op": "const"}, 0, "t")

    def _run(self, templates):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "lib.esm"
            src.write_text(json.dumps({"expression_templates": templates}))
            old_targets, old_argv = gen.TARGETS, sys.argv
            gen.TARGETS = [(str(src), str(Path(d) / "Out.lean"), "T")]
            sys.argv = ["gen-lib-templates.py", "--check"]
            err = io.StringIO()
            try:
                with redirect_stderr(err), self.assertRaises(SystemExit) as cm:
                    gen.main()
            finally:
                gen.TARGETS, sys.argv = old_targets, old_argv
            return cm.exception.code, err.getvalue()

    def test_template_without_params_or_body_reports_and_exits_1(self):
        for t, field in (({"body": "x"}, "params"), ({"params": ["x"]}, "body")):
            code, err = self._run({"f": t})
            self.assertEqual(code, 1)
            self.assertIn(f"expression_templates.f: no {field}", err)

    def test_faq_without_expr_in_a_template_reports_and_exits_1(self):
        code, err = self._run(
            {"f": {"params": ["n"], "body": {"op": "faq", "ranges": {"i": [1, "n"]}}}}
        )
        self.assertEqual(code, 1)
        self.assertIn("expression_templates.f.body: faq has no expr", err)

    def test_negative_zero_in_a_template_reports_and_exits_1(self):
        code, err = self._run({"f": {"params": ["x"], "body": {"op": "+", "args": ["x", -0.0]}}})
        self.assertEqual(code, 1)
        self.assertIn("expression_templates.f.body.args[1]", err)


if __name__ == "__main__":
    unittest.main()
