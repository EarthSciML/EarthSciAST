#!/usr/bin/env python3
"""Differential check of the binary64 model `Esm.F64.rn` (formal/Esm/Float64.lean).

Generates rationals p/q across the normal and subnormal ranges, with emphasis on
exact ties, near-ties, powers of two and integers near 2^53, runs `rn` on each
at K = ℚ (via `lake env lean --run scripts/F64Diff.lean`), and compares against
Python's `float(Fraction(p, q))`, which is correctly rounded (round to nearest,
ties to even). Exits non-zero on any mismatch.

Usage (from formal/, after `lake build`):  python3 scripts/f64-diff.py [N] [SEED]
"""

import random
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

FORMAL = Path(__file__).resolve().parent.parent
MAX_FINITE = Fraction((2**53 - 1) * 2**971)


def cases(n, rng):
    out = []

    def add(v):
        if v != 0 and abs(v) <= MAX_FINITE:
            out.append(v)

    def scale(v, k):
        return v * 2**k if k >= 0 else v / 2**-k

    while len(out) < n:
        kind = rng.randrange(7)
        s = rng.choice((1, -1))
        if kind == 0:  # random rational, random magnitude
            p = rng.randrange(1, 2**rng.randrange(1, 80))
            q = rng.randrange(1, 2**rng.randrange(1, 80))
            add(s * scale(Fraction(p, q), rng.randrange(-1150, 960)))
        elif kind == 1:  # exact tie between two consecutive doubles
            m = rng.randrange(2**52, 2**53)
            add(s * scale(Fraction(2 * m + 1), rng.randrange(-1076, 970)))
        elif kind == 2:  # within a hair of a tie
            m = rng.randrange(2**52, 2**53)
            d = Fraction(rng.choice((1, -1)), 2**rng.randrange(1, 40))
            add(s * scale(2 * m + 1 + d, rng.randrange(-1076, 970)))
        elif kind == 3:  # subnormal range, including ties
            p = rng.randrange(1, 2**rng.randrange(1, 60))
            add(s * Fraction(p, 2**rng.randrange(1074, 1140)))
        elif kind == 4:  # integers around 2^53 and small quotients
            add(Fraction(s * rng.randrange(2**53 - 1000, 2**53 + 1000)))
        elif kind == 5:  # t / 86400 for timestamp-sized t
            add(Fraction(s * rng.randrange(0, 2**45), 86400))
        else:  # near powers of two and the top of the range
            k = rng.randrange(-1074, 1024)
            add(s * (scale(Fraction(1), k) + rng.choice((-1, 0, 1)) * scale(Fraction(1), k - 54)))
    out += [MAX_FINITE, -MAX_FINITE, Fraction(1, 2**1074), Fraction(1, 2**1075),
            Fraction(3, 2**1076), Fraction(2**-1022), Fraction(1, 10)]
    return out


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20261026
    vals = cases(n, random.Random(seed))
    inp = "".join(f"{v.numerator} {v.denominator}\n" for v in vals)
    res = subprocess.run(["lake", "env", "lean", "--run", "scripts/F64Diff.lean"],
                         input=inp, capture_output=True, text=True, cwd=FORMAL)
    if res.returncode != 0:
        print(res.stderr, file=sys.stderr)
        sys.exit(2)
    lines = [l for l in res.stdout.splitlines() if l.strip()]
    if len(lines) != len(vals):
        print(f"f64-diff: expected {len(vals)} results, got {len(lines)}", file=sys.stderr)
        sys.exit(2)
    bad = 0
    for v, line in zip(vals, lines):
        num, den = map(int, line.split())
        want = Fraction(float(v))
        if Fraction(num, den) != want:
            bad += 1
            if bad <= 10:
                print(f"MISMATCH {v.numerator}/{v.denominator}: lean {num}/{den}, python {want}")
    print(f"f64-diff: {len(vals) - bad}/{len(vals)} agree (seed {seed})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
