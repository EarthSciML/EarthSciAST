#!/usr/bin/env python3
"""Cross-binding property-corpus conformance runner (gt-3fbf).

Runs every binding's round-trip driver against the shared corpus at
``tests/property_corpus/expressions/`` and diffs the re-serialized output across
bindings.

THE SOURCE IS A PARTICIPANT (2026-09-01)
----------------------------------------
This runner used to collect ``serialize(parse(F))`` from each binding and
compare those outputs TO EACH OTHER. ``F`` itself was never a participant, so
the stage was *cross-binding-agreeing* (see tests/conformance/README.md, "What
shape is a conformance stage?"): five bindings that all drop the same
expression field agree perfectly and the stage passes on a shared wrong answer.
CONFORMANCE_SPEC.md calls this the strictest gate in the repo, which made the
blind spot worth closing rather than merely noting.

``F`` is now a sixth participant, under the name ``SOURCE``. The corpus
fixtures are hypothesis-generated CANONICAL expressions, so
``serialize(parse(F))`` must reproduce ``F`` exactly — a canonical input has no
legitimate normalization left to undergo — which is what makes them an oracle
at zero cost. The stage is now reference-comparing, and a divergence line names
which SIDE is wrong instead of only that the sides differ.

THE CONTRACT, AND WHY IT CHANGED (audit 2026-07-14, F7)
------------------------------------------------------
This gate used to be invoked with ``--require-divergence``, which exits 1 **iff
``diverged_count == 0``** — and without that flag it exited 0 unconditionally. So
in NEITHER polarity could actual cross-binding round-trip divergence fail the
harness, and fixing every divergence would have turned the build RED. The gate
was named for a property it could not test.

The two questions were conflated, and they are separate:

* **Is the round-trip CONFORMANT?**  Two bindings that re-serialize the same
  expression differently do not implement one format. That is a conformance
  failure and it must fail the build → ``--fail-on-divergence`` (what the harness
  now passes).
* **Is the CORPUS still interesting?**  A generator that has drifted into
  emitting only trivially-agreeing shapes is a corpus-quality problem. It is a
  real question, but it belongs to the corpus GENERATOR's own acceptance check —
  spelling it as "the conformance gate fails when the bindings agree" is what
  made the gate structurally incapable of failing on divergence.
  ``--require-divergence`` remains available for that use, and must not be the
  conformance gate.

A binding whose driver is unavailable is SKIPPED by default; pass
``--require-all-bindings`` (the harness does) to make a missing driver a failure,
because a binding that did not run has not been checked (audit F10).

OPTIONAL PARTICIPANTS: ``lean`` (the executable Lean model of the spec,
formal/) joins when ``$EARTHSCI_PROPERTY_CORPUS_ADAPTER_LEAN`` (or
``earthsci-property-corpus-adapter-lean`` on PATH) names a driver speaking the
same protocol as ``scripts/property_corpus/roundtrip_python.py``. It is then a
binding like the others, in the divergence comparison included. Unconfigured, it
is a named, unrequired exclusion (``summary.optional_exclusions``) that
``--require-all-bindings`` does not count.

Usage::

    python3 scripts/run-property-corpus-conformance.py [--corpus <dir>] \\
        [--output <results.json>] [--fail-on-divergence] [--require-all-bindings]
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CORPUS = PROJECT_ROOT / "tests" / "property_corpus" / "expressions"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from conformance_lib import (  # noqa: E402 — needs the sys.path bootstrap above
    NOT_CONFIGURED,
    OPTIONAL_BINDINGS,
    AdapterHarness,
    optional_exclusion,
)

# Optional participants (`lean`, the executable Lean model of the spec in
# formal/) are addressed the way every manifest runner addresses an adapter:
# $EARTHSCI_PROPERTY_CORPUS_ADAPTER_<NAME>, else
# earthsci-property-corpus-adapter-<name> on PATH. The command speaks THIS
# runner's driver protocol, not the manifest one: it is invoked as
# `<cmd> <fixture.json> ...` and prints `{fixture_name: {"ok": bool,
# "value"|"error": ...}}` on stdout, exactly like
# scripts/property_corpus/roundtrip_python.py.
_OPTIONAL_ADAPTERS = AdapterHarness("property-corpus")


@dataclass
class Binding:
    name: str
    cmd: List[str]
    cwd: Optional[Path] = None
    available: bool = True
    skip_reason: str = ""
    # An optional participant is never required: unavailable, it is a named,
    # unrequired exclusion, and `--require-all-bindings` does not count it.
    optional: bool = False


def detect_bindings() -> List[Binding]:
    """Return the list of bindings with availability flags for the current host."""
    bindings: List[Binding] = []

    # Python — always available if we're running (this script is Python).
    bindings.append(
        Binding(
            name="python",
            cmd=[
                sys.executable,
                str(PROJECT_ROOT / "scripts" / "property_corpus" / "roundtrip_python.py"),
            ],
        )
    )

    # Julia.
    julia = shutil.which("julia")
    bindings.append(
        Binding(
            name="julia",
            cmd=[
                julia or "julia",
                str(PROJECT_ROOT / "scripts" / "property_corpus" / "roundtrip_julia.jl"),
            ],
            available=julia is not None,
            skip_reason="julia not on PATH" if julia is None else "",
        )
    )

    # Rust via cargo example (prebuild so per-fixture invocation is fast).
    cargo = shutil.which("cargo")
    rust_dir = PROJECT_ROOT / "pkg" / "earthsci-ast-rs"
    bindings.append(
        Binding(
            name="rust",
            cmd=[
                cargo or "cargo",
                "run",
                "--quiet",
                "--example",
                "roundtrip_expression",
                "--",
            ],
            cwd=rust_dir,
            available=cargo is not None,
            skip_reason="cargo not on PATH" if cargo is None else "",
        )
    )

    # Go via `go run`.
    go = shutil.which("go")
    go_dir = PROJECT_ROOT / "pkg" / "earthsci-ast-go"
    bindings.append(
        Binding(
            name="go",
            cmd=[
                go or "go",
                "run",
                "./cmd/roundtrip_expression",
            ],
            cwd=go_dir,
            available=go is not None,
            skip_reason="go not on PATH" if go is None else "",
        )
    )

    # TypeScript via Node.js.
    node = shutil.which("node")
    bindings.append(
        Binding(
            name="typescript",
            cmd=[
                node or "node",
                str(PROJECT_ROOT / "scripts" / "property_corpus" / "roundtrip_typescript.mjs"),
            ],
            available=node is not None,
            skip_reason="node not on PATH" if node is None else "",
        )
    )

    for name in OPTIONAL_BINDINGS:
        argv = _OPTIONAL_ADAPTERS.discover(name)
        bindings.append(
            Binding(
                name=name,
                cmd=argv or [],
                available=argv is not None,
                skip_reason=(
                    f"{NOT_CONFIGURED}: set ${_OPTIONAL_ADAPTERS.env_prefix}{name.upper()} "
                    f"or put {_OPTIONAL_ADAPTERS.path_prefix}{name} on PATH"
                    if argv is None
                    else ""
                ),
                optional=True,
            )
        )

    return bindings


def run_binding(binding: Binding, fixtures: List[Path]) -> Dict[str, dict]:
    """Invoke the binding driver with the fixture paths and parse its JSON output."""
    cmd = binding.cmd + [str(p) for p in fixtures]
    proc = subprocess.run(
        cmd,
        cwd=str(binding.cwd) if binding.cwd else None,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        # A total driver failure is an operational error, not a divergence.
        raise RuntimeError(
            f"binding {binding.name} driver failed (exit {proc.returncode})\n"
            f"stderr:\n{proc.stderr}\nstdout:\n{proc.stdout}"
        )
    # Some drivers (cargo in particular) may emit warnings before the JSON.
    # Grab the last non-empty line that parses as JSON.
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    for candidate in reversed(lines):
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue
    raise RuntimeError(
        f"binding {binding.name} did not emit parseable JSON\n"
        f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )


def canonicalize(value) -> str:
    """Stable stringification for cross-binding comparison."""
    return json.dumps(value, sort_keys=True)


# The name under which the SOURCE fixture enters the comparison. Upper-case so
# it sorts ahead of every binding name and heads each divergence line, where it
# is the one participant that says which SIDE is wrong rather than merely that
# the sides differ.
SOURCE_PARTICIPANT = "SOURCE"


def read_sources(fixtures: List[Path]) -> Dict[str, dict]:
    """The corpus fixtures themselves, shaped like a binding driver's output.

    THE SOURCE IS A PARTICIPANT. Without it this stage was cross-binding-
    agreeing only (see tests/conformance/README.md, "What shape is a
    conformance stage?"): five bindings that drop the same expression field
    agree perfectly, so the stage passes on a shared wrong answer — and
    CONFORMANCE_SPEC.md calls this the strictest gate in the repo.

    The corpus fixtures are hypothesis-generated CANONICAL expressions, so
    `serialize(parse(F))` must reproduce `F` exactly: a canonical input has no
    legitimate normalization left to undergo. That is what makes them usable as
    an oracle at zero cost, and it is why the source is compared with the same
    `canonicalize` the bindings get — object key order is free, everything else
    is not.
    """
    out: Dict[str, dict] = {}
    for path in fixtures:
        try:
            out[path.name] = {"ok": True, "value": json.loads(path.read_text())}
        except Exception as exc:  # pragma: no cover — a corrupt corpus file
            out[path.name] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    return out


def compare(outputs: Dict[str, Dict[str, dict]]) -> List[dict]:
    """For each fixture, record per-binding canonical outputs and divergences."""
    report: List[dict] = []
    if not outputs:
        return report

    fixture_names = sorted({name for binding_out in outputs.values() for name in binding_out})
    for fixture in fixture_names:
        per_binding: Dict[str, dict] = {}
        for binding_name, binding_out in outputs.items():
            entry = binding_out.get(fixture, {"ok": False, "error": "missing in output"})
            if entry.get("ok"):
                per_binding[binding_name] = {
                    "ok": True,
                    "canonical": canonicalize(entry.get("value")),
                }
            else:
                per_binding[binding_name] = {
                    "ok": False,
                    "error": entry.get("error", "unknown"),
                }

        # TWO SIGNALS, DELIBERATELY NOT MERGED. `diverged` keeps its exact
        # pre-SOURCE meaning — THE BINDINGS DISAGREE WITH EACH OTHER — because
        # folding the source into it would silently change what
        # `--fail-on-divergence` gates, and this module's own history (the
        # `--require-divergence` mix-up below) is what a conflated signal costs.
        def key(e: dict) -> str:
            return e["canonical"] if e["ok"] else f"ERR::{e['error']}"

        binding_results = {n: e for n, e in per_binding.items() if n != SOURCE_PARTICIPANT}
        distinct = {key(e) for e in binding_results.values()}
        diverged = len(distinct) > 1

        # `source_mismatch` is the signal adding the source exists to produce:
        # the bindings AGREE, and are together different from the authored
        # fixture. Cross-binding agreement cannot see this, and it is the exact
        # shape of "five bindings can agree on the wrong answer".
        source = per_binding.get(SOURCE_PARTICIPANT)
        source_mismatch = (
            source is not None
            and source["ok"]
            and not diverged
            and bool(binding_results)
            and key(source) not in distinct
        )

        report.append(
            {
                "fixture": fixture,
                "diverged": diverged,
                "source_mismatch": source_mismatch,
                "bindings": per_binding,
            }
        )
    return report


def summarize(report: List[dict], bindings: List[str]) -> dict:
    """Aggregate per-fixture findings into a run summary."""
    diverged = [r for r in report if r["diverged"]]
    mismatched = [r for r in report if r.get("source_mismatch")]
    any_failures = [r for r in report if any(not b["ok"] for b in r["bindings"].values())]
    return {
        "total_fixtures": len(report),
        "diverged_count": len(diverged),
        "source_mismatch_count": len(mismatched),
        "any_parse_failure_count": len(any_failures),
        "bindings": bindings,
        "diverged_fixtures": [r["fixture"] for r in diverged][:20],
        "source_mismatch_fixtures": [r["fixture"] for r in mismatched][:20],
    }


def self_test() -> int:
    """No live binding: assert the comparison's two signals and the optional-
    participant contract on synthetic driver outputs."""
    failures: List[str] = []

    def check(ok: bool, label: str, detail: str) -> None:
        print(f"self-test {'OK  ' if ok else 'FAIL'} [{label}]", file=sys.stderr)
        if not ok:
            failures.append(f"{label}: {detail}")

    src = {"op": "+", "args": ["x", 1], "units": "m"}
    dropped = {"op": "+", "args": ["x", 1]}

    def out(v: dict) -> Dict[str, dict]:
        return {"expr_0.json": {"ok": True, "value": v}}

    def run(**parts: dict) -> dict:
        outputs = {n: out(v) for n, v in parts.items()}
        outputs[SOURCE_PARTICIPANT] = out(src)
        return compare(outputs)[0]

    r = run(a=src, b=src)
    check(
        not r["diverged"] and not r["source_mismatch"],
        "faithful-round-trip-is-clean",
        str(r),
    )
    r = run(a=dropped, b=dropped)
    check(
        not r["diverged"] and r["source_mismatch"],
        "shared-drop-is-a-source-mismatch",
        f"two bindings dropping the same field: {r}",
    )
    r = run(a=src, b=dropped)
    check(r["diverged"], "single-drop-is-a-divergence", str(r))
    r = run(a=src, b={"args": [1, "x"], "op": "+", "units": "m"})
    check(r["diverged"], "argument-order-is-not-free", str(r))
    r = run(a={"units": "m", "args": ["x", 1], "op": "+"}, b=src)
    check(
        not r["diverged"] and not r["source_mismatch"],
        "object-key-order-is-free",
        str(r),
    )

    unconfigured = [b for b in detect_bindings() if b.optional and not b.available]
    check(
        all(b.skip_reason.startswith(NOT_CONFIGURED) for b in unconfigured),
        "optional-unconfigured-is-named",
        str([(b.name, b.skip_reason) for b in unconfigured]),
    )
    check(
        {b.name for b in detect_bindings() if b.optional} == set(OPTIONAL_BINDINGS),
        "optional-participants-detected",
        str([b.name for b in detect_bindings()]),
    )

    print(f"self-test: {'OK' if not failures else 'FAILED'}", file=sys.stderr)
    for f in failures:
        print(f"  {f}", file=sys.stderr)
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="Run no binding: assert the comparison's signals (a field every binding "
        "drops is a SOURCE mismatch, one binding's drop is a divergence) and the "
        "optional-participant contract on synthetic outputs, then exit.",
    )
    ap.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    ap.add_argument(
        "--output",
        default=str(PROJECT_ROOT / "conformance-results" / "property_corpus_report.json"),
        help="Where to write the per-fixture comparison report.",
    )
    ap.add_argument(
        "--fail-on-divergence",
        action="store_true",
        help="Exit 1 on ANY cross-binding round-trip divergence (the conformance gate).",
    )
    ap.add_argument(
        "--fail-on-source-mismatch",
        action="store_true",
        help="Exit 1 when every binding AGREES and they all differ from the authored "
        "fixture. A separate question from --fail-on-divergence and never folded into "
        "it: this one asks whether the agreed answer is RIGHT. Mismatches are printed "
        "either way; the flag only decides whether they stop the build.",
    )
    ap.add_argument(
        "--require-all-bindings",
        action="store_true",
        help="Exit 1 if any binding's driver is unavailable (a binding that did not run "
        "has not been checked).",
    )
    ap.add_argument(
        "--require-divergence",
        action="store_true",
        help="CORPUS-QUALITY check, not a conformance gate: exit 1 if the corpus surfaces "
        "no divergence at all (it has become too tame). Never combine with the "
        "conformance gate — see this module's docstring.",
    )
    ap.add_argument(
        "--bindings",
        nargs="*",
        default=None,
        help="Restrict to a subset of bindings (default: all available).",
    )
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    # Resolve: the go and rust drivers run with `cwd` set to their own package
    # directory, so a corpus spelled relatively would reach them as a path that
    # does not exist there — reported as `ok: false` and then, indistinguishably,
    # as cross-binding divergence.
    corpus = Path(args.corpus).resolve()
    fixtures = sorted(corpus.glob("expr_*.json"))
    if not fixtures:
        print(f"error: no fixtures in {corpus}", file=sys.stderr)
        return 1

    bindings = detect_bindings()
    if args.bindings:
        bindings = [b for b in bindings if b.name in args.bindings]

    outputs: Dict[str, Dict[str, dict]] = {}
    skipped: List[str] = []
    optional_exclusions: List[dict] = []
    for binding in bindings:
        if not binding.available:
            if binding.optional:
                # Named, never required: reported, and kept out of `skipped`
                # so `--require-all-bindings` does not count it.
                optional_exclusions.append(optional_exclusion(binding.name, binding.skip_reason))
                print(
                    f"[skip] {binding.name}: optional participant, unrequired "
                    f"({binding.skip_reason})",
                    file=sys.stderr,
                )
                continue
            skipped.append(f"{binding.name} ({binding.skip_reason})")
            print(f"[skip] {binding.name}: {binding.skip_reason}", file=sys.stderr)
            continue
        print(f"[run ] {binding.name}: {len(fixtures)} fixtures", file=sys.stderr)
        try:
            outputs[binding.name] = run_binding(binding, fixtures)
        except RuntimeError as exc:
            print(f"[fail] {binding.name}: {exc}", file=sys.stderr)
            return 1

    # Optional participants (`lean`) do not count toward the minimum: one binding
    # checked against the Lean model alone is not a cross-binding comparison.
    if len([b for b in outputs if b not in OPTIONAL_BINDINGS]) < 2:
        print(
            f"error: need at least 2 available bindings, optional participants not "
            f"counted (got {list(outputs)}); skipped: {skipped}",
            file=sys.stderr,
        )
        return 1

    if args.require_all_bindings and skipped:
        print(
            f"error: {len(skipped)} binding driver(s) unavailable: {skipped}\n"
            "       a binding that did not run has not been checked",
            file=sys.stderr,
        )
        return 1

    # Add the SOURCE fixture as a participant — AFTER the binding-count and
    # required-binding gates above, which count real bindings: the source is an
    # oracle, not a stand-in for a binding that did not run.
    outputs[SOURCE_PARTICIPANT] = read_sources(fixtures)

    report = compare(outputs)
    summary = summarize(report, sorted(outputs.keys()))
    summary["optional_exclusions"] = optional_exclusions

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps({"summary": summary, "report": report}, indent=2, sort_keys=True)
    )

    print(
        f"[done] fixtures={summary['total_fixtures']} "
        f"diverged={summary['diverged_count']} "
        f"source_mismatch={summary['source_mismatch_count']} "
        f"any_parse_failure={summary['any_parse_failure_count']} "
        f"bindings={summary['bindings']}",
        file=sys.stderr,
    )
    print(f"[done] report written to {out_path}", file=sys.stderr)

    # SOURCE mismatches are printed UNCONDITIONALLY, whatever the gate flags
    # say. This is the finding adding the source exists to produce, and a
    # finding nobody sees is not a finding.
    if summary["source_mismatch_count"]:
        print(
            f"[source] {summary['source_mismatch_count']} of "
            f"{summary['total_fixtures']} expressions: ALL bindings agree with each "
            "other and DIFFER FROM THE AUTHORED FIXTURE",
            file=sys.stderr,
        )
        for entry in report:
            if not entry.get("source_mismatch"):
                continue
            got = next(
                r["canonical"]
                for n, r in sorted(entry["bindings"].items())
                if n != SOURCE_PARTICIPANT and r["ok"]
            )
            print(f"  {entry['fixture']}", file=sys.stderr)
            print(
                f"    SOURCE   {entry['bindings'][SOURCE_PARTICIPANT]['canonical']}",
                file=sys.stderr,
            )
            print(f"    bindings {got}", file=sys.stderr)

    if args.require_divergence and summary["diverged_count"] == 0:
        print(
            "error: corpus surfaced zero divergences; regenerate with a richer strategy",
            file=sys.stderr,
        )
        return 1

    # THE conformance gate: bindings that re-serialize the same expression
    # differently do not implement one format.
    if args.fail_on_divergence and summary["diverged_count"] > 0:
        print(
            f"error: {summary['diverged_count']} of {summary['total_fixtures']} corpus "
            "expressions round-trip DIFFERENTLY across bindings",
            file=sys.stderr,
        )
        # Group by the SHAPE of the divergence (which bindings said what), so a
        # single root cause reads as one line instead of 44.
        shapes: Dict[str, List[str]] = {}
        for entry in report:
            if not entry.get("diverged"):
                continue
            by_output: Dict[str, List[str]] = {}
            for name, result in sorted(entry.get("bindings", {}).items()):
                key = json.dumps(result.get("canonical"), sort_keys=True)
                by_output.setdefault(key, []).append(name)
            shape = " | ".join(
                f"{','.join(langs)}={out}" for out, langs in sorted(by_output.items())
            )
            shapes.setdefault(shape, []).append(entry.get("fixture", "?"))
        for shape, fixtures in sorted(shapes.items(), key=lambda kv: -len(kv[1])):
            print(f"  [{len(fixtures)}x] {shape}", file=sys.stderr)
            print(f"        e.g. {', '.join(fixtures[:4])}", file=sys.stderr)
        return 1

    # The SOURCE gate, kept separate from the cross-binding one on purpose: a
    # unanimous disagreement with the fixture is a different fault from the
    # bindings disagreeing with each other, and merging them would make the
    # message lie about which one fired.
    if args.fail_on_source_mismatch and summary["source_mismatch_count"] > 0:
        print(
            f"error: {summary['source_mismatch_count']} of {summary['total_fixtures']} "
            "corpus expressions do not survive serialize(parse(F)) == F in ANY binding "
            "(listed above)",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
