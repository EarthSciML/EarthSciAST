"""Shared ``main()`` skeleton for the Python conformance-adapter CLIs.

The cross-binding conformance runners (``scripts/run-*-conformance.py``)
invoke every Python adapter the same way::

    <adapter> --manifest <manifest.json> --output <result.json>

and expect a ``{"binding": "python", "fixtures": {<id>: <record>}}`` envelope
written to ``--output``. This module owns that contract — the argparse
surface, the per-fixture loop, and the envelope/output discipline — so the
adapters (:mod:`~earthsci_ast.cli.determinism_adapter`,
:mod:`~earthsci_ast.cli.cadence_adapter`,
:mod:`~earthsci_ast.cli.pde_simulation_adapter`) keep only their
per-fixture logic.

Failure handling: a fixture whose handler raises becomes an
``{"error": "<ExcType>: <message>"}`` entry (the runner reports it as a
per-fixture failure) instead of aborting the whole run. Output is written
with ``indent=2, sort_keys=True`` plus a trailing newline.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

#: Per-fixture handler: ``(fixture, manifest, manifest_path) -> record``.
#: ``manifest`` and ``manifest_path`` carry the run-wide context some adapters
#: need (integrator pins, manifest-relative fixture paths).
FixtureHandler = Callable[[Dict[str, Any], Dict[str, Any], Path], Dict[str, Any]]


def adapter_main(
    argv: "Optional[List[str]]",
    *,
    description: Optional[str],
    run_fixture: FixtureHandler,
) -> int:
    """Parse ``--manifest``/``--output``, run ``run_fixture`` over every
    manifest fixture, and write the ``{"binding": "python", ...}`` envelope.

    Returns 0; per-fixture exceptions are captured as ``{"error": ...}``
    records rather than propagated."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    manifest = json.loads(args.manifest.read_text())

    fixtures: Dict[str, Any] = {}
    for fixture in manifest["fixtures"]:
        try:
            fixtures[fixture["id"]] = run_fixture(fixture, manifest, args.manifest)
        except Exception as exc:  # noqa: BLE001 - surface per-fixture failure to the runner
            fixtures[fixture["id"]] = {"error": f"{type(exc).__name__}: {exc}"}

    payload = {"binding": "python", "fixtures": fixtures}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0
