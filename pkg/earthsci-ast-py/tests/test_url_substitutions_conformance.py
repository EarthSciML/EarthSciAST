"""Mount-edge ``url_substitutions`` (esm-spec §4.7 "Binding a data source's
location at the mount"), against the SHARED pin.

Reads ``tests/conformance/url_substitutions/manifest.json``, which every
binding's suite reads. ``cases`` pin the edge rule as a document normalization
(apply the edge with the MOUNTING document's directory, then ordinary §8.2.1
resolution with the DECLARING document's); ``fixtures`` pin it through a real
load at both mount forms: a mounted document's ``data_sources`` merge into the
document that mounts it (esm-spec §4.7 "A mounted document's data sources"), so
``hoisted_sources`` are read off the ROOT document after ``load_path``, and
``index_set_sizes`` show an edge's ``bindings`` reaching through an assembly.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import earthsci_ast
from earthsci_ast._data_source_urls import (
    _remove_dot_segments,
    apply_mount_url_substitutions,
    resolve_data_source_urls,
)
from earthsci_ast.json_walk import ExpressionTemplateError
from earthsci_ast.serialize import to_json

REPO_ROOT = Path(__file__).resolve().parents[3]
SUITE = REPO_ROOT / "tests" / "conformance" / "url_substitutions"
MANIFEST = json.loads((SUITE / "manifest.json").read_text())


def _expected(pin: dict) -> str:
    if "verbatim" in pin:
        return pin["verbatim"]
    return "file://" + _remove_dot_segments(str(REPO_ROOT / pin["repo_path"]))


@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda c: c["id"])
def test_edge_case_matches_the_shared_manifest(case: dict) -> None:
    source: dict = {"url_template": case["url_template"]}
    if "mirrors" in case:
        source["mirrors"] = list(case["mirrors"])
    doc: dict = {"data_sources": {"s": {"kind": "static", "source": source}}}
    edge = {"ref": "x.esm", "url_substitutions": case["url_substitutions"]}
    binder = case.get("binder_url") or str(REPO_ROOT / MANIFEST["binder_dir"])
    declaring = str(REPO_ROOT / MANIFEST["declaring_dir"])
    expect = case["expect"]

    if "error_code" in expect:
        with pytest.raises(ExpressionTemplateError) as excinfo:
            apply_mount_url_substitutions(doc, edge, binder, "case")
            resolve_data_source_urls(doc, declaring)
        assert excinfo.value.code == expect["error_code"], str(excinfo.value)
        for needle in expect["message_contains"]:
            assert needle in str(excinfo.value)
        return

    apply_mount_url_substitutions(doc, edge, binder, "case")
    resolve_data_source_urls(doc, declaring)
    got = doc["data_sources"]["s"]["source"]
    assert got["url_template"] == _expected(expect["url_template"])
    if "mirrors" in expect:
        assert got["mirrors"] == [_expected(m) for m in expect["mirrors"]]


@pytest.mark.parametrize("fixture", MANIFEST["fixtures"], ids=lambda f: f["id"])
def test_fixture_load_matches_the_shared_manifest(fixture: dict) -> None:
    path = str(SUITE / fixture["path"])
    if fixture["expect"] == "accepted":
        loaded = earthsci_ast.load_path(path)
        for name, pin in fixture.get("hoisted_sources", {}).items():
            assert name in loaded.data_sources, f"{name} did not reach the root"
            src = loaded.data_sources[name].source
            assert src.url_template == _expected(pin["url_template"]), name
            if "mirrors" in pin:
                assert list(src.mirrors) == [_expected(m) for m in pin["mirrors"]], name
        for axis, size in fixture.get("index_set_sizes", {}).items():
            assert loaded.index_sets[axis]["size"] == size, axis
        return
    with pytest.raises(ExpressionTemplateError) as excinfo:
        earthsci_ast.load_path(path)
    assert excinfo.value.code == fixture["error_code"], str(excinfo.value)
    for needle in fixture["message_contains"]:
        assert needle in str(excinfo.value)


def test_an_edge_without_url_substitutions_leaves_the_document_alone() -> None:
    doc = {"data_sources": {"s": {"source": {"url_template": "{x}/t.nc"}}}}
    before = json.loads(json.dumps(doc))
    apply_mount_url_substitutions(doc, {"ref": "x.esm"}, "/a", "e")
    apply_mount_url_substitutions(doc, {"ref": "x.esm", "url_substitutions": {}}, "/a", "e")
    assert doc == before


@pytest.mark.parametrize(
    "subs",
    [["snapshot"], {"snapshot": 3}, {"snapshot": "a}"}],
    ids=["not_an_object", "not_a_string", "closing_brace"],
)
def test_a_malformed_edge_is_unresolved(subs) -> None:
    doc = {"data_sources": {"s": {"source": {"url_template": "./{snapshot}/t.nc"}}}}
    with pytest.raises(ExpressionTemplateError) as excinfo:
        apply_mount_url_substitutions(doc, {"ref": "x.esm", "url_substitutions": subs}, "/a", "e")
    assert excinfo.value.code == "data_source_url_unresolved"


def test_the_edge_does_not_write_through_to_the_callers_dict() -> None:
    """Copy-on-write, as :func:`resolve_data_source_urls`: the nested ``source``
    dicts may still be shared with a caller."""
    src = {"url_template": "./{snapshot}/t.nc"}
    doc = {"data_sources": {"s": {"source": src}}}
    apply_mount_url_substitutions(doc, {"url_substitutions": {"snapshot": "a"}}, "/m", "e")
    assert src == {"url_template": "./{snapshot}/t.nc"}
    assert doc["data_sources"]["s"]["source"]["url_template"] == "./a/t.nc"


@pytest.mark.parametrize("fixture_id", ["mount_toplevel", "mount_subsystem"])
def test_the_edge_is_consumed_at_load(fixture_id: str) -> None:
    """§4.7 "Round trip": ``url_substitutions`` does not survive parse -> emit."""
    fixture = next(f for f in MANIFEST["fixtures"] if f["id"] == fixture_id)
    loaded = earthsci_ast.load_path(str(SUITE / fixture["path"]))
    assert '"url_substitutions":' not in to_json(loaded)


def test_a_url_loaded_leaf_resolves_its_relative_locations_against_its_url() -> None:
    """A document mounted from a URL has a URL for a directory: its relative
    locations join it by RFC 3986 §5.2 (esm-spec §4.7 "URL (remote) references"),
    rather than being spliced after the working directory."""
    from earthsci_ast._data_source_urls import resolve_source_url

    assert resolve_source_url("../d/./t.nc", "https://h.org/a/b") == "https://h.org/a/d/t.nc"
    assert resolve_source_url("/abs/t.nc", "https://h.org/a/b") == "file:///abs/t.nc"


def _serve(monkeypatch, docs: dict[str, dict]) -> list[str]:
    """Serve ``docs`` (URL -> document) in place of the network, recording
    each URL fetched; an unknown URL fails as a download does."""
    import io
    import urllib.error
    import urllib.request

    fetched: list[str] = []

    def urlopen(url, *a, **k):
        fetched.append(url)
        if url not in docs:
            raise urllib.error.URLError(f"404 {url}")
        return io.BytesIO(json.dumps(docs[url]).encode())

    monkeypatch.setattr(urllib.request, "urlopen", urlopen)
    return fetched


def _remote_assembly(tmp_path, catalogue_mounts: str) -> tuple[str, dict[str, dict]]:
    stop = {
        name: json.loads((SUITE / "catalogue" / f"stop_{name}.esm").read_text())
        for name in ("outer", "inner")
    }
    catalogue = {
        "esm": "1.0.0",
        "metadata": {"name": "remote_catalogue"},
        "models": {"Outer": {"ref": catalogue_mounts}},
    }
    root = {
        "esm": "1.0.0",
        "metadata": {"name": "remote_root"},
        "models": {
            "Run": {
                "variables": {},
                "equations": [],
                "subsystems": {
                    "Snap": {
                        "ref": "https://example.org/lib/cat.esm",
                        "bindings": {"n_rows": 4},
                    }
                },
            }
        },
    }
    path = tmp_path / "root.esm"
    path.write_text(json.dumps(root))
    docs = {
        "https://example.org/lib/cat.esm": catalogue,
        "https://example.org/lib/stop_outer.esm": stop["outer"],
        "https://example.org/lib/stop_inner.esm": stop["inner"],
    }
    return str(path), docs


def test_a_binding_reaches_through_a_url_loaded_assembly(monkeypatch, tmp_path) -> None:
    """§4.7 "Bindings reach through an assembly", with the catalogue loaded
    from a URL: the walk that decides whether `n_rows` is forwarded follows its
    RELATIVE ref onto the catalogue's URL directory (§4.7 "URL (remote)
    references"), as the load itself does, and the forwarded binding stops at
    the first document that declares the name."""
    path, docs = _remote_assembly(tmp_path, "stop_outer.esm")
    fetched = _serve(monkeypatch, docs)
    loaded = earthsci_ast.load_path(path)
    assert loaded.index_sets["rows"]["size"] == 4
    assert loaded.index_sets["inner_rows"]["size"] == 10
    assert "https://example.org/lib/stop_outer.esm" in fetched
    assert "https://example.org/lib/stop_inner.esm" in fetched


def test_an_unreadable_nested_ref_is_a_read_error_not_an_unknown_name(
    monkeypatch, tmp_path
) -> None:
    """The forwarding walk runs before the leaf's own mounts load, so it must
    report a nested ref it cannot read rather than refuse the edge binding as
    `template_import_unknown_name` (which the unread document might declare)."""
    path, docs = _remote_assembly(tmp_path, "missing.esm")
    _serve(monkeypatch, docs)
    from earthsci_ast.parse import SubsystemRefError

    with pytest.raises(SubsystemRefError) as excinfo:
        earthsci_ast.load_path(path)
    assert excinfo.value.code == "unresolved_subsystem_ref", str(excinfo.value)
    assert "https://example.org/lib/missing.esm" in str(excinfo.value)


@pytest.mark.parametrize(("second", "accepted"), [("a", True), ("b", False)])
def test_a_top_level_and_a_subsystem_mount_are_siblings(second: str, accepted: bool) -> None:
    """esm-spec §4.7: the merge rule spans both mount forms of one document, so
    a top-level mount and a subsystem mount contributing one name must agree."""
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "siblings_across_forms"},
        "models": {
            "T": {"ref": "catalogue/catalogue.esm", "url_substitutions": {"snapshot": "a"}},
            "O": {
                "variables": {},
                "equations": [],
                "subsystems": {
                    "S": {
                        "ref": "catalogue/catalogue.esm",
                        "url_substitutions": {"snapshot": second},
                    }
                },
            },
        },
    }
    if accepted:
        loaded = earthsci_ast.load_string(json.dumps(doc), base_path=str(SUITE))
        assert type(loaded.data_sources) is dict
        assert sorted(loaded.data_sources) == ["fixed", "lead", "segment"]
        return
    with pytest.raises(ExpressionTemplateError) as excinfo:
        earthsci_ast.load_string(json.dumps(doc), base_path=str(SUITE))
    assert excinfo.value.code == "data_source_merge_conflict"
    assert "models.T" in str(excinfo.value) and "subsystems.S" in str(excinfo.value)
