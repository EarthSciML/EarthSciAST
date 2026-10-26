#!/usr/bin/env python3
"""Audit gate for the Lean spec model in `formal/` (see `formal/README.md`).

The model's value rests on three things a passing `lake build` does not show:
that every normative clause of the spec is accounted for, that every claim the
registry makes about a clause is backed by a theorem whose type IS the claim,
and that no proof leans on an escape hatch (`sorry`, `native_decide`, a new
axiom). This script checks those three things.

Subcommands:

  inventory   Every inventory clause cites a section that exists exactly once,
              its quote occurs exactly once in the cited file and lies inside
              that section, and every `MUST` in the spec is covered by some
              clause's quote. `--source F --lines A-B` restricts the coverage
              report to one chunk (for whoever is writing that chunk).
  registry    Every property names inventory clauses that exist and carries the
              fields its status requires. With `--lean`, each proven or refuted
              property's theorem is elaborated against its stated type and its
              axioms are listed.
  tokens      No escape-hatch token appears in any `.lean` file outside a
              registered verified checker.
  all         All three, with `--lean`.

Exit status is 0 only if every requested check passes.
"""

import argparse
import bisect
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORMAL = ROOT / "formal"
INVENTORY_DIR = FORMAL / "inventory"
REGISTRY = FORMAL / "properties.json"
QUESTIONS = FORMAL / "QUESTIONS.md"

SPEC_FILES = ("esm-spec.md", "CONFORMANCE_SPEC.md")
CLASSES = ("semantic", "later", "out_of_scope")
AREAS = (
    "closed_functions",
    "units",
    "scalar",
    "canonical",
    "round_trip",
    "determinism",
    "semiring",
    "arrays",
    "rewrite",
    "reactions",
    "flatten",
    "coupling",
    "events",
    "solver",
    "simulation",
    "data_sources",
    "diagnostics",
    "schema",
    "conformance_harness",
    "precision",
    "api",
    "other",
)
STATUSES = ("open", "proven", "refuted", "question")
ALLOWED_AXIOMS = {"propext", "Classical.choice", "Quot.sound"}
# A clause id is a dotted, lower-case slug: `spec.4.2.minmax-arity`.
ID_RE = re.compile(r"^(spec|conf)\.[0-9a-z.]+\.[a-z0-9][a-z0-9-]*$")
HEADING_RE = re.compile(r"^#{1,6}\s+(\d+(?:\.\d+)*[a-z]?)\.?\s")
FORBIDDEN_TOKENS = {
    "sorry": re.compile(r"\bsorry\b"),
    "admit": re.compile(r"\badmit\b"),
    "native_decide": re.compile(r"\bnative_decide\b|decide\s+\+native"),
    "skipKernelTC": re.compile(r"skipKernelTC"),
    "axiom declaration": re.compile(r"^\s*(private\s+)?axiom\s", re.M),
}


class Report:
    def __init__(self):
        self.errors = []

    def error(self, msg):
        self.errors.append(msg)

    def done(self, title):
        if self.errors:
            print(f"{title}: {len(self.errors)} error(s)")
            for e in self.errors:
                print(f"  - {e}")
            return False
        print(f"{title}: ok")
        return True


class SpecText:
    """A spec file with whitespace-normalized search and section lookup.

    Spec prose is hard-wrapped, so a quote copied from it may break where the
    file does not. Searching the whitespace-collapsed text, and mapping hits back
    to raw offsets, makes a quote's line breaks irrelevant.
    """

    def __init__(self, path):
        self.path = path
        self.raw = path.read_text(encoding="utf-8")
        norm, index = [], []
        prev_space = False
        for i, ch in enumerate(self.raw):
            if ch.isspace():
                if prev_space:
                    continue
                norm.append(" ")
                prev_space = True
            else:
                norm.append(ch)
                prev_space = False
            index.append(i)
        self.norm = "".join(norm)
        self.norm_to_raw = index
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", self.raw)]
        # Section headings, in order: (raw offset, number).
        self.headings = []
        for m in re.finditer(r"^.*$", self.raw, re.M):
            h = HEADING_RE.match(m.group(0))
            if h:
                self.headings.append((m.start(), h.group(1)))
        self.heading_offsets = [o for o, _ in self.headings]
        self.heading_counts = {}
        for _, num in self.headings:
            self.heading_counts[num] = self.heading_counts.get(num, 0) + 1

    def find(self, quote):
        """Raw (start, end) of every occurrence of `quote`."""
        q = re.sub(r"\s+", " ", quote.strip())
        hits, start = [], 0
        while q:
            k = self.norm.find(q, start)
            if k < 0:
                break
            hits.append((self.norm_to_raw[k], self.norm_to_raw[k + len(q) - 1] + 1))
            start = k + 1
        return hits

    def section_at(self, offset):
        k = bisect.bisect_right(self.heading_offsets, offset) - 1
        return self.headings[k][1] if k >= 0 else None

    def line_of(self, offset):
        return bisect.bisect_right(self.line_starts, offset)

    def must_offsets(self):
        return [m.start() for m in re.finditer(r"\bMUST\b", self.raw)]


def load_json(path, report):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        report.error(f"{path.relative_to(ROOT)}: {e}")
        return None


def load_inventory(report):
    clauses = []
    for path in sorted(INVENTORY_DIR.glob("*.json")):
        doc = load_json(path, report)
        if doc is None:
            continue
        source = doc.get("source")
        if source not in SPEC_FILES:
            report.error(f"{path.name}: source must be one of {SPEC_FILES}, got {source!r}")
            continue
        for c in doc.get("clauses", []):
            clauses.append((path.name, source, c))
    return clauses


def check_inventory(args):
    report = Report()
    texts = {name: SpecText(ROOT / name) for name in SPEC_FILES}
    clauses = load_inventory(report)
    seen_ids = {}
    covered = {name: [] for name in SPEC_FILES}
    anchors = question_anchors()
    known = []
    for fname, source, c in clauses:
        where = f"{fname}:{c.get('id', '?')}"
        cid = c.get("id")
        if not isinstance(cid, str) or not ID_RE.match(cid):
            report.error(f"{where}: id must match {ID_RE.pattern}")
        elif cid in seen_ids:
            report.error(f"{where}: duplicate id (also in {seen_ids[cid]})")
        else:
            seen_ids[cid] = fname
        cls = c.get("class")
        if cls not in CLASSES:
            report.error(f"{where}: class must be one of {CLASSES}")
        if c.get("area") not in AREAS:
            report.error(f"{where}: area must be one of {AREAS}")
        if cls in ("semantic", "later") and not isinstance(c.get("phase"), int):
            report.error(f"{where}: a {cls} clause needs an integer phase")
        if not c.get("note"):
            report.error(f"{where}: note is required")
        quote = c.get("quote", "")
        if "MUST" not in quote:
            report.error(f"{where}: quote must contain the clause's MUST")
        cite_errors, span = check_citation(texts[source], source, c.get("section"), quote)
        if span:
            covered[source].append(span)
        # A citation that fails because the SPEC is defective is recorded as a
        # pending question, not fixed by bending the citation. It stays known
        # until the spec is fixed; then the stale marker itself fails, so the
        # question gets closed in the same change.
        blocker = c.get("blocked_by")
        if blocker:
            if blocker not in anchors:
                report.error(f"{where}: blocked_by {blocker!r} is not a QUESTIONS.md anchor")
            elif cite_errors:
                known.append(f"{where} ({blocker}): {cite_errors[0]}")
            else:
                report.error(
                    f"{where}: blocked_by {blocker} is stale — the citation now resolves; "
                    "remove blocked_by and record the ruling in QUESTIONS.md"
                )
        else:
            for e in cite_errors:
                report.error(f"{where}: {e}")

    for source, text in texts.items():
        if args.source and source != args.source:
            continue
        lo, hi = 1, float("inf")
        if args.lines:
            a, b = args.lines.split("-")
            lo, hi = int(a), int(b)
        spans = covered[source]
        missing = []
        for off in text.must_offsets():
            line = text.line_of(off)
            if not lo <= line <= hi:
                continue
            if not any(s <= off < e for s, e in spans):
                missing.append(line)
        if missing:
            shown = ", ".join(str(x) for x in missing[:40])
            more = f" (+{len(missing) - 40} more)" if len(missing) > 40 else ""
            report.error(
                f"{source}: {len(missing)} MUST(s) not covered by any clause, at lines {shown}{more}"
            )
    counts = {}
    for _, _, c in clauses:
        counts[c.get("class")] = counts.get(c.get("class"), 0) + 1
    print(f"inventory: {len(clauses)} clauses {counts}")
    for k in known:
        print(f"  known spec defect: {k}")
    return report.done("inventory")


def check_citation(text, source, section, quote):
    """Errors in one clause's citation, and the raw span its quote covers."""
    errors = []
    n = text.heading_counts.get(section, 0)
    if n != 1:
        errors.append(
            f"section {section!r} has {n} headings in {source}; "
            "a citation must resolve to exactly one"
        )
    hits = text.find(quote)
    if len(hits) != 1:
        errors.append(f"quote occurs {len(hits)} times in {source}; needs exactly 1")
        return errors, None
    start, end = hits[0]
    actual = text.section_at(start)
    if actual != section:
        errors.append(f"quote is in section {actual} (line {text.line_of(start)}), not {section}")
    return errors, (start, end)


def load_registry(report):
    if not REGISTRY.exists():
        return {"properties": [], "verified_checkers": []}
    return load_json(REGISTRY, report) or {"properties": [], "verified_checkers": []}


def question_anchors():
    if not QUESTIONS.exists():
        return set()
    return set(re.findall(r"^#{2,4}\s+(Q-[0-9]+)\b", QUESTIONS.read_text(encoding="utf-8"), re.M))


def check_registry(args):
    report = Report()
    clause_ids = {c.get("id") for _, _, c in load_inventory(Report())}
    reg = load_registry(report)
    anchors = question_anchors()
    seen = set()
    lean_checks = []
    for p in reg.get("properties", []):
        pid = p.get("id", "?")
        if pid in seen:
            report.error(f"{pid}: duplicate property id")
        seen.add(pid)
        for cid in p.get("clauses", []):
            if cid not in clause_ids:
                report.error(f"{pid}: cites unknown inventory clause {cid!r}")
        if not p.get("clauses"):
            report.error(f"{pid}: must cite at least one inventory clause")
        status = p.get("status")
        if status not in STATUSES:
            report.error(f"{pid}: status must be one of {STATUSES}")
            continue
        stmt = p.get("lean_statement", "")
        if status in ("proven", "refuted"):
            if not stmt:
                report.error(f"{pid}: a {status} property needs lean_statement")
            elif not re.search(r"[∀∃]|\bforall\b|\bexists\b", stmt) and not p.get("closed_ok"):
                report.error(
                    f"{pid}: lean_statement quantifies over nothing; a property about fixed "
                    "inputs is a test (set closed_ok with a reason if this is deliberate)"
                )
            if not p.get("theorem"):
                report.error(f"{pid}: a {status} property needs theorem")
            else:
                lean_checks.append((pid, status, stmt, p["theorem"]))
        if status == "refuted":
            repro = p.get("reproducer", "")
            if not repro or not ((ROOT / repro).exists() or repro.split("#")[-1] in anchors):
                report.error(
                    f"{pid}: a refuted property needs a reproducer: a path under the repo "
                    "or a QUESTIONS.md anchor (Q-n)"
                )
        if status == "question" and p.get("question") not in anchors:
            report.error(f"{pid}: question must name a QUESTIONS.md anchor (Q-n)")

    if args.lean and lean_checks:
        run_lean_checks(lean_checks, report)
    print(f"registry: {len(reg.get('properties', []))} properties")
    return report.done("registry")


def run_lean_checks(checks, report):
    """Elaborate each theorem against its registered type and list its axioms."""
    lines = ["import Esm", ""]
    for pid, status, stmt, thm in checks:
        target = f"¬ ({stmt})" if status == "refuted" else f"({stmt})"
        lines.append(f"-- {pid}")
        lines.append(f"example : {target} := @{thm}")
        lines.append(f"#print axioms {thm}")
    audit = FORMAL / ".lake" / "audit" / "Audit.lean"
    audit.parent.mkdir(parents=True, exist_ok=True)
    audit.write_text("\n".join(lines) + "\n", encoding="utf-8")
    proc = subprocess.run(
        ["lake", "env", "lean", str(audit)],
        cwd=FORMAL,
        capture_output=True,
        text=True,
    )
    out = proc.stdout + proc.stderr
    if proc.returncode != 0:
        report.error("theorem/statement mismatch or missing theorem:\n" + out.strip())
        return
    for m in re.finditer(r"'([^']+)' depends on axioms: \[([^\]]*)\]", out):
        extra = {a.strip() for a in m.group(2).split(",")} - ALLOWED_AXIOMS
        if extra:
            report.error(f"{m.group(1)} depends on non-standard axioms {sorted(extra)}")


def check_tokens(args):
    report = Report()
    reg = load_registry(Report())
    allowed = {str(FORMAL / f) for f in reg.get("verified_checkers", [])}
    for path in sorted(FORMAL.rglob("*.lean")):
        if ".lake" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        # Line comments and block comments may mention a token; strip them.
        code = re.sub(r"/-.*?-/", "", text, flags=re.S)
        code = re.sub(r"--[^\n]*", "", code)
        for name, rx in FORBIDDEN_TOKENS.items():
            if name == "native_decide" and str(path) in allowed:
                continue
            for m in rx.finditer(code):
                line = code.count("\n", 0, m.start()) + 1
                report.error(f"{path.relative_to(ROOT)}: {name} (near stripped line {line})")
    return report.done("tokens")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    inv = sub.add_parser("inventory")
    inv.add_argument("--source", choices=SPEC_FILES)
    inv.add_argument("--lines", help="restrict MUST coverage to lines A-B of --source")
    reg = sub.add_parser("registry")
    reg.add_argument("--lean", action="store_true", help="elaborate theorems against statements")
    sub.add_parser("tokens")
    sub.add_parser("all")
    args = ap.parse_args()
    if args.cmd == "inventory":
        ok = check_inventory(args)
    elif args.cmd == "registry":
        ok = check_registry(args)
    elif args.cmd == "tokens":
        ok = check_tokens(args)
    else:
        args.source = args.lines = None
        args.lean = True
        ok = all([check_tokens(args), check_inventory(args), check_registry(args)])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
