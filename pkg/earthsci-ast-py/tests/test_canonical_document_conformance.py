"""Cross-binding document-level canonical form (esm-spec §4.8.2).

Reads ``tests/conformance/canonical_document/*.json`` and asserts that
``canonicalize_document(input)`` equals each fixture's ``expected`` document,
compared as JSON values. Every binding runs the same fixtures.
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


@pytest.mark.parametrize("entry", _manifest()["fixtures"], ids=lambda e: e["id"])
def test_canonical_document_conformance(entry):
    fixture = json.loads((FIXTURES_DIR / entry["path"]).read_text(encoding="utf-8"))
    before = copy.deepcopy(fixture["input"])
    assert canonicalize_document(fixture["input"]) == fixture["expected"]
    assert fixture["input"] == before, "canonicalize_document mutated its input"
