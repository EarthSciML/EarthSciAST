#!/usr/bin/env python3
"""Write tests/conformance/public_rhs_program/manifest.json.

    python3 scripts/gen-public-rhs-program-manifest.py           # write it
    python3 scripts/gen-public-rhs-program-manifest.py --check   # diff only

The case table below is the source of truth: the documents, the construction
options, and the program surface each one must expose (states, parameters,
forcing slots and the default forcing). This script derives the default forcing
buffers from the documents' declared defaults and a few reference values of the
seeded generator, so a binding can test its generator before it tests a
program. See tests/conformance/public_rhs_program/README.md and
CONFORMANCE_SPEC.md §5.51.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = os.path.join(ROOT, "tests", "conformance", "public_rhs_program")
MANIFEST = os.path.join(SUITE, "manifest.json")

N_DRAWS = 4


def fnv1a32(s: str) -> int:
    x = 0x811C9DC5
    for b in s.encode("utf-8"):
        x ^= b
        x = (x * 0x01000193) & 0xFFFFFFFF
    return x


def h(key: str, k: int) -> float:
    x = (fnv1a32(key) + 0x9E3779B1 * k) & 0xFFFFFFFF
    x ^= x >> 16
    x = (x * 0x85EBCA6B) & 0xFFFFFFFF
    x ^= x >> 13
    x = (x * 0xC2B2AE35) & 0xFFFFFFFF
    x ^= x >> 16
    return x / 2**32


def state(name, offset, shape):
    return {"name": name, "offset": offset, "shape": shape}


def param(name, default):
    return {"name": name, "default": default}


def slot(name, shape, kind="forcing"):
    return {"name": name, "shape": shape, "kind": kind}


def prod(shape):
    n = 1
    for d in shape:
        n *= d
    return n


def default_buffer(doc_path: str, flat_name: str, shape: list[int]) -> list[float]:
    """The declared default of a shaped parameter, broadcast over `shape` and
    flattened column-major (first index fastest)."""
    doc = json.load(open(os.path.join(SUITE, doc_path)))
    model, var = flat_name.split(".", 1)
    d = doc["models"][model]["variables"][var]["default"]
    if not isinstance(d, list):
        return [float(d)] * prod(shape)

    # A nested JSON array is row-major in its nesting (outer list = first index);
    # flatten column-major.
    def at(a, idx):
        for i in idx:
            a = a[i]
        return a

    out = []
    idx_ranges = shape
    total = prod(idx_ranges)
    for lin in range(total):
        idx, r = [], lin
        for n in idx_ranges:
            idx.append(r % n)
            r //= n
        out.append(float(at(d, idx)))
    return out


# ---------------------------------------------------------------------------
# The case table
# ---------------------------------------------------------------------------
CASES = [
    {
        "id": "forcing_1d_data_source",
        "kind": "forcing",
        "document": "../missing_data/fixtures/loaded_field_default_served.esm",
        "options": {},
        "n_states": 4,
        "state_layout": [state("LoadedDefault.c", 0, [4])],
        "parameters": [],
        "forcing_slots": [slot("LoadedDefault.bc", [4])],
        "replace_slot": "LoadedDefault.bc",
        "stale_control": {"rust": True, "julia": False},
        "covers": [2, 4, 5],
        "note": "An existing document: a 1-D field fed by a data source with a scalar default, read straight into du. No provider is bound, so the default is the Problem's forcing.",
    },
    {
        "id": "forcing_2d_gridded",
        "kind": "forcing",
        "document": "fixtures/forcing_2d_gridded.esm",
        "options": {},
        "n_states": 31,
        "state_layout": [state("Grid2D.total", 0, []), state("Grid2D.q", 1, [6, 5])],
        "parameters": [param("Grid2D.k", 0.1), param("Grid2D.kd", 0.05)],
        "forcing_slots": [slot("Grid2D.emis", [6, 5]), slot("Grid2D.wind", [5])],
        "replace_slot": "Grid2D.emis",
        "stale_control": {"rust": True, "julia": True},
        "covers": [2, 3, 4, 5, 6, 7],
        "note": "2-D gridded forcing read through state-free observeds (a contraction and a quotient), a 1-D forcing times state, scalar parameters, t, and a zero ghost.",
    },
    {
        "id": "runtime_array_parameters",
        "kind": "array_parameters",
        "document": "../shaped_parameter_broadcast/fixtures/shaped_parameter_scalar_default.esm",
        "options": {"runtime_array_parameters": True},
        "n_states": 8,
        "state_layout": [state("Column.phi", 0, [4]), state("Column.theta", 4, [4])],
        "parameters": [],
        "forcing_slots": [
            slot("Column.ramp", [4], "array_parameter"),
            slot("Column.scale", [4], "array_parameter"),
        ],
        "replace_slot": "Column.scale",
        "stale_control": {"rust": False, "julia": False},
        "baked_twin": {
            "options": {"runtime_array_parameters": False},
            "parameters": [],
            "forcing_slots": [],
        },
        "covers": [2, 4, 5],
        "note": "An existing document: two shaped parameters, one with a scalar default broadcast over its shape and one with an array default. With the option on both are ArrayParameter slots; with it off neither is a slot and both are baked.",
    },
    {
        "id": "fault_state_gather",
        "kind": "fault",
        "document": "fixtures/fault_state_gather.esm",
        "options": {},
        "n_states": 2,
        "state_layout": [state("FaultGather.w", 0, []), state("FaultGather.y", 1, [])],
        "parameters": [param("FaultGather.rate", 2.0)],
        "forcing_slots": [],
        "ok_state": {"FaultGather.w": 2.25, "FaultGather.y": 0.0},
        "fault_state": {"FaultGather.w": 7.5, "FaultGather.y": 0.0},
        "expect_error": {"code": "E_TREEWALK_CONSTARRAY_OOB"},
        "covers": [6],
        "note": "A const-array read at a subscript computed from the state w: in range for w < 5, past the end (index 8) at w = 7.5. No forcing: the empty forcing set is a valid argument.",
    },
]


def build() -> dict:
    cases = []
    for c in CASES:
        c = dict(c)
        c["default_forcing"] = {
            s["name"]: default_buffer(c["document"], s["name"], s["shape"])
            for s in c["forcing_slots"]
        }
        cases.append(c)
    checks = []
    for key, k in [
        ("u0/Grid2D.q", 1),
        ("u0/Grid2D.q", 30),
        ("p1/Grid2D.k", 1),
        ("t2", 1),
        ("fA/Grid2D.emis", 7),
        ("fB/Grid2D.emis", 7),
    ]:
        checks.append({"key": key, "k": k, "h": h(key, k)})
    return {
        "category": "public_rhs_program",
        "version": "1.0",
        "description": (
            "The public, thread-safe right-hand side (issue #541): a program built once and "
            "evaluated with a caller-owned workspace and an immutable, epoch-stamped forcing set. "
            "Every comparison is BITWISE against the same binding's existing single-threaded "
            "evaluation (Rust debug_eval_rhs_into with a taped scratch; Julia the Problem's f!) or "
            "against the same program's own serial results. Generated by "
            "scripts/gen-public-rhs-program-manifest.py."
        ),
        "spec": [
            "API_SPEC.md §5.8 (The public right-hand side)",
            "CONFORMANCE_SPEC.md §5.51",
        ],
        "compiler": "native",
        "bindings_required": ["julia", "rust"],
        "scope_excluded": {
            "python": "No native program (API_SPEC §5.8): rhs_program, forcing_set and default_forcing_set raise compiler_unavailable, which pkg/earthsci-ast-py/tests/test_public_rhs_program.py asserts for the first case.",
            "typescript": "No simulator (API_SPEC §3, capability profiles).",
            "go": "No simulator (API_SPEC §3, capability profiles).",
        },
        "generator": {
            "name": "hash01",
            "h": "x = (fnv1a32(key) + 0x9e3779b1 * k) mod 2^32; x ^= x >> 16; x = (x * 0x85ebca6b) mod 2^32; x ^= x >> 13; x = (x * 0xc2b2ae35) mod 2^32; x ^= x >> 16; h = x / 2^32",
            "fnv1a32": "FNV-1a, 32-bit: offset basis 0x811c9dc5, prime 0x01000193, over the UTF-8 bytes of key",
            "note": "The same function as tests/conformance/range_restricted_rhs (there keyed by the bare variable name). Here the key carries a prefix naming what is drawn.",
            "checks": checks,
        },
        "draws": {
            "count": N_DRAWS,
            "u": 'element k (1-based, column-major over the declared shape; 1 for a 0-d state) of state block v in draw d: 0.5 + h("u<d>/<v>", k)',
            "p": 'draw 0: parameter_vector(prog, {}) (the defaults); draw d >= 1: parameter named n is 0.5 + h("p<d>/<n>", 1), passed through parameter_vector as overrides',
            "t": 'draw 0: 0.0; draw d >= 1: 10 * h("t<d>", 1)',
            "aux": "empty (every program in this suite is whole-domain)",
        },
        "forcing_sets": {
            "D": "default_forcing_set(prog) / RhsProgram::default_forcing(): must equal the case's default_forcing bitwise",
            "A": 'element k (1-based, column-major) of slot s: 0.5 + h("fA/<s>", k), one buffer per forcing_slots entry',
            "B": 'replace_forcing(A, replace_slot, buf) / A.replace(..): buf element k is 0.5 + h("fB/<replace_slot>", k); every other buffer is A\'s',
        },
        "fills": {"du_prefill": "NaN"},
        "concurrency": {
            "tasks": "every (draw, set) pair, sets D, A, B (fault case: the ok_state and the draws, set D)",
            "threads": 16,
            "calls_per_thread": 1000,
            "pick": 'call j (1-based) of thread q (1-based) evaluates task floor(h("c<q>", j) * n_tasks) + 1',
        },
        "history_order": 'task i (1-based) of the full task list is evaluated in the order of ascending h("order", i), ties by i',
        "cases": cases,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = json.dumps(build(), indent=1) + "\n"
    if args.check:
        cur = open(MANIFEST).read() if os.path.exists(MANIFEST) else ""
        if cur != text:
            print(
                f"{MANIFEST} is stale; run scripts/gen-public-rhs-program-manifest.py",
                file=sys.stderr,
            )
            return 1
        return 0
    open(MANIFEST, "w").write(text)
    print(f"wrote {MANIFEST}: {len(CASES)} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
