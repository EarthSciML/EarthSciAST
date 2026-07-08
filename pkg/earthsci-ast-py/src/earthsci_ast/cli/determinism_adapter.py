"""Python determinism-conformance adapter (``CONFORMANCE_SPEC.md`` §5.5.4).

The thin bridge the cross-binding determinism harness
(``scripts/run-determinism-conformance.py``) invokes to exercise the **Python**
relational engine (:mod:`earthsci_ast.relational`) over the shared golden
fixtures in ``tests/conformance/determinism/manifest.json``. The runner discovers
it via ``$EARTHSCI_DETERMINISM_ADAPTER_PYTHON`` or as
``earthsci-determinism-adapter-python`` on ``PATH`` and calls::

    earthsci-determinism-adapter-python --manifest <manifest.json> --output <result.json>

For each fixture it runs the real producers over ``inputs.canonical`` and writes
the canonical index set, its byte-form serialization, and the dense-ID array in
Python's **native 0-based** emission base (the harness normalises via
``rank_base_pin``). Keep this thin — the contract lives in the engine, not here.
"""

from __future__ import annotations

import operator
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

from earthsci_ast.cli._adapter_main import adapter_main
from earthsci_ast.relational import (
    canonical_index_set_json,
    distinct,
    group_aggregate,
    rank,
    serialize_canonical,
    skolem,
    skolem_edge,
)


def _directed_edges_from_faces(faces: List[List[Any]]) -> List[Tuple[Any, Any]]:
    """Traverse consecutive vertices of each face (with wraparound) into directed
    edges — the realistic producer step a mesh FAQ performs before skolem
    canonicalisation (mirrors the runner's reference shaping)."""
    edges: List[Tuple[Any, Any]] = []
    for face in faces:
        n = len(face)
        for i in range(n):
            edges.append((face[i], face[(i + 1) % n]))
    return edges


def _compute_fixture(fixture: Dict[str, Any]) -> Dict[str, Any]:
    """The canonical conformance outputs for a fixture (its `inputs.canonical`
    payload). Kept as the single-payload entry point the Python conformance tests
    drive directly; :func:`main` reuses it for the adversarial variants too."""
    return _compute_payload(fixture, fixture["inputs"]["canonical"])


def _compute_payload(fixture: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    primitive = fixture["primitive"]

    if primitive == "skolem_distinct_rank":
        mode = fixture.get("skolem")
        if "faces" in payload:
            edges = _directed_edges_from_faces(payload["faces"])
        elif "tuples" in payload:
            edges = [tuple(t) for t in payload["tuples"]]
        else:
            raise ValueError(f"fixture {fixture['id']}: input needs 'faces' or 'tuples'")

        if mode == "undirected":
            keys = [skolem_edge(a, b) for (a, b) in edges]
        elif mode == "directed":
            keys = [skolem(t) for t in edges]
        else:
            raise ValueError(f"fixture {fixture['id']}: unknown skolem mode {mode!r}")

        index_set = distinct(keys)
        serialized = canonical_index_set_json(keys)
        ranking = rank(keys)  # native 0-based
        dense = [ranking.ids[t] for t in index_set]

    elif primitive == "group_by_sum":
        pairs = group_aggregate(
            payload["rows"],
            key=lambda row: row[0],
            value=lambda row: row[1],
            op=operator.add,
        )
        index_set = pairs
        serialized = serialize_canonical(pairs)
        dense = list(range(len(pairs)))  # positions of the sorted distinct keys

    else:
        raise ValueError(f"fixture {fixture['id']}: unknown primitive {primitive!r}")

    return {
        "index_set": [list(row) for row in index_set],
        "serialized": serialized,
        "dense_ids_canonical": dense,
    }


def _run_fixture(
    fixture: Dict[str, Any], _manifest: Dict[str, Any], _manifest_path: Path
) -> Dict[str, Any]:
    record = _compute_fixture(fixture)
    # Run the adversarial variants through the SAME real producers and emit
    # each — the runner asserts they collapse to the golden, proving order-,
    # duplicate-, and orientation-independence per binding (§5.5.4).
    variants = {
        vname: _compute_payload(fixture, vpayload)
        for vname, vpayload in (fixture["inputs"].get("variants") or {}).items()
    }
    if variants:
        record["variants"] = variants
    return record


def main(argv: "List[str] | None" = None) -> int:
    return adapter_main(argv, description=__doc__, run_fixture=_run_fixture)


if __name__ == "__main__":
    sys.exit(main())
