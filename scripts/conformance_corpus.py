#!/usr/bin/env python3

"""Build the shared conformance CORPUS MANIFEST — the single source of truth
for what every language producer must sweep.

Why this exists (audit 2026-07-14, F5): all four producers used to enumerate
``tests/valid`` / ``tests/invalid`` themselves, NON-recursively, and each one
therefore silently skipped the same 69 fixtures (the entire ``aggregate`` and
``template_imports`` corpora) — plus ``lib/**``, which nothing swept at all
(CONFORMANCE_SPEC §2.2.1). Five hand-rolled directory walks are five chances to
skip something and never notice.

So the walk happens exactly ONCE, here, and every producer is handed the
resulting list. The comparator then asserts that every language emitted a record
for every manifest entry — a producer that skips an entry FAILS the run instead
of shrinking its own denominator.

The same logic applies to the display / substitution fixtures, whose JSON comes
in three different shapes (flat list, ``{test_cases: [...]}`` dict, grouped
``{tests: [...]}`` items). Each binding used to re-implement that traversal and
each one got it wrong differently — Julia and TypeScript looked for top-level
``chemical_formulas`` / ``expressions`` / ``tests`` keys that NO fixture has, so
both emitted nothing and the comparator scored the empty agreement as 100%
consistent (audit C2). Here the cases are expanded once into a flat, id-keyed
list; producers just render what they are given.

Manifest shape::

    {
      "generated_at": "...",
      "validation_files": [
        {"id": "valid/minimal_chemistry.esm", "category": "valid",
         "path": "tests/valid/minimal_chemistry.esm", "basename": "...",
         "expect": "valid"},
        ...
      ],
      "display_cases": [
        {"id": "all_operators.json#0", "fixture": "all_operators.json",
         "kind": "expression" | "formula", "input": <expr-or-string>,
         "expected": {"unicode": ..., "latex": ..., "ascii": ...}},
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


# --- display / substitution case expansion ----------------------------------


def _iter_display_case_dicts(data: Any):
    """Yield every display case dict in a fixture, in a FIXED traversal order.

    The corpus uses three shapes and every producer has to agree on the walk,
    so it lives here and only here:

    1. top-level list of case dicts (``{input, unicode, latex, ascii}``)
    2. top-level list of GROUP dicts, each with ``tests`` or ``test_cases``
    3. top-level dict with ``test_cases`` / ``cases`` / ``tests``

    A fixture with none of the above (e.g. ``model_summary.json``, which pins a
    model summary rather than a rendering) contributes zero cases.
    """
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        for key in ("test_cases", "cases", "tests"):
            if isinstance(data.get(key), list):
                items = data[key]
                break
        else:
            return
    else:
        return

    for item in items:
        if not isinstance(item, dict):
            continue
        if "input" in item:
            yield item
            continue
        for key in ("tests", "test_cases", "cases"):
            sub = item.get(key)
            if isinstance(sub, list):
                for case in sub:
                    if isinstance(case, dict) and "input" in case:
                        yield case
                break


def _expected_renderings(case: dict[str, Any]) -> dict[str, Any]:
    """Pinned renderings, in either of the two spellings the corpus uses.

    ``element_recognition.json`` uses a third spelling — a single
    ``expected_output`` plus a ``format`` discriminator — so it is normalised
    here too rather than being silently dropped (it was).
    """
    expected: dict[str, Any] = {}
    for fmt in ("unicode", "latex", "ascii"):
        value = case.get(f"expected_{fmt}", case.get(fmt))
        if value is not None:
            expected[fmt] = value
    if not expected and "expected_output" in case:
        fmt = case.get("format", "unicode")
        if fmt in ("unicode", "latex", "ascii"):
            expected[fmt] = case["expected_output"]
    return expected


def build_display_cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    display_dir = REPO_ROOT / "tests" / "display"
    if not display_dir.is_dir():
        return cases

    for path in sorted(display_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except Exception as exc:  # a corpus file that will not parse is a corpus bug
            raise SystemExit(f"display fixture {path} is not valid JSON: {exc}") from exc

        for index, case in enumerate(_iter_display_case_dicts(data)):
            source = case["input"]
            cases.append(
                {
                    "id": f"{path.name}#{index}",
                    "fixture": path.name,
                    # A bare string input is a CHEMICAL FORMULA (`"O3"` →
                    # `"O₃"`); a dict input is an Expression. The two go through
                    # different renderers in every binding.
                    "kind": "formula" if isinstance(source, str) else "expression",
                    "input": source,
                    "expected": _expected_renderings(case),
                }
            )
    return cases


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
        "display_cases": build_display_cases(),
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
        f"{len(manifest['display_cases'])} display cases, "
        f"{len(manifest['substitution_cases'])} substitution cases"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
