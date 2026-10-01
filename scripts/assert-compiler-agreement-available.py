#!/usr/bin/env python3
"""Assert that a `compiler_agreement` run's compiler actually RAN, rather than skipping.

Why this exists. ``tests/conformance/compiler_agreement/manifest.json`` leaves
``compilers.native.bindings_required`` empty and lists julia, rust and python as
``bindings_optional`` — and likewise for ``xla``, ``mtk`` and ``sympy``. That is
deliberate and correct for the main conformance workflow: a checkout with no
Reactant, no ``XLA_EXTENSION_DIR`` and no strict native build must report the
compiler as ``unavailable``, print the reason, and move on — a visible skip, never
a silent pass.

The consequence is that ``run-compiler-agreement-conformance.py`` exits 0 on that
skip. A workflow whose whole point is that a particular compiler ran would go
green having tested nothing. This reads the report the runner wrote and fails
unless the named binding's status under the named compiler is literally ``ok``.

The compiler is an argument rather than inferred, because a report is keyed by
compiler and a workflow wired to the wrong one would otherwise sail through: a
report that carries no section for the compiler being asserted says nothing about
it, and that is a configuration error, not a verdict.

The runner has no ``--require-available`` flag, and the manifest and the runner
are not a workflow's to change. If such a flag is added, delete this script and
pass the flag instead.

Usage:
    python3 scripts/assert-compiler-agreement-available.py <report.json> <binding> <compiler>

Exit codes:
    0  the binding's status under that compiler is "ok"
    1  the binding is unavailable, skipped, failed, or absent from that compiler's section
    2  the report is missing, unreadable, or carries no section for that compiler
       (no verdict about it is possible)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# The interpreter is `bindings_required` for all three bindings, so the runner
# already fails when it does not run. Asserting it here is not wrong, only
# vacuous, and a workflow that meant to assert a compiled lane and typed this
# instead would get a green it did not earn.
_VACUOUS = "interpreter"


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    report_path = Path(argv[1])
    binding = argv[2]
    compiler = argv[3]

    try:
        report = json.loads(report_path.read_text())
    except OSError as err:
        print(
            f"assert-compiler-agreement-available: cannot read {report_path}: {err}",
            file=sys.stderr,
        )
        print(
            "  The producer step must have written a report; a missing one means it did "
            "not run at all.",
            file=sys.stderr,
        )
        return 2
    except ValueError as err:
        print(
            f"assert-compiler-agreement-available: {report_path} is not valid JSON: {err}",
            file=sys.stderr,
        )
        return 2

    section = (report.get("compilers") or {}).get(compiler)
    if section is None:
        print(
            f"assert-compiler-agreement-available: {report_path} has no section for compiler "
            f"{compiler!r} (compilers present: {sorted(report.get('compilers') or {})}). This "
            "assertion only means something about a run that ASKED for that compiler.",
            file=sys.stderr,
        )
        return 2

    if compiler == _VACUOUS:
        print(
            f"assert-compiler-agreement-available: note — {_VACUOUS!r} is bindings_required for "
            "every binding, so the runner's own exit code already covers this. Asserting it "
            "here is harmless but proves nothing extra.",
            file=sys.stderr,
        )

    entry = (section.get("bindings") or {}).get(binding)
    if entry is None:
        print(
            f"assert-compiler-agreement-available: {report_path} has no entry for binding "
            f"{binding!r} under compiler {compiler!r} (bindings present: "
            f"{sorted(section.get('bindings') or {})})",
            file=sys.stderr,
        )
        return 1

    status = entry.get("status")
    if status == "ok":
        n = len(entry.get("fixtures") or {})
        print(f"{binding} / {compiler} ran and passed: {n} fixture(s) gated, status ok")
        return 0

    print(
        f"assert-compiler-agreement-available: {binding} / {compiler} status is {status!r}, "
        "not 'ok'.",
        file=sys.stderr,
    )
    if status in ("unavailable", "skipped"):
        print(
            "  This workflow exists to RUN that compiler, so an unavailable or skipped one is "
            "a FAILURE here even though the tier manifest lists this binding as optional for "
            "it (which is what lets the main conformance workflow skip it visibly instead).",
            file=sys.stderr,
        )
    for key in ("reason", "error"):
        if entry.get(key):
            print(f"  {key}: {entry[key]}", file=sys.stderr)
    if entry.get("stderr"):
        print(f"  adapter stderr:\n{entry['stderr']}", file=sys.stderr)
    for u in report.get("unavailable") or []:
        if u.get("compiler") == compiler:
            print(
                f"  unavailable ledger: {u['binding']} / {u['compiler']}: {u['reason']}",
                file=sys.stderr,
            )
    for r in report.get("refusals") or []:
        if r.get("compiler") == compiler:
            print(
                f"  refusal: {r['binding']} / {r['compiler']} refused {r['fixture']}: "
                f"{r.get('rule')} — {r.get('reason')} [{r.get('verdict')}]",
                file=sys.stderr,
            )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
