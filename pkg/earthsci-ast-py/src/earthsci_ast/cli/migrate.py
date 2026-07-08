"""``esm-migrate`` CLI — migrate ``.esm`` files across spec versions.

Currently supports the v0.1.x → v0.2.0 migration defined in
docs/rfcs/discretization.md §10.1 and §16.1 (relocation of
``domains.<d>.boundary_conditions`` to ``models.<M>.boundary_conditions``).

Usage::

    esm-migrate --from 0.1.0 --to 0.2.0 input.esm > output.esm
    esm-migrate --from 0.1.0 --to 0.2.0 --in-place input.esm
    esm-migrate --from 0.1.0 --to 0.2.0 --dry-run input.esm
"""

from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from ..migration import MigrationError, migrate_file_0_1_to_0_2


def _load(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as fp:
        return json.load(fp)


def _dump(data: Dict[str, Any]) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def _parse_version(s: str) -> tuple[int, int, int]:
    parts = s.split(".")
    if len(parts) != 3:
        raise MigrationError(f"Invalid version: {s}")
    return (int(parts[0]), int(parts[1]), int(parts[2]))


def _run_migration(data: Dict[str, Any], from_v: str, to_v: str) -> Dict[str, Any]:
    """Dispatch to the correct migration path based on (from, to)."""
    fv = _parse_version(from_v)
    tv = _parse_version(to_v)
    # Only 0.1.x → 0.2.0 is currently implemented by this tool.
    if fv[0] == 0 and fv[1] == 1 and tv == (0, 2, 0):
        return migrate_file_0_1_to_0_2(data)
    raise MigrationError(
        f"Unsupported migration path {from_v} -> {to_v}. Supported: 0.1.x -> 0.2.0."
    )


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="esm-migrate",
        description=(
            "Migrate an ESM file between spec versions. "
            "Currently supports 0.1.x -> 0.2.0 (boundary-condition relocation)."
        ),
    )
    p.add_argument(
        "--from",
        dest="from_version",
        required=True,
        help="Source spec version (e.g., 0.1.0).",
    )
    p.add_argument(
        "--to",
        dest="to_version",
        required=True,
        help="Target spec version (e.g., 0.2.0).",
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--in-place",
        action="store_true",
        help="Overwrite the input file with the migrated output.",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="Show a unified diff of the migration without writing.",
    )
    p.add_argument(
        "-o",
        "--output",
        default=None,
        help="Write migrated output to this path instead of stdout.",
    )
    p.add_argument(
        "input",
        help="Path to the input .esm file.",
    )
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    in_path = Path(args.input)
    if not in_path.exists():
        print(f"esm-migrate: input file not found: {in_path}", file=sys.stderr)
        return 2

    try:
        data = _load(in_path)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"esm-migrate: failed to parse {in_path}: {exc}", file=sys.stderr)
        return 2

    try:
        migrated = _run_migration(data, args.from_version, args.to_version)
    except MigrationError as exc:
        print(f"esm-migrate: {exc}", file=sys.stderr)
        return 1

    original_text = _dump(data)
    migrated_text = _dump(migrated)

    if args.dry_run:
        diff: List[str] = list(
            difflib.unified_diff(
                original_text.splitlines(keepends=True),
                migrated_text.splitlines(keepends=True),
                fromfile=str(in_path),
                tofile=str(in_path) + " (migrated)",
            )
        )
        sys.stdout.writelines(diff)
        return 0

    if args.in_place:
        in_path.write_text(migrated_text, encoding="utf-8")
        return 0

    if args.output:
        Path(args.output).write_text(migrated_text, encoding="utf-8")
        return 0

    sys.stdout.write(migrated_text)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
