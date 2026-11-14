#!/usr/bin/env python3
"""Whole-corpus check of the document source formats, through the Lean model.

For every `.esm` file under `tests/` that is a JSON object (the robustness, security and
malformed-JSON fixtures that are not JSON at all are skipped and counted):

* the Markdown round trip: `esm-lean print-md`, then `esm-lean parse-md` on the printed
  text, must give the document's canonical form (`esm-lean canon`);
* the same for Typst (`print-typ`, `parse-typ`);
* with `--typst`: every printed `.typ` must compile, with the repository's `esm` Typst
  package (`typst/packages`, passed as `--package-path`);
* with `--katex`: every math piece of every printed `.md` must render in KaTeX
  (`katex-check.cjs`, which needs the `katex` npm package).

Exits non-zero on any failure, listing the first few of each kind.

Usage (from the repository root, after `lake build` in formal/):

    python3 formal/scripts/doc-corpus.py [--typst PATH] [--katex] [--jobs N] [--keep DIR]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
BINARY = ROOT / "formal" / ".lake" / "build" / "bin" / "esm-lean"
PACKAGES = ROOT / "typst" / "packages"
KATEX_CHECK = Path(__file__).resolve().parent / "katex-check.cjs"


def corpus():
    """The JSON-object `.esm` files under tests/, and the count of those skipped."""
    files, skipped = [], 0
    for f in sorted((ROOT / "tests").rglob("*.esm")):
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, UnicodeDecodeError):
            skipped += 1
            continue
        if isinstance(doc, dict):
            files.append(f)
        else:
            skipped += 1
    return files, skipped


def run(binary, mode, path):
    p = subprocess.run([str(binary), mode, str(path)], capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr.strip()


def check_one(binary, src, out_dir, typst):
    """The failures of one document, as (kind, message) pairs."""
    stem = str(src.relative_to(ROOT / "tests")).replace(os.sep, "__")[: -len(".esm")]
    rc, canon, err = run(binary, "canon", src)
    if rc != 0:
        return [("canon", f"{src}: {err}")]
    fails = []
    for fmt, ext in (("md", ".md"), ("typ", ".typ")):
        rc, text, err = run(binary, f"print-{fmt}", src)
        if rc != 0:
            fails.append((f"print-{fmt}", f"{src}: {err}"))
            continue
        printed = out_dir / (stem + ext)
        printed.write_text(text, encoding="utf-8")
        rc, back, err = run(binary, f"parse-{fmt}", printed)
        if rc != 0:
            fails.append((f"parse-{fmt}", f"{src}: {err}"))
        elif back != canon:
            fails.append((f"round trip {fmt}", f"{src}: read back a different document"))
        elif fmt == "typ" and typst:
            p = subprocess.run(
                [
                    typst,
                    "compile",
                    "--package-path",
                    str(PACKAGES),
                    "-f",
                    "pdf",
                    str(printed),
                    os.devnull,
                ],
                capture_output=True,
                text=True,
            )
            if p.returncode != 0:
                fails.append(("typst compile", f"{src}: {p.stderr.strip()[:600]}"))
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--binary", default=str(BINARY), help="the esm-lean executable")
    ap.add_argument("--typst", help="compile every printed .typ with this typst executable")
    ap.add_argument(
        "--katex", action="store_true", help="render every printed .md's math with KaTeX"
    )
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    ap.add_argument("--keep", help="write the printed files here (default: a temporary directory)")
    args = ap.parse_args()

    files, skipped = corpus()
    out_dir = Path(args.keep) if args.keep else Path(tempfile.mkdtemp(prefix="esm-doc-corpus-"))
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        with ThreadPoolExecutor(args.jobs) as pool:
            results = list(
                pool.map(lambda f: check_one(args.binary, f, out_dir, args.typst), files)
            )
        fails = [x for r in results for x in r]
        if args.katex:
            p = subprocess.run(
                ["node", str(KATEX_CHECK), str(out_dir)], capture_output=True, text=True
            )
            print(p.stdout.strip())
            if p.returncode != 0:
                fails.append(("katex", p.stderr.strip()[:4000]))
    finally:
        if not args.keep:
            shutil.rmtree(out_dir, ignore_errors=True)

    checks = "Markdown and Typst round trips" + (", Typst compile" if args.typst else "")
    print(
        f"{len(files)} documents ({skipped} files under tests/ are not JSON objects and are skipped): {checks}"
    )
    if not fails:
        print("all pass")
        return 0
    by_kind = {}
    for kind, msg in fails:
        by_kind.setdefault(kind, []).append(msg)
    for kind, msgs in sorted(by_kind.items()):
        print(f"\n{kind}: {len(msgs)} failure(s)")
        for m in msgs[:10]:
            print("  " + m)
    return 1


if __name__ == "__main__":
    sys.exit(main())
