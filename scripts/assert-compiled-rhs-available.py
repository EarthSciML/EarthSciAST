#!/usr/bin/env python3
"""Assert that a `compiled_rhs` run's binding actually RAN, rather than skipping.

Why this exists. ``tests/conformance/compiled_rhs/manifest.json`` lists julia
and rust under ``engines.compiled.bindings_optional`` and leaves
``bindings_required`` empty. That is deliberate and correct for the main
conformance workflow: a checkout with no ``XLA_EXTENSION_DIR`` and no Reactant
must report the compiled engine as ``unavailable``, print the reason, and move
on — a visible skip, never a silent pass.

The consequence is that ``run-compiled-rhs-conformance.py`` exits 0 on that
skip. In ``.github/workflows/xla-backends.yml`` the whole point is that the
compiled engine ran, so the exit code alone would let the workflow go green
having tested nothing. This reads the report the runner wrote and fails unless
the named binding's status is literally ``ok``.

The runner has no ``--require-available`` flag, and the manifest and the runner
are not this workflow's to change. If such a flag is added, delete this script
and pass the flag instead.

Usage:
    python3 scripts/assert-compiled-rhs-available.py <report.json> <binding>

Exit codes:
    0  the binding's status is "ok"
    1  the binding is unavailable, skipped, failed, or absent from the report
    2  the report is missing or unreadable (no verdict is possible)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    report_path = Path(argv[1])
    binding = argv[2]

    try:
        report = json.loads(report_path.read_text())
    except OSError as err:
        print(f"assert-compiled-rhs-available: cannot read {report_path}: {err}", file=sys.stderr)
        print(
            "  The producer step must have written a report; a missing one means "
            "it did not run at all.",
            file=sys.stderr,
        )
        return 2
    except ValueError as err:
        print(
            f"assert-compiled-rhs-available: {report_path} is not valid JSON: {err}",
            file=sys.stderr,
        )
        return 2

    engine = report.get("engine")
    entry = (report.get("bindings") or {}).get(binding)
    if entry is None:
        print(
            f"assert-compiled-rhs-available: {report_path} has no entry for binding "
            f"{binding!r} (bindings present: {sorted((report.get('bindings') or {}))})",
            file=sys.stderr,
        )
        return 1

    status = entry.get("status")
    if status == "ok":
        n = len(entry.get("fixtures") or {})
        print(f"{binding} / {engine} engine ran and passed: {n} fixture(s) gated, status ok")
        return 0

    print(
        f"assert-compiled-rhs-available: {binding} / {engine} engine status is "
        f"{status!r}, not 'ok'.",
        file=sys.stderr,
    )
    if status in ("unavailable", "skipped"):
        print(
            "  This workflow exists to RUN the compiled engine, so an unavailable or "
            "skipped engine is a FAILURE here even though the tier manifest lists "
            "this binding as optional for the compiled engine (which is what lets "
            "the main conformance workflow skip it visibly instead).",
            file=sys.stderr,
        )
    for key in ("reason", "error"):
        if entry.get(key):
            print(f"  {key}: {entry[key]}", file=sys.stderr)
    if entry.get("stderr"):
        print(f"  adapter stderr:\n{entry['stderr']}", file=sys.stderr)
    for u in report.get("unavailable") or []:
        print(
            f"  unavailable ledger: {u['binding']} / {u['engine']}: {u['reason']}", file=sys.stderr
        )
    for r in report.get("refusals") or []:
        print(
            f"  refusal: {r['binding']} refused {r['fixture']}: {r.get('rule')} — "
            f"{r.get('reason')} [{r.get('verdict')}]",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
