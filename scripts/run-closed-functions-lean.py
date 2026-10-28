#!/usr/bin/env python3
"""Score the Lean reference model (`esm-lean`) on the closed-function fixtures.

Runs `esm-lean <mode> <expected.json>` on every `tests/closed_functions/*/*/
expected.json` (or the fixtures given on the command line) and checks each
scenario against the fixture: a numeric `expected` within the fixture's
`tolerance` (`abs` OR `rel`; integers exact when both are 0), an
`expected_error_code` exactly. Scenarios come from `scenarios` and
`error_scenarios`.

The mode is chosen from the fixture's `function` prefix (`datetime.year` ->
`datetime`). A fixture whose prefix has no mode in `MODES` is skipped and
counted, not failed.

With no fixtures named, it also runs `esm-lean tables` on the §9.5.5 table-check
ledger `tests/conformance/function_tables/load_errors/cases.json` (tables built
in memory, NaN / Inf / -Inf included, ruling Q-109) and checks each case's code
(`expected_error_code`, null for a table that passes) exactly.

Prints one summary line; exits 1 on any mismatch or adapter failure.

    python3 scripts/run-closed-functions-lean.py [--no-build] [-v] [fixture.json ...]
"""

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORMAL = ROOT / "formal"
FIXTURES = ROOT / "tests" / "closed_functions"
BINARY = FORMAL / ".lake" / "build" / "bin" / "esm-lean"
TABLE_LEDGER = ROOT / "tests" / "conformance" / "function_tables" / "load_errors" / "cases.json"

# function-name prefix -> esm-lean mode
MODES = {
    "datetime": "datetime",
    "interp": "interp",
}


def close(actual, expected, tol):
    if isinstance(expected, str) or isinstance(actual, str):
        return actual == expected
    a, e = float(actual), float(expected)
    if math.isnan(e):
        return math.isnan(a)
    diff = abs(a - e)
    return diff <= tol.get("abs", 0) or diff <= tol.get("rel", 0) * abs(e)


def check_fixture(path, verbose):
    """Returns (passed, failed, skipped, messages)."""
    fixture = json.loads(path.read_text(encoding="utf-8"))
    fn = fixture.get("function", "")
    mode = MODES.get(fn.split(".")[0])
    scenarios = fixture.get("scenarios", []) + fixture.get("error_scenarios", [])
    rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    if mode is None:
        return 0, 0, len(scenarios), [f"skip {rel}: no esm-lean mode for {fn!r}"]
    proc = subprocess.run([str(BINARY), mode, str(path)], capture_output=True, text=True)
    msgs = [f"{rel}: {line}" for line in proc.stderr.splitlines()] if verbose else []
    if proc.returncode != 0:
        return (
            0,
            len(scenarios),
            0,
            [f"FAIL {rel}: esm-lean exited {proc.returncode}: {proc.stderr.strip()}"],
        )
    results = {r["name"]: r for r in json.loads(proc.stdout)["results"]}
    tol = fixture.get("tolerance", {})
    passed = failed = 0
    for s in scenarios:
        name = s["name"]
        r = results.get(name)
        if r is None:
            ok, got = False, "no result"
        elif "expected_error_code" in s:
            got = r.get("error", r.get("value"))
            ok = r.get("error") == s["expected_error_code"]
        elif "value" in r:
            got = r["value"]
            ok = close(got, s["expected"], tol)
        else:
            got = f"error {r.get('error')}"
            ok = False
        if ok:
            passed += 1
        else:
            failed += 1
            want = s.get("expected_error_code", s.get("expected"))
            msgs.append(
                f"FAIL {rel} {name}: inputs {s.get('inputs')} expected {want!r}, got {got!r}"
            )
    return passed, failed, 0, msgs


def check_table_ledger(path):
    """`esm-lean tables` on a load_errors ledger. Returns (passed, failed, messages)."""
    ledger = json.loads(path.read_text(encoding="utf-8"))
    cases = ledger.get("cases", [])
    rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    proc = subprocess.run([str(BINARY), "tables", str(path)], capture_output=True, text=True)
    if proc.returncode != 0:
        return (
            0,
            len(cases),
            [f"FAIL {rel}: esm-lean exited {proc.returncode}: {proc.stderr.strip()}"],
        )
    results = {r["name"]: r for r in json.loads(proc.stdout)["results"]}
    passed = failed = 0
    msgs = []
    for c in cases:
        r = results.get(c["name"])
        got = r.get("error") if r is not None else "no result"
        if r is not None and got == c.get("expected_error_code"):
            passed += 1
        else:
            failed += 1
            msgs.append(
                f"FAIL {rel} {c['name']}: expected {c.get('expected_error_code')!r}, got {got!r}"
            )
    return passed, failed, msgs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("fixtures", nargs="*", type=Path)
    ap.add_argument(
        "--no-build", action="store_true", help="do not run `lake build esm-lean` first"
    )
    ap.add_argument(
        "-v", "--verbose", action="store_true", help="also show the adapter's diagnostics"
    )
    args = ap.parse_args()
    if not args.no_build:
        b = subprocess.run(
            ["lake", "build", "esm-lean"], cwd=FORMAL, capture_output=True, text=True
        )
        if b.returncode != 0:
            print(b.stdout + b.stderr)
            print("closed-functions (lean): build failed")
            sys.exit(1)
    paths = [p.resolve() for p in args.fixtures] or sorted(FIXTURES.glob("*/*/expected.json"))
    tp = tf = ts = 0
    for p in paths:
        passed, failed, skipped, msgs = check_fixture(p, args.verbose)
        tp, tf, ts = tp + passed, tf + failed, ts + skipped
        for m in msgs:
            if m.startswith("FAIL") or args.verbose:
                print(m)
    nf = len(paths)
    if not args.fixtures and TABLE_LEDGER.exists():
        passed, failed, msgs = check_table_ledger(TABLE_LEDGER)
        tp, tf, nf = tp + passed, tf + failed, nf + 1
        for m in msgs:
            print(m)
    print(f"closed-functions (lean): {tp} passed, {tf} failed, {ts} skipped in {nf} fixtures")
    sys.exit(1 if tf else 0)


if __name__ == "__main__":
    main()
