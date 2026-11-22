"""Markdown and Typst source documents loaded from files (esm-spec §1.2.1).

Runs every case of ``tests/conformance/source_documents/manifest.json`` (see
that directory's README): a loader reading a document from a path picks its
format by the file extension, at the root and at every ref site.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from earthsci_ast import flatten, load_path
from earthsci_ast.json_walk import decode_document
from earthsci_ast.serialize import to_json

REPO = Path(__file__).resolve().parents[3]
TIER = REPO / "tests" / "conformance" / "source_documents"
MANIFEST = json.loads((TIER / "manifest.json").read_text())


def _mask_refs(node):
    if isinstance(node, dict):
        return {
            k: ("<ref>" if k == "ref" and isinstance(v, str) else _mask_refs(v))
            for k, v in node.items()
        }
    if isinstance(node, list):
        return [_mask_refs(v) for v in node]
    return node


def _loaded(path: Path) -> dict:
    # A twin differs from its fixture only in the `ref` spellings.
    return _mask_refs(json.loads(to_json(load_path(path))))


@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda c: c["id"])
def test_source_documents_conformance(case):
    fixture = TIER / case["fixture"]
    if case["expect"] == "same_as_twin":
        assert _loaded(fixture) == _loaded(TIER / case["twin"])
        return

    def run():
        f = load_path(fixture)
        if case["driver"] == "flatten":
            flatten(f)

    if case["expect"] == "ok":
        run()
        return
    assert case["expect"] == "error"
    with pytest.raises(Exception) as info:
        run()
    assert getattr(info.value, "code", None) == case["code"], repr(info.value)


@pytest.mark.parametrize(
    "location",
    ["https://example.com/a/leaf.typ", "https://example.com/a/leaf.typ?v=2#top"],
)
def test_a_url_is_read_by_the_extension_of_its_path(location):
    text = (TIER / "leaf.typ").read_text()
    assert decode_document(text, location) == decode_document(text, TIER / "leaf.typ")


@pytest.mark.parametrize("name", ["leaf.TYP", "leaf.typst", "leaf.typ.esm"])
def test_any_other_name_is_json(name):
    with pytest.raises(json.JSONDecodeError):
        decode_document((TIER / "leaf.typ").read_text(), name)
