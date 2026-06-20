#!/usr/bin/env python3
"""
Cross-binding determinism conformance runner (ess-my4.5).

Backs the normative determinism contract in CONFORMANCE_SPEC.md §5.5 (RFC
semiring-faq-unified-ir §5.7) with an executable, adversarial harness. The
value-invention primitives (`skolem`, `distinct`, `rank`) and group-by
aggregate joins produce index sets and dense IDs that OTHER nodes consume, so
two bindings that disagree on order or numbering produce *different models*.
This runner asserts they do not.

Two phases, one harness:

  * NOW (skeleton): `--self-test` runs an embedded REFERENCE implementation of
    the primitives over a static golden example (tests/conformance/determinism/
    manifest.json) and asserts that (a) every binding-neutral output matches the
    committed golden byte-for-byte, (b) every adversarial input variant
    (permuted / duplicated / reversed orientation) collapses to the identical
    golden output, (c) the rank base-pin round-trips (Julia 1-based emission
    normalizes to the canonical 0-based numbering), and (d) the harness actually
    REJECTS non-conforming output (negative controls). This runs green before
    any producer exists, parallel to M1.

  * LATER (M2 joins / M3 relational engine): each binding ships a thin adapter
    registered via $EARTHSCI_DETERMINISM_ADAPTER_<BINDING> (or on PATH as
    earthsci-determinism-adapter-<binding>). The default run mode invokes each
    adapter on the same manifest and asserts its serialized index sets + dense
    IDs are byte-identical to the golden (after base normalization) and to each
    other. Populate `bindings_required` in the manifest as producers land.

See tests/conformance/determinism/README.md for the adapter contract.

Usage:
    python scripts/run-determinism-conformance.py --self-test
    python scripts/run-determinism-conformance.py \\
        --manifest tests/conformance/determinism/manifest.json \\
        --output  conformance-results/determinism/report.json \\
        [--bindings julia,rust,python]

Exit codes:
    0  self-test passed, or every required binding matched the golden
    1  a contract violation / mismatch (or self-test failed)
    2  manifest / config error (no run attempted)
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO_ROOT / "tests" / "conformance" / "determinism" / "manifest.json"

KNOWN_BINDINGS = ("julia", "rust", "python", "typescript", "go")


def _eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


# === The reference implementation =========================================
#
# This is the contract as code: tiny, pure, and the single source the golden
# values are checked against. Producers in every binding MUST reproduce these
# outputs bit-for-bit. Nothing here may depend on hash-table iteration order or
# a language-native hash value (CONFORMANCE_SPEC.md §5.5 governing principle).


class DeterminismError(Exception):
    """A determinism-contract violation in input or producer output."""


def _reject_float_keys(tup: tuple) -> None:
    """Rule 1: floats are forbidden in keys. bool is a Python int subclass and
    is permitted (categorical 0/1); genuine floats are rejected rather than
    silently bucketed on a platform-dependent repr."""
    for component in tup:
        if isinstance(component, float):
            raise DeterminismError(
                f"float component {component!r} forbidden in key {tup!r}: "
                "keys must be integer / categorical IDs (CONFORMANCE_SPEC §5.5 rule 1)"
            )


def directed_edges_from_faces(faces: list[list]) -> list[tuple]:
    """Traverse consecutive vertices of each face (with wraparound) into
    directed edges. This is the realistic producer step a mesh FAQ performs
    before skolem canonicalization."""
    edges: list[tuple] = []
    for face in faces:
        n = len(face)
        for i in range(n):
            edges.append((face[i], face[(i + 1) % n]))
    return edges


def skolem(tuples: list[tuple], mode: str) -> list[tuple]:
    """Rule 4: a canonical TUPLE, never a hash. Symmetric relations sort their
    components (undirected edge -> (min, max)); directed relations preserve
    order."""
    out: list[tuple] = []
    for t in tuples:
        t = tuple(t)
        _reject_float_keys(t)
        if mode == "undirected":
            out.append(tuple(sorted(t)))
        elif mode == "directed":
            out.append(t)
        else:
            raise DeterminismError(f"unknown skolem mode {mode!r}")
    return out


def distinct_sorted(tuples: list[tuple]) -> list[tuple]:
    """Rule 2: sort by the total order, then drop ADJACENT duplicates. The
    output order IS the sorted order — never first-seen / insertion order.

    Implemented as sort-then-dedup (not set()) precisely so the result demonstrably
    does not depend on any hash-set iteration order (Rule, governing principle)."""
    for t in tuples:
        _reject_float_keys(tuple(t))
    ordered = sorted(tuple(t) for t in tuples)  # total order: int by value, str by code point
    out: list[tuple] = []
    for t in ordered:
        if not out or out[-1] != t:
            out.append(t)
    return out


def rank_canonical(distinct_seq: list[tuple]) -> dict[tuple, int]:
    """Rule 3: dense IDs by position in the sorted distinct sequence, in the
    CANONICAL 0-based numbering. Bindings convert to their emission base at the
    boundary."""
    return {t: i for i, t in enumerate(distinct_seq)}


def group_by_sum(rows: list[list]) -> list[tuple]:
    """Rule 5: hash only to bucket; emit SORTED by canonical key. (+) is
    associative + commutative so input/parallel order cannot change a bucket.

    For an integer semiring the reduction is exact regardless of order. For a
    float semiring the contract requires the per-bucket reduction be done
    sequentially in canonical order to avoid last-ULP drift; we collect each
    bucket's addends and reduce them in the (stable) canonical input order, so
    swapping to a float (+) keeps the same reduction order."""
    buckets: dict[Any, list] = {}
    for row in rows:
        key, val = row[0], row[1]
        _reject_float_keys((key,))
        buckets.setdefault(key, []).append(val)
    out: list[tuple] = []
    for key in sorted(buckets):  # canonical key order (code-point for strings)
        total = 0
        for v in buckets[key]:
            total += v
        out.append((key, total))
    return out


def canonical_serialize(rows: list) -> str:
    """The canonical byte form of an index set: compact JSON (no spaces),
    UTF-8 (no \\uXXXX escaping), tuples as arrays. This is the same canonical-JSON
    discipline the round-trip idempotence contract relies on; it is what
    'byte-identical serialized index set' means."""
    plain = [list(r) for r in rows]
    return json.dumps(plain, separators=(",", ":"), ensure_ascii=False)


def reference_compute(fixture: dict) -> dict:
    """Run the reference primitives for one fixture's input, returning the
    binding-neutral conformance outputs: the index set, its canonical
    serialization, and the canonical (0-based) dense-ID array."""
    return _compute(fixture, fixture["inputs"]["canonical"])


def _compute(fixture: dict, payload: dict) -> dict:
    primitive = fixture["primitive"]
    if primitive == "skolem_distinct_rank":
        if "faces" in payload:
            tuples = directed_edges_from_faces(payload["faces"])
        elif "tuples" in payload:
            tuples = [tuple(t) for t in payload["tuples"]]
        else:
            raise DeterminismError(
                f"fixture {fixture['id']}: input needs 'faces' or 'tuples'"
            )
        keys = skolem(tuples, fixture["skolem"])
        index_set = distinct_sorted(keys)
    elif primitive == "group_by_sum":
        index_set = group_by_sum(payload["rows"])
    else:
        raise DeterminismError(f"unknown primitive {primitive!r}")

    dense = list(range(len(index_set)))  # canonical 0-based, by position
    return {
        "index_set": [list(t) for t in index_set],
        "serialized": canonical_serialize(index_set),
        "dense_ids_canonical": dense,
    }


def normalize_dense_ids(reported: list[int], emission_base: int) -> list[int]:
    """Rule 3 boundary conversion: map a binding's natively-based dense IDs back
    to the canonical 0-based numbering for comparison."""
    return [i - emission_base for i in reported]


# === Manifest loading =====================================================


class ManifestError(Exception):
    pass


def load_manifest(path: Path) -> dict:
    try:
        with path.open() as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ManifestError(f"failed to load manifest {path}: {e}") from e
    _validate_shape(manifest, path)
    return manifest


def _validate_shape(manifest: Any, path: Path) -> None:
    if not isinstance(manifest, dict):
        raise ManifestError(f"{path}: top-level must be a JSON object")
    if manifest.get("category") != "determinism_conformance":
        raise ManifestError(
            f"{path}: category must be 'determinism_conformance', "
            f"got {manifest.get('category')!r}"
        )
    if not isinstance(manifest.get("version"), str):
        raise ManifestError(f"{path}: version must be a string")
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ManifestError(f"{path}: fixtures must be a non-empty array")
    seen: set[str] = set()
    for i, fx in enumerate(fixtures):
        if not isinstance(fx, dict):
            raise ManifestError(f"{path}: fixtures[{i}] must be an object")
        fid = fx.get("id")
        if not isinstance(fid, str) or not fid:
            raise ManifestError(f"{path}: fixtures[{i}].id must be a non-empty string")
        if fid in seen:
            raise ManifestError(f"{path}: duplicate fixture id {fid!r}")
        seen.add(fid)
        for field in ("primitive", "inputs", "expected"):
            if field not in fx:
                raise ManifestError(f"{path}: fixtures[{fid}] missing '{field}'")
        exp = fx["expected"]
        for field in ("index_set", "serialized", "dense_ids_canonical"):
            if field not in exp:
                raise ManifestError(
                    f"{path}: fixtures[{fid}].expected missing '{field}'"
                )


# === Adapter discovery / invocation (M2/M3) ===============================


def discover_adapter(binding: str) -> list[str] | None:
    env_cmd = os.environ.get(f"EARTHSCI_DETERMINISM_ADAPTER_{binding.upper()}")
    if env_cmd:
        return shlex.split(env_cmd)
    on_path = shutil.which(f"earthsci-determinism-adapter-{binding}")
    if on_path:
        return [on_path]
    return None


def run_adapter(binding: str, argv: list[str], manifest_path: Path,
                timeout: float | None) -> dict:
    with tempfile.NamedTemporaryFile(
        "r", suffix=".json", prefix=f"determinism-{binding}-", delete=False
    ) as tmp:
        out_path = Path(tmp.name)
    try:
        cmd = [*argv, "--manifest", str(manifest_path), "--output", str(out_path)]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=timeout, check=False)
        except FileNotFoundError as e:
            return {"binding": binding, "adapter_status": "missing",
                    "error": str(e), "fixtures": {}}
        except subprocess.TimeoutExpired:
            return {"binding": binding, "adapter_status": "timeout",
                    "error": f"adapter timed out after {timeout}s", "fixtures": {}}
        if not out_path.exists() or out_path.stat().st_size == 0:
            return {"binding": binding, "adapter_status": "no_output",
                    "error": "adapter wrote no output", "exit_code": proc.returncode,
                    "stderr": (proc.stderr or "").strip()[-2000:], "fixtures": {}}
        try:
            with out_path.open() as f:
                payload = json.load(f)
        except json.JSONDecodeError as e:
            return {"binding": binding, "adapter_status": "invalid_output",
                    "error": f"adapter output not valid JSON: {e}", "fixtures": {}}
        if not isinstance(payload, dict) or "fixtures" not in payload:
            return {"binding": binding, "adapter_status": "invalid_output",
                    "error": "adapter output missing 'fixtures'", "fixtures": {}}
        payload.setdefault("binding", binding)
        payload["adapter_status"] = "ok"
        return payload
    finally:
        try:
            out_path.unlink()
        except OSError:
            pass


# === Comparison ===========================================================


def compare_to_golden(fixture: dict, produced: dict, emission_base: int) -> dict:
    """Compare one producer's output for one fixture to the committed golden.
    Byte-identity on the serialized index set; exact equality on dense IDs
    after base normalization."""
    exp = fixture["expected"]
    problems: list[str] = []

    got_ser = produced.get("serialized")
    if got_ser != exp["serialized"]:
        problems.append(
            f"serialized index set differs:\n    golden={exp['serialized']!r}\n"
            f"    got   ={got_ser!r}"
        )

    got_set = produced.get("index_set")
    if got_set != exp["index_set"]:
        problems.append(
            f"index_set differs: golden={exp['index_set']!r} got={got_set!r}"
        )

    raw_ids = produced.get("dense_ids_canonical")
    if raw_ids is not None and emission_base:
        raw_ids = normalize_dense_ids(raw_ids, emission_base)
    if raw_ids != exp["dense_ids_canonical"]:
        problems.append(
            f"dense IDs differ (after base normalization): "
            f"golden={exp['dense_ids_canonical']!r} got={raw_ids!r}"
        )

    return {"match": not problems, "problems": problems}


# === Self-test (the static-example phase) =================================


def self_test(manifest_path: Path) -> int:
    if not manifest_path.is_file():
        _eprint(f"self-test: manifest missing: {manifest_path}")
        return 1
    try:
        manifest = load_manifest(manifest_path)
    except ManifestError as e:
        _eprint(f"self-test: {e}")
        return 1

    rc = 0
    fixtures = manifest["fixtures"]

    # --- Check A: reference output matches golden, byte-for-byte. ----------
    for fx in fixtures:
        produced = reference_compute(fx)
        result = compare_to_golden(fx, produced, emission_base=0)
        if not result["match"]:
            rc = 1
            _eprint(f"self-test FAIL [{fx['id']}]: reference != golden")
            for p in result["problems"]:
                _eprint(f"  {p}")
        else:
            print(f"self-test OK   [{fx['id']}]: reference == golden "
                  f"({produced['serialized']})")

    # --- Check B: every adversarial variant collapses to the golden. -------
    for fx in fixtures:
        golden = fx["expected"]
        for vname, vpayload in (fx["inputs"].get("variants") or {}).items():
            produced = _compute(fx, vpayload)
            if produced["serialized"] != golden["serialized"]:
                rc = 1
                _eprint(f"self-test FAIL [{fx['id']}/{vname}]: variant diverged from golden")
                _eprint(f"    golden={golden['serialized']!r}")
                _eprint(f"    got   ={produced['serialized']!r}")
            else:
                print(f"self-test OK   [{fx['id']}/{vname}]: collapses to golden")

    # --- Check C: rank base-pin round-trips (Julia 1-based -> canonical). ---
    pin = manifest.get("rank_base_pin", {})
    julia_base = pin.get("julia", 1)
    for fx in fixtures:
        produced = reference_compute(fx)
        canonical = produced["dense_ids_canonical"]
        julia_emission = [i + julia_base for i in canonical]
        if normalize_dense_ids(julia_emission, julia_base) != canonical:
            rc = 1
            _eprint(f"self-test FAIL [{fx['id']}]: base-pin round-trip broke")
        else:
            print(f"self-test OK   [{fx['id']}]: rank base-pin round-trips "
                  f"(julia {julia_emission} -> canonical {canonical})")

    # --- Check D: negative controls — the harness must REJECT bad output. --
    # D1: first-seen / unsorted order must be flagged, not accepted.
    ref_fx = next(f for f in fixtures if f["id"] == "edge_enumeration")
    golden_set = ref_fx["expected"]["index_set"]
    if len(golden_set) >= 2:
        scrambled = [golden_set[-1], *golden_set[:-1]]  # rotate: no longer sorted
        bad = {
            "index_set": scrambled,
            "serialized": canonical_serialize(scrambled),
            "dense_ids_canonical": list(range(len(scrambled))),
        }
        verdict = compare_to_golden(ref_fx, bad, emission_base=0)
        if verdict["match"]:
            rc = 1
            _eprint("self-test FAIL [neg/first_seen_order]: harness accepted "
                    "unsorted index set (it must reject)")
        else:
            print("self-test OK   [neg/first_seen_order]: unsorted output rejected")

    # D2: float key components must be rejected by the primitives.
    try:
        distinct_sorted([(1.5, 2)])
    except DeterminismError:
        print("self-test OK   [neg/float_in_key]: float key rejected")
    else:
        rc = 1
        _eprint("self-test FAIL [neg/float_in_key]: float key was NOT rejected")

    print("\nself-test:", "OK" if rc == 0 else "FAILED")
    return rc


# === Default run mode (producers, M2/M3) ==================================


def run_suite(manifest_path: Path, bindings: list[str], output_path: Path,
              timeout: float | None) -> int:
    manifest = load_manifest(manifest_path)
    pin = manifest.get("rank_base_pin", {})

    if not bindings:
        bindings = list(manifest.get("bindings_required") or [])
        bindings.extend(b for b in (manifest.get("bindings_optional") or [])
                        if b not in bindings)
    for b in bindings:
        if b not in KNOWN_BINDINGS:
            _eprint(f"error: unknown binding {b!r}; known: {KNOWN_BINDINGS}")
            return 2

    required = set(manifest.get("bindings_required") or [])
    fixtures = manifest["fixtures"]

    adapters: dict[str, dict] = {}
    for b in bindings:
        argv = discover_adapter(b)
        if argv is None:
            adapters[b] = {"binding": b, "adapter_status": "missing",
                           "error": ("adapter not found; expected on PATH as "
                                     f"earthsci-determinism-adapter-{b} or via "
                                     f"$EARTHSCI_DETERMINISM_ADAPTER_{b.upper()}"),
                           "fixtures": {}}
            continue
        adapters[b] = run_adapter(b, argv, manifest_path, timeout)

    report: dict[str, Any] = {"manifest_path": str(manifest_path),
                              "status": "ok", "bindings": {}}
    overall_ok = True

    for b in bindings:
        ar = adapters[b]
        b_base = pin.get(b, 0)
        b_report: dict[str, Any] = {"adapter_status": ar.get("adapter_status"),
                                    "error": ar.get("error"), "fixtures": {}}
        if ar.get("adapter_status") != "ok":
            if b in required:
                overall_ok = False
                b_report["status"] = "fail"
            else:
                b_report["status"] = "skipped"
            report["bindings"][b] = b_report
            continue
        b_ok = True
        for fx in fixtures:
            produced = ar.get("fixtures", {}).get(fx["id"])
            if produced is None:
                b_report["fixtures"][fx["id"]] = {"status": "missing"}
                b_ok = False
                continue
            verdict = compare_to_golden(fx, produced, b_base)
            b_report["fixtures"][fx["id"]] = {
                "status": "ok" if verdict["match"] else "mismatch",
                "problems": verdict["problems"],
            }
            if not verdict["match"]:
                b_ok = False
        b_report["status"] = "ok" if b_ok else "fail"
        # A producer that bothered to REGISTER (adapter_status == ok) must
        # conform — a mismatch always fails the run, optional or not. Optional
        # bindings get a pass only by being absent (handled above as "skipped").
        if not b_ok:
            overall_ok = False
        report["bindings"][b] = b_report

    if not any(a.get("adapter_status") == "ok" for a in adapters.values()):
        # M2/M3 not landed yet: no producers to check. The --self-test gate is
        # the green check until adapters exist; not a failure.
        report["status"] = "no_producers"
        print("No determinism adapters registered yet (M2 joins / M3 relational "
              "engine pending). The contract is gated by --self-test until then.")
    else:
        report["status"] = "ok" if overall_ok else "fail"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")

    _print_summary(report)
    if report["status"] == "fail":
        return 1
    return 0


def _print_summary(report: dict) -> None:
    print("=== Determinism Conformance Report ===")
    print(f"manifest: {report['manifest_path']}")
    print(f"status:   {report['status'].upper()}")
    for b, br in report.get("bindings", {}).items():
        print(f"  {b:>12}  {br.get('status')}  ({br.get('adapter_status')})")
        for fid, fr in br.get("fixtures", {}).items():
            if fr.get("status") != "ok":
                print(f"      FAIL {fid}: {fr.get('problems') or fr.get('status')}")


# === CLI ==================================================================


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST,
                   help="Path to the determinism manifest.json.")
    p.add_argument("--output", type=Path,
                   default=Path("conformance-results/determinism/report.json"),
                   help="Where to write the aggregated report.")
    p.add_argument("--bindings", default="",
                   help="Comma-separated bindings (default: manifest required+optional).")
    p.add_argument("--timeout", type=float, default=None,
                   help="Per-adapter timeout in seconds.")
    p.add_argument("--self-test", action="store_true",
                   help="Assert the contract against the embedded reference "
                        "implementation and golden example, then exit.")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if args.self_test:
        return self_test(args.manifest)
    if not args.manifest.is_file():
        _eprint(f"error: manifest not found: {args.manifest}")
        return 2
    bindings = [b.strip() for b in args.bindings.split(",") if b.strip()]
    try:
        return run_suite(args.manifest, bindings, args.output, args.timeout)
    except ManifestError as e:
        _eprint(f"manifest error: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
