"""Python geometry-conformance adapter (``CONFORMANCE_SPEC.md`` §5.8.6).

The thin bridge the cross-binding geometry harness
(``scripts/run-geometry-conformance.py``) invokes to exercise the **Python**
conservative-regridding assembly (:mod:`earthsci_toolkit.conservative_regrid` —
``build_regridder`` / ``candidate_overlap_pairs``, bead ess-my4.4.7) over the
shared golden fixtures in ``tests/conformance/geometry/manifest.json``. The runner
discovers it via ``$EARTHSCI_GEOMETRY_ADAPTER_PYTHON`` or as
``earthsci-geometry-adapter-python`` on ``PATH`` and calls::

    earthsci-geometry-adapter-python --manifest <manifest.json> --output <result.json>

For each fixture it builds the regridder over ``inputs.canonical`` and emits the
broad-phase candidate overlap-pair set (Python's **native 0-based** emission
base — the harness normalises via ``base_pin``), the post-floor per-pair overlap
areas ``A_ij``, the partition-of-unity residual, and (when the fixture supplies
``F_src`` + ``src_areas``) the global-conservation residual. For every adversarial
``inputs.variants`` payload it emits the candidate set, which the runner remaps
and asserts collapses to the golden. Keep this thin — the contract lives in the
assembly module, not here.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List

import numpy as np

from earthsci_toolkit.conservative_regrid import (
    build_regridder,
    candidate_overlap_pairs,
)

try:  # the spherical/geodesic clip's optional S2 backend
    from earthsci_toolkit.geometry import GeometryBackendUnavailable
except ImportError:  # pragma: no cover - defensive
    class GeometryBackendUnavailable(Exception):  # type: ignore
        pass


def _is_backend_unavailable(exc: BaseException) -> bool:
    """True when the narrow-phase clip failed only because its geometry backend
    is absent (e.g. spherical needs the optional `spherely`/S2 dependency). The
    interpreter wraps it, so we walk the cause chain and fall back to the message.
    A genuine clip bug is NOT swallowed — it re-raises."""
    seen = exc
    while seen is not None:
        if isinstance(seen, GeometryBackendUnavailable):
            return True
        seen = seen.__cause__
    msg = str(exc).lower()
    return "spherely" in msg or "backend" in msg


def _to_poly(poly: List[List[float]]) -> np.ndarray:
    """Manifest polygon ([[x, y], ...]) to the [n, 2] float array the kernel
    expects."""
    return np.asarray(poly, dtype=float)


def _fixture_atol(fixture: Dict[str, Any], tolerances: Dict[str, Any]) -> float:
    """The §5.8.2 sliver floor atol ≈ factor·R² (R = characteristic length,
    default 1) — the same value the runner uses, so slivers floor identically."""
    factor = float(tolerances.get("area_atol_factor", 1e-15))
    r = float(fixture.get("characteristic_length", 1.0))
    return factor * r * r


def _candidate_pairs(payload: Dict[str, Any], dx: float, dy: float) -> List[List[int]]:
    src = [_to_poly(p) for p in payload["src"]]
    tgt = [_to_poly(p) for p in payload["tgt"]]
    return [[i, j] for (i, j) in candidate_overlap_pairs(src, tgt, dx, dy)]


def _compute_canonical(fixture: Dict[str, Any],
                       tolerances: Dict[str, Any]) -> Dict[str, Any]:
    payload = fixture["inputs"]["canonical"]
    src = [_to_poly(p) for p in payload["src"]]
    tgt = [_to_poly(p) for p in payload["tgt"]]
    dx, dy = float(fixture["dx"]), float(fixture["dy"])
    manifold = fixture["manifold"]
    atol = _fixture_atol(fixture, tolerances)

    # Broad phase first — pure integer binning, no geometry backend. This is the
    # byte-identical candidate set the gate's PRIMARY assertion rides on, so it is
    # always emitted even when the narrow-phase clip backend is missing.
    record: Dict[str, Any] = {
        "candidate_pairs": _candidate_pairs(fixture["inputs"]["canonical"], dx, dy),
    }

    try:
        r = build_regridder(src, tgt, manifold=manifold, dx=dx, dy=dy, atol=atol)
    except Exception as exc:  # narrow-phase clip — may need an absent backend
        if _is_backend_unavailable(exc):
            record["narrow_phase_unavailable"] = str(exc)
            return record
        raise

    record["areas"] = [[i, j, float(r.A_ij[i, j])] for (i, j) in r.candidate_pairs]
    pou_res = r.partition_of_unity_residual()
    record["partition_of_unity_max_residual"] = (
        float(np.max(np.abs(pou_res))) if pou_res.size else 0.0)

    if "F_src" in fixture and "src_areas" in fixture:
        f_src = np.asarray(fixture["F_src"], dtype=float)
        src_areas = np.asarray(fixture["src_areas"], dtype=float)
        record["conservation_residual"] = float(
            r.conservation_residual(f_src, src_areas))
    return record


def _compute_fixture(fixture: Dict[str, Any],
                     tolerances: Dict[str, Any]) -> Dict[str, Any]:
    record = _compute_canonical(fixture, tolerances)
    dx, dy = float(fixture["dx"]), float(fixture["dy"])
    variants = {
        vname: {"candidate_pairs": _candidate_pairs(vpayload, dx, dy)}
        for vname, vpayload in (fixture["inputs"].get("variants") or {}).items()
    }
    if variants:
        record["variants"] = variants
    return record


def main(argv: "List[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    with args.manifest.open() as f:
        manifest = json.load(f)
    tolerances = manifest.get("tolerances", {})

    fixtures: Dict[str, Any] = {}
    for fixture in manifest["fixtures"]:
        fixtures[fixture["id"]] = _compute_fixture(fixture, tolerances)

    result = {"binding": "python", "fixtures": fixtures}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        json.dump(result, f)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
