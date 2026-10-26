#!/usr/bin/env python3
"""Score the Lean model (`esm-lean units`) against the unit-registry golden.

Runs `esm-lean units tests/conformance/unit_registry/golden/unit_verdicts.json`
from `formal/` and checks every record against the golden's contract
(tests/conformance/unit_registry/README.md):

  accept                 resolves; its dimension equals the canonical's; the exact
                         scale ratio equals `scale_exact` as a string; and when
                         `scale_to_canonical` is non-null the double factor is
                         within 1e-12 relative of it.
  reject                 does not resolve.
  reject_scaling_factor  does not resolve, and the diagnostic contains
                         `scaling factor`.

Exits non-zero on any mismatch and prints a one-line summary.
"""

import json
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORMAL = ROOT / "formal"
GOLDEN = ROOT / "tests" / "conformance" / "unit_registry" / "golden" / "unit_verdicts.json"
REL_TOL = 1e-12


def run_model():
    proc = subprocess.run(
        ["lake", "exe", "esm-lean", "units", str(GOLDEN)],
        cwd=FORMAL,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"esm-lean units failed ({proc.returncode}):\n{proc.stderr}")
    return json.loads(proc.stdout)


def bits_to_float(bits):
    return struct.unpack("<d", struct.pack("<Q", int(bits)))[0]


def main():
    golden = json.loads(GOLDEN.read_text(encoding="utf-8"))
    model = run_model()
    failures = []
    counts = {}
    for key in ("accept", "reject", "reject_scaling_factor"):
        want, got = golden.get(key, []), model.get(key, [])
        counts[key] = len(want)
        if len(want) != len(got):
            failures.append(f"{key}: golden has {len(want)} entries, model returned {len(got)}")
            continue
        for w, g in zip(want, got):
            u = w["units"]
            if g.get("units") != u:
                failures.append(f"{key}: record order mismatch at {u!r}")
                continue
            if key == "accept":
                if not g.get("resolved") or not g.get("canonical_resolved"):
                    failures.append(f"accept {u!r}: does not resolve ({g.get('error')})")
                    continue
                if not g.get("dim_equal"):
                    failures.append(
                        f"accept {u!r}: dimension {g.get('dim')} != canonical "
                        f"{w['canonical']!r} {g.get('canonical_dim')}"
                    )
                if g.get("scale_exact") != w["scale_exact"]:
                    failures.append(
                        f"accept {u!r}: scale_exact {g.get('scale_exact')!r} != {w['scale_exact']!r}"
                    )
                expect = w.get("scale_to_canonical")
                if expect is not None:
                    f = bits_to_float(g["factor_bits"])
                    if abs(f - expect) > REL_TOL * abs(expect):
                        failures.append(f"accept {u!r}: factor {f!r} != {expect!r} (rel 1e-12)")
            else:
                if g.get("resolved"):
                    failures.append(f"{key} {u!r}: resolves, must not")
                elif key == "reject_scaling_factor" and "scaling factor" not in (g.get("error") or ""):
                    failures.append(f"{key} {u!r}: diagnostic lacks 'scaling factor': {g.get('error')!r}")
    for f in failures:
        print(f"  - {f}")
    total = sum(counts.values())
    summary = ", ".join(f"{k} {v}" for k, v in counts.items())
    status = "ok" if not failures else f"{len(failures)} mismatch(es)"
    print(f"unit_registry (esm-lean): {total} strings ({summary}): {status}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
