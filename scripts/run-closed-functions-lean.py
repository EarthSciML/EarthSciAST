#!/usr/bin/env python3
"""Score the Lean reference model (`esm-lean`) on the standard-library template tiers.

Runs `esm-lean templates` on every document of the standard-library template tiers
in `TEMPLATE_TIERS` (`interp_templates`, `datetime_templates`,
`relational_templates`, `geometry_templates`, each scored when its manifest
exists), checking each test assertion of the manifest's model against the
evaluated `apply_expression_template` equation (or array entry, matched by
its `coords`) it names. A fixture the adapter cannot run (one that needs a
simulation) is listed in its tier with the reason, and an assertion on an
array equation outside the adapter's slice (a `join`-gated or contracting
`faq`) is reported by the adapter; both count as skipped. The assertions and
their tolerances are read the way the inline-test runner reads them (each bound
resolved assertion -> test -> model, `authored_assertions` in
scripts/run-inline-tests-conformance.py); a zero band is a bit-for-bit match.

It also scores the template form of every relational rewrite that has a golden
file (`tests/conformance/relational_templates/rewrites/manifest.json`): `esm-lean templates
<rewrite> <model> <case.json>` on each caller-data case, checking each derived
set's members (the template's integer keys decoded with the entry's `decode`)
and extent, the `rank` and `rank_lookup` variables and the arg-witness
`assignments`, bit for bit. The right-hand side and inline-test values need a
simulation and count as skipped, as does a quantity the adapter reports outside
its slice.

Prints one summary line; exits 1 on any mismatch or adapter failure.

    python3 scripts/run-closed-functions-lean.py [--no-build] [-v]
"""

import argparse
import importlib.util
import json
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORMAL = ROOT / "formal"
BINARY = FORMAL / ".lake" / "build" / "bin" / "esm-lean"
CONFORMANCE = ROOT / "tests" / "conformance"
REWRITES = CONFORMANCE / "relational_templates" / "rewrites"
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
            "sets; esm-lean does not simulate",
            "bin_skolem_count_ode_template": "asserts an ODE trajectory over invented index "
            "sets; esm-lean does not simulate",
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
    or contracting `faq`) is counted as skipped.
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


def _rewrite_case(entry, gold, case):
    """One caller-data case of a relational rewrite against its golden values.
    Returns (passed, failed, skipped, messages)."""
    path = ROOT / entry["out"] if "out" in entry else REWRITES / f"{entry['id']}.esm"
    rel = path.relative_to(ROOT)
    model = entry["models"][0]
    cmp = entry["compare"]
    checks = []  # (label, kind, want)
    for faq, want in (gold.get("sets") or {}).items():
        checks.append((f"set {faq}", "set", (faq, want)))
    for key in ("rank", "rank_lookup"):
        if key in gold:
            checks.append(
                (
                    f"{key} {gold[key]['variable']}",
                    "field",
                    (gold[key]["variable"], gold[key]["values"]),
                )
            )
    for var, want in (gold.get("assignments") or {}).items():
        checks.append((f"assignments {var}", "field", (var, want)))
    skipped = 1 if "rhs" in gold else 0
    if not checks:
        return 0, 0, skipped, []
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(case, fh)
        case_path = fh.name
    try:
        proc = subprocess.run(
            [str(BINARY), "templates", str(path), model, case_path], capture_output=True, text=True
        )
    finally:
        Path(case_path).unlink()
    if proc.returncode != 0:
        return (
            0,
            len(checks),
            skipped,
            [f"FAIL {rel}: esm-lean exited {proc.returncode}: {proc.stderr.strip()}"],
        )
    results = json.loads(proc.stdout)["results"]
    decode = {s["faq"]: s["decode"] for s in cmp.get("sets", [])}
    passed = failed = 0
    msgs = []
    for label, kind, want in checks:
        if kind == "set":
            faq, w = want
            rs = [r for r in results if r.get("set") == faq]
            if not rs or "skipped" in rs[0]:
                skipped += 1
                continue
            r = rs[0]
            if "members" not in r:
                ok, got = False, r.get("error", "no result")
            else:
                d = decode[faq]
                keys = [exact_value({"bits": m["bits"]}) for m in r["members"]]
                got = [
                    [int(k // d["n_b"]) + d["lo"][0], int(k % d["n_b"]) + d["lo"][1]] for k in keys
                ]
                ok = (
                    all(k == math.floor(k) for k in keys)
                    and got == w["members"]
                    and r["extent"] == w["extent"]
                )
        else:
            var, w = want
            rs = [r for r in results if r.get("name") == var]
            if any("skipped" in r for r in rs):
                skipped += 1
                continue
            got = [r.get("bits") for r in rs]
            ok = got == [bits(x) for x in w]
            got = [r.get("value", r.get("error")) for r in rs]
        if ok:
            passed += 1
        else:
            failed += 1
            msgs.append(f"FAIL {rel} {label}: expected {want!r}, got {got!r}")
    return passed, failed, skipped, msgs


def check_rewrites():
    """The relational rewrites with golden files. Returns
    (passed, failed, skipped, fixtures, messages)."""
    manifest = json.loads((REWRITES / "manifest.json").read_text(encoding="utf-8"))
    tp = tf = ts = nf = 0
    msgs = []
    for entry in manifest["rewrites"]:
        if not entry.get("golden"):
            continue
        nf += 1
        gold = json.loads((REWRITES / entry["golden"]).read_text(encoding="utf-8"))
        ts += len(gold.get("inline_tests") or [])
        for case, gc in zip(entry["cases"], gold["cases"]):
            p, f, s, m = _rewrite_case(entry, gc, case)
            tp, tf, ts = tp + p, tf + f, ts + s
            msgs += m
    return tp, tf, ts, nf, msgs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
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
    tp = tf = ts = nf = 0
    for manifest_path, skips in TEMPLATE_TIERS:
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
    if (REWRITES / "manifest.json").exists():
        passed, failed, skipped, n, msgs = check_rewrites()
        tp, tf, ts, nf = tp + passed, tf + failed, ts + skipped, nf + n
        for m in msgs:
            print(m)
    print(f"closed-functions (lean): {tp} passed, {tf} failed, {ts} skipped in {nf} fixtures")
    sys.exit(1 if tf else 0)


if __name__ == "__main__":
    main()
