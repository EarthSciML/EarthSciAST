#!/usr/bin/env python3
"""Seeded differential tests for static ESM expressions."""

from __future__ import annotations

import argparse
import json
import math
import os
import selectors
import shlex
import struct
import subprocess
import sys
import time
from collections import Counter
from collections.abc import Iterator
from contextlib import ExitStack, contextmanager
from pathlib import Path
from typing import Any

from hypothesis import given, seed, settings, strategies as st
from shaped_cases import KINDS, fixture as shaped_fixture

ROOT = Path(__file__).resolve().parents[2]
MODEL = "Probe"
PARAMETERS = ("a", "b", "c")
REQUEST = {"test_id": "probe", "assertion_idx": 1}
EDGES = (
    0.0,
    1.0,
    -1.0,
    5e-324,
    -5e-324,
    2.0**-1022,
    2.0**31 - 1,
    -(2.0**31),
    2.0**53,
    sys.float_info.max,
    -sys.float_info.max,
)
VALUES = st.one_of(
    st.sampled_from(EDGES),
    st.integers(-32, 32).map(float),
    st.floats(allow_nan=False, allow_infinity=False, width=64).map(
        lambda value: 0.0 if value == 0.0 else value
    ),
)
COMPARISONS = ("<", "<=", ">", ">=", "==", "!=")


def node(op: str, *args: Any) -> dict:
    return {"op": op, "args": list(args)}


def extend(terms: st.SearchStrategy) -> st.SearchStrategy:
    conditions = st.builds(node, st.sampled_from(COMPARISONS), terms, terms)
    return st.one_of(
        st.builds(node, st.sampled_from(("-", "abs", "floor", "ceil")), terms),
        st.builds(node, st.sampled_from(("-", "/")), terms, terms),
        st.tuples(
            st.sampled_from(("+", "*", "min", "max")), st.lists(terms, min_size=2, max_size=5)
        ).map(lambda pair: node(pair[0], *pair[1])),
        conditions,
        st.builds(node, st.just("not"), conditions),
        st.builds(node, st.sampled_from(("and", "or")), conditions, conditions),
        st.builds(node, st.just("ifelse"), conditions, terms, terms),
    )


def document(expr: Any, values: tuple[float, ...]) -> dict:
    referenced = {term for term in walk(expr) if isinstance(term, str)}
    return {
        "esm": "2.4.0",
        "metadata": {"name": "ScalarProbe", "description": "Generated scalar differential fixture"},
        "models": {
            MODEL: {
                "variables": {
                    **{
                        name: {
                            "type": "parameter",
                            "units": "1",
                            "description": name,
                            "default": value,
                        }
                        for name, value in input_values(values)
                        if name in referenced
                    },
                    "result": {"type": "unknown", "units": "1", "description": "Scalar result"},
                },
                "equations": [{"lhs": "result", "rhs": expr}],
                "tests": [
                    {
                        "id": REQUEST["test_id"],
                        "time_span": {"start": 0, "end": 1},
                        "assertions": [{"variable": "result", "time": 0, "expected": 0}],
                    }
                ],
            }
        },
    }


def input_values(values: tuple[float, ...]) -> Iterator[tuple[str, float]]:
    # §5.5.3.1 permits numeric narrowing at parse time. Construct negative
    # zero in the AST from an integer zero rather than depending on spelling.
    return zip((*PARAMETERS, "zero"), (*values, 0), strict=True)


def dumps(value: Any, **kwargs: Any) -> str:
    return json.dumps(value, allow_nan=False, **kwargs)


def parse_bits(bits: str) -> int:
    if not isinstance(bits, str) or not bits.isascii() or not bits.isdecimal():
        raise ValueError(f"invalid binary64 bit string {bits!r}")
    encoding = int(bits)
    if not 0 <= encoding < 2**64:
        raise ValueError(f"binary64 encoding out of range: {bits}")
    return encoding


def bits_to_float(bits: int) -> float:
    return struct.unpack(">d", bits.to_bytes(8, "big"))[0]


class AdapterRejection(Exception):
    """An adapter returned a document error through the wire protocol."""


@contextmanager
def adapter(command: list[str]):
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as proc:
        assert proc.stdin is not None and proc.stdout is not None
        os.set_blocking(proc.stdin.fileno(), False)
        os.set_blocking(proc.stdout.fileno(), False)
        try:
            yield proc
        finally:
            proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def ask(proc: subprocess.Popen, request: dict, timeout: float) -> tuple[int, ...]:
    assert proc.stdin is not None and proc.stdout is not None
    pending = memoryview((dumps(request) + "\n").encode("utf-8"))
    deadline = time.monotonic() + timeout
    line = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(proc.stdin, selectors.EVENT_WRITE)
        while True:
            ready = selector.select(max(0, deadline - time.monotonic()))
            if not ready or time.monotonic() >= deadline:
                raise RuntimeError(f"{proc.args[0]} timed out waiting for a result")
            try:
                if pending:
                    pending = pending[os.write(proc.stdin.fileno(), pending) :]
                    if not pending:
                        selector.unregister(proc.stdin)
                        selector.register(proc.stdout, selectors.EVENT_READ)
                else:
                    chunk = os.read(proc.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError(
                            f"{proc.args[0]} exited before returning a complete result"
                        )
                    line.extend(chunk)
                    if b"\n" in chunk:
                        break
            except BlockingIOError:
                continue
    try:
        response = json.loads(line)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{proc.args[0]} returned an invalid JSON reply") from exc
    if "error" in response:
        raise AdapterRejection(response["error"])
    values = response["values"]
    if not isinstance(values, list) or len(values) != len(request["requests"]):
        raise ValueError(f"{proc.args[0]} returned the wrong number of assertion values")
    return tuple(map(parse_bits, values))


def agree(reference: int, result: int) -> bool:
    # The operations have fixed binary64 order. The NaN rule concerns
    # propagation, for which the payload and sign are immaterial.
    return reference == result or (
        math.isnan(bits_to_float(reference)) and math.isnan(bits_to_float(result))
    )


def walk(expr: Any) -> Iterator[Any]:
    yield expr
    if isinstance(expr, dict):
        for arg in expr.values():
            yield from walk(arg)
    elif isinstance(expr, list):
        for arg in expr:
            yield from walk(arg)


def edge(value: float) -> str | None:
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "infinity"
    if value == 0.0:
        return "-0" if math.copysign(1.0, value) < 0 else "+0"
    if abs(value) < sys.float_info.min:
        return "subnormal"
    if value in EDGES:
        return "boundary"
    return None


class Mismatch(Exception):
    def __init__(self, fixture: dict, outcomes: dict[str, str]):
        super().__init__(", ".join(f"{name}={value}" for name, value in outcomes.items()))
        self.fixture = fixture


def compare(
    fixture: dict, participants: dict[str, subprocess.Popen], timeout: float
) -> tuple[float, ...]:
    requests = [
        {"test_id": test["id"], "assertion_idx": index}
        for test in fixture["models"][MODEL]["tests"]
        for index in range(1, len(test["assertions"]) + 1)
    ]
    if not requests:
        raise ValueError("differential fixture requires at least one inline assertion")
    request = {"document": fixture, "requests": requests}
    responses = {}
    errors = {}
    for name, proc in participants.items():
        try:
            responses[name] = ask(proc, request, timeout)
        except AdapterRejection as exc:
            errors[name] = f"error: {exc}"
    reference = () if "lean" in errors else responses["lean"]
    difference = next(
        (
            index
            for index, bits in enumerate(reference)
            if any(not agree(bits, values[index]) for values in responses.values())
        ),
        None,
    )
    if errors or difference is not None:
        index = difference if difference is not None else 0
        outcomes = {
            name: f"{bits_to_float(values[index])!r} (0x{values[index]:016x})"
            for name, values in responses.items()
        }
        selected = requests[index]
        assertion = f"{selected['test_id']}/{selected['assertion_idx']}"
        raise Mismatch(fixture, {"assertion": assertion} | outcomes | errors)
    return tuple(map(bits_to_float, reference))


def run(commands: dict[str, list[str]], args: argparse.Namespace) -> None:
    op_counts: Counter[str] = Counter()
    edge_counts: Counter[str] = Counter()
    cases = 0
    disagreements = 0
    shrinking = not args.observer
    runner_error: Exception | None = None
    if args.shaped:
        families = [shaped_fixture(MODEL, REQUEST["test_id"], kind) for kind in KINDS]
    else:
        expr = st.recursive(
            st.one_of(st.sampled_from(PARAMETERS), st.just(node("-", "zero"))),
            extend,
            max_leaves=12,
        )
        families = [st.builds(document, expr, st.tuples(VALUES, VALUES, VALUES))]
    with ExitStack() as stack:
        participants = {name: stack.enter_context(adapter(cmd)) for name, cmd in commands.items()}
        if args.fixture is not None:
            fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
            compare(fixture, participants, args.timeout)
            print(f"{args.fixture} passed for {', '.join(commands)}")
            return

        def check(fixture: dict) -> None:
            nonlocal cases, disagreements, runner_error
            if runner_error is not None:
                return
            try:
                result = compare(fixture, participants, args.timeout)
            except Mismatch:
                if shrinking:
                    raise
                disagreements += 1
                result = ()
            except (OSError, ValueError, RuntimeError, KeyError, TypeError) as exc:
                # A broken stream can leave a late reply in flight. Do not
                # reuse it to shrink an adapter startup or protocol failure.
                runner_error = exc
                return
            if shrinking and args.observer:
                return
            cases += 1
            model = fixture["models"][MODEL]
            op_counts.update(
                {
                    term["op"]
                    for term in walk(model["equations"])
                    if isinstance(term, dict) and "op" in term
                }
            )
            observed = [var["default"] for var in model["variables"].values() if "default" in var]
            observed.extend(result)
            edge_counts.update({kind for value in observed if (kind := edge(value)) is not None})

        def sweep() -> None:
            cases_per_family, remainder = divmod(args.cases, len(families))
            try:
                for index, family in enumerate(families):
                    count = cases_per_family + (index < remainder)
                    if count == 0:
                        break
                    test = settings(
                        max_examples=count, deadline=None, database=None, report_multiple_bugs=False
                    )(given(family)(check))
                    seed(args.seed)(test)()
                    if runner_error is not None:
                        break
            finally:
                if runner_error is not None:
                    raise runner_error

        sweep()
        kind = "shaped" if args.shaped else "scalar"
        print(
            f"{cases} {kind} cases for {', '.join(commands)} "
            f"(seed {args.seed}, {disagreements} disagreements)",
            flush=True,
        )
        print("Operators", dict(sorted(op_counts.items())), flush=True)
        print("Edges", dict(sorted(edge_counts.items())), flush=True)
        if disagreements:
            # Replay the same seed with failures enabled so Hypothesis can
            # shrink one discrepancy after coverage for the sweep is reported.
            shrinking = True
            sweep()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean", type=Path, default=ROOT / "formal/.lake/build/bin/esm-lean")
    parser.add_argument("--adapter", action="append", default=[], metavar="NAME=COMMAND")
    parser.add_argument("--seed", type=int, default=20261026)
    parser.add_argument("--cases", type=int, default=200)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--shaped", action="store_true", help="generate static array expressions")
    parser.add_argument("--fixture", type=Path, help="replay one differential fixture")
    parser.add_argument(
        "--observer", action="store_true", help="report disagreements without failing"
    )
    parser.add_argument("--reproducer", type=Path)
    args = parser.parse_args()
    if args.cases < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--cases and --timeout must be positive")
    if args.reproducer is None:
        kind = "shaped" if args.shaped else "scalar"
        args.reproducer = ROOT / "conformance-results" / f"{kind}-difftest.esm"
    commands = {
        "lean": [str(args.lean.resolve()), "static-assertions-jsonl", MODEL],
        "python": [sys.executable, str(Path(__file__).with_name("scalar_python.py"))],
    }
    for adapter_spec in args.adapter:
        name, sep, command = adapter_spec.partition("=")
        argv = shlex.split(command)
        if not sep or not name or name in commands or not argv:
            parser.error(f"invalid or duplicate adapter {adapter_spec!r}")
        commands[name] = argv
    try:
        run(commands, args)
    except Mismatch as exc:
        if args.fixture is None:
            args.reproducer.parent.mkdir(parents=True, exist_ok=True)
            args.reproducer.write_text(dumps(exc.fixture, indent=2) + "\n", encoding="utf-8")
            print(f"Seed {args.seed} shrank a disagreement to {args.reproducer}", file=sys.stderr)
        else:
            print(f"Disagreement on {args.fixture}", file=sys.stderr)
        print(str(exc), file=sys.stderr)
        return 0 if args.observer else 1
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as exc:
        print(f"Differential runner failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
