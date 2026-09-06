"""Conformance harness adapter — round-trip category (Python binding).

The oracle is the AUTHORED FIXTURE. The shared harness used to compare emit
pass 2 against emit pass 3, with ``F`` itself never a participant — the
self-comparing shape described in ``tests/conformance/README.md``, blind to any
field lost on the FIRST load because the second emit forgets exactly what the
first forgot.

esm-spec §9.6.4 rule 5 states BOTH halves normatively ("Load preservation" and
"Idempotence") and neither implies the other, so both are asserted here.

This module is the CROSS-BINDING adapter, driven by
``tests/conformance/round_trip/manifest.json``. It is deliberately distinct from
``test_roundtrip_against_original.py``, which sweeps the whole ``tests/valid``
corpus with Python-local exclusions and a hard stale-exclusion assertion. The
shared manifest cannot make that assertion — the bindings genuinely differ on
which optional transforms they apply, so "an excused fixture MUST differ" would
fail the *correct* binding. See the README's adapter contract, item 8.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest
from conftest import CONFORMANCE_DIR, FIXTURES_ROOT

import earthsci_ast as ea

BINDING = "python"
MANIFEST_PATH = CONFORMANCE_DIR / "round_trip" / "manifest.json"


def _manifest() -> dict:
    assert MANIFEST_PATH.is_file(), f"conformance manifest not found at {MANIFEST_PATH}"
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    assert manifest["category"] == "round_trip"
    assert manifest["fixtures"]
    return manifest


MANIFEST = _manifest()
PRESERVED_KEYS = frozenset(MANIFEST["preserved_keys"])

# Fixture id -> the divergence entry naming THIS binding non-conformant. A
# binding listed `conformant`, or listed in neither column, stays held to full
# equality: that is what makes the ledger a ratchet rather than a licence.
EXCUSED_BY_DIVERGENCE: dict[str, str] = {
    fixture: entry["id"]
    for entry in MANIFEST.get("known_divergences", [])
    if BINDING in entry["nonconformant"]
    for fixture in entry["fixtures"]
}


def _normalize(value: Any, parent: str = "") -> Any:
    """Applied to BOTH sides, so no relaxation can hide a drop.

    Implements the five normalizations in ``tests/conformance/README.md``
    (admissions 1 and 2 of esm-spec §9.6.4 rule 5).
    """
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, item in value.items():
            norm = _normalize(item, key)
            if isinstance(norm, (dict, list)) and not norm:
                continue
            if key == "expect_cadence":
                continue
            if key == "independent_variable" and parent == "domain" and norm == "t":
                continue
            if key == "initial_offset" and norm == 0:
                continue
            out[key] = norm
        return out
    if isinstance(value, list):
        return [_normalize(item, parent) for item in value]
    return value


def _diff(a: Any, b: Any, path: str = "") -> list[str]:
    """Every JSON-pointer path at which the two documents differ.

    Numbers compare by MATHEMATICAL VALUE, not spelling — a tolerance for where
    the bindings stand today (see the manifest's `normalizations`), not a rule
    the format grants.
    """
    out: list[str] = []
    if isinstance(a, dict) and isinstance(b, dict):
        for key, value in a.items():
            if key in b:
                out += _diff(value, b[key], f"{path}/{key}")
            else:
                out.append(f"{path}/{key}  DROPPED (was {json.dumps(value)[:120]})")
        for key, value in b.items():
            if key not in a:
                out.append(f"{path}/{key}  ADDED ({json.dumps(value)[:120]})")
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"{path}  LENGTH {len(a)} -> {len(b)}")
        else:
            for i, (x, y) in enumerate(zip(a, b)):
                out += _diff(x, y, f"{path}[{i}]")
    elif (
        isinstance(a, (int, float))
        and isinstance(b, (int, float))
        and not isinstance(a, bool)
        and not isinstance(b, bool)
    ):
        if float(a) != float(b):
            out.append(f"{path}  {a} -> {b}")
    elif a != b:
        out.append(f"{path}  {json.dumps(a)[:120]} -> {json.dumps(b)[:120]}")
    return out


def _dropped_keys(original: Any, emitted: Any, path: str = "") -> Iterator[tuple[str, str]]:
    """``(wire_key, json_path)`` for every mapping key in ``original`` absent
    from ``emitted``, recursively."""
    if isinstance(original, dict) and isinstance(emitted, dict):
        for key, value in original.items():
            here = f"{path}.{key}"
            if key not in emitted:
                yield key, here
            else:
                yield from _dropped_keys(value, emitted[key], here)
    elif isinstance(original, list) and isinstance(emitted, list):
        for i, (x, y) in enumerate(zip(original, emitted)):
            yield from _dropped_keys(x, y, f"{path}[{i}]")


def _ids(fixture: dict) -> str:
    return fixture["id"]


@pytest.mark.parametrize("fixture", MANIFEST["fixtures"], ids=_ids)
def test_round_trip(fixture: dict) -> None:
    fid = fixture["id"]
    path = FIXTURES_ROOT / fixture["path"]
    if not path.is_file():
        pytest.skip(f"fixture not on disk: {path}")

    loaded = ea.load_path(path)
    first_json = ea.to_json(loaded)

    authored = _normalize(json.loads(path.read_text(encoding="utf-8")))
    emitted = _normalize(json.loads(first_json))

    excused = bool(fixture.get("load_transforms")) or fid in EXCUSED_BY_DIVERGENCE
    diff = _diff(authored, emitted)

    # 1. LOAD PRESERVATION (esm-spec §9.6.4 rule 5).
    if not excused:
        assert not diff, (
            f"{fid}: save(load(F)) differs from F — either a field is being "
            f"dropped/invented, or a spec-REQUIRED load-time transform needs a "
            f"`load_transforms` entry citing its clause. Do NOT add one to silence "
            f"a drop.\n  " + "\n  ".join(diff)
        )

    # 2. FIELD LOSS — runs on EVERY fixture, excused or not. A load-time
    #    transform rewrites a CONSTRUCT; it does not licence dropping the
    #    document around it.
    lost = [where for key, where in _dropped_keys(authored, emitted) if key in PRESERVED_KEYS]
    assert not lost, f"{fid}: dropped preserved field(s) at {lost}"

    # 3. IDEMPOTENCE (esm-spec §9.6.4 rule 5) — still required, no longer alone.
    #    A ledger-excused fixture may fail here for a reason the ledger already
    #    records: a drop that removes a SCHEMA-REQUIRED field emits a document
    #    this binding cannot re-load at all, so there is no second emit to
    #    compare. That is reported as a visible known failure naming the ledger
    #    entry — never a silent pass — while every other fixture hard-fails.
    entry = EXCUSED_BY_DIVERGENCE.get(fid)
    try:
        second_json = ea.to_json(ea.load_document(json.loads(first_json)))
    except Exception as exc:  # noqa: BLE001 — re-raised unless the ledger owns it
        if entry is None:
            raise
        pytest.xfail(f"{fid}: emit is not re-loadable ({exc}); known_divergence '{entry}'")
    assert json.loads(first_json) == json.loads(second_json), f"{fid}: emit is not a fixed point"


def test_every_ledger_fixture_is_in_the_manifest() -> None:
    """A ledger entry naming a fixture the manifest does not run excuses nothing."""
    ids = {f["id"] for f in MANIFEST["fixtures"]}
    for entry in MANIFEST.get("known_divergences", []):
        missing = set(entry["fixtures"]) - ids
        assert not missing, f"known_divergence {entry['id']} names unlisted fixture(s) {missing}"


def test_ledger_columns_are_disjoint_and_total() -> None:
    """Every entry must place all five bindings, and none in both columns —
    otherwise 'held to full equality' is ambiguous for whoever is missing."""
    bindings = {"julia", "python", "rust", "go", "typescript"}
    for entry in MANIFEST.get("known_divergences", []):
        conf, nonconf = set(entry["conformant"]), set(entry["nonconformant"])
        assert not (conf & nonconf), f"{entry['id']}: binding in both columns"
        assert conf | nonconf == bindings, f"{entry['id']}: does not place every binding"
