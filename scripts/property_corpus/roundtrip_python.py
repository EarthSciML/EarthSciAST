#!/usr/bin/env python3
"""Python expression round-trip driver for property-corpus conformance.

Reads a set of expression JSON fixtures, passes each through
``_parse_expression``/``_serialize_expression``, and emits a JSON object
``{fixture_name: {"ok": bool, "value"|"error": ...}}`` to stdout.

Usage: ``roundtrip_python.py <fixture.json> [<fixture.json> ...]``
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "pkg" / "earthsci-ast-py" / "src"))

from earthsci_ast.parse import _parse_expression  # noqa: E402
from earthsci_ast.serialize import _serialize_expression  # noqa: E402


def roundtrip_one(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        parsed = _parse_expression(data)
        serialized = _serialize_expression(parsed)
        return {"ok": True, "value": serialized}
    except Exception as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}


def main() -> None:
    results = {Path(p).name: roundtrip_one(Path(p)) for p in sys.argv[1:]}
    json.dump(results, sys.stdout, sort_keys=True)


if __name__ == "__main__":
    main()
