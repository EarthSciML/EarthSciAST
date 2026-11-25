"""Regression cases for a scalar adapter's JSON Lines deadline."""

import sys
import unittest

from scalar import adapter, ask


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


if __name__ == "__main__":
    unittest.main()
