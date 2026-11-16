#!/usr/bin/env python3
"""The cross-binding gate for the document source formats (CONFORMANCE §5.59).

Every participant (the five bindings and `esm-lean`, the executable Lean model) prints
every corpus document as Markdown and as Typst, and every participant reads back every
text any participant printed. The gate passes when, for every document `d`, every
format, every printer `P` and every reader `Q`:

* `canon_P(d)` is the reference canonical form `R(d)`;
* `print_P(d)` is, byte for byte, the reference participant's text;
* `parse_Q(print_P(d))` is `R(d)`.

`R(d)` is `esm-lean canon` of the corpus file itself, so no participant is ever compared
only with itself: a printer and a reader that drift together in one binding still
disagree with the model and with the other four.

The corpus is every `.esm` under `tests/` that is a JSON object (the corpus of
`formal/scripts/doc-corpus.py` and of each binding's own round-trip test). It is read at
run time and never stored.

Subcommands (from the repository root):

    corpus  --out FILE                       write the corpus manifest
    print   --participant P --out DIR        P prints the corpus into DIR
    parse   --participant P --prints DIR...  P reads every distinct printed text
            --out DIR
    compare --prints DIR... --parses DIR...  check the three rules; exit 1 on a failure
            [--reference lean] [--summary FILE]
    all     --work DIR [--participants ...]  print, parse and compare, in one go

A prints or parses directory is named after its participant (`.../prints/rust`), or after
the CI artifact it came from (`prints-rust`, `parses-rust`).

Each binding has a batch driver that takes `print MANIFEST OUT` or `parse MANIFEST OUT`
(see `DRIVERS`). A print manifest is a JSON array of `{"id", "path"}`; the driver
writes `<id>.canon.json`, `<id>.md` and `<id>.typ`, or `<id>.<step>.error` (step
`canon`, `md` or `typ`) holding the message when a step fails. A parse manifest is a
JSON array of `{"id", "path", "format"}` (`markdown` or `typst`); the driver writes
`<id>.json`, or `<id>.error`.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GATE_DIR = ROOT / "scripts" / "document_format_gate"
PARTICIPANTS = ("lean", "rust", "julia", "python", "typescript", "go")
FORMATS = (("markdown", "md"), ("typst", "typ"))
INT64_MIN, INT64_MAX = -(2**63), 2**63 - 1
SHOWN = 20  # failures listed per kind
CRASHES = 20  # driver crashes tolerated in one run before the run is abandoned


def _doc_corpus():
    """formal/scripts/doc-corpus.py, the Lean round trip, whose corpus and `esm-lean`
    call the gate shares."""
    spec = importlib.util.spec_from_file_location(
        "doc_corpus", ROOT / "formal/scripts/doc-corpus.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DOC_CORPUS = _doc_corpus()


# ---------------------------------------------------------------- corpus


def corpus() -> list[dict]:
    """The corpus of formal/scripts/doc-corpus.py (the JSON-object `.esm` files under
    tests/), as `{"id", "path"}` in path order."""
    files, _ = DOC_CORPUS.corpus()
    return [{"id": DOC_CORPUS.doc_id(f), "path": str(f)} for f in files]


# ---------------------------------------------------------------- drivers


def _lean_binary(args) -> Path:
    b = Path(args.lean or os.environ.get("ESM_LEAN") or ROOT / "formal/.lake/build/bin/esm-lean")
    if not b.is_file():
        sys.exit(
            f"esm-lean not found at {b} (build it with `lake build` in formal/, or pass --lean)"
        )
    return b.resolve()


def _python() -> str:
    return os.environ.get("ESM_GATE_PYTHON") or sys.executable


def driver_command(participant: str, args) -> list[str] | None:
    """The command line of a binding's batch driver; None for the Lean participant."""
    if participant == "lean":
        return None
    if participant == "rust":
        exe = os.environ.get("ESM_GATE_RUST")
        if exe:
            return [exe]
        return [
            "cargo",
            "run",
            "--quiet",
            "--manifest-path",
            str(ROOT / "pkg/earthsci-ast-rs/Cargo.toml"),
            "--features",
            "conformance-adapters",
            "--bin",
            "earthsci-document-format-adapter-rust",
            "--",
        ]
    if participant == "go":
        exe = os.environ.get("ESM_GATE_GO")
        if exe:
            return [exe]
        return ["go", "run", "./cmd/esm-document-format"]
    if participant == "python":
        return [_python(), str(GATE_DIR / "python_driver.py")]
    if participant == "typescript":
        return ["node", str(GATE_DIR / "typescript_driver.mjs")]
    if participant == "julia":
        project = os.environ.get("ESM_GATE_JULIA_PROJECT") or str(ROOT / "pkg/EarthSciAST.jl")
        return [
            "julia",
            "--startup-file=no",
            f"--project={project}",
            str(GATE_DIR / "julia_driver.jl"),
        ]
    sys.exit(f"unknown participant {participant!r}")


def _driver_cwd(participant: str) -> Path:
    return ROOT / "pkg/earthsci-ast-go" if participant == "go" else ROOT


def _missing_steps(mode: str, item: dict, out: Path) -> list[str]:
    """The output steps of one manifest item that a driver has not written yet: for
    `print`, `canon` (then nothing else is expected), `md` and `typ`; for `parse`, the
    single step `""`."""
    stem = out / item["id"]
    if mode == "parse":
        return [] if any(Path(f"{stem}{s}").is_file() for s in (".json", ".error")) else [""]
    if Path(f"{stem}.canon.error").is_file():
        return []
    if not Path(f"{stem}.canon.json").is_file():
        return ["canon"]
    return [
        ext
        for _, ext in FORMATS
        if not any(Path(f"{stem}.{ext}{s}").is_file() for s in ("", ".error"))
    ]


def run_driver(participant: str, mode: str, manifest: list[dict], out: Path, args) -> None:
    """Run a participant's driver over the manifest. A driver that dies partway (a stack
    overflow or out-of-memory error is fatal in Go and Julia, and no driver can turn it
    into a per-item error) is blamed on the item it was on, the first one without output
    (drivers work in manifest order), which gets an `.error` file; the driver is then
    run again on the items after it."""
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if participant == "lean":
        _lean(mode, manifest, out, _lean_binary(args), args.jobs)
        return
    mpath = out.parent / f".{out.name}.{mode}-manifest.json"
    print(f"[{participant}] {mode}: {len(manifest)} items", flush=True)
    todo, crashes = manifest, 0
    while todo:
        mpath.write_text(json.dumps(todo), encoding="utf-8")
        cmd = driver_command(participant, args) + [mode, str(mpath), str(out)]
        r = subprocess.run(cmd, cwd=_driver_cwd(participant))
        mpath.unlink()
        if r.returncode == 0:
            return
        i = next((i for i, it in enumerate(todo) if _missing_steps(mode, it, out)), None)
        # A driver that fails before its first item (a build or load error) is not a
        # crash on that item.
        if i is None or (todo is manifest and i == 0):
            sys.exit(f"[{participant}] {mode} driver exited {r.returncode}")
        crashes += 1
        item = todo[i]
        msg = f"the {participant} driver crashed (exit {r.returncode}) on this item"
        print(f"[{participant}] {msg}: {item['id']}", flush=True)
        for step in _missing_steps(mode, item, out):
            Path(f"{out / item['id']}{'.' + step if step else ''}.error").write_text(
                msg, encoding="utf-8"
            )
        if crashes >= CRASHES:
            sys.exit(f"[{participant}] {mode} driver crashed {crashes} times; giving up")
        todo = todo[i + 1 :]


def _lean(mode, manifest, out: Path, binary: Path, jobs):
    def call(lean_mode, path):
        rc, stdout, stderr = DOC_CORPUS.run(binary, lean_mode, path)
        return (stdout, None) if rc == 0 else (None, stderr or f"exit {rc}")

    def print_one(item):
        canon, err = call("canon", item["path"])
        if canon is None:
            (out / f"{item['id']}.canon.error").write_text(err, encoding="utf-8")
            return
        cpath = out / f"{item['id']}.canon.json"
        cpath.write_bytes(canon)
        for _, ext in FORMATS:
            text, err = call(f"print-{ext}", cpath)
            if text is None:
                (out / f"{item['id']}.{ext}.error").write_text(err, encoding="utf-8")
            else:
                (out / f"{item['id']}.{ext}").write_bytes(text)

    def parse_one(item):
        ext = dict(FORMATS)[item["format"]]
        doc, err = call(f"parse-{ext}", item["path"])
        if doc is None:
            (out / f"{item['id']}.error").write_text(err, encoding="utf-8")
        else:
            (out / f"{item['id']}.json").write_bytes(doc)

    print(f"[lean] {mode}: {len(manifest)} items", flush=True)
    with ThreadPoolExecutor(jobs or os.cpu_count() or 1) as pool:
        list(pool.map(print_one if mode == "print" else parse_one, manifest))


# ---------------------------------------------------------------- texts


def text_key(fmt: str, data: bytes) -> str:
    """A printed text's identity: its format and its bytes."""
    return hashlib.sha256(fmt.encode() + b"\0" + data).hexdigest()[:24]


def printed_texts(prints: list[Path]) -> dict[str, dict]:
    """Every distinct printed text: key -> {"id", "path", "format"}."""
    texts = {}
    for d in prints:
        for fmt, ext in FORMATS:
            for f in sorted(d.glob(f"*.{ext}")):
                k = text_key(fmt, f.read_bytes())
                texts.setdefault(k, {"id": k, "path": str(f.resolve()), "format": fmt})
    return texts


# ---------------------------------------------------------------- compare


def normalize(v):
    """A JSON value with every number in its canonical kind (CONFORMANCE §5.5.3.1): an
    integral value in Int64 is an integer, any other number a binary64. An integer past
    the binary64 range is an infinity, as `json.loads` reads `1e400`."""
    if isinstance(v, bool) or v is None or isinstance(v, str):
        return v
    if isinstance(v, int):
        if INT64_MIN <= v <= INT64_MAX:
            return v
        try:
            return float(v)
        except OverflowError:
            return math.inf if v > 0 else -math.inf
    if isinstance(v, float):
        if v.is_integer() and INT64_MIN <= v <= INT64_MAX:
            return int(v)
        return v
    if isinstance(v, list):
        return [normalize(x) for x in v]
    return {k: normalize(x) for k, x in v.items()}


def _load(path: Path):
    try:
        return normalize(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError, RecursionError) as e:
        return e


def _first_diff(a: bytes, b: bytes) -> str:
    """Where text `b` first differs from the reference `a`. Lines keep their endings, so
    a `\\r\\n` or a missing final newline shows in the line quoted."""
    al = a.decode("utf-8", "replace").splitlines(keepends=True)
    bl = b.decode("utf-8", "replace").splitlines(keepends=True)
    for i, (x, y) in enumerate(zip(al, bl)):
        if x != y:
            return f"line {i + 1}: {y!r} (reference {x!r})"
    if len(al) != len(bl):
        return f"length {len(bl)} lines (reference {len(al)})"
    return "differs in bytes that are not valid UTF-8"


def compare(
    prints: list[Path], parses: list[Path], reference: str, docs: list[dict], required: list[str]
):
    """The gate's verdict: (report lines, failure count). Every participant in
    `required` must have both printed and read: a participant whose output is missing
    altogether (a lost CI artifact, say) would otherwise drop out of the matrix and
    leave a smaller gate that passes."""
    # A directory is named after its participant, optionally with the `prints-` or
    # `parses-` prefix of the CI artifact it was downloaded from.
    pdir = {d.name.removeprefix("prints-"): d for d in prints}
    qdir = {d.name.removeprefix("parses-"): d for d in parses}
    if reference not in pdir:
        sys.exit(f"no prints from the reference participant {reference!r}")
    fails: dict[str, list[str]] = {}

    def fail(kind, msg):
        fails.setdefault(kind, []).append(msg)

    # A missing participant fails the gate, but the others are still compared, so one
    # participant's broken job does not hide what the rest found.
    for p in required:
        for what, dirs in (("prints", pdir), ("reads", qdir)):
            if p not in dirs:
                fail("missing participants", f"no {what} from {p}")
    printers = [p for p in PARTICIPANTS if p in pdir] + sorted(set(pdir) - set(PARTICIPANTS))
    readers = [p for p in PARTICIPANTS if p in qdir] + sorted(set(qdir) - set(PARTICIPANTS))
    ref_dir = pdir[reference]

    refs = {}
    for doc in docs:
        r = ref_dir / f"{doc['id']}.canon.json"
        refs[doc["id"]] = _load(r) if r.is_file() else None
        if refs[doc["id"]] is None or isinstance(refs[doc["id"]], Exception):
            fail(f"{reference} canon", f"{doc['id']}: no reference canonical form")

    # Rule 1: every participant's canonical form is the reference's.
    canon_ok = {}
    for p in printers:
        ok = 0
        for doc in docs:
            ref = refs[doc["id"]]
            got_path = pdir[p] / f"{doc['id']}.canon.json"
            if ref is None or isinstance(ref, Exception):
                continue
            if not got_path.is_file():
                fail(f"{p} canon", f"{doc['id']}: {_error_text(pdir[p], doc['id'], 'canon')}")
            elif _load(got_path) != ref:
                fail(f"{p} canon", f"{doc['id']}: differs from {reference} canon")
            else:
                ok += 1
        canon_ok[p] = ok

    # Rule 2: every participant prints the reference's bytes.
    print_ok = {}
    keys = {}  # (printer, doc id, fmt) -> text key
    for p in printers:
        for fmt, ext in FORMATS:
            ok = 0
            for doc in docs:
                got = pdir[p] / f"{doc['id']}.{ext}"
                want = ref_dir / f"{doc['id']}.{ext}"
                if not got.is_file():
                    fail(f"{p} print {fmt}", f"{doc['id']}: {_error_text(pdir[p], doc['id'], ext)}")
                    continue
                data = got.read_bytes()
                keys[(p, doc["id"], fmt)] = text_key(fmt, data)
                if not want.is_file():
                    continue
                wdata = want.read_bytes()
                if data != wdata:
                    fail(
                        f"{p} print {fmt}",
                        f"{doc['id']}: {_first_diff(wdata, data)}",
                    )
                else:
                    ok += 1
            print_ok[(p, fmt)] = ok

    # Rule 3: every reader reads every printer's text as the reference canonical form.
    cells = {}
    parsed_cache: dict[tuple[str, str], object] = {}
    for q in readers:
        for p in printers:
            for fmt, _ in FORMATS:
                ok = 0
                for doc in docs:
                    k = keys.get((p, doc["id"], fmt))
                    ref = refs[doc["id"]]
                    if k is None or ref is None or isinstance(ref, Exception):
                        continue
                    if (q, k) not in parsed_cache:
                        j = qdir[q] / f"{k}.json"
                        if j.is_file():
                            parsed_cache[(q, k)] = _load(j)
                        else:
                            e = qdir[q] / f"{k}.error"
                            parsed_cache[(q, k)] = RuntimeError(
                                "refused: "
                                + (e.read_text(encoding="utf-8").strip().splitlines() or [""])[0][
                                    :200
                                ]
                                if e.is_file()
                                else "no output for this text"
                            )
                    got = parsed_cache[(q, k)]
                    if isinstance(got, Exception):
                        fail(f"{q} reads {p} {fmt}", f"{doc['id']}: {got}")
                    elif got != ref:
                        fail(f"{q} reads {p} {fmt}", f"{doc['id']}: reads a different document")
                    else:
                        ok += 1
                cells[(q, p, fmt)] = ok

    n = len(docs)
    lines = [
        "## Document formats: cross-binding gate",
        "",
        f"{n} corpus documents. Reference canonical form and texts: `{reference}`.",
        "",
        "| Participant | canonical form | prints Markdown | prints Typst |",
        "|---|---|---|---|",
    ]
    for p in printers:
        lines.append(
            f"| {p} | {_frac(canon_ok[p], n)} | {_frac(print_ok[(p, 'markdown')], n)} "
            f"| {_frac(print_ok[(p, 'typst')], n)} |"
        )
    for fmt, _ in FORMATS:
        lines += [
            "",
            f"**{fmt.capitalize()}: documents read back as the reference canonical form** "
            "(row: printer, column: reader)",
            "",
            "| printer \\ reader | " + " | ".join(readers) + " |",
            "|---|" + "---|" * len(readers),
        ]
        for p in printers:
            lines.append(
                f"| {p} | " + " | ".join(_frac(cells[(q, p, fmt)], n) for q in readers) + " |"
            )
    total = sum(len(v) for v in fails.values())
    lines += ["", f"**{'PASS' if total == 0 else 'FAIL'}**: {total} failures."]
    for kind, msgs in sorted(fails.items()):
        lines += ["", f"### {kind}: {len(msgs)}", ""]
        lines += [f"- {m}" for m in msgs[:SHOWN]]
        if len(msgs) > SHOWN:
            lines.append(f"- … and {len(msgs) - SHOWN} more")
    return lines, total


def _frac(ok, n):
    return f"{ok}/{n}" if ok == n else f"**{ok}/{n}**"


def _error_text(d: Path, doc_id: str, step: str) -> str:
    e = d / f"{doc_id}.{step}.error"
    if e.is_file():
        return "refused: " + (e.read_text(encoding="utf-8").strip().splitlines() or [""])[0][:200]
    return "no output"


# ---------------------------------------------------------------- commands


def cmd_corpus(args):
    docs = corpus()
    Path(args.out).write_text(json.dumps(docs, indent=1), encoding="utf-8")
    print(f"{len(docs)} corpus documents")


def _docs(args) -> list[dict]:
    docs = json.loads(Path(args.corpus).read_text(encoding="utf-8")) if args.corpus else corpus()
    if len(docs) < 100 and not getattr(args, "limit", 0):
        sys.exit(f"only {len(docs)} corpus documents found")
    return docs


def cmd_print(args):
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    run_driver(args.participant, "print", _docs(args), out, args)


def cmd_parse(args):
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    texts = printed_texts([Path(p) for p in args.prints])
    run_driver(args.participant, "parse", sorted(texts.values(), key=lambda t: t["id"]), out, args)


def cmd_compare(args):
    lines, total = compare(
        [Path(p) for p in args.prints],
        [Path(p) for p in args.parses],
        args.reference,
        _docs(args),
        args.participants.split(","),
    )
    report = "\n".join(lines) + "\n"
    print(report)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(report)
    sys.exit(1 if total else 0)


def cmd_all(args):
    work = Path(args.work)
    parts = args.participants.split(",")
    docs_path = work / "corpus.json"
    work.mkdir(parents=True, exist_ok=True)
    docs = corpus()[: args.limit or None]
    docs_path.write_text(json.dumps(docs), encoding="utf-8")
    args.corpus = str(docs_path)
    for p in parts:
        out = work / "prints" / p
        if out.exists():
            shutil.rmtree(out)
        run_driver(p, "print", docs, out, args)
    prints = [work / "prints" / p for p in parts]
    texts = sorted(printed_texts(prints).values(), key=lambda t: t["id"])
    for p in parts:
        out = work / "parses" / p
        if out.exists():
            shutil.rmtree(out)
        run_driver(p, "parse", texts, out, args)
    args.prints = [str(x) for x in prints]
    args.parses = [str(work / "parses" / p) for p in parts]
    cmd_compare(args)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(s):
        s.add_argument(
            "--lean", help="the esm-lean executable (default: $ESM_LEAN, then formal/.lake)"
        )
        s.add_argument("--jobs", type=int, default=0, help="esm-lean processes at once")
        s.add_argument("--corpus", help="a manifest from `corpus` (default: read tests/ now)")

    s = sub.add_parser("corpus")
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_corpus)

    s = sub.add_parser("print")
    common(s)
    s.add_argument("--participant", required=True, choices=PARTICIPANTS)
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_print)

    s = sub.add_parser("parse")
    common(s)
    s.add_argument("--participant", required=True, choices=PARTICIPANTS)
    s.add_argument("--prints", nargs="+", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_parse)

    s = sub.add_parser("compare")
    common(s)
    s.add_argument("--prints", nargs="+", required=True)
    s.add_argument("--parses", nargs="+", required=True)
    s.add_argument("--reference", default="lean")
    s.add_argument(
        "--participants",
        default=",".join(PARTICIPANTS),
        help="the participants that must all be present (default: all six)",
    )
    s.add_argument("--summary", help="append the report here (e.g. $GITHUB_STEP_SUMMARY)")
    s.set_defaults(func=cmd_compare)

    s = sub.add_parser("all")
    common(s)
    s.add_argument("--work", required=True)
    s.add_argument("--participants", default=",".join(PARTICIPANTS))
    s.add_argument("--limit", type=int, default=0, help="only the first N documents (a smoke run)")
    s.add_argument("--reference", default="lean")
    s.add_argument("--summary")
    s.set_defaults(func=cmd_all)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
