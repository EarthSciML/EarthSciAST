#!/usr/bin/env python3
"""Interleaved whole-solve A/B of the interpolation-bracket spellings (issue #588).

Runs `esm simulate --compiler native` on the documents `generate.py` writes,
alternating the spellings within every repeat (and rotating which goes first),
and reports the median CPU and wall seconds of each, plus whether every
spelling's trajectory is bit-identical to the `interp.linear` one's.

Spellings per N:

    fn_const                 interp.linear on const tables (the fast form)
    compose_const_fused      the composition, bracket counted (the default)
    compose_const_unfused    the same, --no-count-fold (the general fold)
    compose_runtime_fused    the composition over a parameter-built axis
    compose_runtime_unfused  the same, unfused

Usage (Rust; build `esm` with RUSTFLAGS="-C llvm-args=-align-loops=64" for
timings):

    python3 bench/interp_bracket/ab.py --esm target/release/esm --n 59 --n 200 \\
        --repeats 3 --time 200 --work "$BUILD/interp_ab"

`--base-esm` adds the unfused spellings run by a second binary (a build
without the recognition), labelled `*_base`. `--taskset 0,1` pins every run.
"""

import argparse
import json
import os
import resource
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import generate  # noqa: E402


def run(cmd, env, taskset):
    if taskset:
        cmd = ["taskset", "-c", taskset] + cmd
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter()
    p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    wall = time.perf_counter() - t0
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    if p.returncode != 0:
        sys.exit(f"failed ({p.returncode}): {' '.join(cmd)}\n{p.stdout[-4000:]}")
    return cpu, wall


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--esm", required=True, help="the esm binary under test")
    ap.add_argument("--base-esm", help="a second esm binary whose compositions run as *_base")
    ap.add_argument("--n", type=int, action="append", help="level counts (default 59 and 200)")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--time", type=float, default=200.0, help="simulated seconds")
    ap.add_argument("--work", required=True, help="scratch directory for documents and outputs")
    ap.add_argument("--taskset", help="cpu list every run is pinned to")
    ap.add_argument("--json", help="write the per-run records here")
    a = ap.parse_args(argv)
    os.makedirs(a.work, exist_ok=True)
    sizes = a.n or [59, 200]
    records = []
    for n in sizes:
        generate.main(["--n", str(n), "--out", a.work])
        doc = lambda sp: os.path.join(a.work, generate.filename(sp, n))  # noqa: E731
        off = ["--no-count-fold"]
        configs = [
            ("fn_const", a.esm, doc("const_fn"), []),
            ("compose_const_fused", a.esm, doc("const_compose"), []),
            ("compose_const_unfused", a.esm, doc("const_compose"), off),
            ("compose_runtime_fused", a.esm, doc("runtime_compose"), []),
            ("compose_runtime_unfused", a.esm, doc("runtime_compose"), off),
        ]
        if a.base_esm:
            configs += [
                ("compose_const_base", a.base_esm, doc("const_compose"), []),
                ("compose_runtime_base", a.base_esm, doc("runtime_compose"), []),
            ]
        times = {c[0]: [] for c in configs}
        outputs = {}
        for rep in range(a.repeats):
            order = configs[rep % len(configs):] + configs[: rep % len(configs)]
            for label, exe, path, flags in order:
                out = os.path.join(a.work, f"out_N{n}_{label}.json")
                cmd = [exe, "simulate", path, "--compiler", "native", "--time", str(a.time), "-o", out] + flags
                cpu, wall = run(cmd, os.environ, a.taskset)
                times[label].append((cpu, wall))
                records.append({"n": n, "label": label, "repeat": rep, "cpu_s": cpu, "wall_s": wall})
                outputs[label] = out
        ref = json.load(open(outputs["fn_const"]))
        print(f"\nN = {n}, {a.repeats} interleaved repeats, simulated {a.time} s")
        print(f"{'spelling':28s} {'cpu med':>9s} {'wall med':>9s} {'cpu / fn':>9s}  trajectory")
        fn_cpu = statistics.median(c for c, _ in times["fn_const"])
        for label, *_ in configs:
            cpu = statistics.median(c for c, _ in times[label])
            wall = statistics.median(w for _, w in times[label])
            same = json.load(open(outputs[label])) == ref
            print(f"{label:28s} {cpu:9.3f} {wall:9.3f} {cpu / fn_cpu:9.2f}  "
                  f"{'bit-identical' if same else 'DIFFERS'}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(records, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
