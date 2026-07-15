#!/usr/bin/env python3

"""Python conformance producer for ESM Format cross-language testing.

Reads the shared CORPUS MANIFEST (``scripts/conformance_corpus.py``) and emits a
record for every entry in it. The producer does NOT enumerate the corpus itself:
that is exactly how 69 fixtures went unswept for a year, in four producers, in
four different ways (audit 2026-07-14, F5).

Every validation entry runs the full **load → resolve → validate** pipeline
(``earthsci_ast.load`` resolves §4.7 subsystem refs against the file's own
directory, then structural validation runs on the resolved form). ``validate()``
does no file I/O in any binding, so without the resolve phase a ``{ref}`` stub
reads as unresolved and ``tests/valid/lib_*_subsystem_inclusion.esm`` and
``tests/invalid/subsystem_ref_not_found.esm`` could not both be satisfied.

Emitted per validation entry (the shape every binding must produce):

    {"outcome": "valid" | "invalid",       # the binding's verdict
     "phase": "load" | "validate",         # where the verdict was reached
     "is_valid": bool,
     "schema_errors":     [{"path", "message", "keyword"}],
     "structural_errors": [{"path", "code", "message", "details"}],
     "error": "...",  "error_type": "..."} # when load/resolve raised

A rejection raised by load/resolve is still a rejection: ``outcome`` is the
binding's answer to "is this document acceptable?", regardless of which phase
answered it.
"""

from __future__ import annotations

import json
import os
import sys
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any

script_dir = Path(__file__).resolve().parent
project_root = script_dir.parent
python_package = project_root / "pkg" / "earthsci-ast-py"

sys.path.insert(0, str(python_package / "src"))

try:
    import earthsci_ast
except ImportError as e:  # pragma: no cover - environment problem, not a conformance one
    print(f"Failed to import earthsci_ast Python library: {e}")
    print("Make sure the Python package is properly installed")
    sys.exit(1)


def _error_to_dict(err: Any) -> dict[str, Any]:
    """Normalise a binding error object to the shared wire shape."""
    path = getattr(err, "path", "")
    message = getattr(err, "message", str(err))
    code = getattr(err, "code", "") or ""
    keyword = getattr(err, "keyword", "") or code
    details = getattr(err, "details", None)
    return {
        "path": path,
        "message": message,
        "code": code,
        "keyword": keyword,
        "details": details if isinstance(details, dict) else {},
    }


def run_validation(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """load → resolve → validate every entry in the shared manifest.

    When the load/resolve phase REJECTS a document, `validate()` is still called
    on the raw document. Otherwise a binding that raises early would emit an
    empty error list and its pinned `(code, path)` findings could never be
    checked — the rejection would be reported as an opaque string. Every binding
    gets its best shot at producing structured errors; whatever it can produce is
    what the pin check judges.
    """
    print("Running validation sweep...")
    results: dict[str, dict[str, Any]] = {}

    for entry in manifest["validation_files"]:
        path = project_root / entry["path"]
        record: dict[str, Any] = {
            "schema_errors": [],
            "structural_errors": [],
        }

        # --- load + resolve (the only phase that does file I/O; it anchors §4.7
        # subsystem refs and §9.7 template imports at the file's own directory) --
        esm_data = None
        try:
            esm_data = earthsci_ast.load(path)
            record["resolve_ok"] = True
        except Exception as exc:
            record["resolve_ok"] = False
            record["error"] = str(exc)
            record["error_type"] = type(exc).__name__

        # --- validate ---------------------------------------------------------
        try:
            if esm_data is not None:
                result = earthsci_ast.validate(esm_data)
            else:
                # Raw document, so a load-phase rejection still yields whatever
                # structured findings the binding is able to enumerate.
                result = earthsci_ast.validate(json.loads(path.read_text()))
            record["schema_errors"] = [_error_to_dict(e) for e in (result.schema_errors or [])]
            record["structural_errors"] = [
                _error_to_dict(e) for e in (result.structural_errors or [])
            ]
            record["is_valid"] = bool(result.is_valid)
            record["phase"] = "validate"
        except Exception as exc:
            record["is_valid"] = False
            record["phase"] = "load" if not record["resolve_ok"] else "validate"
            record.setdefault("error", str(exc))
            record.setdefault("error_type", type(exc).__name__)

        # The verdict is "did this binding accept the document", regardless of
        # WHICH phase answered. A rejection at resolve is still a rejection.
        record["is_valid"] = bool(record.get("is_valid")) and record["resolve_ok"]
        record["outcome"] = "valid" if record["is_valid"] else "invalid"
        results[entry["id"]] = record

    return results


_RENDERERS = {
    "unicode": earthsci_ast.to_unicode,
    "latex": earthsci_ast.to_latex,
    "ascii": earthsci_ast.to_ascii,
}


def run_display(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Render every manifest display case in all three formats.

    The cases are handed to us already expanded and id'd, so every binding
    renders the SAME 424 cases in the same order — the comparator can then
    demand byte-equality per case id instead of scoring an empty intersection
    as agreement (audit C2).
    """
    print("Running display sweep...")
    results: dict[str, dict[str, Any]] = {}

    for case in manifest["display_cases"]:
        record: dict[str, Any] = {}
        for fmt, render in _RENDERERS.items():
            try:
                record[fmt] = render(case["input"])
            except Exception as exc:
                record[fmt] = None
                record.setdefault("errors", {})[fmt] = str(exc)
        results[case["id"]] = record

    return results


def run_substitution(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Apply `substitute` to every manifest substitution case."""
    print("Running substitution sweep...")
    results: dict[str, dict[str, Any]] = {}

    for case in manifest["substitution_cases"]:
        try:
            results[case["id"]] = {"result": earthsci_ast.substitute(case["input"], case["bindings"])}
        except Exception as exc:
            results[case["id"]] = {"result": None, "error": str(exc)}

    return results


def load_manifest() -> dict[str, Any]:
    """The manifest path is passed by the harness; there is no fallback sweep.

    A producer that invents its own corpus when the manifest is missing is a
    producer that can silently under-report coverage. Fail instead.
    """
    if len(sys.argv) >= 3:
        manifest_path = Path(sys.argv[2])
    elif os.environ.get("ESM_CONFORMANCE_MANIFEST"):
        manifest_path = Path(os.environ["ESM_CONFORMANCE_MANIFEST"])
    else:
        manifest_path = Path(sys.argv[1]).parent / "corpus_manifest.json"

    if not manifest_path.is_file():
        print(f"Corpus manifest not found: {manifest_path}", file=sys.stderr)
        print(
            "Generate it with: python3 scripts/conformance_corpus.py --output <path>",
            file=sys.stderr,
        )
        sys.exit(2)
    return json.loads(manifest_path.read_text())


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: python run-python-conformance.py <output_dir> [<corpus_manifest.json>]")
        sys.exit(1)

    output_dir = Path(sys.argv[1])
    manifest = load_manifest()

    print("Running Python conformance producer...")
    print(f"Output directory: {output_dir}")

    errors: list[str] = []
    validation_results: dict[str, Any] = {}
    display_results: dict[str, Any] = {}
    substitution_results: dict[str, Any] = {}

    try:
        validation_results = run_validation(manifest)
        print(f"✓ Validation sweep completed ({len(validation_results)} files)")
    except Exception as exc:
        errors.append(f"Validation sweep crashed: {exc}")
        print(f"✗ Validation sweep crashed: {exc}")
        print(traceback.format_exc())

    try:
        display_results = run_display(manifest)
        print(f"✓ Display sweep completed ({len(display_results)} cases)")
    except Exception as exc:
        errors.append(f"Display sweep crashed: {exc}")
        print(f"✗ Display sweep crashed: {exc}")

    try:
        substitution_results = run_substitution(manifest)
        print(f"✓ Substitution sweep completed ({len(substitution_results)} cases)")
    except Exception as exc:
        errors.append(f"Substitution sweep crashed: {exc}")
        print(f"✗ Substitution sweep crashed: {exc}")

    output_dir.mkdir(parents=True, exist_ok=True)
    results_file = output_dir / "results.json"
    with open(results_file, "w") as f:
        json.dump(
            {
                "language": "python",
                "timestamp": datetime.now().isoformat(),
                "validation_results": validation_results,
                "display_results": display_results,
                "substitution_results": substitution_results,
                "errors": errors,
            },
            f,
            indent=2,
            default=repr,
        )
    print(f"Python conformance results written to: {results_file}")

    # A producer CRASH is fatal; a fixture-level divergence is not the
    # producer's verdict to make — the comparator owns that judgement, and it
    # needs every binding's results.json to make it.
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
