#!/usr/bin/env python3
"""vec-coverage sweep: run every simulable ESD conformance problem through the
Rust `pde_conformance` example with ESS_VEC_DEBUG=1 and record, per rule /
per observed, whether it vectorized and (if not) the DEEPEST bail-out frame.

Not part of the crate: this drives the published `pde_conformance` example from
outside, so it needs no edits to the (concurrently owned) simulate_array files.

Usage:
  sweep_esd.py --esd <EarthSciDiscretizations> --ess <EarthSciAST worktree>
               --out <results.json> [--category simulation|convergence]
               [--jobs N] [--limit N]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# ---- trace grammar (rhs.rs) ------------------------------------------------
RE_OBS_VEC = re.compile(r"^\[vec-obs\] (.+?): vectorized, (\d+) us, (\d+) node visits")
RE_OBS_CELL = re.compile(r"^\[vec-obs\] (.+?): PER-CELL, (\d+) us")
RE_OBS_FRAME = re.compile(r"^\[vec-obs\]   (.*)$")
RE_BAIL_OBS = re.compile(r"^\[vec-bail\] observed (.+?) -> per-cell oracle:")
RE_BAIL_RULE = re.compile(r"^\[vec-bail\] rule D\((.+?)\) -> per-cell oracle")
RE_BAIL_EARLY = re.compile(r"^\[vec-bail\] rule D\((.+?)\) fell back before the overlay ran")
RE_BAIL_FRAME = re.compile(r"^\[vec-bail\]   (.*)$")


def parse_trace(stderr: str) -> dict:
    """Parse a stderr stream into {kind, name, us, deepest, frames} records.

    Deduplicated by (kind, name): a solve calls the RHS thousands of times and
    emits the same block each call. We keep the FIRST occurrence's frames and
    the MAX observed microseconds (the steady-state cost, not the warm-up).
    """
    recs: dict[tuple[str, str], dict] = {}
    cur: dict | None = None
    for line in stderr.splitlines():
        m = RE_OBS_VEC.match(line)
        if m:
            cur = None
            k = ("obs_scalar", m.group(1))
            r = recs.setdefault(k, {"kind": "obs_scalar", "name": m.group(1),
                                    "status": "vectorized", "us": 0,
                                    "visits": int(m.group(3)),
                                    "deepest": None, "frames": [], "n": 0})
            # A block that reports "vectorized" AFTER any PER-CELL block for the
            # same name means it flipped; keep the worse verdict.
            if r["status"] == "vectorized":
                r["us"] = max(r["us"], int(m.group(2)))
            r["n"] += 1
            continue
        m = RE_OBS_CELL.match(line)
        if m:
            k = ("obs_scalar", m.group(1))
            r = recs.setdefault(k, {"kind": "obs_scalar", "name": m.group(1),
                                    "status": "per-cell", "us": 0, "visits": None,
                                    "deepest": None, "frames": [], "n": 0})
            r["status"] = "per-cell"
            r["us"] = max(r["us"], int(m.group(2)))
            r["n"] += 1
            cur = r
            continue
        m = RE_BAIL_OBS.match(line)
        if m:
            k = ("obs_arrayloop", m.group(1))
            r = recs.setdefault(k, {"kind": "obs_arrayloop", "name": m.group(1),
                                    "status": "per-cell", "us": None, "visits": None,
                                    "deepest": None, "frames": [], "n": 0})
            r["n"] += 1
            cur = r
            continue
        m = RE_BAIL_RULE.match(line) or RE_BAIL_EARLY.match(line)
        if m:
            early = RE_BAIL_EARLY.match(line) is not None
            k = ("rule", m.group(1))
            r = recs.setdefault(k, {"kind": "rule", "name": m.group(1),
                                    "status": "per-cell", "us": None, "visits": None,
                                    "deepest": "PRE-OVERLAY: rule shape rejected before the overlay ran"
                                    if early else None,
                                    "frames": [], "n": 0})
            r["n"] += 1
            cur = None if early else r
            continue
        m = RE_OBS_FRAME.match(line) or RE_BAIL_FRAME.match(line)
        if m and cur is not None:
            if not cur["frames"]:
                cur["deepest"] = m.group(1).strip()
            if len(cur["frames"]) < 30:
                cur["frames"].append(m.group(1).strip())
            continue
    return {f"{v['kind']}:{v['name']}": v for v in recs.values()}


CAP = 16 << 20  # bytes of stderr to parse; trace blocks repeat every RHS call


def run_case(job) -> dict:
    ess, case, problem, model, mode, extra, timeout, errdir, excluded = job
    env = dict(os.environ)
    env["ESS_VEC_DEBUG"] = "1"
    exe = Path(ess) / "pkg/earthsci-ast-rs/Cargo.toml"
    cmd = ["cargo", "run", "--release", "--quiet", "--manifest-path", str(exe),
           "--example", "pde_conformance", "--", mode, str(problem),
           "--model", model, "--solver", "Erk", "--reltol", "1e-10",
           "--abstol", "1e-12"] + list(extra)
    rec = {"case": case, "mode": mode, "problem": str(problem), "model": model,
           "manifest_excluded_rust": excluded}
    # stderr to a FILE (lustre), not a pipe: a non-terminating case emits a
    # trace block per RHS call and would otherwise buffer hundreds of MB of
    # duplicate text in RAM (/ is tmpfs here).
    ep = Path(errdir) / f"{case}.{mode}.err"
    status = "ok"
    with ep.open("wb") as fh:
        try:
            p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=fh,
                               env=env, timeout=timeout)
            if p.returncode != 0:
                status = "error"
        except subprocess.TimeoutExpired:
            status = "timeout"
    with ep.open("rb") as fh:
        err = fh.read(CAP).decode("utf-8", "replace")
    rec["status"] = status
    rec["stderr_bytes"] = ep.stat().st_size
    rec["entries"] = parse_trace(err)
    if status != "ok":
        rec["message"] = "\n".join(
            l for l in err.splitlines() if not l.startswith("[vec-"))[-1200:]
    return rec


def discover(esd: Path, category: str, which: str = "included"):
    """`which`: included | excluded | all.

    A manifest that excludes the Rust binding is still worth TRACING: the
    exclusions in this corpus say "Rust hangs / does not terminate", which is a
    statement about solve time, not about whether the RHS evaluates. The bail
    log is emitted on the very first RHS call, so a short-timeout run of an
    excluded case still yields a complete coverage verdict for it.
    """
    root = esd / "tests" / "conformance" / category
    out = []
    if not root.is_dir():
        return out
    for d in sorted(root.iterdir()):
        mf = d / "manifest.json"
        if not mf.is_file():
            continue
        m = json.loads(mf.read_text())
        excl = m.get("scope_excluded", {}).get("rust") or m.get(
            "blocked_upstream_bindings", {}).get("rust")
        if which == "included" and excl:
            continue
        if which == "excluded" and not excl:
            continue
        problem = (d / m["problem"]).resolve()
        if not problem.is_file():
            continue
        if category == "simulation":
            out.append((m["case"], problem, m["model"], "pde-tests", [], excl))
        elif category == "convergence":
            at = str(m.get("assert_time", 0.1))
            # Trace the COARSEST resolution only: a bail verdict is a property
            # of the discretized expression, not of N, and the finest grids in
            # this corpus cost minutes each.
            res = sorted(m["resolutions"], key=lambda r: r["n"])[:1]
            out.append((m["case"], problem, m["model"], "convergence",
                        ["--assert-time", at,
                         "--norms", ",".join(m.get("norms", ["L2_error"])),
                         "--resolutions", json.dumps(res)], excl))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esd", required=True)
    ap.add_argument("--ess", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--category", default="simulation")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--which", default="included",
                    choices=["included", "excluded", "all"])
    ap.add_argument("--errdir", default=None)
    a = ap.parse_args()

    errdir = Path(a.errdir or (Path(a.out).parent / f"err-{a.category}-{a.which}"))
    errdir.mkdir(parents=True, exist_ok=True)
    cases = discover(Path(a.esd), a.category, a.which)
    if a.limit:
        cases = cases[: a.limit]
    print(f"{len(cases)} {a.category} cases ({a.which})", file=sys.stderr)
    jobs = [(a.ess, c, p, m, mode, extra, a.timeout, str(errdir), excl)
            for (c, p, m, mode, extra, excl) in cases]
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for i, r in enumerate(ex.map(run_case, jobs), 1):
            nf = sum(1 for v in r["entries"].values() if v["status"] == "per-cell")
            nv = sum(1 for v in r["entries"].values() if v["status"] == "vectorized")
            print(f"[{i}/{len(jobs)}] {r['case']}: {r['status']} "
                  f"vec={nv} per-cell={nf}", file=sys.stderr)
            results.append(r)
    Path(a.out).write_text(json.dumps(
        {"category": a.category, "cases": results}, indent=1))


if __name__ == "__main__":
    main()
