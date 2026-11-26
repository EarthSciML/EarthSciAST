"""Regression cases for a scalar adapter's JSON Lines deadline."""

import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from scalar import Mismatch, adapter, ask, run


class AdapterDeadline(unittest.TestCase):
    def test_waits_for_a_complete_line(self):
        child = """
import sys
import time
sys.stdin.readline()
sys.stdout.write('{"values":')
sys.stdout.flush()
time.sleep(0.5)
print('["0"]}')
"""
        with adapter([sys.executable, "-c", child]) as process:
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                ask(process, {}, 0.1)

    def test_includes_writing_the_request(self):
        with adapter([sys.executable, "-c", "import time; time.sleep(0.5)"]) as process:
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                ask(process, {"large": "x" * 1_000_000}, 0.1)


class DifferentialFailures(unittest.TestCase):
    args = SimpleNamespace(fixture=None, observer=False, seed=20261026, cases=5, timeout=1)

    def test_transport_failure_does_not_retry_the_stream(self):
        with patch("scalar.compare", side_effect=RuntimeError("adapter timed out")) as compare:
            with self.assertRaisesRegex(RuntimeError, "adapter timed out"):
                run({}, self.args)
        compare.assert_called_once()

    def test_comparison_disagreement_remains_a_hypothesis_failure(self):
        def disagree(document, _participants, _timeout):
            raise Mismatch(document, {"lean": "0", "python": "1"})

        with patch("scalar.compare", side_effect=disagree) as compare:
            with self.assertRaisesRegex(Mismatch, "lean=0, python=1"):
                run({}, self.args)
        self.assertGreater(compare.call_count, 1)


if __name__ == "__main__":
    unittest.main()
