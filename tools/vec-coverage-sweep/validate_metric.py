#!/usr/bin/env python3
"""Validate the trace-derived coverage metric against wall-clock timing.

The bail log only fires on FALLBACK. There is no positive trace line for a
vectorized compiled rule or a vectorized `ArrayLoop` observed, so "no
[vec-bail] lines" is ambiguous: it can mean "fully vectorized" OR "the model
never reached a traced call site at all". `RhsStats` has the same blind spot in
the other direction (`observeds: 0/0` while 914 ms of a 921 ms RHS is spent in
uncounted per-cell `AlgebraicRule::Scalar` observeds — the finding recorded in
ef51292c).

The independent check is behavioural: run each case twice, once normally and
once with `ESS_VEC_DISABLE=1` (which forces `try_eval_arrayop_vectorized` to
return `None` everywhere, at EVERY call site including `eval_arrayop`). A case
whose work really is on the vectorized path must get materially slower. A ratio
near 1.0 means the overlay was never load-bearing for that case, and a
"vectorized" verdict inferred from trace silence is vacuous for it.

Usage: validate_metric.py --esd <..> --ess <..> --out ratios.json [--jobs N]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sweep_esd import discover  # noqa: E402


def timed(ess, problem, model, mode, extra, disable, timeout):
    env = dict(os.environ)
    env.pop("ESS_VEC_DEBUG", None)
    if disable:
        env["ESS_VEC_DISABLE"] = "1"
    else:
        env.pop("ESS_VEC_DISABLE", None)
    cmd = ["cargo", "run", "--release", "--quiet", "--manifest-path",
           str(Path(ess) / "pkg/earthsci-ast-rs/Cargo.toml"),
           "--example", "pde_conformance", "--", mode, str(problem),
           "--model", model, "--solver", "Erk", "--reltol", "1e-10",
           "--abstol", "1e-12"] + list(extra)
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, env=env, timeout=timeout)
        return time.monotonic() - t0, ("ok" if p.returncode == 0 else "error")
    except subprocess.TimeoutExpired:
        return float(timeout), "timeout"


def run(job):
    ess, case, problem, model, mode, extra, timeout = job
    on, s_on = timed(ess, problem, model, mode, extra, False, timeout)
    off, s_off = timed(ess, problem, model, mode, extra, True, timeout)
    return {"case": case, "vec_s": round(on, 3), "novec_s": round(off, 3),
            "ratio": round(off / on, 3) if on > 0 else None,
            "status_vec": s_on, "status_novec": s_off}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esd", required=True)
    ap.add_argument("--ess", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--category", default="simulation")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--cases", default="")
    a = ap.parse_args()

    cases = discover(Path(a.esd), a.category, "included")
    if a.cases:
        want = set(a.cases.split(","))
        cases = [c for c in cases if c[0] in want]
    jobs = [(a.ess, c, p, m, mode, extra, a.timeout)
            for (c, p, m, mode, extra, _e) in cases]
    out = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for r in ex.map(run, jobs):
            print(f"{r['case']}: vec={r['vec_s']}s novec={r['novec_s']}s "
                  f"ratio={r['ratio']}x ({r['status_vec']}/{r['status_novec']})",
                  file=sys.stderr)
            out.append(r)
    Path(a.out).write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
