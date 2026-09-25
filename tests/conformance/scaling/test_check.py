#!/usr/bin/env python3
"""The checker's own test: canned result files through every outcome.

python3 tests/conformance/scaling/test_check.py
"""

import copy
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check  # noqa: E402


def result(family, n, **kw):
    r = {
        "family": family,
        "n": n,
        "n_cells": n,
        "n_states": n,
        "status": "ok",
        "reason": None,
        "build_s": 1e-3 + n * 1e-8,
        "code_size": 4,
        "code_size_unit": "tape_instructions",
        "first_call_s": 1e-5,
        "steady_rhs_s": n * 1e-9,
        "allocs_per_call": 0,
        "hand_loop_s": n * 1e-9,
        "hand_loop_max_abs_diff": 0.0,
        "dy_max_abs": 1.0,
        "interpreter_max_abs_diff": 0.0,
    }
    r.update(kw)
    return r


def run(results, ledger, *args):
    with open(os.path.join(HERE, "manifest.json")) as fh:
        manifest = json.load(fh)
    manifest = copy.deepcopy(manifest)
    manifest["ledger"] = {"rust": ledger}
    with tempfile.TemporaryDirectory() as d:
        mp = os.path.join(d, "manifest.json")
        rp = os.path.join(d, "r.json")
        op = os.path.join(d, "rows.json")
        with open(mp, "w") as fh:
            json.dump(manifest, fh)
        with open(rp, "w") as fh:
            json.dump(
                {"binding": "rust", "compiler": "native", "threads": 1, "results": results}, fh
            )
        code = check.main([rp, "--manifest", mp, "--json", op, *args])
        with open(op) as fh:
            rows = json.load(fh)["rows"]
    return code, {(r["family"], r["n"], r["gate"]): r["outcome"] for r in rows}


def main():
    ok = [result("stencil_1d", 100), result("stencil_1d", 1000)]
    code, o = run(ok, [])
    assert code == 0, o
    assert o[("stencil_1d", None, "code_size_flat")] == "pass"
    assert o[("stencil_1d", 100, "no_steady_alloc")] == "pass"

    # An unledgered failure is red; the same failure ledgered is not.
    grew = [result("stencil_1d", 100), result("stencil_1d", 1000, code_size=5, allocs_per_call=64)]
    code, o = run(grew, [])
    assert code == 1 and o[("stencil_1d", None, "code_size_flat")] == "FAIL", o
    assert o[("stencil_1d", 1000, "no_steady_alloc")] == "FAIL", o
    ledger = [
        {"family": "stencil_1d", "gate": "code_size_flat", "phase": 2},
        {"family": "stencil_1d", "n": 1000, "gate": "no_steady_alloc", "phase": 5},
    ]
    code, o = run(grew, ledger)
    assert code == 0, o
    assert o[("stencil_1d", None, "code_size_flat")] == "ledgered"

    # A deterministic ledger entry that now passes is red ("remove this entry").
    code, o = run(ok, ledger)
    assert code == 1 and o[("stencil_1d", 1000, "no_steady_alloc")] == "STALE", o

    # A refusal fails `builds` and leaves the other gates unmeasured.
    refused = [
        result(
            "regrid",
            100,
            status="refused",
            reason="polygon_intersection_area",
            code_size=None,
            allocs_per_call=None,
            hand_loop_max_abs_diff=None,
        )
    ]
    code, o = run(refused, [])
    assert code == 1 and o[("regrid", 100, "builds")] == "FAIL", o
    assert o[("regrid", 100, "no_steady_alloc")] == "skip"
    code, o = run(refused, [{"family": "regrid", "gate": "builds", "phase": 3}])
    assert code == 0, o

    # A timing gate that now passes under a ledger entry is reported, not red.
    big = [result("stencil_1d", 10000), result("stencil_1d", 100000)]
    code, o = run(big, [{"family": "stencil_1d", "n": 100000, "gate": "speed", "phase": 5}])
    assert code == 0 and o[("stencil_1d", 100000, "speed")] == "fixed?", o
    slow = [result("stencil_1d", 10000), result("stencil_1d", 100000, steady_rhs_s=1.0)]
    code, o = run(slow, [])
    assert code == 1 and o[("stencil_1d", 100000, "speed")] == "FAIL", o
    code, o = run(slow, [], "--report-timing")
    assert code == 0 and o[("stencil_1d", 100000, "speed")] == "FAIL", o
    code, o = run(slow, [], "--gates", "deterministic")
    assert code == 0 and ("stencil_1d", 100000, "speed") not in o, o

    # A wrong hand loop is caught even when native looks fast.
    wrong = [result("stencil_1d", 100, hand_loop_max_abs_diff=1e-3)]
    code, o = run(wrong, [])
    assert code == 1 and o[("stencil_1d", 100, "hand_loop_agrees")] == "FAIL", o

    # --require names what is missing.
    code, o = run(ok, [], "--require", "pr")
    assert code == 1 and o[("stencil_2d", 100, "present")] == "MISSING", o
    # An entry with n_min is not exercised by a run that stops below it.
    late = [{"family": "stencil_1d", "gate": "code_size_flat", "n_min": 100000, "phase": 2}]
    code, o = run(ok, late)
    assert code == 0 and o[("stencil_1d", None, "code_size_flat")] == "pass", o
    grown = ok + [result("stencil_1d", 100000, code_size=2)]
    code, o = run(grown, late)
    assert code == 0 and o[("stencil_1d", None, "code_size_flat")] == "ledgered", o

    # --require looks across files: one file per family is a complete sweep.
    with open(os.path.join(HERE, "manifest.json")) as fh:
        fams = json.load(fh)["families"]
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for fam, spec in fams.items():
            rs = [result(fam, n) for n in spec["pr_sizes"]]
            path = os.path.join(d, f"{fam}.json")
            with open(path, "w") as fh:
                json.dump(
                    {"binding": "julia", "compiler": "native", "threads": 1, "results": rs}, fh
                )
            paths.append(path)
        out = os.path.join(d, "rows.json")
        check.main([*paths, "--require", "pr", "--json", out])
        with open(out) as fh:
            outcomes = {r["outcome"] for r in json.load(fh)["rows"]}
        assert "MISSING" not in outcomes, outcomes
    print("test_check: ok")


if __name__ == "__main__":
    main()
