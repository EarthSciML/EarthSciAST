"""Python cadence-partition conformance adapter (``CONFORMANCE_SPEC.md`` §5.7).

The thin bridge the cross-binding cadence harness
(``scripts/run-cadence-conformance.py``) invokes to exercise the **Python**
partition pass (:mod:`earthsci_ast.cadence`) over the shared golden fixtures
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
contract lives in :mod:`earthsci_ast.cadence`, not here.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from earthsci_ast.cadence import (
    canonical_serialize,
    compute_fold,
    model_from_doc,
    partition,
)
from earthsci_ast.cli._adapter_main import adapter_main


def _load_model(repo_root: Path, fixture_rel: str, model_name: str) -> dict[str, Any]:
    # model_from_doc attaches the document's top-level `data_loaders` so the
    # loader-seeded cadence refinement (§5.7.2) can resolve a discrete variable's
    # data_ingest source loader.
    doc = json.loads((repo_root / fixture_rel).read_text())
    return model_from_doc(doc, model_name)


def _compute_fixture(fixture: dict[str, Any], repo_root: Path) -> dict[str, Any]:
    """Run the Python partition pass over one manifest fixture and produce its
    conformance record (class summary / materialization thresholds / folded
    buffers)."""
    model = _load_model(repo_root, fixture["fixture"], fixture["model"])
    result = partition(model)

    const_fold = fixture.get("const_fold") or {}
    inputs = const_fold.get("inputs", {})
    buffers: dict[str, str] = {}
    for label, spec in (const_fold.get("expected") or {}).items():
        buffers[label] = canonical_serialize(compute_fold(label, spec, inputs))

    materialization_points: list[dict[str, Any]] = [
        {"threshold": mp.threshold} for mp in result.materialization_points
    ]

    return {
        "class_summary": result.class_summary,
        "hot_tree_empty": result.hot_tree_empty,
        "event_handler_empty": result.event_handler_empty,
        "materialization_points": materialization_points,
        "const_fold_buffers": buffers,
    }


def _run_fixture(
    fixture: dict[str, Any], _manifest: dict[str, Any], manifest_path: Path
) -> dict[str, Any]:
    # Fixtures are repo-root-relative; resolve them relative to the manifest's
    # repo root (tests/conformance/cadence/manifest.json → parents[3]) so the
    # adapter works regardless of the invoking cwd.
    repo_root = manifest_path.resolve().parents[3]
    return _compute_fixture(fixture, repo_root)


def main(argv: list[str] | None = None) -> int:
    return adapter_main(argv, description=__doc__, run_fixture=_run_fixture)


if __name__ == "__main__":
    sys.exit(main())
