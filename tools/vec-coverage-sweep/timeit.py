#!/usr/bin/env python3
"""Serial, cargo-free A/B timing of ESD cases with and without the overlay.

`cargo run` takes the target-dir lock even when everything is up to date, so
concurrent invocations serialize and the wall clock stops measuring the model —
the first parallel attempt produced a suspicious cluster of ~31 s readings that
were pure lock contention. This invokes the built example binary directly and
runs one case at a time, reporting the MINIMUM of N reps.

Usage: timeit.py --esd <..> --bin <pde_conformance> [--reps 3] [case ...]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sweep_esd import discover  # noqa: E402


def best(cmd, env, reps, timeout):
    m, status = float("inf"), "ok"
    for _ in range(reps):
        t0 = time.monotonic()
        try:
            p = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, env=env,
                               timeout=timeout)
            if p.returncode != 0:
                status = "error"
        except subprocess.TimeoutExpired:
            return float(timeout), "timeout"
        m = min(m, time.monotonic() - t0)
    return m, status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esd", required=True)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--which", default="all")
    ap.add_argument("--out", default=None)
    ap.add_argument("cases", nargs="*")
    a = ap.parse_args()

    found = {c[0]: c for c in discover(Path(a.esd), "simulation", a.which)}
    names = a.cases or sorted(found)
    base = dict(os.environ)
    base.pop("ESS_VEC_DEBUG", None)
    base.pop("ESS_VEC_DISABLE", None)
    off = dict(base, ESS_VEC_DISABLE="1")
    rows = []
    for n in names:
        if n not in found:
            print(f"{n}: NOT FOUND", file=sys.stderr)
            continue
        _c, prob, model, mode, extra, _e = found[n]
        cmd = [a.bin, mode, str(prob), "--model", model, "--solver", "Erk",
               "--reltol", "1e-10", "--abstol", "1e-12"] + list(extra)
        v, sv = best(cmd, base, a.reps, a.timeout)
        o, so = best(cmd, off, a.reps, a.timeout)
        rows.append({"case": n, "vec_s": round(v, 3), "novec_s": round(o, 3),
                     "speedup": round(o / v, 3) if v else None,
                     "status_vec": sv, "status_novec": so})
        print(f"{n:46s} vec={v:8.3f}s novec={o:8.3f}s "
              f"speedup={o / v:6.2f}x ({sv}/{so})", flush=True)
    if a.out:
        Path(a.out).write_text(json.dumps(rows, indent=1))


if __name__ == "__main__":
    main()
