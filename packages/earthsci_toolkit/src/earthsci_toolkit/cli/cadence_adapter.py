"""Python cadence-partition conformance adapter (``CONFORMANCE_SPEC.md`` §5.7).

The thin bridge the cross-binding cadence harness
(``scripts/run-cadence-conformance.py``) invokes to exercise the **Python**
partition pass (:mod:`earthsci_toolkit.cadence`) over the shared golden fixtures
in ``tests/conformance/cadence/manifest.json``. The runner discovers it via
``$EARTHSCI_CADENCE_ADAPTER_PYTHON`` or as ``earthsci-cadence-adapter-python`` on
``PATH`` and calls::

    earthsci-cadence-adapter-python --manifest <manifest.json> --output <result.json>

For each fixture it runs the real partition pass over the (value-free) ESM model
to derive the class summary and the materialization-point set, and folds the
``const`` buffers from the manifest's document-literal inputs through the real
relational engine. Output per fixture: ``class_summary`` (annotated nodes by
derived class), ``materialization_points`` (the threshold multiset), and
``const_fold_buffers`` (each buffer's canonical byte form). Keep this thin — the
contract lives in :mod:`earthsci_toolkit.cadence`, not here.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List

from earthsci_toolkit.cadence import (
    canonical_serialize,
    compute_fold,
    model_from_doc,
    partition,
)

# The manifest's fixture paths are repo-root-relative; this file lives at
# packages/earthsci_toolkit/src/earthsci_toolkit/cli/cadence_adapter.py.
REPO_ROOT = Path(__file__).resolve().parents[5]


def _load_model(repo_root: Path, fixture_rel: str, model_name: str) -> Dict[str, Any]:
    # model_from_doc attaches the document's top-level `data_loaders` so the
    # loader-seeded cadence refinement (§5.7.2) can resolve a discrete variable's
    # data_ingest source loader.
    doc = json.loads((repo_root / fixture_rel).read_text())
    return model_from_doc(doc, model_name)


def _compute_fixture(fixture: Dict[str, Any], repo_root: Path = REPO_ROOT) -> Dict[str, Any]:
    """Run the Python partition pass over one manifest fixture and produce its
    conformance record (class summary / materialization thresholds / folded
    buffers)."""
    model = _load_model(repo_root, fixture["fixture"], fixture["model"])
    result = partition(model)

    const_fold = fixture.get("const_fold") or {}
    inputs = const_fold.get("inputs", {})
    buffers: Dict[str, str] = {}
    for label, spec in (const_fold.get("expected") or {}).items():
        buffers[label] = canonical_serialize(compute_fold(label, spec, inputs))

    materialization_points: List[Dict[str, Any]] = [
        {"threshold": mp.threshold} for mp in result.materialization_points
    ]

    return {
        "class_summary": result.class_summary,
        "hot_tree_empty": result.hot_tree_empty,
        "event_handler_empty": result.event_handler_empty,
        "materialization_points": materialization_points,
        "const_fold_buffers": buffers,
    }


def main(argv: "List[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    with args.manifest.open() as f:
        manifest = json.load(f)

    # Fixtures are repo-root-relative; resolve them relative to the manifest's
    # repo root (tests/conformance/cadence/manifest.json → parents[3]) so the
    # adapter works regardless of the invoking cwd.
    repo_root = args.manifest.resolve().parents[3]

    fixtures: Dict[str, Any] = {}
    for fixture in manifest["fixtures"]:
        fixtures[fixture["id"]] = _compute_fixture(fixture, repo_root)

    result = {"binding": "python", "fixtures": fixtures}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        json.dump(result, f)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
