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


def run_case(job) -> dict:
    ess, case, problem, model, mode, extra, timeout = job
    env = dict(os.environ)
    env["ESS_VEC_DEBUG"] = "1"
    cmd = ["cargo", "run", "--release", "--quiet", "--manifest-path",
           str(Path(ess) / "pkg/earthsci-ast-rs/Cargo.toml"),
           "--example", "pde_conformance", "--", mode, str(problem),
           "--model", model, "--solver", "Erk", "--reltol", "1e-10",
           "--abstol", "1e-12"] + list(extra)
    rec = {"case": case, "mode": mode, "problem": str(problem), "model": model}
    try:
        p = subprocess.run(cmd, capture_output=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        rec["status"] = "timeout"
        rec["message"] = f"timeout after {timeout}s"
        rec["entries"] = parse_trace((e.stderr or b"").decode("utf-8", "replace"))
        return rec
    err = p.stderr.decode("utf-8", "replace")
    rec["entries"] = parse_trace(err)
    if p.returncode != 0:
        rec["status"] = "error"
        rec["message"] = "\n".join(
            l for l in err.splitlines() if not l.startswith("[vec-"))[-1500:]
    else:
        rec["status"] = "ok"
    return rec


def discover(esd: Path, category: str):
    root = esd / "tests" / "conformance" / category
    out = []
    if not root.is_dir():
        return out
    for d in sorted(root.iterdir()):
        mf = d / "manifest.json"
        if not mf.is_file():
            continue
        m = json.loads(mf.read_text())
        if "rust" in m.get("scope_excluded", {}) or "rust" in m.get(
                "blocked_upstream_bindings", {}):
            continue
        problem = (d / m["problem"]).resolve()
        if not problem.is_file():
            continue
        if category == "simulation":
            out.append((m["case"], problem, m["model"], "pde-tests", []))
        elif category == "convergence":
            at = str(m.get("assert_time", 0.1))
            out.append((m["case"], problem, m["model"], "convergence",
                        ["--assert-time", at]))
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
    a = ap.parse_args()

    cases = discover(Path(a.esd), a.category)
    if a.limit:
        cases = cases[: a.limit]
    print(f"{len(cases)} {a.category} cases", file=sys.stderr)
    jobs = [(a.ess, c, p, m, mode, extra, a.timeout)
            for (c, p, m, mode, extra) in cases]
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
