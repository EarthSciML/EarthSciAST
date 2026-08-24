"""The Python binding's public surface must equal the API manifest.

`api-surface.json` at the repo root is the cross-language record of what every
binding exports (see API_SPEC.md). This test pins the Python half of it: a name
in ``earthsci_ast.__all__`` but not in the manifest fails, and a name in the
manifest but not in ``__all__`` fails too.

If this test fails you have changed the public API. That is allowed -- but the
manifest has to change with it, in the same commit:

    python3 scripts/gen-api-surface.py

and then say in API_SPEC.md which tier the new symbol lands in.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import earthsci_ast

REPO_ROOT = Path(__file__).resolve().parents[3]
MANIFEST_PATH = REPO_ROOT / "api-surface.json"

# ---------------------------------------------------------------------------
# Phase 4 (esm-libraries-spec §2.5 / API_SPEC §5.8): `simulate` is DELETED and
# `prepare` / `PreparedModel` are REPLACED by Problem construction, in Julia,
# Python and Rust. `api-surface.json` is regenerated ONCE, after all three
# bindings land, so between now and that regeneration the manifest still
# describes the old Python surface. These two sets carry the delta so the
# surface stays pinned rather than un-asserted in the interval.
#
# When `python3 scripts/gen-api-surface.py` runs for the merged phase, BOTH
# sets go back to empty — the manifest then says all of this itself, and a
# non-empty set here is a claim that the manifest is stale.
# ---------------------------------------------------------------------------

#: Exported by the Python binding now; not yet in the manifest.
PENDING_ADDED = {
    "CallbackSet",
    "EnsembleProblem",
    "Integrator",
    "Problem",
    "ReturnCode",
    "Solution",
    "callbacks",
    "esm_problem",
    "init",
    "remake",
    "solve",
    "solve_all",
    "step",
}

#: Still in the manifest; deleted from the Python binding.
PENDING_REMOVED = {
    "PreparedModel",
    "SimulationResult",
    "prepare",
    "simulate",
}


def _spellings(entry: object) -> list[str]:
    """A binding entry is a string, or a list when it exports aliases."""
    if isinstance(entry, str):
        return [entry]
    return list(entry)


@pytest.fixture(scope="module")
def manifest() -> dict:
    assert MANIFEST_PATH.is_file(), f"api-surface.json not found at {MANIFEST_PATH}"
    return json.loads(MANIFEST_PATH.read_text())


@pytest.fixture(scope="module")
def declared(manifest: dict) -> set[str]:
    names: set[str] = set()
    for sym in manifest["symbols"]:
        entry = sym["bindings"].get("python")
        if entry is not None:
            names.update(_spellings(entry))
    return names


def test_all_is_a_set(declared: set[str]) -> None:
    """__all__ must not repeat a name -- duplicates hide surface changes."""
    dupes = sorted({n for n in earthsci_ast.__all__ if earthsci_ast.__all__.count(n) > 1})
    assert not dupes, f"duplicate entries in __all__: {dupes}"


def test_no_undeclared_exports(declared: set[str]) -> None:
    """Every name in __all__ must be in the manifest (nothing leaks out)."""
    extra = sorted(set(earthsci_ast.__all__) - declared - PENDING_ADDED)
    assert not extra, (
        "exported by earthsci_ast but absent from api-surface.json:\n  "
        + "\n  ".join(extra)
        + "\nAdd them by re-running `python3 scripts/gen-api-surface.py`, then "
          "assign each a tier in API_SPEC.md."
    )


def test_no_missing_exports(declared: set[str]) -> None:
    """Every Python name in the manifest must be in __all__ (nothing vanishes)."""
    missing = sorted(declared - set(earthsci_ast.__all__) - PENDING_REMOVED)
    assert not missing, (
        "declared for python in api-surface.json but not in earthsci_ast.__all__:\n  "
        + "\n  ".join(missing)
        + "\nEither restore the export or drop it from the manifest -- dropping a "
          "`stable` symbol is a major-version break (API_SPEC.md §3)."
    )


def test_pending_sets_are_disjoint_from_the_live_surface() -> None:
    """The delta above must describe reality: everything PENDING_ADDED names is
    actually exported, and nothing PENDING_REMOVED names still is. Without this
    the two allowances could silently outlive the change they cover."""
    exported = set(earthsci_ast.__all__)
    assert not (PENDING_ADDED - exported), (
        "PENDING_ADDED names symbols the binding does not export: "
        f"{sorted(PENDING_ADDED - exported)}"
    )
    assert not (PENDING_REMOVED & exported), (
        "PENDING_REMOVED names symbols the binding still exports: "
        f"{sorted(PENDING_REMOVED & exported)}"
    )


def test_every_exported_name_resolves() -> None:
    """__all__ must not name an attribute that does not exist."""
    unresolved = sorted(n for n in earthsci_ast.__all__ if not hasattr(earthsci_ast, n))
    assert not unresolved, f"__all__ names unresolvable attributes: {unresolved}"


def test_manifest_kinds_match_python_objects(manifest: dict) -> None:
    """A symbol the manifest calls a type must be a type in Python, and so on."""
    import inspect

    mismatches = []
    for sym in manifest["symbols"]:
        entry = sym["bindings"].get("python")
        if entry is None:
            continue
        for name in _spellings(entry):
            obj = getattr(earthsci_ast, name, None)
            if obj is None:
                continue
            if sym["kind"] == "error":
                if not (inspect.isclass(obj) and issubclass(obj, BaseException)):
                    mismatches.append(f"{name}: manifest says error, is {type(obj).__name__}")
            elif sym["kind"] == "type":
                # A manifest `type` may be a class, a typing alias, or an enum.
                if inspect.isfunction(obj) or inspect.isbuiltin(obj):
                    mismatches.append(f"{name}: manifest says type, is a function")
            elif sym["kind"] == "function":
                if inspect.isclass(obj):
                    mismatches.append(f"{name}: manifest says function, is a class")
    assert not mismatches, "kind mismatches vs api-surface.json:\n  " + "\n  ".join(mismatches)
