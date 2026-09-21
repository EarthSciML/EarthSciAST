#!/usr/bin/env python3
"""Phase 0 census for the "Choosing the Compiler" plan — Python binding.

Answers two questions over a corpus of ``.esm`` documents, one JSON line per
document:

1. **What the reference can run.** Build each document with
   ``compiler="interpreter"`` — every fast tier off, the per-cell ``faq``
   evaluator for every aggregate — and evaluate its right-hand side once at
   ``(u0, p, t0)``. This is the widest thing the binding runs, so it is the
   denominator: a document the reference cannot build is not a refusal, it is a
   document.

2. **What the strict default refuses.** Build the SAME document with
   ``compiler="native"`` — whole-box vectorized NumPy for every document — and
   record whether it refused, with the rule, the phase, the deepest reason and
   the whole chain of declines the refusal carries. Construction evaluates the
   const-geometry hoist, the right-hand side once and the output-time observed
   pass, so a refusal here is the refusal a caller gets.

   The phase-0 run of this script predates the ``compiler`` keyword and forced
   the NumPy pathway by monkeypatching ``_choose_pathway``, with the ladder
   instrumented by ``sys.settrace`` to recover the decline reasons. Both are
   gone: the keyword is real and the reasons come from the binding's own
   recorder (:class:`earthsci_ast.compiler.CompilerReport`), so what the census
   reports is what a caller sees.

The instrumentation is a pure wrapper installed at run time: the tier functions
are module globals that :func:`earthsci_ast.numpy_interpreter._eval_faq` looks
up per call, so rebinding them observes the ladder without changing it. Each
wrapper forwards its arguments untouched and returns the callee's own value.

Decline lines are captured with :func:`sys.settrace` for the FIRST occurrence of
each ``(node, tier)`` pair only — the reason a given node declines a given tier
is a property of the node, so one sample is enough and the tracer never runs
during the bulk of the evaluation.

Usage
-----
::

    # one document, one JSON line on stdout (the worker; also useful by hand)
    python3 scripts/compiler_census.py --one tests/simulation/simple_ode.esm

    # a whole corpus, one subprocess per document with a timeout
    python3 scripts/compiler_census.py \
        --root ../../tests --root /path/to/EarthSciModels \
        --output /scratch/.../census.jsonl --timeout 180

    # aggregate a finished run into the tables the audit carries
    python3 scripts/compiler_census.py --summarize /scratch/.../census.jsonl

Run the sweep as one subprocess per document: a document whose build allocates
without bound (``isrm.esm-class`` is the known one) takes the whole process
down, and a document that never finishes (``geoschem_fullchem.esm``) has to be
killed. Both outcomes are recorded rather than lost.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import resource
import subprocess
import sys
import threading
import time
import traceback
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

# --------------------------------------------------------------------------
# The tiers of the faq ladder, fastest first. Order is the order
# ``_eval_faq`` tries them in; a tier absent from a given node's attempt list
# was never reached (an earlier tier answered, or a guard skipped it).
# --------------------------------------------------------------------------
TIERS = (
    "_eval_faq_batched_leaf",
    "_eval_faq_prefix_scan",
    "_eval_faq_operator_cached",
    "_eval_faq_reduce_vectorized",
    "_eval_faq_vectorized",
    "_eval_faq_contraction_broadcast",
    "_materialize_map",
)
# The landing paths. ``_eval_faq_scalar`` and ``_eval_faq_scalar_gate_driven``
# walk the tree once per output cell (× contraction point); ``_eval_faq_ragged``
# is per-output-cell too but is the only path a ragged range has.
LANDINGS = ("_eval_faq_scalar", "_eval_faq_ragged")


# --------------------------------------------------------------------------
# Per-document worker
# --------------------------------------------------------------------------


def _node_key(expr: Any) -> str:
    """A key for one faq node, stable across processes.

    ``id()`` is not comparable between the default build and the forced-array
    build, let alone between documents, so hash the node's structure instead.
    Falls back to the object identity when the node is not reprable."""
    try:
        text = repr(expr)
    except Exception:  # pragma: no cover - defensive
        return f"id{id(expr):x}"
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:16]


def _node_label(expr: Any) -> str:
    """A short human-readable tag for a faq node: the reducer and its indices."""
    out = getattr(expr, "output_idx", None)
    red = getattr(expr, "semiring", None) or getattr(expr, "reduce", None) or "+"
    ranges = getattr(expr, "ranges", None) or {}
    bits = [f"reduce={red}", f"out={list(out) if out else []}", f"idx={sorted(ranges)}"]
    if getattr(expr, "join", None):
        bits.append("join")
    if getattr(expr, "filter", None) is not None:
        bits.append("filter")
    return " ".join(bits)


class _Ladder:
    """Records what every faq node did during one right-hand-side evaluation."""

    def __init__(self) -> None:
        # node key -> the node's label, for the report
        self.labels: dict[str, str] = {}
        # node key -> how many times _eval_faq was entered for it
        self.evaluated: Counter = Counter()
        # node key -> how many times it landed on a per-cell path
        self.landed: Counter = Counter()
        # node key -> landing function name
        self.landing_fn: dict[str, str] = {}
        # node key -> ordered tuple of tiers that declined before the landing
        self.declines: dict[str, tuple[str, ...]] = {}
        # (node key, tier) -> the source line the tier returned None from
        self.decline_lines: dict[str, str] = {}
        # node key -> why the ladder was bypassed entirely, when it was
        self.bypass: dict[str, str] = {}
        # node key -> number of output cells the landing walks
        self.cells: dict[str, int] = {}
        # codegen (Tier-1 source) declines — these land on the compiled-closure
        # tier, still whole-box, so they are a cost decline, not a refusal
        self.codegen_declines: int = 0
        # scratch for the node currently inside _eval_faq
        self._current: list[str] = []
        self._attempts: dict[str, list[str]] = defaultdict(list)
        self._traced: set = set()

    # -- report ---------------------------------------------------------
    def report(self) -> dict[str, Any]:
        per_cell = {k: v for k, v in self.landed.items() if v}
        reasons: Counter = Counter()
        for key in per_cell:
            reasons[self.reason_for(key)] += 1
        return {
            "faq_nodes_evaluated": len(self.evaluated),
            "faq_evaluations": int(sum(self.evaluated.values())),
            "faq_nodes_per_cell": len(per_cell),
            "faq_per_cell_landings": int(sum(per_cell.values())),
            "per_cell_cells_total": int(sum(self.cells.get(k, 0) for k in per_cell)),
            "codegen_declines": self.codegen_declines,
            "decline_reasons": dict(reasons),
            "per_cell_nodes": [
                {
                    "node": key,
                    "label": self.labels.get(key, ""),
                    "landings": per_cell[key],
                    "cells": self.cells.get(key, 0),
                    "landing_fn": self.landing_fn.get(key, ""),
                    "reason": self.reason_for(key),
                    "declined": list(self.declines.get(key, ())),
                    "decline_lines": {
                        t: self.decline_lines[f"{key}|{t}"]
                        for t in self.declines.get(key, ())
                        if f"{key}|{t}" in self.decline_lines
                    },
                }
                for key in sorted(per_cell, key=lambda k: -per_cell[k])[:40]
            ],
        }

    def reason_for(self, key: str) -> str:
        """One string naming why this node walks per cell."""
        if key in self.bypass:
            return self.bypass[key]
        declined = self.declines.get(key, ())
        if not declined:
            return "no tier attempted"
        lines = [self.decline_lines.get(f"{key}|{t}", "?") for t in declined]
        return "; ".join(f"{t}@{ln}" for t, ln in zip(declined, lines))


def _install(active: dict, npi: Any, npc: Any) -> None:
    """Rebind the ladder's functions to recording wrappers.

    ``active["ladder"]`` names the recorder in force; the caller swaps it to
    separate the BUILD phase (the const-geometry hoist and the static observed
    materialization, which evaluate aggregates too) from the single right-hand
    side evaluation. Both phases matter: under the planned strict ``native``
    compiler construction evaluates the right-hand side once, so a per-cell
    landing in either phase is a build-time refusal."""
    import sys as _sys

    def L() -> _Ladder:
        return active["ladder"]

    def traced(fn, args, kwargs):
        """Run ``fn`` under a line tracer; return (value, decline line)."""
        code = fn.__code__
        box: dict[str, Any] = {}

        def local(frame, event, arg):
            if event == "return":
                box["line"] = frame.f_lineno
            return local

        def glob(frame, event, arg):
            return local if frame.f_code is code else None

        old = _sys.gettrace()
        _sys.settrace(glob)
        try:
            value = fn(*args, **kwargs)
        finally:
            _sys.settrace(old)
        src = os.path.basename(code.co_filename)
        return value, f"{src}:{box.get('line', '?')}"

    def wrap_tier(name: str):
        original = getattr(npi, name)

        def tier(*args, **kwargs):
            key = L()._current[-1] if L()._current else "?"
            pair = f"{key}|{name}"
            if pair in L()._traced:
                value = original(*args, **kwargs)
                line = None
            else:
                L()._traced.add(pair)
                value, line = traced(original, args, kwargs)
            if value is None:
                L()._attempts[key].append(name)
                if line is not None:
                    L().decline_lines[pair] = line
            return value

        tier.__name__ = name
        setattr(npi, name, tier)

    def wrap_landing(name: str):
        original = getattr(npi, name)

        def landing(expr, ctx, out_syms, out_ranges_exp, out_shape, *rest, **kwargs):
            key = L()._current[-1] if L()._current else _node_key(expr)
            L().landed[key] += 1
            L().landing_fn[key] = name
            L().declines[key] = tuple(L()._attempts.get(key, ()))
            cells = 1
            for n in out_shape or ():
                cells *= int(n)
            L().cells[key] = max(L().cells.get(key, 0), cells)
            return original(expr, ctx, out_syms, out_ranges_exp, out_shape, *rest, **kwargs)

        landing.__name__ = name
        setattr(npi, name, landing)

    faq_original = npi._eval_faq
    has_overlap = npi._join_has_overlap

    def eval_faq(expr, ctx):
        key = _node_key(expr)
        L().labels.setdefault(key, _node_label(expr))
        L().evaluated[key] += 1
        L()._attempts[key] = []
        # The two documented bypasses: a recurrence sweep and an overlap gate
        # go straight to a per-cell path with no tier attempted at all.
        if getattr(ctx, "recur", None) is not None:
            L().bypass[key] = "recurrence bypass (numpy_interpreter.py:2430)"
        else:
            try:
                if has_overlap(expr):
                    L().bypass[key] = "overlap gate bypass (numpy_interpreter.py:2418)"
            except Exception:
                pass
        L()._current.append(key)
        try:
            return faq_original(expr, ctx)
        finally:
            L()._current.pop()

    npi._eval_faq = eval_faq
    for name in TIERS:
        wrap_tier(name)
    for name in LANDINGS:
        wrap_landing(name)

    cg_original = npc.compile_box_body

    def compile_box_body(*args, **kwargs):
        value = cg_original(*args, **kwargs)
        if value is None:
            L().codegen_declines += 1
        return value

    npc.compile_box_body = compile_box_body


def _error_code(exc: BaseException) -> str:
    """The leading ``snake_case:`` error code of an exception message, if any."""
    text = str(exc).strip()
    head = text.split(":", 1)[0]
    if head and len(head) < 64 and head.replace("_", "").isalnum() and head.islower():
        return head
    return ""


def _fail(exc: BaseException) -> dict[str, Any]:
    return {
        "ok": False,
        "error_class": type(exc).__name__,
        "error_code": _error_code(exc),
        "error": str(exc)[:400],
    }


def census_one(path: str, tspan: tuple[float, float] = (0.0, 1.0)) -> dict[str, Any]:
    """Build one document under each of the two compilers and return its record."""
    record: dict[str, Any] = {"path": path}

    import earthsci_ast
    from earthsci_ast import esm_problem
    from earthsci_ast import numpy_codegen as npc
    from earthsci_ast import numpy_interpreter as npi
    from earthsci_ast.compiler import CompilerRefusedRuleError

    record["binding"] = os.path.dirname(earthsci_ast.__file__)

    # -- pass 1: the reference ------------------------------------------------
    # The right-hand side is evaluated here too, not just under `native`: the
    # comparison below is between two documents-that-RUN, and comparing a build
    # against a build-plus-evaluation would invent a difference.
    t0 = time.perf_counter()
    try:
        prob = esm_problem(path, tspan, compiler="interpreter")
        record["interpreter"] = {
            "ok": True,
            "compiler": prob.compiler,
            "engine": prob.engine,
            "states": len(prob.flat.state_variables),
            "params": len(prob.flat.parameters),
            "tiers": prob.compiler_report.tiers(),
            "rules": len(prob.compiler_report.rules()),
        }
        try:
            if prob.build is not None:
                prob.build.rhs_function(float(tspan[0]), prob.build.y0)
                record["interpreter"]["rhs"] = {"ok": True}
            else:
                record["interpreter"]["rhs"] = {"ok": True, "note": "no rhs_function"}
        except BaseException as exc:  # noqa: BLE001
            record["interpreter"]["rhs"] = _fail(exc)
        del prob
    except BaseException as exc:  # noqa: BLE001 - a census records everything
        record["interpreter"] = _fail(exc)
    record["interpreter"]["seconds"] = round(time.perf_counter() - t0, 3)

    # -- pass 2: the strict default -------------------------------------------
    # `esm_problem` itself evaluates the hoist, one right-hand side and the
    # output-time observed pass under the policy, so a refusal surfaces here
    # without the census driving anything by hand. The ladder wrappers stay
    # installed only to count the LANDINGS a `native` build that survived made;
    # the refusal's own reasons come off the exception.
    ladder = _Ladder()
    active = {"ladder": ladder}
    _install(active, npi, npc)
    t0 = time.perf_counter()
    try:
        prob = esm_problem(path, tspan)
        native: dict[str, Any] = {
            "ok": True,
            "refused": False,
            "compiler": prob.compiler,
            "engine": prob.engine,
            "tiers": prob.compiler_report.tiers(),
            "rules": len(prob.compiler_report.rules()),
            "build_seconds": round(time.perf_counter() - t0, 3),
            "ladder": ladder.report(),
        }
        record["native"] = native
        del prob
    except CompilerRefusedRuleError as exc:
        record["native"] = {
            "ok": False,
            "refused": True,
            "error_class": type(exc).__name__,
            "error_code": exc.code,
            "error": str(exc)[:400],
            "rule": exc.rule,
            "phase": exc.phase,
            "reason": exc.reason,
            "declines": list(exc.declines),
            "build_seconds": round(time.perf_counter() - t0, 3),
        }
    except BaseException as exc:  # noqa: BLE001
        record["native"] = _fail(exc)
        record["native"]["refused"] = False
        record["native"]["build_seconds"] = round(time.perf_counter() - t0, 3)

    record["max_rss_kb"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return record


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


def iter_documents(roots: list[str]) -> list[str]:
    docs: list[str] = []
    for root in roots:
        base = Path(root)
        if base.is_file():
            docs.append(str(base.resolve()))
            continue
        docs.extend(str(p) for p in sorted(base.rglob("*.esm")))
    return docs


def run_sweep(args: argparse.Namespace) -> int:
    docs = iter_documents(args.root)
    if args.skip:
        skip = {Path(s).name for s in args.skip}
        docs = [d for d in docs if Path(d).name not in skip]
    done: set = set()
    if args.resume and os.path.exists(args.output):
        with open(args.output) as fh:
            for line in fh:
                try:
                    done.add(json.loads(line)["path"])
                except Exception:
                    pass
    env = dict(os.environ)
    env["PYTHONPATH"] = str(Path(__file__).resolve().parent.parent / "src") + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
    )
    total = len(docs)
    todo = [d for d in docs if d not in done]
    lock = threading.Lock()
    counter = {"n": 0}

    def one(doc: str) -> str:
        cmd = [
            sys.executable,
            os.path.abspath(__file__),
            "--one",
            doc,
            "--memcap",
            str(args.memcap),
        ]
        started = time.perf_counter()
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True, timeout=args.timeout, env=env
            )
            line = proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else ""
            if line.startswith("{"):
                return line
            return json.dumps(
                {
                    "path": doc,
                    "worker": "crashed",
                    "returncode": proc.returncode,
                    "stderr": proc.stderr[-600:],
                    "seconds": round(time.perf_counter() - started, 1),
                }
            )
        except subprocess.TimeoutExpired:
            return json.dumps(
                {"path": doc, "worker": "timeout", "timeout": args.timeout, "seconds": args.timeout}
            )

    with open(args.output, "a" if args.resume else "w", buffering=1) as out:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for line in pool.map(one, todo):
                with lock:
                    out.write(line + "\n")
                    counter["n"] += 1
                    if counter["n"] % 25 == 0 or counter["n"] == len(todo):
                        print(
                            f"[{counter['n']}/{len(todo)}] of {total}",
                            file=sys.stderr,
                            flush=True,
                        )
    return 0


# --------------------------------------------------------------------------
# Aggregation
# --------------------------------------------------------------------------


def summarize(paths: list[str]) -> None:
    rows = []
    for p in paths:
        with open(p) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))

    by_engine: Counter = Counter()
    ok_engine: Counter = Counter()
    ref_fail: Counter = Counter()
    ref_rhs_fail: Counter = Counter()
    native_fail: Counter = Counter()
    refusal_reason: Counter = Counter()
    refusal_phase: Counter = Counter()
    refusal_chain: Counter = Counter()
    native_tiers: Counter = Counter()
    worker_bad: Counter = Counter()
    builds_ref = runs_ref = 0
    native_built = native_refused = 0
    refusals: list[tuple[str, str, str, str]] = []
    # A document `native` refuses that the reference cannot run either is not a
    # capability gap this plan created; it is tracked separately so the headline
    # number is the one a caller would meet.
    refused_and_runnable = 0

    for r in rows:
        if r.get("worker"):
            worker_bad[r["worker"]] += 1
            continue
        ref = r.get("interpreter", {})
        nat = r.get("native", {})
        ref_rhs = ref.get("rhs", {}) if ref.get("ok") else {}
        ref_runs = bool(ref.get("ok")) and bool(ref_rhs.get("ok"))
        if ref.get("ok"):
            builds_ref += 1
            by_engine[ref.get("engine", "?")] += 1
            if ref_rhs.get("ok"):
                runs_ref += 1
                ok_engine[ref.get("engine", "?")] += 1
            else:
                ref_rhs_fail[f"{ref_rhs.get('error_class')}/{ref_rhs.get('error_code') or '-'}"] += 1
        else:
            ref_fail[f"{ref.get('error_class')}/{ref.get('error_code') or '-'}"] += 1

        if nat.get("refused"):
            native_refused += 1
            if ref_runs:
                refused_and_runnable += 1
            refusal_reason[nat.get("reason", "?")] += 1
            refusal_phase[nat.get("phase", "?")] += 1
            chain = " → ".join(t for t, _ in nat.get("declines") or []) or "(no tier attempted)"
            refusal_chain[chain] += 1
            refusals.append(
                (r["path"], nat.get("rule", "?"), nat.get("phase", "?"), nat.get("reason", "?"))
            )
        elif nat.get("ok"):
            native_built += 1
            for tier, n in (nat.get("tiers") or {}).items():
                native_tiers[tier] += n
        else:
            native_fail[f"{nat.get('error_class')}/{nat.get('error_code') or '-'}"] += 1

    def table(title: str, counter: Counter) -> None:
        print(f"\n## {title}")
        for k, v in counter.most_common():
            print(f"  {v:6d}  {k}")

    print(f"documents recorded: {len(rows)}")
    table("worker outcomes (no record at all)", worker_bad)
    print("\n# compiler='interpreter' (the reference)")
    table("built, by segmenting engine", by_engine)
    print(f"  total built: {builds_ref}")
    table("built AND right-hand side evaluated, by engine", ok_engine)
    print(f"  total runnable: {runs_ref}")
    table("BUILD failures", ref_fail)
    table("RHS failures", ref_rhs_fail)
    print("\n# compiler='native' (the strict default)")
    print(f"    built                       : {native_built}")
    print(f"    REFUSED (compiler_refused_rule): {native_refused}")
    print(f"      of which the reference runs : {refused_and_runnable}")
    table("refusal phase", refusal_phase)
    table("refusal: deepest reason", refusal_reason)
    table("refusal: decline chain, fastest tier first", refusal_chain)
    table("landings by tier, over the documents native BUILT", native_tiers)
    table("native BUILD failures that are not refusals", native_fail)
    print(f"\n## every refusal ({len(refusals)})")
    for path, rule, phase, reason in sorted(refusals):
        print(f"  {path}\n      [{phase}] {rule}\n      {reason}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--one", help="census a single document; one JSON line to stdout")
    ap.add_argument("--root", action="append", default=[], help="corpus root (repeatable)")
    ap.add_argument("--output", help="JSONL output path for a sweep")
    ap.add_argument("--timeout", type=int, default=180, help="per-document seconds")
    ap.add_argument("--jobs", type=int, default=1, help="documents in flight at once")
    ap.add_argument(
        "--memcap", type=int, default=8, help="per-worker address-space cap, GiB (0 = none)"
    )
    ap.add_argument("--skip", action="append", default=[], help="basename to skip")
    ap.add_argument("--resume", action="store_true", help="keep records already in --output")
    ap.add_argument("--summarize", action="append", default=[], help="JSONL to aggregate")
    args = ap.parse_args(argv)

    if args.summarize:
        summarize(args.summarize)
        return 0
    if args.one:
        # A per-worker address-space cap. The sweep runs several workers under
        # one cgroup, so a document that allocates without bound (isrm.esm-class)
        # would take the whole job down with it; capping turns that into a
        # MemoryError this record carries.
        if args.memcap:
            cap = args.memcap * (1 << 30)
            resource.setrlimit(resource.RLIMIT_AS, (cap, cap))
        try:
            rec = census_one(args.one)
        except BaseException as exc:  # noqa: BLE001
            rec = {
                "path": args.one,
                "worker": "worker_error",
                "error": traceback.format_exc()[-800:],
            }
            del exc
        print(json.dumps(rec))
        return 0
    if not args.root or not args.output:
        ap.error("a sweep needs at least one --root and an --output")
    return run_sweep(args)


if __name__ == "__main__":
    raise SystemExit(main())
