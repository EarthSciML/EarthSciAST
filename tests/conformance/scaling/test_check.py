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


def run(results, ledger, *args, binding="rust", gates=None):
    with open(os.path.join(HERE, "manifest.json")) as fh:
        manifest = json.load(fh)
    manifest = copy.deepcopy(manifest)
    manifest["ledger"] = {binding: ledger}
    for gate, fields in (gates or {}).items():
        manifest["gates"][gate].update(fields)
    with tempfile.TemporaryDirectory() as d:
        mp = os.path.join(d, "manifest.json")
        rp = os.path.join(d, "r.json")
        op = os.path.join(d, "rows.json")
        with open(mp, "w") as fh:
            json.dump(manifest, fh)
        with open(rp, "w") as fh:
            json.dump(
                {"binding": binding, "compiler": "native", "threads": 1, "results": results}, fh
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
        {
            "family": "stencil_1d",
            "n": 1000,
            "gate": "no_steady_alloc",
            "max_bytes_per_call": 128,
            "phase": 5,
        },
    ]
    code, o = run(grew, ledger)
    assert code == 0, o
    assert o[("stencil_1d", None, "code_size_flat")] == "ledgered"
    assert o[("stencil_1d", 1000, "no_steady_alloc")] == "ledgered", o
    # A ledgered allocation past the entry's own bound is red: the entry
    # excuses a few bytes per call, not a jump to megabytes.
    blew = [result("stencil_1d", 100), result("stencil_1d", 1000, allocs_per_call=4_000_000)]
    code, o = run(blew, ledger[1:])
    assert code == 1 and o[("stencil_1d", 1000, "no_steady_alloc")] == "EXCEEDS", o
    code, o = run(
        [result("stencil_1d", 100), result("stencil_1d", 1000, allocs_per_call=128)], ledger[1:]
    )
    assert code == 0 and o[("stencil_1d", 1000, "no_steady_alloc")] == "ledgered", o
    # A no_steady_alloc entry must state its bound, and only that gate has one.
    unbounded = [{"family": "stencil_1d", "n": 1000, "gate": "no_steady_alloc", "phase": 5}]
    code, o = run(grew[1:], unbounded)
    assert code == 1, o
    assert check.ledger_shape_errors({"rust": unbounded}), unbounded
    assert check.ledger_shape_errors({"rust": [dict(unbounded[0], max_bytes_per_call=True)]})
    assert check.ledger_shape_errors(
        {"rust": [{"family": "regrid", "gate": "builds", "max_bytes_per_call": 64}]}
    )
    assert not check.ledger_shape_errors({"rust": ledger})
    # The committed ledgers are well formed.
    with open(os.path.join(HERE, "manifest.json")) as fh:
        committed = json.load(fh)["ledger"]
    assert not check.ledger_shape_errors(committed), check.ledger_shape_errors(committed)

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

    # A document that built must carry each deterministic gate's measure: a
    # null there is a missing measurement, not an unmeasurable one.
    lost = [
        result(
            "stencil_1d",
            100,
            hand_loop_max_abs_diff=None,
            hand_loop_error="canonical_vars: no state named u",
        )
    ]
    code, o = run(lost, [])
    assert code == 1 and o[("stencil_1d", 100, "hand_loop_agrees")] == "FAIL", o
    code, o = run([result("stencil_1d", 100, allocs_per_call=None)], [])
    assert code == 1 and o[("stencil_1d", 100, "no_steady_alloc")] == "FAIL", o
    # ...unless the result says the measure is unmeasurable there.
    declared = [
        result(
            "stencil_1d",
            100,
            allocs_per_call=None,
            unmeasurable={"allocs_per_call": "no counting allocator on this target"},
        )
    ]
    code, o = run(declared, [])
    assert code == 0 and o[("stencil_1d", 100, "no_steady_alloc")] == "skip", o
    # A missing measurement a ledger entry covers is ledgered like any failure.
    code, o = run(lost, [{"family": "stencil_1d", "gate": "hand_loop_agrees", "phase": 2}])
    assert code == 0 and o[("stencil_1d", 100, "hand_loop_agrees")] == "ledgered", o
    # A refused document's hand loop is checked against the interpreter only up
    # to its size cap: a null there stays unmeasured.
    code, o = run(refused, [{"family": "regrid", "gate": "builds", "phase": 3}])
    assert o[("regrid", 100, "hand_loop_agrees")] == "skip", o

    # regrid's speed gate applies from 2000 states (its ladder stops at 6324),
    # so its N = 1000 and 3162 points are gated and N = 100 is not.
    rg = [
        result("regrid", n, n_states=2 * n, steady_rhs_s=1.0, hand_loop_s=1e-6)
        for n in (100, 1000, 3162)
    ]
    code, o = run(rg, [], "--report-timing")
    assert o[("regrid", 100, "speed")] == "skip", o
    assert o[("regrid", 1000, "speed")] == "FAIL" and o[("regrid", 3162, "speed")] == "FAIL", o

    # build_slope's document-size allowance: the limit is max_ns_per_state
    # plus per_byte_ns times the document bytes each added state costs.
    per_byte = {"build_slope": {"max_ns_per_state": 20, "per_byte_ns": {"rust": 10, "julia": 100}}}

    def grows(build_hi, bytes_hi, bytes_lo=1000, **kw):
        lo = result("unstructured_gather", 100, build_s=0.0, n_bytes=bytes_lo, **kw)
        hi = result(
            "unstructured_gather", 1000, n_states=1100, build_s=build_hi, n_bytes=bytes_hi, **kw
        )
        return [lo, hi]

    # 30 bytes/state at 10 ns/byte allows 20 + 300 ns/state under Rust:
    # 310 ns/state passes, 330 does not.
    code, o = run(grows(310e-9 * 1000, 31000), [], gates=per_byte)
    assert code == 0 and o[("unstructured_gather", None, "build_slope")] == "pass", o
    code, o = run(grows(330e-9 * 1000, 31000), [], gates=per_byte)
    assert code == 1 and o[("unstructured_gather", None, "build_slope")] == "FAIL", o
    # Each binding has its own per-byte cost: the same 330 ns/state is within
    # Julia's 20 + 3000.
    code, o = run(grows(330e-9 * 1000, 31000), [], binding="julia", gates=per_byte)
    assert code == 0 and o[("unstructured_gather", None, "build_slope")] == "pass", o
    # A document whose size does not grow with N gets no allowance.
    code, o = run(grows(30e-9 * 1000, 1000), [], gates=per_byte)
    assert code == 1 and o[("unstructured_gather", None, "build_slope")] == "FAIL", o
    # Nor does a result written before the adapters recorded n_bytes.
    old = grows(310e-9 * 1000, 31000)
    for r in old:
        del r["n_bytes"]
    code, o = run(old, [], gates=per_byte)
    assert code == 1 and o[("unstructured_gather", None, "build_slope")] == "FAIL", o
    assert check.build_slope_limit(
        {"binding": "go"}, per_byte["build_slope"], *grows(0, 31000)
    ) == (20, "")
    lim, _ = check.build_slope_limit(
        {"binding": "rust"}, {"max_ns_per_state": 20, "per_byte_ns": 10}, *grows(0, 31000)
    )
    assert abs(lim - 320) < 1e-9, lim

    # A family whose document grows by equations states its own per-byte rate
    # (scalar_chemistry's gate_overrides); the gate's data rate applies to the rest.
    def chem(fam, build_hi):
        lo = result(fam, 100, build_s=0.0, n_bytes=0)
        hi = result(fam, 1100, n_states=1100, build_s=build_hi, n_bytes=328_000)
        return [lo, hi]

    code, o = run(chem("scalar_chemistry", 60_000e-9 * 1000), [], "--report-timing")
    assert o[("scalar_chemistry", None, "build_slope")] == "pass", o
    code, o = run(chem("scalar_chemistry", 70_000e-9 * 1000), [], "--report-timing")
    assert o[("scalar_chemistry", None, "build_slope")] == "FAIL", o
    code, o = run(chem("unstructured_gather", 60_000e-9 * 1000), [], "--report-timing")
    assert o[("unstructured_gather", None, "build_slope")] == "FAIL", o
    code, o = run(
        chem("scalar_chemistry", 1_900_000e-9 * 1000), [], "--report-timing", binding="julia"
    )
    assert o[("scalar_chemistry", None, "build_slope")] == "pass", o

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

    # A family's stated code-size slack, per binding: stencil_2d's fused tape
    # may lose two instructions at a larger N under Rust, and not three; a
    # binding the slack does not name keeps slack 0.
    wobble = [result("stencil_2d", 100), result("stencil_2d", 1000, code_size=2)]
    code, o = run(wobble, [])
    assert code == 0 and o[("stencil_2d", None, "code_size_flat")] == "pass", o
    code, o = run([result("stencil_2d", 100), result("stencil_2d", 1000, code_size=1)], [])
    assert code == 1 and o[("stencil_2d", None, "code_size_flat")] == "FAIL", o
    code, o = run([result("stencil_1d", 100), result("stencil_1d", 1000, code_size=2)], [])
    assert code == 1 and o[("stencil_1d", None, "code_size_flat")] == "FAIL", o
    assert check.code_size_slack({"binding": "julia"}, {"code_size_flat": {"slack": 0}},
                                 {"gate_overrides": {"code_size_flat": {"slack": {"rust": 2}}}}) == 0

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


def test_check():
    main()


if __name__ == "__main__":
    main()
