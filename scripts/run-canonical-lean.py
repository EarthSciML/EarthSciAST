#!/usr/bin/env python3
"""Score the Lean RFC §5.4 expression canonicalizer on the shared byte fixtures."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "tests" / "conformance" / "canonical"
ADAPTER = ROOT / "formal" / ".lake" / "build" / "bin" / "esm-lean"


def invoke(adapter, *args, source=None):
    return subprocess.run(
        [str(adapter), "canonical-json", *map(str, args)],
        input=source,
        capture_output=True,
        check=False,
    )


def compare_bytes(result, expected):
    if result.returncode:
        return (
            f"adapter exited {result.returncode}: {result.stderr.decode(errors='replace').strip()}"
        )
    if result.stdout != expected:
        return f"expected {expected!r}, got {result.stdout!r}"
    return None


def compare_error(result, code, path=None):
    if result.returncode != 1 or result.stdout:
        return f"expected {code}, got exit {result.returncode} and stdout {result.stdout!r}"
    try:
        error = json.loads(result.stderr)
    except (UnicodeError, json.JSONDecodeError):
        return f"invalid error JSON: {result.stderr!r}"
    if not isinstance(error, dict) or error.get("code") != code:
        return f"expected {code}, got {error!r}"
    if path is not None and error.get("path") != path:
        return f"expected error path {path!r}, got {error!r}"
    return None


def score_fixture(adapter, path):
    fixture = json.loads(path.read_bytes())
    result = invoke(adapter, "--fixture", path)
    if "expect_error" in fixture:
        return compare_error(result, fixture["expect_error"])
    expected = fixture["expected"].encode("utf-8")
    failure = compare_bytes(result, expected)
    if failure:
        return failure
    repeated = invoke(adapter, "-", source=result.stdout)
    failure = compare_bytes(repeated, result.stdout)
    return f"fixed point: {failure}" if failure else None


def score_controls(adapter):
    # Read the exact tokens on stdin. A Python JSON decode/re-encode here would
    # hide bugs where a typed exponent or underflow loses its original kind.
    controls = (
        (b"1", b"1"),
        (b"1e0", b"1.0"),
        (b"-0.0", b"-0.0"),
        (b"-1e-400", b"-0.0"),
        (b"1e-6", b"0.000001"),
        (b"1e21", b"1e21"),
        (b'{"op":"*","args":[-0.0,"x"]}', b"-0.0"),
        (b'{"op":"*","args":[1.0,"x"]}', b'{"args":[1.0,"x"],"op":"*"}'),
        (rb'"a\u0009\u0008\u000cb\\u0009"', rb'"a\t\b\fb\\u0009"'),
        (
            b'{"op":"apply_operator","args":[],"name":"f","bindings":{"x":1}}',
            b'{"args":[],"name":"f","op":"apply_operator"}',
        ),
    )
    for source, expected in controls:
        failure = compare_bytes(invoke(adapter, "-", source=source), expected)
        if failure:
            yield f"control {source!r}: {failure}"

    overflow = invoke(adapter, "-", source=b'{"op":"+","args":[1e400,0]}')
    failure = compare_error(overflow, "E_CANONICAL_NONFINITE", "/args/0")
    if failure:
        yield f"overflow control: {failure}"
    division = invoke(adapter, "-", source=b'{"op":"/","args":[0,0]}')
    failure = compare_error(division, "E_CANONICAL_DIVBY_ZERO", "")
    if failure:
        yield f"division control: {failure}"
    for expression, code in (
        (b'{"op":"/","args":[0,0]}', "E_CANONICAL_DIVBY_ZERO"),
        (b"1e400", "E_CANONICAL_NONFINITE"),
    ):
        source = (
            b'{"op":"apply_operator","args":[],"name":"f","bindings":{"x/y":' + expression + b"}}"
        )
        failure = compare_error(invoke(adapter, "-", source=source), code, "/bindings/x~1y")
        if failure:
            yield f"binding control: {failure}"
    mixed_zero = invoke(adapter, "-", source=b'{"op":"*","args":[0,-0.0]}')
    failure = compare_error(mixed_zero, "E_CANONICAL_UNSUPPORTED_EXPRESSION", "")
    if failure:
        yield f"mixed-zero control: {failure}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, default=ADAPTER)
    args = parser.parse_args()
    adapter = args.adapter.resolve()
    if not adapter.is_file():
        parser.error(f"build esm-lean first (adapter missing: {adapter})")

    fixtures = json.loads((CORPUS / "manifest.json").read_bytes())["fixtures"]
    if not fixtures:
        parser.error("canonical-form manifest has no fixtures")
    failures = []
    for fixture in fixtures:
        failure = score_fixture(adapter, CORPUS / fixture["path"])
        if failure:
            failures.append(f"{fixture['id']}: {failure}")
    failures.extend(score_controls(adapter))
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        return 1
    print(f"Lean canonical expressions: {len(fixtures)} fixtures and typed-number controls passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
