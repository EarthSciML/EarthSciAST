#!/usr/bin/env python3

"""Build the shared conformance CORPUS MANIFEST — the single source of truth
for what every language producer must sweep.

Why this exists (audit 2026-07-14, F5): all four producers used to enumerate
``tests/valid`` / ``tests/invalid`` themselves, NON-recursively, and each one
therefore silently skipped the same 69 fixtures (the entire ``faq`` and
``template_imports`` corpora) — plus ``lib/**``, which nothing swept at all
(CONFORMANCE_SPEC §2.2.1). Five hand-rolled directory walks are five chances to
skip something and never notice.

So the walk happens exactly ONCE, here, and every producer is handed the
resulting list. The comparator then asserts that every language emitted a record
for every manifest entry — a producer that skips an entry FAILS the run instead
of shrinking its own denominator.

The same logic applies to the substitution fixtures: the cases are expanded
once into a flat, id-keyed list, and producers just evaluate what they are given.

Manifest shape::

    {
      "generated_at": "...",
      "validation_files": [
        {"id": "valid/minimal_chemistry.esm", "category": "valid",
         "path": "tests/valid/minimal_chemistry.esm", "basename": "...",
         "expect": "valid"},
        ...
      ],
      "substitution_cases": [
        {"id": "simple_var_replace.json#0", "fixture": "...",
         "input": <expr>, "bindings": {...}, "expected": <expr>},
        ...
      ]
    }

``expect`` is the fixture's DECLARED outcome, which the comparator asserts each
binding against (audit F4 — the comparator used to compare languages only to
each other, so a valid fixture rejected by everyone, or an invalid fixture
accepted by everyone, passed).
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent

# Directories swept for the validation category, and the outcome each declares.
# `lib/**` is the SHIPPED standard library: not a fixture, but CONFORMANCE_SPEC
# §2.2.1 pins it to exactly the `tests/valid/` standard, because it is the one
# place where a bug reaches users rather than a test report.
VALIDATION_ROOTS: list[tuple[str, str, str]] = [
    # (category, directory relative to repo root, expected outcome)
    ("valid", "tests/valid", "valid"),
    ("invalid", "tests/invalid", "invalid"),
    ("lib", "lib", "valid"),
]


def build_validation_files() -> list[dict[str, Any]]:
    """Recursively enumerate every `.esm` under the validation roots."""
    entries: list[dict[str, Any]] = []
    for category, reldir, expect in VALIDATION_ROOTS:
        root = REPO_ROOT / reldir
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.esm")):
            rel_to_root = path.relative_to(root).as_posix()
            entries.append(
                {
                    "id": f"{category}/{rel_to_root}",
                    "category": category,
                    "path": path.relative_to(REPO_ROOT).as_posix(),
                    "basename": path.name,
                    "expect": expect,
                }
            )
    return entries


# --- substitution case expansion ---------------------------------------------


def build_substitution_cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    substitution_dir = REPO_ROOT / "tests" / "substitution"
    if not substitution_dir.is_dir():
        return cases

    for path in sorted(substitution_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except Exception as exc:
            raise SystemExit(f"substitution fixture {path} is not valid JSON: {exc}") from exc

        items = data if isinstance(data, list) else data.get("cases", [])
        index = 0
        for case in items:
            if not (isinstance(case, dict) and "input" in case and "bindings" in case):
                continue
            cases.append(
                {
                    "id": f"{path.name}#{index}",
                    "fixture": path.name,
                    "input": case["input"],
                    "bindings": case["bindings"],
                    "expected": case.get("expected"),
                }
            )
            index += 1
    return cases


def build_manifest() -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "validation_files": build_validation_files(),
        "substitution_cases": build_substitution_cases(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--output", required=True, help="Path to write the corpus manifest JSON")
    args = parser.parse_args()

    manifest = build_manifest()

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2) + "\n")

    print(
        f"Corpus manifest written to {out}: "
        f"{len(manifest['validation_files'])} validation files, "
        f"{len(manifest['substitution_cases'])} substitution cases"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
