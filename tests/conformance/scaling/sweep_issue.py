#!/usr/bin/env python3
"""Turn a red scaling sweep into a GitHub issue.

    sweep_issue.py CHECK.json [--file] [--repo OWNER/NAME] [--label LABEL ...]

CHECK.json is what `check.py --json` wrote over a clean sweep (`sweep.sh` writes
$SCALING_BUILD/check.json). When it holds red findings, prints an issue title and
body naming every red row; with --file, files it through `gh issue create`.
Prints nothing and exits 0 when the sweep is green.
"""

import argparse
import json
import subprocess
import sys

RED = ("FAIL", "EXCEEDS", "STALE", "MISSING")


def fmt(v):
    return f"{v:.4g}" if isinstance(v, float) else str(v)


def issue(check):
    rows = [r for r in check["rows"] if r["outcome"] in RED]
    red = check.get("red") or []
    if not rows and not red:
        return None
    title = f"Scaling sweep red: {len(red)} finding(s)"
    lines = [
        "The scheduled clean scaling sweep (tests/conformance/scaling/sweep.sh) is red.",
        "",
        "| binding | threads | family | N | gate | outcome | measured | note |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        n = "all" if r["n"] is None else r["n"]
        lines.append(
            f"| {r['binding']} | {r['threads']} | {r['family']} | {n} | {r['gate']} | "
            f"{r['outcome']} | {fmt(r['measured'])} | {r['note'] or ''} |"
        )
    other = [m for m in red if not any(m.startswith(f"{r['binding']} ") for r in rows)]
    if other:
        lines += ["", "Other findings:", ""] + [f"- {m}" for m in other]
    return title, "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("check")
    ap.add_argument("--file", action="store_true", help="file the issue with gh")
    ap.add_argument("--repo", help="gh --repo")
    ap.add_argument("--label", action="append", default=[])
    a = ap.parse_args(argv)
    with open(a.check) as fh:
        found = issue(json.load(fh))
    if found is None:
        return 0
    title, body = found
    if not a.file:
        print(title)
        print()
        print(body)
        return 0
    cmd = ["gh", "issue", "create", "--title", title, "--body", body]
    if a.repo:
        cmd += ["--repo", a.repo]
    for label in a.label:
        cmd += ["--label", label]
    return subprocess.run(cmd).returncode


if __name__ == "__main__":
    sys.exit(main())
