#!/usr/bin/env python3
"""Score the Lean spec model (`esm-lean interp`) on tests/closed_functions/interp.

For every `tests/closed_functions/interp/*/expected.json`, runs
`formal/.lake/build/bin/esm-lean interp <file>` and compares each scenario:
success scenarios against `expected` at the fixture's `tolerance`
(`|got - want| <= max(abs, rel * |want|)`, NaN matches only NaN), error
scenarios against `expected_error_code`.

A fixture that disagrees with a RULING (formal/QUESTIONS.md) is listed in
KNOWN: the model follows the ruling, the mismatch is printed as known and does
not fail the run unless --strict is given. Every other mismatch fails it.
Prints one summary line; exit status 1 on any (unknown) mismatch.
"""

import argparse
import json
import math
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TIER = ROOT / "tests" / "closed_functions" / "interp"
EXE = ROOT / "formal" / ".lake" / "build" / "bin" / "esm-lean"

# (fixture dir, scenario) -> why the model's answer differs from the fixture
KNOWN = {
    ("searchsorted", "nan_in_xs"): "Q-7 ruled the code `searchsorted_nan`; fixture still says "
    "`searchsorted_nan_in_table`",
}


def num(v):
    if isinstance(v, str):
        return {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}[v]
    return float(v)


def got_value(r):
    if "bits" in r:
        return struct.unpack("<d", struct.pack("<Q", int(r["bits"])))[0]
    return num(r["value"])


def close(got, want, tol):
    if math.isnan(want) or math.isnan(got):
        return math.isnan(want) and math.isnan(got)
    if got == want:
        return True
    return abs(got - want) <= max(tol.get("abs", 0), tol.get("rel", 0) * abs(want))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="count KNOWN disagreements as failures")
    args = ap.parse_args()
    passed = failed = known = 0
    for exp in sorted(TIER.glob("*/expected.json")):
        fx = json.loads(exp.read_text())
        proc = subprocess.run([str(EXE), "interp", str(exp)], capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"FAIL {exp.parent.name}: esm-lean exited {proc.returncode}: {proc.stderr.strip()}")
            failed += 1
            continue
        results = {r["name"]: r for r in json.loads(proc.stdout)["results"]}
        tol = fx.get("tolerance", {"abs": 0, "rel": 0})
        for s in fx.get("scenarios", []) + fx.get("error_scenarios", []):
            name = s["name"]
            r = results.get(name)
            if r is None:
                ok, msg = False, "no result"
            elif "expected_error_code" in s:
                ok = r.get("error_code") == s["expected_error_code"]
                msg = f"want error {s['expected_error_code']}, got {r.get('error_code', r.get('value'))}"
            elif "error_code" in r:
                ok, msg = False, f"want {s['expected']}, got error {r['error_code']}"
            else:
                got = got_value(r)
                ok = close(got, num(s["expected"]), tol)
                msg = f"want {s['expected']}, got {got!r}"
            if ok:
                passed += 1
                continue
            key = (exp.parent.name, name)
            if key in KNOWN and not args.strict:
                known += 1
                print(f"KNOWN {exp.parent.name}/{name}: {msg} ({KNOWN[key]})")
            else:
                failed += 1
                print(f"FAIL {exp.parent.name}/{name}: {msg}")
    print(f"interp lean: {passed} passed, {failed} failed, {known} known disagreements with fixtures")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
