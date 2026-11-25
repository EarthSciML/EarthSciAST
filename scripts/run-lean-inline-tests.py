#!/usr/bin/env python3
"""Adapt `esm-lean static-assertions` to the inline-test manifest protocol."""

import argparse
import importlib.util
import json
import math
import struct
import subprocess
from pathlib import Path

RUNNER = Path(__file__).with_name("run-inline-tests-conformance.py")
SPEC = importlib.util.spec_from_file_location("inline_tests_conformance", RUNNER)
INLINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INLINE)
BINARY = INLINE.REPO_ROOT / "formal" / ".lake" / "build" / "bin" / "esm-lean"


def run_fixture(manifest_path, fixture):
    scope = INLINE.lean_assertion_exclusions(fixture, "lean", "interpreter")
    authored = [
        a for a in INLINE.authored_assertions(manifest_path, fixture) if a["variable"] not in scope
    ]
    keys = [{"test_id": a["test_id"], "assertion_idx": a["assertion_idx"]} for a in authored]
    proc = subprocess.run(
        [
            BINARY,
            "static-assertions",
            INLINE.fixture_path(manifest_path, fixture),
            fixture["model"],
        ],
        input=json.dumps(keys),
        capture_output=True,
        text=True,
    )
    if proc.returncode:
        message = proc.stderr.strip()
        code, sep, reason = message.partition(": ")
        if sep and code in {"unsupported_construct", "float32_unsupported"}:
            return {"status": "refused", "code": code, "reason": reason}
        return {"error": message or f"esm-lean exited {proc.returncode}"}

    bits = json.loads(proc.stdout)
    if not isinstance(bits, list) or len(bits) != len(keys):
        raise ValueError("esm-lean returned the wrong number of assertions")
    assertions = []
    for key, entry, value in zip(keys, authored, bits):
        actual = struct.unpack(">d", int(value).to_bytes(8, "big"))[0]
        assertions.append(
            {
                **key,
                "variable": entry["variable"],
                "passed": INLINE.within(actual, entry["expected"], entry["rtol"], entry["atol"]),
                "actual": actual if math.isfinite(actual) else str(actual),
            }
        )
    return {"assertions": assertions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", required=True)
    args = parser.parse_args()
    manifest = INLINE.load_manifest(args.manifest)
    payload = {"binding": "lean", "compiler": args.compiler}
    if args.compiler != "interpreter":
        payload.update(status="unavailable", reason="Lean provides the AST interpreter")
    else:
        fixtures = {}
        for fixture in manifest["fixtures"]:
            try:
                result = run_fixture(args.manifest, fixture)
            except (OSError, ValueError, OverflowError) as e:
                result = {"error": str(e)}
            fixtures[fixture["id"]] = result
        payload["fixtures"] = fixtures
    args.output.write_text(json.dumps(payload, allow_nan=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
