#!/usr/bin/env python3
"""A stand-in `compiler_agreement` adapter, for the runner's own test.

The real adapters live in the bindings and need a Julia, Rust or Python runtime
plus a working `esm_problem`. This one implements the same CLI over a canned
table, so `test_runner.py` can drive the runner through every outcome the
contract names — ok, mismatch, refused, unavailable, error — and through both
ledgers, in pure Python and in under a second. It is a test fixture for the
HARNESS; it never evaluates a document and must never be mistaken for a producer.

CLI, identical to the contract in `README.md`:

    stub_adapter.py --manifest <manifest.json> --output <out.json> --compiler <value>

plus one flag no real adapter has:

    --scenario <name>   pick the canned outcome table (default: per compiler)

Trajectory values come from `synthetic_value`, a closed form over (element index,
save time). The point is that the table is REPRODUCIBLE: the test mints a golden
by running the stub's all-ok scenario through `--write-golden`, then re-runs the
stub and expects the same numbers back, so an `ok` verdict in the test is a real
comparison rather than an assertion that nothing was checked.

Exit codes follow the contract: 0 when every fixture answered, 1 when at least
one fixture errored — with the report written either way, because the per-fixture
entries are what say which fixture broke.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

# Per-fixture outcomes by POSITION in the manifest, so the table does not have to
# name the tier's fixture ids and rot when the tier grows one. A table entry is
# one of "ok", "mismatch", "refused" or "error"; the fifth outcome,
# `unavailable`, is a whole-output shape and so is a table of its own. A table
# shorter than the fixture list repeats its last entry.
SCENARIOS: dict[str, object] = {
    "all_ok": ["ok"],
    "all_refused": ["refused"],
    "all_mismatch": ["mismatch"],
    "all_error": ["error"],
    # The default mix for a compiler with partial coverage: the first fixture
    # lands, the second is wrong, the third cannot be lowered, the fourth throws,
    # and the rest land.
    "mixed": ["ok", "mismatch", "refused", "error", "ok", "ok"],
    # The whole-output shape: no `fixtures` map at all.
    "unavailable": "unavailable",
}

# Which scenario each compiler runs when `--scenario` is not given. These are the
# shapes a phase-1 fleet would plausibly have: complete interpreters, a native
# lane with holes, no XLA or ModelingToolkit runtime here, and a sympy lane that
# refuses everything shaped.
DEFAULT_SCENARIO = {
    "interpreter": "all_ok",
    "native": "mixed",
    "xla": "unavailable",
    "mtk": "unavailable",
    "sympy": "all_refused",
}


def tests_root(manifest_path: Path) -> Path:
    """Walk up from the manifest to the nearest ancestor named ``tests``. The same
    rule the runner and every real adapter use; a fixed number of parent hops
    breaks the moment a manifest moves a level."""
    manifest_path = manifest_path.resolve()
    for parent in manifest_path.parents:
        if parent.name == "tests":
            return parent
    return manifest_path.parent


def synthetic_value(index: int, t: float) -> float:
    """The canned trajectory: a decaying exponential per element. Deterministic and
    finite, so the golden the test mints from it is reproducible bit for bit."""
    return (index + 1) * math.exp(-0.5 * t)


def fixture_run(fixture: dict, manifest_path: Path) -> tuple[list[str], list[float]]:
    """(state order, save times) for one fixture, from whichever source defines the
    run — the manifest for a ``from: manifest`` entry, the document's own inline
    test for a ``from: inline_tests`` one."""
    tr = fixture["trajectory"]
    if tr["from"] == "manifest":
        return list(tr["initial_conditions"]), [float(t) for t in tr["saveat"]]
    doc_path = tests_root(manifest_path) / fixture["path"]
    with doc_path.open() as f:
        doc = json.load(f)
    model = doc["models"][fixture["model"]]
    test = next(t for t in model.get("tests", []) if t.get("id") == tr["test_id"])
    order = list(test.get("initial_conditions") or {})
    if not order:
        order = sorted({str(a["variable"]) for a in test.get("assertions") or []})
    times = sorted({float(a["time"]) for a in test.get("assertions") or [] if "time" in a})
    return order, times


def build(manifest: dict, manifest_path: Path, compiler: str, scenario: str) -> tuple[dict, int]:
    table = SCENARIOS[scenario]
    if table == "unavailable":
        return (
            {
                "binding": "stub",
                "compiler": compiler,
                "status": "unavailable",
                "reason": (
                    f"the stub adapter has no {compiler} runtime configured here "
                    "(canned scenario 'unavailable')"
                ),
            },
            0,
        )
    fixtures: dict[str, dict] = {}
    errored = False
    for i, fx in enumerate(manifest["fixtures"]):
        outcome = table[i] if i < len(table) else table[-1]
        if outcome == "refused":
            fixtures[fx["id"]] = {
                "status": "refused",
                "rule": f"{compiler}/lower_model",
                "reason": (
                    f"the stub adapter's canned table refuses {fx['id']} under {compiler} "
                    "(scenario " + scenario + ")"
                ),
            }
            continue
        if outcome == "error":
            errored = True
            fixtures[fx["id"]] = {
                "error": f"RuntimeError: the stub adapter's canned table errors on {fx['id']}"
            }
            continue
        order, saveat = fixture_run(fx, manifest_path)
        state = {
            repr(float(t)): {name: synthetic_value(j, float(t)) for j, name in enumerate(order)}
            for t in saveat
        }
        if outcome == "mismatch":
            # One element, one save time, moved far outside any band the manifest
            # can carry. A small perturbation would make the test depend on which
            # tolerance class the fixture happens to declare.
            first_t = repr(float(saveat[0]))
            state[first_t][order[0]] += 1.0
        fixtures[fx["id"]] = {"state_order": list(order), "state": state, "observed": {}}
    return (
        {"binding": "stub", "compiler": compiler, "fixtures": fixtures},
        1 if errored else 0,
    )


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--compiler", required=True)
    p.add_argument("--scenario", default=None, choices=sorted(SCENARIOS))
    args = p.parse_args(argv)

    with args.manifest.open() as f:
        manifest = json.load(f)
    scenario = args.scenario or DEFAULT_SCENARIO.get(args.compiler, "all_ok")
    payload, rc = build(manifest, args.manifest, args.compiler, scenario)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
