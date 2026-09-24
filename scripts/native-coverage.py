#!/usr/bin/env python3
"""Native coverage ledger (the `native_coverage` tier).

A census builds every document of the corpus — every ``.esm`` under ``tests/``
plus every ``.esm`` in a checkout of EarthSciML/EarthSciModels — through
``esm_problem`` twice per binding, once under ``native`` and once under
``interpreter``. A document the interpreter builds and native does not is a
NATIVE COVERAGE GAP. Each binding's gaps are listed, with the refusal's code,
rule and reason, in a committed ledger
(``tests/conformance/native_coverage/<binding>.json``), and the list may only
shrink: the same one-way rule the compiler-agreement tier's per-fixture
``required`` map and its named exclusions follow (CONFORMANCE_SPEC §5.44.3).

The check compares a fresh census against the ledger:

  * a gap the ledger does not name is RED — native lost coverage;
  * a ledger entry native now builds is RED, with "remove this entry" — a stale
    entry would let the same document regress again unnoticed;
  * a ledger entry that is no longer a gap for another reason (the interpreter
    stopped building it too, the document left the corpus or became an invalid
    fixture) is RED the same way, since the ledger lists gaps and nothing else;
  * a ledger entry whose refusal CODE drifted is RED — the refusal the ledger
    excuses is not the one native now raises;
  * a census that has no record for some corpus document is RED — a document
    the census lost is not a document native builds.

Excluded from the gap list, as the research census classified them: documents
under an ``invalid/`` directory (they are meant to fail, and a refusal there is
not coverage), and library fragments (template or coupling libraries, which are
not runnable documents).

Subcommands:

    corpus        list the corpus, one absolute path per line
    check         compare a census against the committed ledger (exit 1 on drift)
    write-ledger  write the ledger from a census (the baseline; see the README)
    self-test     drive the check through every arm on synthetic records, and
                  validate the committed ledgers' shape

Usage:
    python3 scripts/native-coverage.py corpus --earthscimodels ../EarthSciModels --out corpus.txt
    python3 scripts/native-coverage.py check --binding julia \\
        --census out/julia_native.jsonl --census-interpreter out/julia_interpreter.jsonl \\
        --corpus corpus.txt --earthscimodels ../EarthSciModels
    python3 scripts/native-coverage.py check --binding rust --census out/rust.jsonl \\
        --corpus corpus.txt --earthscimodels ../EarthSciModels
    python3 scripts/native-coverage.py self-test

The census drivers are ``pkg/EarthSciAST.jl/scripts/compiler_census.jl`` (Julia,
one sweep per compiler) and ``pkg/earthsci-ast-rs/examples/compiler_census.rs``
(Rust, both compilers per document); ``scripts/native-coverage-census.sh`` runs
both and then this check.

Exit codes:
    0  the census matches the ledger exactly, or the self-test passed
    1  the census and the ledger disagree, the census is incomplete, or the
       self-test failed
    2  a usage or input error (a missing file, a malformed ledger)
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
TIER_DIR = REPO_ROOT / "tests" / "conformance" / "native_coverage"
BINDINGS = ("julia", "rust")
# The prefix a corpus path outside this repository is recorded under.
MODELS_PREFIX = "EarthSciModels/"
REASON_CHARS = 400

# A library fragment is a template or coupling library: it is imported by other
# documents and has no model of its own to build. These are the messages the
# research census classified as such.
LIBRARY_FRAGMENT = re.compile(
    r"nothing to flatten|coupling_import_not_library|is_coupling_library|"
    r"template_import_is_coupling"
)


class InputError(Exception):
    """A usage or input error: exit 2, no verdict."""


# ─────────────────────────────────────────────────────────────────────────────
# The corpus
# ─────────────────────────────────────────────────────────────────────────────


def list_corpus(repo_root: Path, models_root: Path | None) -> list[Path]:
    """Every ``.esm`` under ``<repo>/tests`` and under the EarthSciModels checkout."""
    docs = sorted(p.resolve() for p in (repo_root / "tests").rglob("*.esm"))
    if models_root is not None:
        docs += sorted(
            p.resolve() for p in models_root.rglob("*.esm") if ".git" not in p.parts
        )
    return docs


def relativize(path: str, repo_root: Path, models_root: Path | None) -> str:
    """A census path as the ledger records it: ``tests/…`` or ``EarthSciModels/…``."""
    p = Path(path).resolve()
    try:
        return p.relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        pass
    if models_root is not None:
        try:
            return MODELS_PREFIX + p.relative_to(models_root.resolve()).as_posix()
        except ValueError:
            pass
    raise InputError(f"{path} is under neither {repo_root} nor the EarthSciModels checkout")


def is_invalid_fixture(rel: str) -> bool:
    return "/invalid/" in f"/{rel}"


# ─────────────────────────────────────────────────────────────────────────────
# Census records → one outcome per document per compiler
# ─────────────────────────────────────────────────────────────────────────────


def _squash(text: str | None) -> str:
    return " ".join((text or "").split())[:REASON_CHARS]


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise InputError(f"census file {path} does not exist")
    rows = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or '"marker"' in line and '"start"' in line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as e:
            raise InputError(f"{path}:{n}: not JSON ({e})") from e
    return rows


def julia_outcome(rec: dict[str, Any]) -> dict[str, Any]:
    """One Julia census record (compiler_census.jl) as an outcome.

    Only the front door counts: ``esm_problem`` must build. The census falls back
    to ``_build_evaluator`` for documents that need providers or a model
    selection, but a document only the fallback builds is not one a caller can
    build."""
    if rec.get("ok") and rec.get("entry") == "esm_problem":
        return {"ok": True}
    status = rec.get("status")
    if status in ("timeout", "crashed", "worker_load_failure"):
        return {"ok": False, "code": status, "rule": None,
                "reason": _squash(rec.get("error_type"))}
    code = rec.get("esm_problem_error_code") or rec.get("error_code") or \
        rec.get("esm_problem_error_type") or rec.get("error_type") or "error"
    msg = rec.get("esm_problem_error_message") or rec.get("error_message") or ""
    m = re.search(r"refuses '([^']*)'", msg)
    return {"ok": False, "code": code, "rule": m.group(1) if m else None,
            "reason": _squash(msg)}


def rust_outcome(rec: dict[str, Any], tag: str) -> dict[str, Any]:
    """One compiler's half of a Rust census record (examples/compiler_census.rs)."""
    if rec.get("killed"):
        return {"ok": False, "code": "killed", "rule": None,
                "reason": _squash(f"exit {rec.get('rc')}: {rec.get('stderr_tail', '')}")}
    if rec.get(f"{tag}_ok"):
        return {"ok": True}
    variant = rec.get(f"{tag}_err_variant") or "error"
    if variant == "CompilerRefusedRule":
        tier = rec.get(f"{tag}_refused_tier")
        reason = rec.get(f"{tag}_refused_reason") or ""
        return {"ok": False, "code": "compiler_refused_rule",
                "rule": rec.get(f"{tag}_refused_rule"),
                "reason": _squash(f"[{tier}] {reason}" if tier else reason)}
    return {"ok": False, "code": variant, "rule": None,
            "reason": _squash(rec.get(f"{tag}_err"))}


def outcomes(binding: str, census: Path, census_interpreter: Path | None,
             repo_root: Path, models_root: Path | None
             ) -> dict[str, dict[str, dict[str, Any]]]:
    """``{relative path: {"native": outcome, "interpreter": outcome}}``."""
    out: dict[str, dict[str, dict[str, Any]]] = {}
    if binding == "julia":
        if census_interpreter is None:
            raise InputError("julia needs --census (native) and --census-interpreter")
        for compiler, path in (("native", census), ("interpreter", census_interpreter)):
            for rec in _read_jsonl(path):
                if not rec.get("path"):
                    continue
                c = rec.get("compiler")
                if c is not None and c != compiler:
                    raise InputError(f"{path}: a record answers for compiler {c!r}, "
                                     f"not {compiler!r}: the two census files are swapped")
                rel = relativize(rec["path"], repo_root, models_root)
                out.setdefault(rel, {})[compiler] = julia_outcome(rec)
    elif binding == "rust":
        for rec in _read_jsonl(census):
            if not rec.get("path"):
                continue
            rel = relativize(rec["path"], repo_root, models_root)
            out[rel] = {"native": rust_outcome(rec, "native"),
                        "interpreter": rust_outcome(rec, "interpreter")}
    else:
        raise InputError(f"unknown binding {binding!r}")
    return out


def classify(outs: dict[str, dict[str, dict[str, Any]]]) -> dict[str, Any]:
    """Split the census into the native gap and everything else, with counts."""
    gaps: dict[str, dict[str, Any]] = {}
    counts: Counter[str] = Counter()
    for rel, o in outs.items():
        n, i = o.get("native"), o.get("interpreter")
        if n is None or i is None:
            continue
        if is_invalid_fixture(rel):
            counts["invalid fixture (excluded)"] += 1
            continue
        if not n["ok"] and LIBRARY_FRAGMENT.search(n.get("reason") or ""):
            counts["library fragment (excluded)"] += 1
            continue
        key = {(True, True): "both build", (False, True): "native gap",
               (True, False): "native only", (False, False): "both fail"}[(n["ok"], i["ok"])]
        counts[key] += 1
        if key == "native gap":
            gaps[rel] = {"path": rel, "code": n["code"], "rule": n.get("rule"),
                         "reason": n.get("reason") or ""}
    return {"gaps": gaps, "counts": dict(counts)}


# ─────────────────────────────────────────────────────────────────────────────
# The ledger
# ─────────────────────────────────────────────────────────────────────────────

ENTRY_KEYS = ("path", "code", "rule", "reason")


def load_ledger(path: Path, binding: str) -> dict[str, Any]:
    if not path.is_file():
        raise InputError(f"ledger {path} does not exist")
    try:
        led = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise InputError(f"{path}: not JSON ({e})") from e
    validate_ledger(led, path, binding)
    return led


def validate_ledger(led: Any, path: Path | str, binding: str) -> None:
    """The ledger's shape: one binding, native against interpreter, entries sorted
    by path, unique, each carrying the four fields."""
    if not isinstance(led, dict):
        raise InputError(f"{path}: the ledger must be a JSON object")
    for key, want in (("category", "native_coverage"), ("binding", binding),
                      ("compiler", "native"), ("reference_compiler", "interpreter")):
        if led.get(key) != want:
            raise InputError(f"{path}: {key!r} must be {want!r}, not {led.get(key)!r}")
    entries = led.get("entries")
    if not isinstance(entries, list):
        raise InputError(f"{path}: 'entries' must be a list")
    paths = []
    for k, e in enumerate(entries):
        if not isinstance(e, dict) or set(e) != set(ENTRY_KEYS):
            raise InputError(f"{path}: entries[{k}] must carry exactly {list(ENTRY_KEYS)}")
        if not isinstance(e["path"], str) or not isinstance(e["code"], str) or not e["code"]:
            raise InputError(f"{path}: entries[{k}] needs a string path and a non-empty code")
        if is_invalid_fixture(e["path"]):
            raise InputError(f"{path}: entries[{k}] names an invalid fixture, which the "
                             f"ledger never lists")
        paths.append(e["path"])
    if paths != sorted(paths):
        raise InputError(f"{path}: entries must be sorted by path")
    dup = [p for p, c in Counter(paths).items() if c > 1]
    if dup:
        raise InputError(f"{path}: duplicate entries for {dup}")


def compare(gaps: dict[str, dict[str, Any]], outs: dict[str, dict[str, dict[str, Any]]],
            ledger: dict[str, Any], ledger_name: str,
            corpus: list[str] | None) -> list[str]:
    """Every way the census and the ledger disagree, as a list of RED findings."""
    red: list[str] = []
    if corpus is not None:
        for rel in corpus:
            o = outs.get(rel, {})
            for c in ("native", "interpreter"):
                if c not in o:
                    red.append(f"census incomplete: no {c} record for {rel}")
    listed = {e["path"]: e for e in ledger["entries"]}
    for rel in sorted(gaps):
        g = gaps[rel]
        if rel not in listed:
            red.append(
                f"NEW native refusal: {rel} builds under interpreter and not under native "
                f"({g['code']}{', rule ' + repr(g['rule']) if g['rule'] else ''}): {g['reason']}. "
                f"The ledger only shrinks; fix native rather than add an entry.")
        elif listed[rel]["code"] != g["code"]:
            red.append(
                f"code drift: {rel} is ledgered as {listed[rel]['code']!r} but native now "
                f"answers {g['code']!r}: {g['reason']}. Update the entry's code and reason.")
    for rel in sorted(listed):
        if rel in gaps:
            continue
        o = outs.get(rel)
        if o is None or "native" not in o or "interpreter" not in o:
            why = "the document is not in the census"
        elif is_invalid_fixture(rel):
            why = "the document is an invalid fixture"
        elif o["native"]["ok"]:
            why = "native now builds it"
        elif not o["interpreter"]["ok"]:
            why = "the interpreter no longer builds it either"
        else:
            why = "it is excluded from the gap list (library fragment)"
        red.append(f"stale entry: {rel}: {why}. Remove this entry from {ledger_name}.")
    return red


def render_ledger(binding: str, gaps: dict[str, dict[str, Any]], counts: dict[str, int],
                  measured: dict[str, Any]) -> str:
    led = {
        "category": "native_coverage",
        "version": "1.0",
        "binding": binding,
        "compiler": "native",
        "reference_compiler": "interpreter",
        "$comment": (
            "Every corpus document the interpreter builds through esm_problem and native "
            "does not, with native's refusal. The list only shrinks: a document missing "
            "from it that native refuses is RED, and an entry native now builds is RED "
            "until it is removed. See README.md in this directory."),
        "measured": dict(measured, counts=dict(sorted(counts.items()))),
        "entries": [{k: gaps[p][k] for k in ENTRY_KEYS} for p in sorted(gaps)],
    }
    return json.dumps(led, indent=2, ensure_ascii=False) + "\n"


def _git_head(path: Path) -> str | None:
    try:
        return subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], check=True,
                              capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────


def _roots(args) -> tuple[Path, Path | None]:
    repo = Path(args.repo_root).resolve()
    models = Path(args.earthscimodels).resolve() if args.earthscimodels else None
    if models is not None and not models.is_dir():
        raise InputError(f"--earthscimodels {models} is not a directory")
    return repo, models


def _load_corpus(args, repo: Path, models: Path | None) -> list[str] | None:
    if not args.corpus:
        return None
    return [relativize(ln.strip(), repo, models)
            for ln in Path(args.corpus).read_text().splitlines() if ln.strip()]


def cmd_corpus(args) -> int:
    repo, models = _roots(args)
    docs = list_corpus(repo, models)
    text = "".join(f"{p}\n" for p in docs)
    if args.out:
        Path(args.out).write_text(text)
        print(f"corpus: {len(docs)} documents -> {args.out}")
    else:
        sys.stdout.write(text)
    return 0


def _census(args):
    repo, models = _roots(args)
    outs = outcomes(args.binding, Path(args.census),
                    Path(args.census_interpreter) if args.census_interpreter else None,
                    repo, models)
    return repo, models, outs, classify(outs)


def cmd_check(args) -> int:
    repo, models, outs, cls = _census(args)
    ledger_path = Path(args.ledger) if args.ledger else TIER_DIR / f"{args.binding}.json"
    ledger = load_ledger(ledger_path, args.binding)
    red = compare(cls["gaps"], outs, ledger, str(ledger_path), _load_corpus(args, repo, models))
    counts = cls["counts"]
    print(f"native coverage ({args.binding}): {len(outs)} documents in the census; "
          + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
    print(f"  ledger {ledger_path}: {len(ledger['entries'])} entries; "
          f"census: {len(cls['gaps'])} native gaps")
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps({
            "binding": args.binding, "counts": counts,
            "gaps": [cls["gaps"][p] for p in sorted(cls["gaps"])],
            "ledger_entries": len(ledger["entries"]), "findings": red,
            "passed": not red}, indent=2) + "\n")
    for r in red:
        print(f"  RED  {r}")
    if red:
        print(f"native coverage ({args.binding}): FAILED, {len(red)} finding(s)")
        return 1
    print(f"native coverage ({args.binding}): the census matches the ledger")
    return 0


def cmd_write_ledger(args) -> int:
    repo, models, outs, cls = _census(args)
    corpus = _load_corpus(args, repo, models)
    if corpus is not None:
        missing = [r for r in corpus if len(outs.get(r, {})) < 2]
        if missing:
            print(f"refusing to write a ledger from an incomplete census: "
                  f"{len(missing)} corpus documents lack a record, e.g. {missing[:3]}")
            return 1
    if args.provenance:
        measured = json.loads(Path(args.provenance).read_text())
    else:
        measured = {
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "earthsciast_commit": _git_head(repo),
            "earthscimodels_commit": _git_head(models) if models else None,
        }
    measured["documents"] = len(outs)
    if args.note:
        measured["note"] = args.note
    ledger_path = Path(args.ledger) if args.ledger else TIER_DIR / f"{args.binding}.json"
    ledger_path.write_text(render_ledger(args.binding, cls["gaps"], cls["counts"], measured))
    print(f"wrote {ledger_path}: {len(cls['gaps'])} entries")
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# Self-test
# ─────────────────────────────────────────────────────────────────────────────


def _self_test() -> list[str]:
    """Drive `compare` through every arm on synthetic outcomes."""
    fails: list[str] = []
    ok = {"ok": True}

    def refused(code="compiler_refused_rule", reason="no compiled form"):
        return {"ok": False, "code": code, "rule": "M.x", "reason": reason}

    base = {
        "tests/valid/a.esm": {"native": refused(), "interpreter": ok},
        "tests/valid/b.esm": {"native": ok, "interpreter": ok},
        "tests/valid/c.esm": {"native": refused("parse_error"), "interpreter": refused("parse_error")},
        "tests/invalid/d.esm": {"native": refused(), "interpreter": ok},
        "tests/lib/e.esm": {"native": refused("error", "nothing to flatten"), "interpreter": ok},
        MODELS_PREFIX + "components/f.esm": {"native": refused(), "interpreter": ok},
    }
    cls = classify(base)
    if sorted(cls["gaps"]) != ["EarthSciModels/components/f.esm", "tests/valid/a.esm"]:
        fails.append(f"classify: gaps {sorted(cls['gaps'])}; the invalid fixture and the "
                     f"library fragment must be excluded")
    ledger = json.loads(render_ledger("rust", cls["gaps"], cls["counts"], {}))
    try:
        validate_ledger(ledger, "<synthetic>", "rust")
    except InputError as e:
        fails.append(f"a rendered ledger does not validate: {e}")
    corpus = sorted(base)

    def run(outs, led=ledger, corp=corpus):
        return compare(classify(outs)["gaps"], outs, led, "<ledger>", corp)

    def expect(label, outs, needle, led=ledger, corp=corpus):
        red = run(outs, led, corp)
        if needle is None and red:
            fails.append(f"{label}: expected green, got {red}")
        if needle is not None and not any(needle in r for r in red):
            fails.append(f"{label}: expected a finding containing {needle!r}, got {red}")

    expect("exact match", base, None)
    new = copy.deepcopy(base)
    new["tests/valid/b.esm"]["native"] = refused()
    expect("a new refusal", new, "NEW native refusal: tests/valid/b.esm")
    fixed = copy.deepcopy(base)
    fixed["tests/valid/a.esm"]["native"] = ok
    expect("native now builds a ledgered document", fixed,
           "native now builds it. Remove this entry")
    both = copy.deepcopy(base)
    both["tests/valid/a.esm"]["interpreter"] = refused()
    expect("the interpreter stops building a ledgered document", both,
           "the interpreter no longer builds it either. Remove this entry")
    drift = copy.deepcopy(base)
    drift["tests/valid/a.esm"]["native"] = refused("unbound_variable")
    expect("a drifted refusal code", drift, "code drift: tests/valid/a.esm")
    gone = copy.deepcopy(base)
    del gone["tests/valid/a.esm"]
    expect("a ledgered document leaves the corpus", gone,
           "not in the census. Remove this entry", corp=sorted(gone))
    lost = copy.deepcopy(base)
    del lost["tests/valid/b.esm"]["interpreter"]
    expect("a census that lost a record", lost, "census incomplete: no interpreter record")
    reason = copy.deepcopy(base)
    reason["tests/valid/a.esm"]["native"] = refused(reason="a reworded reason")
    expect("a reworded reason alone", reason, None)
    # The shape guard.
    for label, mutate in (
        ("unsorted entries", lambda l: l["entries"].reverse()),
        ("a duplicate entry", lambda l: l["entries"].append(dict(l["entries"][-1]))),
        ("an invalid fixture", lambda l: l["entries"].__setitem__(
            0, dict(l["entries"][0], path="tests/invalid/x.esm"))),
        ("a missing field", lambda l: l["entries"][0].pop("rule")),
        ("the wrong binding", lambda l: l.__setitem__("binding", "julia")),
    ):
        bad = copy.deepcopy(ledger)
        mutate(bad)
        try:
            validate_ledger(bad, "<synthetic>", "rust")
            fails.append(f"ledger shape: {label} was accepted")
        except InputError:
            pass
    # The two census readers.
    j = julia_outcome({"ok": False, "entry": None, "esm_problem_error_code": "compiler_refused_rule",
                       "esm_problem_error_message": "TreeWalkError: compiler=:native refuses 'M.y': why"})
    if (j["code"], j["rule"]) != ("compiler_refused_rule", "M.y"):
        fails.append(f"julia_outcome: {j}")
    if julia_outcome({"ok": True, "entry": "_build_evaluator"})["ok"]:
        fails.append("julia_outcome: a build only the fallback entry reaches counted as native building")
    r = rust_outcome({"native_ok": False, "native_err_variant": "CompilerRefusedRule",
                      "native_refused_rule": "M.z", "native_refused_tier": "continuous",
                      "native_refused_reason": "wholesale: unsupported op"}, "native")
    if (r["code"], r["rule"], r["reason"]) != ("compiler_refused_rule", "M.z",
                                              "[continuous] wholesale: unsupported op"):
        fails.append(f"rust_outcome: {r}")
    if rust_outcome({"killed": True, "rc": 124}, "interpreter")["code"] != "killed":
        fails.append("rust_outcome: a killed document must not read as a build")
    return fails


def cmd_self_test(args) -> int:
    fails = _self_test()
    for binding in BINDINGS:
        path = TIER_DIR / f"{binding}.json"
        try:
            led = load_ledger(path, binding)
        except InputError as e:
            fails.append(str(e))
            continue
        for e in led["entries"]:
            if e["path"].startswith("tests/") and not (REPO_ROOT / e["path"]).is_file():
                fails.append(f"{path}: entry {e['path']} names a file that does not exist; "
                             f"remove this entry")
        print(f"native coverage: {path.name} holds {len(led['entries'])} entries")
    for f in fails:
        print(f"  FAIL  {f}")
    if fails:
        print(f"native-coverage self-test: FAILED, {len(fails)} finding(s)")
        return 1
    print("native-coverage self-test: every arm of the check and both ledgers are sound")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def roots(p):
        p.add_argument("--repo-root", default=str(REPO_ROOT),
                       help="the EarthSciAST checkout the corpus's tests/ comes from")
        p.add_argument("--earthscimodels", default=None,
                       help="the EarthSciModels checkout (omit to leave it out)")

    p = sub.add_parser("corpus", help="list the corpus")
    roots(p)
    p.add_argument("--out", default=None)
    p.set_defaults(fn=cmd_corpus)

    for name, fn in (("check", cmd_check), ("write-ledger", cmd_write_ledger)):
        p = sub.add_parser(name)
        roots(p)
        p.add_argument("--binding", required=True, choices=BINDINGS)
        p.add_argument("--census", required=True,
                       help="Rust: the census JSON Lines; Julia: the native sweep")
        p.add_argument("--census-interpreter", default=None,
                       help="Julia: the interpreter sweep")
        p.add_argument("--corpus", default=None,
                       help="the corpus list the census ran over; every document in it "
                            "must have a record")
        p.add_argument("--ledger", default=None,
                       help="default: tests/conformance/native_coverage/<binding>.json")
        if name == "check":
            p.add_argument("--report", default=None, help="write a JSON report here")
        else:
            p.add_argument("--note", default=None, help="a note for the ledger's 'measured' block")
            p.add_argument("--provenance", default=None,
                           help="the census's provenance.json (the commits it ran on); "
                                "default: the checkouts' current HEADs")
        p.set_defaults(fn=fn)

    p = sub.add_parser("self-test")
    p.set_defaults(fn=cmd_self_test)

    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except InputError as e:
        print(f"native-coverage: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
