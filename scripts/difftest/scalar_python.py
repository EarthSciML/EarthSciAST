"""JSON Lines adapter for the official Python inline test runner."""

import json
import struct
import sys

import numpy as np
from earthsci_ast import EarthSciAstError, load_document
from earthsci_ast.inline_tests import run_inline_tests


def run(case: dict) -> dict:
    document = load_document(case["document"])
    with np.errstate(invalid="ignore", divide="ignore", over="ignore", under="ignore"):
        results = run_inline_tests(document, model_name="Probe", compiler="interpreter")
    by_id = {(r.test_id, r.assertion_idx): r for r in results}
    values = []
    for request in case["requests"]:
        result = by_id[(request["test_id"], request["assertion_idx"])]
        if result.actual is None:
            return {"error": result.message}
        # "expected" in the generated document is a placeholder. The
        # comparison is made by the differential driver using this raw value.
        values.append(str(int.from_bytes(struct.pack(">d", result.actual), "big")))
    return {"values": values}


def main() -> None:
    for line in sys.stdin:
        try:
            result = run(json.loads(line))
        except (EarthSciAstError, KeyError, ValueError) as exc:
            result = {"error": str(exc)}
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
