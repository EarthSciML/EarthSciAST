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
(`expected_error_code`, null for a table that passes) exactly; and
`esm-lean templates` on every document of the standard-library template tiers
in `TEMPLATE_TIERS` (`interp_templates`, `datetime_templates`,
`relational_templates`, `geometry_templates`, each scored when its manifest
exists), checking each test assertion of the manifest's model against the
evaluated `apply_expression_template` equation (or array entry, matched by
its `coords`) it names. A fixture the adapter cannot run (one that needs a
simulation) is listed in its tier with the reason, and an assertion on an
array equation outside the adapter's slice (a `join`-gated or contracting
`faq`, a geometry leaf) is reported by the adapter; both count as skipped. The assertions and their
tolerances are read the way the inline-test runner reads them (each bound
resolved assertion -> test -> model, `authored_assertions` in
scripts/run-inline-tests-conformance.py); a zero band is a bit-for-bit match.

Prints one summary line; exits 1 on any mismatch or adapter failure.

    python3 scripts/run-closed-functions-lean.py [--no-build] [-v] [fixture.json ...]
"""

import argparse
import importlib.util
import json
import math
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORMAL = ROOT / "formal"
FIXTURES = ROOT / "tests" / "closed_functions"
BINARY = FORMAL / ".lake" / "build" / "bin" / "esm-lean"
TABLE_LEDGER = ROOT / "tests" / "conformance" / "function_tables" / "load_errors" / "cases.json"
CONFORMANCE = ROOT / "tests" / "conformance"
# Standard-library template tiers: manifest -> {fixture id: why the adapter skips it}.
TEMPLATE_TIERS = [
    (CONFORMANCE / "interp_templates" / "manifest.json", {}),
    (CONFORMANCE / "datetime_templates" / "manifest.json", {}),
    (
        CONFORMANCE / "relational_templates" / "manifest.json",
        {
            "nearest_generator_template_ode": "asserts an ODE trajectory; esm-lean evaluates "
            "expressions and does not simulate",
            "edge_enumeration_ode_template": "asserts an ODE trajectory over invented index "
            "sets; esm-lean does not simulate or run value invention",
            "bin_skolem_count_ode_template": "asserts an ODE trajectory over invented index "
            "sets; esm-lean does not simulate or run value invention",
        },
    ),
    (CONFORMANCE / "geometry_templates" / "manifest.json", {}),
]


def _load_inline_runner():
    """scripts/run-inline-tests-conformance.py, whose hyphenated name cannot be
    imported with a plain `import`."""
    spec = importlib.util.spec_from_file_location(
        "run_inline_tests_conformance", ROOT / "scripts" / "run-inline-tests-conformance.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


INLINE = _load_inline_runner()

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


def bits(x):
    return str(struct.unpack("<Q", struct.pack("<d", float(x)))[0])


def exact_value(r):
    """The adapter's value, read from its `bits` (the printed `value` may be
    rounded to a few digits)."""
    if "bits" in r:
        return struct.unpack("<d", struct.pack("<Q", int(r["bits"])))[0]
    return float(r["value"])


def _assertion_coords(path, model_name):
    """`{(test_id, assertion_idx): coords}` for the assertions of the model that
    pin an array entry (`coords`, esm-spec §6.6.5)."""
    model = (json.loads(path.read_text(encoding="utf-8")).get("models") or {}).get(model_name) or {}
    out = {}
    for test in model.get("tests") or []:
        for i, a in enumerate(test.get("assertions") or [], start=1):
            if a.get("coords"):
                out[(str(test.get("id")), i)] = tuple(sorted(a["coords"].items()))
    return out


def check_template_doc(manifest_path, fx):
    """`esm-lean templates` on the manifest fixture `fx`'s document, scored
    against the assertions of the model it names. An assertion on an array
    equation the adapter reports `skipped` (outside its slice: a `join`-gated
    or contracting `faq`, a geometry leaf) is counted as skipped.
    Returns (passed, failed, skipped, messages)."""
    path = INLINE.fixture_path(manifest_path, fx)
    rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    if "model" not in fx:
        try:
            models = list(json.loads(path.read_text(encoding="utf-8")).get("models") or {})
        except (OSError, json.JSONDecodeError) as e:
            return 0, 1, 0, [f"FAIL {rel}: cannot read: {e}"]
        if len(models) != 1:
            return (
                0,
                1,
                0,
                [
                    f"FAIL {rel}: fixture {fx.get('id')!r} names no `model` and the document "
                    f"has {len(models)} models"
                ],
            )
        fx = {**fx, "model": models[0]}
    try:
        asserts = INLINE.authored_assertions(manifest_path, fx)
    except INLINE.ManifestError as e:
        return 0, 1, 0, [f"FAIL {rel}: {e}"]
    coords = _assertion_coords(path, fx["model"])
    proc = subprocess.run(
        [str(BINARY), "templates", str(path), fx["model"]], capture_output=True, text=True
    )
    if proc.returncode != 0:
        return (
            0,
            len(asserts),
            0,
            [f"FAIL {rel}: esm-lean exited {proc.returncode}: {proc.stderr.strip()}"],
        )
    results = {}
    skipped_names = set()
    for r in json.loads(proc.stdout)["results"]:
        if "skipped" in r:
            skipped_names.add(r["name"])
        key = (r["name"], tuple(sorted((r.get("coords") or {}).items())))
        results[key] = r
    passed = failed = skipped = 0
    msgs = []
    for a in asserts:
        where = coords.get((a["test_id"], a["assertion_idx"]), ())
        if a["variable"] in skipped_names:
            skipped += 1
            continue
        r = results.get((a["variable"], where))
        if r is None or "value" not in r:
            ok, got = False, (r or {}).get("error", "no result")
        elif a["rtol"] == 0 and a["atol"] == 0:
            ok, got = r["bits"] == bits(a["expected"]), r["value"]
        else:
            got = exact_value(r)
            ok = INLINE.within(got, a["expected"], a["rtol"], a["atol"])
        if ok:
            passed += 1
        else:
            failed += 1
            at = f"{dict(where)}" if where else ""
            msgs.append(
                f"FAIL {rel} {a['test_id']}#{a['assertion_idx']} {a['variable']}{at}: "
                f"expected {a['expected']!r}, got {got!r}"
            )
    return passed, failed, skipped, msgs


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
    for manifest_path, skips in TEMPLATE_TIERS if not args.fixtures else []:
        if not manifest_path.exists():
            continue
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for fx in manifest.get("fixtures", []):
            nf += 1
            if fx.get("id") in skips:
                ts += 1
                if args.verbose:
                    print(f"skip {manifest_path.parent.name}/{fx['id']}: {skips[fx['id']]}")
                continue
            passed, failed, skipped, msgs = check_template_doc(manifest_path, fx)
            tp, tf, ts = tp + passed, tf + failed, ts + skipped
            for m in msgs:
                print(m)
    print(f"closed-functions (lean): {tp} passed, {tf} failed, {ts} skipped in {nf} fixtures")
    sys.exit(1 if tf else 0)


if __name__ == "__main__":
    main()
