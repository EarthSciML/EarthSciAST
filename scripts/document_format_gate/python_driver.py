#!/usr/bin/env python3
"""The Python batch driver of the document-format gate (scripts/run-document-format-gate.py).

    python_driver.py print MANIFEST OUT    canonical form and both printed texts
    python_driver.py parse MANIFEST OUT    read each text back

The manifest and output layout are described in run-document-format-gate.py.
"""

import json
import sys
from pathlib import Path

from earthsci_ast import canonicalize_document, parse_document, print_document

EXT = {"markdown": "md", "typst": "typ"}


def dump(v) -> str:
    return json.dumps(v, ensure_ascii=False, sort_keys=True)


def run_print(manifest, out: Path):
    for item in manifest:
        stem = out / item["id"]
        try:
            canon = canonicalize_document(
                json.loads(Path(item["path"]).read_text(encoding="utf-8"))
            )
            Path(f"{stem}.canon.json").write_text(dump(canon), encoding="utf-8")
        except Exception as e:  # noqa: BLE001 - every failure is recorded for the gate
            Path(f"{stem}.canon.error").write_text(repr(e), encoding="utf-8")
            continue
        for fmt, ext in EXT.items():
            try:
                Path(f"{stem}.{ext}").write_text(print_document(canon, fmt), encoding="utf-8")
            except Exception as e:  # noqa: BLE001
                Path(f"{stem}.{ext}.error").write_text(repr(e), encoding="utf-8")


def run_parse(manifest, out: Path):
    for item in manifest:
        stem = out / item["id"]
        try:
            doc = parse_document(Path(item["path"]).read_text(encoding="utf-8"), item["format"])
            Path(f"{stem}.json").write_text(dump(doc), encoding="utf-8")
        except Exception as e:  # noqa: BLE001
            code = getattr(e, "code", None)
            Path(f"{stem}.error").write_text(f"{code or type(e).__name__}: {e}", encoding="utf-8")


def main():
    mode, manifest, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    items = json.loads(Path(manifest).read_text(encoding="utf-8"))
    {"print": run_print, "parse": run_parse}[mode](items, out)


if __name__ == "__main__":
    main()
