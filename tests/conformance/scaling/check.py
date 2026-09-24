#!/usr/bin/env python3
"""Apply the scaling tier's gates and known-failure ledger to adapter result files.

    check.py RESULT.json [RESULT.json ...] [--gates deterministic|all]
             [--require pr|sweep] [--manifest PATH] [--json OUT]

Prints one row per (file, family, N, gate) with the measured value and one of
    pass      the gate holds
    FAIL      the gate fails and no ledger entry covers it          (red)
    ledgered  the gate fails and a ledger entry covers it
    STALE     a ledger entry covers a DETERMINISTIC gate that now
              passes: remove the entry                              (red)
    fixed?    a ledger entry covers a TIMING gate that now passes:
              reported, not red, because timing noise can flip it
    skip      not measurable (the document did not build, or a field is null)
    MISSING   --require named a (family, N) no result file covers   (red)
Exit status 0 when nothing is red, 1 otherwise. With --report-timing the
timing gates are printed but never red. The gates, thresholds and the
ledger live in manifest.json; README.md says what each gate means.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TIMING = "timing"
DETERMINISTIC = "deterministic"
MAX_CELLS_FOR_SLOPE = 1_000_000


def load(path):
    with open(path) as fh:
        return json.load(fh)


def fmt(v):
    if v is None:
        return "null"
    if isinstance(v, float):
        return f"{v:.4g}"
    if isinstance(v, dict):
        return ", ".join(f"{k}:{fmt(x)}" for k, x in v.items())
    return str(v)


class Check:
    """One gate evaluated at one (result file, family, N)."""

    def __init__(self, run, family, n, gate, kind, passed, measured, note=""):
        self.run = run
        self.family = family
        self.n = n
        self.gate = gate
        self.kind = kind
        self.passed = passed  # True, False, or None (skip)
        self.measured = measured
        self.note = note
        self.entry = None
        self.outcome = None


def per_result_checks(run, r, gates, family_spec):
    fam, n = r["family"], r.get("n", r.get("n_cells"))
    excl = family_spec.get("gate_exclusions", {})
    out = []
    ok = r.get("status") == "ok"
    out.append(
        Check(
            run,
            fam,
            n,
            "builds",
            DETERMINISTIC,
            ok,
            r.get("status") if ok else f"{r.get('status')}: {(r.get('reason') or '')[:160]}",
        )
    )
    if "no_steady_alloc" in gates and "no_steady_alloc" not in excl:
        a = r.get("allocs_per_call")
        lim = gates["no_steady_alloc"]["max_bytes_per_call"]
        out.append(
            Check(
                run,
                fam,
                n,
                "no_steady_alloc",
                DETERMINISTIC,
                None if (not ok or a is None) else a <= lim,
                a,
            )
        )
    if "hand_loop_agrees" in gates and "hand_loop_agrees" not in excl:
        d = r.get("hand_loop_max_abs_diff")
        scale = max(1.0, abs(r.get("dy_max_abs") or 0.0))
        tol = gates["hand_loop_agrees"]["rel_tol"] * scale
        out.append(
            Check(
                run,
                fam,
                n,
                "hand_loop_agrees",
                DETERMINISTIC,
                None if d is None else d <= tol,
                d,
                f"tol {tol:.3g}",
            )
        )
    if "speed" in gates and "speed" not in excl:
        g = gates["speed"]
        s, h = r.get("steady_rhs_s"), r.get("hand_loop_s")
        big = (r.get("n_states") or 0) >= g.get("min_n_states", 0)
        ratio = s / h if (ok and s is not None and h) else None
        out.append(
            Check(
                run,
                fam,
                n,
                "speed",
                TIMING,
                None if (ratio is None or not big) else ratio <= g["max_ratio"],
                ratio,
                "" if big else f"below {g.get('min_n_states')} states",
            )
        )
    return out


def family_checks(run, fam, results, gates, family_spec):
    excl = family_spec.get("gate_exclusions", {})
    built = sorted((r for r in results if r.get("status") == "ok"), key=lambda r: r["n_states"])
    out = []
    if "code_size_flat" in gates and "code_size_flat" not in excl:
        sized = [r for r in built if r.get("code_size") is not None]
        sizes = {r.get("n", r["n_cells"]): r["code_size"] for r in sized}
        if len(sized) < 2:
            out.append(
                Check(
                    run,
                    fam,
                    None,
                    "code_size_flat",
                    DETERMINISTIC,
                    None,
                    sizes,
                    "fewer than two built sizes",
                )
            )
        else:
            spread = max(sizes.values()) - min(sizes.values())
            out.append(
                Check(
                    run,
                    fam,
                    None,
                    "code_size_flat",
                    DETERMINISTIC,
                    spread <= gates["code_size_flat"].get("slack", 0),
                    sizes,
                )
            )
    if "build_slope" in gates and "build_slope" not in excl:
        cand = [
            r for r in built if r["n_cells"] <= MAX_CELLS_FOR_SLOPE and r.get("build_s") is not None
        ]
        if len(cand) < 2 or cand[-1]["n_states"] == cand[0]["n_states"]:
            out.append(
                Check(
                    run, fam, None, "build_slope", TIMING, None, None, "fewer than two built sizes"
                )
            )
        else:
            lo, hi = cand[0], cand[-1]
            ns = (hi["build_s"] - lo["build_s"]) / (hi["n_states"] - lo["n_states"]) * 1e9
            out.append(
                Check(
                    run,
                    fam,
                    None,
                    "build_slope",
                    TIMING,
                    ns < gates["build_slope"]["max_ns_per_state"],
                    ns,
                    f"ns/state over N={lo.get('n')}..{hi.get('n')}",
                )
            )
    return out


def threads_label(run):
    return "serial" if (run.get("threads") or 1) == 1 else "threaded"


def entry_matches(e, c):
    if e.get("family") != c.family or e.get("gate") != c.gate:
        return False
    if e.get("compiler", "native") != c.run.get("compiler"):
        return False
    if "threads" in e and e["threads"] != threads_label(c.run):
        return False
    if e.get("n") is not None and e.get("n") != c.n:
        return False
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("results", nargs="+")
    ap.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument(
        "--gates",
        choices=["deterministic", "all"],
        default="all",
        help="deterministic: builds, code_size_flat, no_steady_alloc, hand_loop_agrees only",
    )
    ap.add_argument(
        "--require",
        choices=["pr", "sweep"],
        help="every (family, N) of this size list must have a result",
    )
    ap.add_argument(
        "--report-timing",
        action="store_true",
        help="evaluate and print the timing gates, but never go red on one "
        "(the scheduled sweep, until plan phase 6 makes them block)",
    )
    ap.add_argument("--json", help="also write the rows as JSON here")
    a = ap.parse_args(argv)

    manifest = load(a.manifest)
    gates = dict(manifest["gates"])
    if a.gates == "deterministic":
        gates = {k: v for k, v in gates.items() if v["kind"] == DETERMINISTIC}
    fams = manifest["families"]

    checks = []
    red = []
    for path in a.results:
        run = load(path)
        run["_path"] = path
        by_family = {}
        for r in run["results"]:
            if r["family"] not in fams:
                red.append(f"{path}: result for unknown family {r['family']!r}")
                continue
            by_family.setdefault(r["family"], []).append(r)
            checks += per_result_checks(run, r, gates, fams[r["family"]])
        for fam, rs in by_family.items():
            checks += family_checks(run, fam, rs, gates, fams[fam])
        if a.require:
            have = {(r["family"], r.get("n")) for r in run["results"]}
            for fam, spec in fams.items():
                for n in spec["pr_sizes" if a.require == "pr" else "sizes"]:
                    if (fam, n) not in have:
                        c = Check(run, fam, n, "present", DETERMINISTIC, False, None)
                        c.outcome = "MISSING"
                        checks.append(c)

    ledgers = manifest.get("ledger", {})
    entry_hits = {}  # (binding, index) -> [checks]
    for c in checks:
        if c.outcome:
            continue
        ledger = ledgers.get(c.run.get("binding"), [])
        for i, e in enumerate(ledger):
            if e.get("gate") in gates and entry_matches(e, c):
                c.entry = (c.run.get("binding"), i)
                entry_hits.setdefault(c.entry, []).append(c)
                break
        if c.passed is None:
            c.outcome = "skip"
        elif c.passed:
            c.outcome = (
                "pass" if c.entry is None else ("STALE" if c.kind == DETERMINISTIC else "fixed?")
            )
        else:
            c.outcome = "FAIL" if c.entry is None else "ledgered"

    # A ledger entry that covers several N (no `n`) is stale only when it no
    # longer covers any failure; per-check STALE marks are withdrawn otherwise.
    for key, hits in entry_hits.items():
        if any(h.outcome == "ledgered" for h in hits):
            for h in hits:
                if h.outcome in ("STALE", "fixed?"):
                    h.outcome = "pass"

    rows = []
    for c in checks:
        rows.append(
            {
                "file": c.run["_path"],
                "binding": c.run.get("binding"),
                "threads": c.run.get("threads"),
                "family": c.family,
                "n": c.n,
                "gate": c.gate,
                "kind": c.kind,
                "measured": c.measured,
                "outcome": c.outcome,
                "note": c.note,
                "ledger": ledgers[c.entry[0]][c.entry[1]] if c.entry else None,
            }
        )
    order = {k: i for i, k in enumerate(fams)}
    rows.sort(key=lambda r: (r["file"], order.get(r["family"], 99), r["n"] or 0, r["gate"]))

    w = [22, 8, 8, 17, 9]
    print(
        f"{'family':<{w[0]}} {'N':>{w[1]}} {'threads':>{w[2]}} {'gate':<{w[3]}} {'outcome':<{w[4]}} measured"
    )
    last = None
    for r in rows:
        if r["file"] != last:
            print(f"-- {r['file']} (binding {r['binding']}, threads {r['threads']})")
            last = r["file"]
        extra = f"  [{r['note']}]" if r["note"] else ""
        if r["ledger"] and r["outcome"] in ("ledgered", "STALE", "fixed?"):
            extra += f"  [ledger: phase {r['ledger'].get('phase')}]"
        n = "all" if r["n"] is None else r["n"]
        print(
            f"{r['family']:<{w[0]}} {n!s:>{w[1]}} {r['threads']!s:>{w[2]}} {r['gate']:<{w[3]}} "
            f"{r['outcome']:<{w[4]}} {fmt(r['measured'])}{extra}"
        )

    for r in rows:
        if a.report_timing and r["kind"] == TIMING:
            continue
        if r["outcome"] == "FAIL":
            red.append(
                f"{r['family']} N={r['n']} {r['gate']}: fails and is not in the ledger ({fmt(r['measured'])})"
            )
        elif r["outcome"] == "STALE":
            red.append(
                f"{r['family']} N={r['n']} {r['gate']}: passes; remove this entry from the "
                f"{r['binding']} ledger"
            )
        elif r["outcome"] == "MISSING":
            red.append(f"{r['family']} N={r['n']}: no result")
    counts = {}
    for r in rows:
        counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
    print("\n" + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    if a.json:
        with open(a.json, "w") as fh:
            json.dump({"rows": rows, "red": red}, fh, indent=1)
    for msg in red:
        print(f"RED: {msg}", file=sys.stderr)
    return 1 if red else 0


if __name__ == "__main__":
    sys.exit(main())
