#!/usr/bin/env python3
"""
Cross-binding conservative-regridding geometry conformance runner (ess-my4.4.8).

Backs the normative geometry tolerance contract in CONFORMANCE_SPEC.md §5.8 (RFC
semiring-faq-unified-ir §8.1 + Appendix B.5) with an executable, adversarial
harness. This is the **tolerance-mode analogue** of the determinism gate
(scripts/run-determinism-conformance.py): unlike the byte-identity contracts in
§5.5–§5.7, the conservative regridder's areas/weights are compared with a
combined relative + absolute tolerance and a sliver floor, and the PRIMARY gate
is the physical invariants — global conservation and partition-of-unity. The one
thing that stays byte-identical is the integer broad-phase **candidate
overlap-pair index set** (the bin-Skolem equi-join), which falls under the §5.5
determinism contract.

The gate asserts, in priority order (CONFORMANCE_SPEC.md §5.8.6):

  1. Candidate set — the bin-Skolem candidate overlap-pair index set is
     byte-identical across bindings (after base normalization), INCLUDING the
     adversarial permuted-input-order variant, which MUST collapse to the
     identical candidate set (§5.8.5).
  2. Invariants — partition-of-unity Σ_i W_ij = 1 to a tight epsilon (exact by
     construction) and, for fixtures whose target tiles the source domain,
     global conservation Σ_j A_j·F_tgt[j] = Σ_i A_i·F_src[i] within the
     application/resolution tolerance (§5.8.3).
  3. Per-pair areas / weights — within atol + rtol·A_ref, with sub-atol slivers
     treated as zero ("present-but-tiny" and "absent" both pass) (§5.8.2).

Two phases, one harness (mirrors the determinism gate):

  * NOW (skeleton, gated by `--self-test`): the runner asserts the contract
    against an embedded REFERENCE implementation (pure-Python bin-Skolem broad
    phase + planar Sutherland–Hodgman clip + shoelace area) over the static
    golden example (tests/conformance/geometry/manifest.json). It verifies the
    candidate set reproduces the golden byte-for-byte (planar AND spherical —
    binning is manifold-independent), every permuted variant collapses to it,
    the planar areas reproduce the golden, partition-of-unity is the algebraic
    identity it claims to be, conservation is exact for the tiling fixtures, and
    the harness actually REJECTS non-conforming output (negative controls).

  * PRODUCERS (live — the M4 assemblies ess-my4.4.6 / .4.7 have landed): each
    binding ships a thin adapter registered via
    $EARTHSCI_GEOMETRY_ADAPTER_<BINDING> (or on PATH as
    earthsci-geometry-adapter-<binding>). The default run mode invokes each
    adapter on the same manifest — over the canonical input AND every adversarial
    variant — and asserts its candidate set is byte-identical to the golden, its
    invariants hold to tolerance, and its per-pair areas agree with the golden
    (and, when ≥2 bindings run together, with the reference binding) within the
    §5.8.2 tolerance. The first cut gates Julia + Python; Rust folds into the
    same gate once its S2 FFI binding lands (ess-my4.4.10/.11/.12).

See tests/conformance/geometry/README.md for the adapter contract.

Usage:
    python scripts/run-geometry-conformance.py --self-test
    python scripts/run-geometry-conformance.py \\
        --manifest tests/conformance/geometry/manifest.json \\
        --output  conformance-results/geometry/report.json \\
        [--bindings julia,python]

Exit codes:
    0  self-test passed, or every required binding matched the contract
    1  a contract violation / mismatch (or self-test failed)
    2  manifest / config error (no run attempted)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO_ROOT / "tests" / "conformance" / "geometry" / "manifest.json"

KNOWN_BINDINGS = ("julia", "rust", "python", "typescript", "go")

# Tolerance defaults — the spec pins only one numeric literal (atol ≈ 1e-15·R²,
# the sliver floor); rtol, the conservation tolerance, and the partition-of-unity
# epsilon are intentionally calibrated / application-set / exact-by-construction
# (CONFORMANCE_SPEC.md §5.8.2-3). The manifest's `tolerances` block overrides
# these; they are the documented fallbacks.
DEFAULT_TOLERANCES = {
    "area_rtol": 1e-9,          # matches REGRID_DEFAULT_RTOL in both bindings
    "area_atol_factor": 1e-15,  # atol = factor · R²  (R = characteristic length)
    "partition_of_unity_atol": 1e-12,
    "conservation_atol": 1e-9,
}


def _eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


# === The reference implementation =========================================
#
# The contract as code: pure, hash-free, and the single source the planar golden
# values are checked against. The broad phase here is exactly the determinism
# contract (integer bin keys → equi-join → distinct, all in sorted total order);
# the narrow phase is a Sutherland–Hodgman convex clip + shoelace area, valid for
# the axis-aligned rectangular cells of the planar fixtures. Spherical areas are
# NOT reproduced here (they need an S2/GeometryOps stack); for spherical fixtures
# the reference checks only the manifold-independent candidate set and the
# algebraic invariants, and the committed golden areas are binding-derived.


class GeometryError(Exception):
    """A geometry-conformance contract violation in input or producer output."""


def _reject_float_bin(component: Any, ctx: str) -> None:
    """§5.8.5: no float in a broad-phase key. Bin coordinates are integers minted
    by floor(); a float component means a producer leaked a raw coordinate into
    the key instead of quantizing it."""
    if isinstance(component, float) and not isinstance(component, bool):
        raise GeometryError(
            f"float component {component!r} forbidden in bin key ({ctx}): the "
            "broad phase must be integer-keyed (CONFORMANCE_SPEC §5.8.5)"
        )


def _bbox(poly: list[list[float]]) -> tuple[float, float, float, float]:
    xs = [v[0] for v in poly]
    ys = [v[1] for v in poly]
    return min(xs), max(xs), min(ys), max(ys)


def cell_bin_keys(poly: list[list[float]], dx: float, dy: float) -> list[tuple]:
    """Every integer spatial-bin Skolem key the cell's bbox spans — quantize to
    floor(coord/step) and mint ("bin", bx, by) for each spanned bin. Binning by
    the full bbox span (not one corner) keeps the broad phase complete."""
    lo_x, hi_x, lo_y, hi_y = _bbox(poly)
    bx_lo, bx_hi = math.floor(lo_x / dx), math.floor(hi_x / dx)
    by_lo, by_hi = math.floor(lo_y / dy), math.floor(hi_y / dy)
    keys = []
    for bx in range(bx_lo, bx_hi + 1):
        for by in range(by_lo, by_hi + 1):
            keys.append(("bin", bx, by))
    return keys


def candidate_overlap_pairs(
    src_polys: list, tgt_polys: list, dx: float, dy: float
) -> list[tuple[int, int]]:
    """The bin-Skolem candidate overlap-pair set {(i, j)} (broad phase), 0-based.
    Equi-join of the (bin_key, cell) tables on the shared bin key, then distinct
    over the surviving (i, j) pairs — emitted in sorted total order, so the result
    is the byte-identical, permutation-invariant candidate set the gate asserts
    on. No floating-point coordinate comparison enters here."""
    src_rows = []
    for i, p in enumerate(src_polys):
        for key in cell_bin_keys(p, dx, dy):
            for c in key[1:]:
                _reject_float_bin(c, "src")
            src_rows.append((key, i))
    tgt_rows = []
    for j, p in enumerate(tgt_polys):
        for key in cell_bin_keys(p, dx, dy):
            for c in key[1:]:
                _reject_float_bin(c, "tgt")
            tgt_rows.append((key, j))
    # value-equality equi-join on the bin key, then distinct over the (i,j) pairs
    by_key: dict[tuple, list[int]] = {}
    for key, j in tgt_rows:
        by_key.setdefault(key, []).append(j)
    pairs: set[tuple[int, int]] = set()
    for key, i in src_rows:
        for j in by_key.get(key, ()):
            pairs.add((i, j))
    return sorted(pairs)  # sorted total order — never hash/first-seen order


def _left(a: list[float], b: list[float], p: list[float]) -> float:
    """Signed area ×2 of triangle (a, b, p); ≥ 0 ⟺ p is left-of / on directed
    edge a→b. For a CCW convex clip polygon the interior is the left half-plane."""
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])


def _edge_intersect(s: list[float], e: list[float],
                    a: list[float], b: list[float]) -> list[float]:
    """Intersection of segment s→e with the infinite line a→b."""
    dc = (a[0] - b[0], a[1] - b[1])
    dp = (s[0] - e[0], s[1] - e[1])
    n1 = a[0] * b[1] - a[1] * b[0]
    n2 = s[0] * e[1] - s[1] * e[0]
    denom = dc[0] * dp[1] - dc[1] * dp[0]
    if denom == 0.0:
        return [e[0], e[1]]  # parallel — shouldn't happen for a real crossing
    x = (n1 * dp[0] - n2 * dc[0]) / denom
    y = (n1 * dp[1] - n2 * dc[1]) / denom
    return [x, y]


def _clip_planar(subject: list[list[float]],
                 clip: list[list[float]]) -> list[list[float]]:
    """Sutherland–Hodgman: clip the subject polygon against each edge of the
    convex CCW clip polygon. Boundary points count as inside (≥ 0) so that a
    purely edge-tangent overlap yields a degenerate (zero-area) ring rather than
    vanishing — the sliver floor, not the clipper, decides it is absent."""
    output = [list(v) for v in subject]
    n = len(clip)
    for k in range(n):
        a, b = clip[k], clip[(k + 1) % n]
        if not output:
            break
        input_list = output
        output = []
        s = input_list[-1]
        for e in input_list:
            e_in = _left(a, b, e) >= 0
            s_in = _left(a, b, s) >= 0
            if e_in:
                if not s_in:
                    output.append(_edge_intersect(s, e, a, b))
                output.append([e[0], e[1]])
            elif s_in:
                output.append(_edge_intersect(s, e, a, b))
            s = e
    return output


def _shoelace_area(ring: list[list[float]]) -> float:
    """|Σ ½(x_v·y_{v+1} − x_{v+1}·y_v)| — the planar polygon_area FAQ."""
    n = len(ring)
    if n < 3:
        return 0.0
    acc = 0.0
    for v in range(n):
        x0, y0 = ring[v]
        x1, y1 = ring[(v + 1) % n]
        acc += x0 * y1 - x1 * y0
    return abs(acc) * 0.5


def reference_overlap_area(poly_a: list, poly_b: list, manifold: str,
                           atol: float) -> float:
    """Reference A_ij for a single candidate pair (planar only). Sub-atol slivers
    snap to exactly zero."""
    if manifold != "planar":
        raise GeometryError(
            f"reference clip is planar-only; got manifold {manifold!r}"
        )
    ring = _clip_planar(poly_a, poly_b)
    area = _shoelace_area(ring)
    return 0.0 if area <= atol else area


def reference_assemble(fixture: dict, payload: dict, atol: float) -> dict:
    """Run the reference broad+narrow phase for one fixture payload, returning the
    candidate set and (planar only) the post-floor per-pair areas + the assembled
    A_j / weights / invariant residuals."""
    src, tgt = payload["src"], payload["tgt"]
    dx, dy = fixture["dx"], fixture["dy"]
    manifold = fixture["manifold"]
    pairs = candidate_overlap_pairs(src, tgt, dx, dy)
    record: dict[str, Any] = {
        "candidate_pairs": [list(p) for p in pairs],
        "serialized": canonical_serialize([list(p) for p in pairs]),
    }
    if manifold != "planar":
        return record  # spherical: candidate set only (areas are binding-derived)

    n_src, n_tgt = len(src), len(tgt)
    a_ij = [[0.0] * n_tgt for _ in range(n_src)]
    areas: list[list] = []
    for (i, j) in pairs:
        a = reference_overlap_area(src[i], tgt[j], manifold, atol)
        a_ij[i][j] = a
        areas.append([i, j, a])
    a_j = [sum(a_ij[i][j] for i in range(n_src)) for j in range(n_tgt)]
    # partition-of-unity residual per covered target cell
    pou = 0.0
    for j in range(n_tgt):
        if a_j[j] > 0.0:
            w_sum = sum(a_ij[i][j] / a_j[j] for i in range(n_src))
            pou = max(pou, abs(w_sum - 1.0))
    record["areas"] = areas
    record["A_j"] = a_j
    record["partition_of_unity_max_residual"] = pou
    f_src = fixture.get("F_src")
    src_areas = fixture.get("src_areas")
    if f_src is not None and src_areas is not None:
        f_tgt = [
            (sum(a_ij[i][j] * f_src[i] for i in range(n_src)) / a_j[j])
            if a_j[j] > 0.0 else 0.0
            for j in range(n_tgt)
        ]
        cons = sum(a_j[j] * f_tgt[j] for j in range(n_tgt)) - sum(
            src_areas[i] * f_src[i] for i in range(n_src))
        record["conservation_residual"] = cons
    return record


def canonical_serialize(rows: list) -> str:
    """The canonical byte form of an index set: compact JSON (no spaces), UTF-8,
    tuples as arrays — the same discipline the determinism gate uses. This is what
    'byte-identical candidate set' means."""
    plain = [list(r) for r in rows]
    return json.dumps(plain, separators=(",", ":"), ensure_ascii=False)


def normalize_pairs(pairs: list, base: int) -> list[list[int]]:
    """Map a binding's natively-based candidate pairs back to canonical 0-based
    (Julia emits 1-based; the harness normalizes via base_pin), then re-sort so
    the canonical serialization is order-independent of the producer."""
    out = [[i - base, j - base] for (i, j) in pairs]
    return sorted(out)


def remap_pairs(pairs: list, base: int, src_order: list[int],
                tgt_order: list[int]) -> list[list[int]]:
    """Translate a permuted-variant's emitted pairs back to canonical labels:
    base-normalize, then map each permuted position through the variant's
    src_order / tgt_order to its canonical index. Proves the candidate set is
    permutation-invariant (§5.8.5)."""
    out = []
    for (i, j) in pairs:
        out.append([src_order[i - base], tgt_order[j - base]])
    return sorted(out)


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
    if manifest.get("category") != "geometry_conformance":
        raise ManifestError(
            f"{path}: category must be 'geometry_conformance', "
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
        for field in ("manifold", "dx", "dy", "inputs", "expected"):
            if field not in fx:
                raise ManifestError(f"{path}: fixtures[{fid}] missing '{field}'")
        if "canonical" not in fx["inputs"]:
            raise ManifestError(
                f"{path}: fixtures[{fid}].inputs missing 'canonical'")
        for field in ("candidate_index_set", "candidate_serialized"):
            if field not in fx["expected"]:
                raise ManifestError(
                    f"{path}: fixtures[{fid}].expected missing '{field}'")


def fixture_atol(fixture: dict, tolerances: dict) -> float:
    """The §5.8.2 sliver floor atol ≈ factor·R² for this fixture (R = its declared
    characteristic length, default 1)."""
    r = fixture.get("characteristic_length", 1.0)
    return tolerances["area_atol_factor"] * r * r


# === Adapter discovery / invocation =======================================


def discover_adapter(binding: str) -> list[str] | None:
    env_cmd = os.environ.get(f"EARTHSCI_GEOMETRY_ADAPTER_{binding.upper()}")
    if env_cmd:
        return shlex.split(env_cmd)
    on_path = shutil.which(f"earthsci-geometry-adapter-{binding}")
    if on_path:
        return [on_path]
    return None


def run_adapter(binding: str, argv: list[str], manifest_path: Path,
                timeout: float | None) -> dict:
    with tempfile.NamedTemporaryFile(
        "r", suffix=".json", prefix=f"geometry-{binding}-", delete=False
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


def _areas_to_map(areas: list, atol: float, base: int = 0) -> dict[tuple, float]:
    """Index a producer's per-pair area list by canonical 0-based (i, j),
    snapping sub-atol areas to zero (§5.8.2 'present-but-tiny' == 'absent')."""
    out: dict[tuple, float] = {}
    for row in areas or ():
        i, j, a = row[0], row[1], float(row[2])
        out[(i - base, j - base)] = 0.0 if a <= atol else a
    return out


def area_match(a_ref: float, a_got: float, atol: float, rtol: float) -> bool:
    """§5.8.2: |A_got − A_ref| ≤ atol + rtol·A_ref, with both sides already
    sub-atol-floored to zero by the caller."""
    return abs(a_got - a_ref) <= atol + rtol * a_ref


def compare_to_golden(fixture: dict, produced: dict, base: int,
                      tolerances: dict) -> dict:
    """Compare one producer's output for one fixture to the committed golden:
    byte-identity on the candidate set; partition-of-unity to a tight epsilon;
    conservation (tiling fixtures only) within tolerance; per-pair areas within
    the §5.8.2 tolerance against the golden (when the golden pins them)."""
    exp = fixture["expected"]
    atol = fixture_atol(fixture, tolerances)
    rtol = fixture.get("area_rtol", tolerances["area_rtol"])
    problems: list[str] = []

    # (1) Candidate set — byte-identical after base normalization (PRIMARY).
    got_pairs = produced.get("candidate_pairs")
    if got_pairs is None:
        problems.append("adapter emitted no 'candidate_pairs'")
    else:
        norm = normalize_pairs([tuple(p) for p in got_pairs], base)
        got_ser = canonical_serialize(norm)
        if got_ser != exp["candidate_serialized"]:
            problems.append(
                "candidate set differs (after base normalization):\n"
                f"    golden={exp['candidate_serialized']!r}\n"
                f"    got   ={got_ser!r}"
            )

    # The narrow phase (clip + area) needs a geometry backend the broad phase
    # does not — Python's spherical clip requires the optional `spherely` (S2)
    # dependency. When a binding reports it is unavailable, the candidate set
    # (computed above, backend-free) is still gated, but the area / invariant
    # sub-checks are skipped for this fixture rather than failed. The planar
    # fixtures need no backend, so this only ever degrades the spherical cells.
    if produced.get("narrow_phase_unavailable"):
        return {"match": not problems, "problems": problems,
                "narrow_phase_skipped": True}

    # (2a) Partition-of-unity — exact by construction, tight epsilon.
    pou = produced.get("partition_of_unity_max_residual")
    if pou is not None and abs(float(pou)) > tolerances["partition_of_unity_atol"]:
        problems.append(
            f"partition-of-unity residual {pou!r} exceeds tight epsilon "
            f"{tolerances['partition_of_unity_atol']:g} (§5.8.3)"
        )

    # (2b) Global conservation — only where the target tiles the source domain.
    if fixture.get("conservation_exact"):
        cons = produced.get("conservation_residual")
        if cons is None:
            problems.append(
                "fixture is conservation_exact but adapter emitted no "
                "'conservation_residual'"
            )
        elif abs(float(cons)) > tolerances["conservation_atol"]:
            problems.append(
                f"conservation residual {cons!r} exceeds tolerance "
                f"{tolerances['conservation_atol']:g} (§5.8.3)"
            )

    # (3) Per-pair areas — against the golden, when the golden pins them.
    if "areas" in exp:
        golden_areas = _areas_to_map(exp["areas"], atol, base=0)
        got_areas = _areas_to_map(produced.get("areas", []), atol, base=base)
        for key, a_ref in golden_areas.items():
            a_got = got_areas.get(key, 0.0)
            if not area_match(a_ref, a_got, atol, rtol):
                problems.append(
                    f"area for pair {list(key)} out of tolerance: "
                    f"golden={a_ref!r} got={a_got!r} "
                    f"(atol={atol:g}, rtol={rtol:g})"
                )
        for key, a_got in got_areas.items():
            if key not in golden_areas and not area_match(0.0, a_got, atol, rtol):
                problems.append(
                    f"area for pair {list(key)} present in producer but not "
                    f"golden and above the sliver floor: got={a_got!r}"
                )

    return {"match": not problems, "problems": problems}


def compare_variants(fixture: dict, produced: dict, base: int) -> dict:
    """Assert every adversarial input variant collapses to the golden candidate
    set after base-normalization and the variant's index remap. A fixture that
    declares variants whose adapter emitted no matching block is a FAILURE."""
    golden = fixture["expected"]
    declared = fixture.get("inputs", {}).get("variants") or {}
    if not declared:
        return {"match": True, "problems": []}
    produced_variants = produced.get("variants")
    if not isinstance(produced_variants, dict):
        return {
            "match": False,
            "problems": [
                f"adapter emitted no 'variants' for a fixture with "
                f"{len(declared)} adversarial input(s); cannot prove "
                "permutation-independence (§5.8.5)"
            ],
        }
    problems: list[str] = []
    for vname, vspec in declared.items():
        v = produced_variants.get(vname)
        if not isinstance(v, dict):
            problems.append(f"variant {vname!r} missing from adapter output")
            continue
        got_pairs = v.get("candidate_pairs")
        if got_pairs is None:
            problems.append(f"variant {vname!r} emitted no 'candidate_pairs'")
            continue
        src_order = vspec.get("src_order")
        tgt_order = vspec.get("tgt_order")
        if src_order is not None and tgt_order is not None:
            remapped = remap_pairs([tuple(p) for p in got_pairs], base,
                                   src_order, tgt_order)
        else:
            remapped = normalize_pairs([tuple(p) for p in got_pairs], base)
        got_ser = canonical_serialize(remapped)
        if got_ser != golden["candidate_serialized"]:
            problems.append(
                f"variant {vname!r} did not collapse to golden candidate set:\n"
                f"    golden={golden['candidate_serialized']!r}\n"
                f"    got   ={got_ser!r}"
            )
    return {"match": not problems, "problems": problems}


def compare_cross_binding(fixture: dict, ref: dict, ref_base: int,
                          other: dict, other_base: int,
                          tolerances: dict) -> list[str]:
    """Per-pair area agreement between a binding and the reference binding
    (§5.8.2). Used for fixtures the golden does not pin numerically (the spherical
    cells, whose areas are S2/GeometryOps-derived): two bindings may legitimately
    disagree only within atol + rtol·A_ref, sub-atol slivers treated as zero."""
    if ref.get("narrow_phase_unavailable") or other.get("narrow_phase_unavailable"):
        return []  # a backend is absent on one side — nothing to cross-check
    atol = fixture_atol(fixture, tolerances)
    rtol = fixture.get("area_rtol", tolerances["area_rtol"])
    ref_areas = _areas_to_map(ref.get("areas", []), atol, base=ref_base)
    other_areas = _areas_to_map(other.get("areas", []), atol, base=other_base)
    problems: list[str] = []
    for key in sorted(set(ref_areas) | set(other_areas)):
        a_ref = ref_areas.get(key, 0.0)
        a_got = other_areas.get(key, 0.0)
        if not area_match(a_ref, a_got, atol, rtol):
            problems.append(
                f"cross-binding area for pair {list(key)} disagrees beyond "
                f"tolerance: ref={a_ref!r} got={a_got!r} "
                f"(atol={atol:g}, rtol={rtol:g})"
            )
    return problems


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
    tolerances = {**DEFAULT_TOLERANCES, **manifest.get("tolerances", {})}

    # --- Check A: reference candidate set + planar areas + invariants. ------
    for fx in fixtures:
        atol = fixture_atol(fx, tolerances)
        produced = reference_assemble(fx, fx["inputs"]["canonical"], atol)
        exp = fx["expected"]
        if produced["serialized"] != exp["candidate_serialized"]:
            rc = 1
            _eprint(f"self-test FAIL [{fx['id']}]: candidate set != golden")
            _eprint(f"    golden={exp['candidate_serialized']!r}")
            _eprint(f"    got   ={produced['serialized']!r}")
        else:
            print(f"self-test OK   [{fx['id']}]: candidate set == golden "
                  f"({produced['serialized']})")

        if fx["manifold"] == "planar":
            verdict = compare_to_golden(fx, produced, 0, tolerances)
            if not verdict["match"]:
                rc = 1
                _eprint(f"self-test FAIL [{fx['id']}]: reference assembly != golden")
                for p in verdict["problems"]:
                    _eprint(f"  {p}")
            else:
                print(f"self-test OK   [{fx['id']}]: planar areas + invariants "
                      "reproduce golden")
        else:
            # Spherical: candidate set is reproduced above; if the golden pins
            # areas, confirm they satisfy the partition-of-unity identity so the
            # golden itself is internally consistent before any producer runs.
            if "areas" in exp:
                _verify_invariant_algebra(fx, exp, tolerances)

    # --- Check B: every adversarial variant collapses to the golden. --------
    for fx in fixtures:
        golden = fx["expected"]
        atol = fixture_atol(fx, tolerances)
        for vname, vspec in (fx["inputs"].get("variants") or {}).items():
            produced = reference_assemble(fx, vspec, atol)
            pairs = [tuple(p) for p in produced["candidate_pairs"]]
            src_order = vspec.get("src_order")
            tgt_order = vspec.get("tgt_order")
            if src_order is not None and tgt_order is not None:
                remapped = remap_pairs(pairs, 0, src_order, tgt_order)
            else:
                remapped = normalize_pairs(pairs, 0)
            got_ser = canonical_serialize(remapped)
            if got_ser != golden["candidate_serialized"]:
                rc = 1
                _eprint(f"self-test FAIL [{fx['id']}/{vname}]: variant diverged")
                _eprint(f"    golden={golden['candidate_serialized']!r}")
                _eprint(f"    got   ={got_ser!r}")
            else:
                print(f"self-test OK   [{fx['id']}/{vname}]: collapses to golden")

    # --- Check C: negative controls — the harness must REJECT bad output. ---
    # C1: a permuted candidate set that is NOT re-sorted (left in producer order)
    #     must still pass IF it canonicalizes; an out-of-order serialized golden
    #     must be rejected by byte comparison.
    ref_fx = fixtures[0]
    golden_set = ref_fx["expected"]["candidate_index_set"]
    if len(golden_set) >= 2:
        scrambled = [golden_set[-1], *golden_set[:-1]]  # not sorted
        bad = {"candidate_pairs": scrambled}
        verdict = compare_to_golden(ref_fx, bad, 0, tolerances)
        # normalize_pairs re-sorts, so a scrambled-but-complete set canonicalizes
        # to the golden and SHOULD pass — that is the order-independence contract.
        if not verdict["match"] and any("candidate set differs" in p
                                        for p in verdict["problems"]):
            rc = 1
            _eprint("self-test FAIL [neg/reorder]: re-sorted candidate set "
                    "wrongly rejected (broad phase must be order-independent)")
        else:
            print("self-test OK   [neg/reorder]: permuted candidate set "
                  "canonicalizes to golden")
        # C1b: a candidate set MISSING a pair must be rejected.
        missing = {"candidate_pairs": golden_set[:-1]}
        verdict2 = compare_to_golden(ref_fx, missing, 0, tolerances)
        if verdict2["match"]:
            rc = 1
            _eprint("self-test FAIL [neg/missing_pair]: harness accepted an "
                    "incomplete candidate set (it must reject)")
        else:
            print("self-test OK   [neg/missing_pair]: incomplete candidate set "
                  "rejected")

    # C2: float bin component must be rejected by the broad phase.
    try:
        candidate_overlap_pairs([[[0.0, 0.0], [1.0, 1.0]]],
                                [[[0.0, 0.0], [1.0, 1.0]]], dx=float("nan"), dy=1.0)
    except (GeometryError, ValueError):
        print("self-test OK   [neg/float_in_key]: degenerate bin step rejected")
    else:
        # NaN step yields no spanned bins rather than a float key; assert the
        # explicit float-key guard fires on a hand-built float component instead.
        try:
            _reject_float_bin(1.5, "src")
        except GeometryError:
            print("self-test OK   [neg/float_in_key]: float bin component rejected")
        else:
            rc = 1
            _eprint("self-test FAIL [neg/float_in_key]: float bin NOT rejected")

    # C3: an area outside tolerance must be flagged.
    planar_fx = next((f for f in fixtures
                      if f["manifold"] == "planar" and "areas" in f["expected"]
                      and f["expected"]["areas"]), None)
    if planar_fx is not None:
        atol = fixture_atol(planar_fx, tolerances)
        good = reference_assemble(planar_fx, planar_fx["inputs"]["canonical"], atol)
        bad_areas = [[r[0], r[1], r[2] + 1.0] for r in good["areas"]]
        bad = {**good, "areas": bad_areas}
        verdict = compare_to_golden(planar_fx, bad, 0, tolerances)
        if verdict["match"]:
            rc = 1
            _eprint("self-test FAIL [neg/area_off]: harness accepted an area "
                    "1.0 outside tolerance (it must reject)")
        else:
            print("self-test OK   [neg/area_off]: out-of-tolerance area rejected")

    # C4: a partition-of-unity residual above the epsilon must be flagged.
    if planar_fx is not None:
        bad = {"candidate_pairs": planar_fx["expected"]["candidate_index_set"],
               "partition_of_unity_max_residual": 1e-3}
        verdict = compare_to_golden(planar_fx, bad, 0, tolerances)
        if verdict["match"]:
            rc = 1
            _eprint("self-test FAIL [neg/pou]: harness accepted a broken "
                    "partition-of-unity residual (it must reject)")
        else:
            print("self-test OK   [neg/pou]: broken partition-of-unity rejected")

    print("\nself-test:", "OK" if rc == 0 else "FAILED")
    return rc


def _verify_invariant_algebra(fixture: dict, exp: dict, tolerances: dict) -> None:
    """For a spherical fixture, confirm the committed golden areas satisfy the
    algebraic partition-of-unity identity (Σ_i A_ij / A_j = 1) so the golden
    itself is internally consistent before any producer is compared to it."""
    n_tgt = 0
    cols: dict[int, list[float]] = {}
    for row in exp["areas"]:
        i, j, a = row[0], row[1], float(row[2])
        cols.setdefault(j, []).append(a)
        n_tgt = max(n_tgt, j + 1)
    for j, col in cols.items():
        s = sum(col)
        if s > 0.0:
            pou = abs(sum(a / s for a in col) - 1.0)
            if pou > tolerances["partition_of_unity_atol"]:
                print(f"self-test WARN [{fixture['id']}]: golden spherical areas "
                      f"violate partition-of-unity (residual {pou:g})",
                      file=sys.stderr)


# === Default run mode (producers) =========================================


def run_suite(manifest_path: Path, bindings: list[str], output_path: Path,
              timeout: float | None) -> int:
    manifest = load_manifest(manifest_path)
    pin = manifest.get("base_pin", {})
    tolerances = {**DEFAULT_TOLERANCES, **manifest.get("tolerances", {})}
    reference_binding = manifest.get("reference_binding", "julia")

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
                                     f"earthsci-geometry-adapter-{b} or via "
                                     f"$EARTHSCI_GEOMETRY_ADAPTER_{b.upper()}"),
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
            verdict = compare_to_golden(fx, produced, b_base, tolerances)
            variants = compare_variants(fx, produced, b_base)
            match = verdict["match"] and variants["match"]
            b_report["fixtures"][fx["id"]] = {
                "status": "ok" if match else "mismatch",
                "problems": verdict["problems"] + variants["problems"],
            }
            if not match:
                b_ok = False
        b_report["status"] = "ok" if b_ok else "fail"
        if not b_ok:
            overall_ok = False
        report["bindings"][b] = b_report

    # Cross-binding area agreement (the §5.8.2 "against the reference binding"
    # check) — runs only when the reference binding AND ≥1 other both produced.
    cross: dict[str, Any] = {}
    ref_ar = adapters.get(reference_binding)
    if ref_ar and ref_ar.get("adapter_status") == "ok":
        ref_base = pin.get(reference_binding, 0)
        for b in bindings:
            if b == reference_binding:
                continue
            ar = adapters.get(b)
            if not ar or ar.get("adapter_status") != "ok":
                continue
            b_base = pin.get(b, 0)
            pair_report: dict[str, Any] = {}
            ok = True
            for fx in fixtures:
                ref_fx = ref_ar.get("fixtures", {}).get(fx["id"])
                other_fx = ar.get("fixtures", {}).get(fx["id"])
                if ref_fx is None or other_fx is None:
                    continue
                probs = compare_cross_binding(fx, ref_fx, ref_base,
                                              other_fx, b_base, tolerances)
                if probs:
                    ok = False
                    pair_report[fx["id"]] = probs
            cross[f"{b}_vs_{reference_binding}"] = {
                "status": "ok" if ok else "fail", "problems": pair_report}
            if not ok:
                overall_ok = False
    if cross:
        report["cross_binding"] = cross

    any_ok = any(a.get("adapter_status") == "ok" for a in adapters.values())
    if not any_ok and not required:
        report["status"] = "no_producers"
        print("No geometry adapters registered for any requested binding, and "
              "none are required. The contract is gated by --self-test here.")
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
    print("=== Geometry Conformance Report ===")
    print(f"manifest: {report['manifest_path']}")
    print(f"status:   {report['status'].upper()}")
    for b, br in report.get("bindings", {}).items():
        print(f"  {b:>12}  {br.get('status')}  ({br.get('adapter_status')})")
        for fid, fr in br.get("fixtures", {}).items():
            if fr.get("status") != "ok":
                print(f"      FAIL {fid}: {fr.get('problems') or fr.get('status')}")
    for pair, pr in report.get("cross_binding", {}).items():
        print(f"  cross {pair}: {pr.get('status')}")
        for fid, probs in pr.get("problems", {}).items():
            print(f"      FAIL {fid}: {probs}")


# === CLI ==================================================================


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST,
                   help="Path to the geometry manifest.json.")
    p.add_argument("--output", type=Path,
                   default=Path("conformance-results/geometry/report.json"),
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
