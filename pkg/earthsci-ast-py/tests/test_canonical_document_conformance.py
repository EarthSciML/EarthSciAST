"""Cross-binding document-level canonical form (esm-spec §4.8.2).

Reads ``tests/conformance/canonical_document/*.json`` and asserts that
``canonicalize_document(input)`` equals each fixture's ``expected`` document,
compared as JSON values with numbers compared by type too (``2`` is not ``2.0``).
Every binding runs the same fixtures.
"""

from __future__ import annotations

import copy
import json

import pytest
from conftest import CONFORMANCE_DIR

from earthsci_ast import canonicalize_document

FIXTURES_DIR = CONFORMANCE_DIR / "canonical_document"


def _manifest():
    return json.loads((FIXTURES_DIR / "manifest.json").read_text(encoding="utf-8"))


def _typed(value):
    """JSON text with sorted keys: an int and an equal float spell differently."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


@pytest.mark.parametrize("entry", _manifest()["fixtures"], ids=lambda e: e["id"])
def test_canonical_document_conformance(entry):
    fixture = json.loads((FIXTURES_DIR / entry["path"]).read_text(encoding="utf-8"))
    before = copy.deepcopy(fixture["input"])
    got = canonicalize_document(fixture["input"])
    assert _typed(got) == _typed(fixture["expected"])
    assert fixture["input"] == before, "canonicalize_document mutated its input"
