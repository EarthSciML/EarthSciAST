"""Standard-library refs ``esm:std/<file>.esm`` (esm-spec §4.7).

Runs every case of ``tests/conformance/stdlib_refs/manifest.json`` (see that
directory's README), then checks with a substitute bundle that relative refs
inside a bundled file resolve among the bundled files, that cycles key on the
``esm:std`` identity, and that a document loaded from a string with no base
reaches the library.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from earthsci_ast import flatten, load_path, load_string
from earthsci_ast import stdlib as esm_stdlib
from earthsci_ast.serialize import to_json

REPO = Path(__file__).resolve().parents[3]
TIER = REPO / "tests" / "conformance" / "stdlib_refs"
MANIFEST = json.loads((TIER / "manifest.json").read_text())


def _code(exc: BaseException) -> str | None:
    return getattr(exc, "code", None)


def _mask_refs(node):
    if isinstance(node, dict):
        return {
            k: ("<ref>" if k == "ref" and isinstance(v, str) else _mask_refs(v))
            for k, v in node.items()
        }
    if isinstance(node, list):
        return [_mask_refs(v) for v in node]
    return node


def _comparable(f) -> dict:
    # A twin differs from its fixture in the `ref` spellings and in its
    # metadata description; everything else must match.
    doc = _mask_refs(json.loads(to_json(f)))
    doc.pop("metadata", None)
    return doc


def _loaded(path: Path):
    return _comparable(load_path(path))


@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda c: c["id"])
def test_stdlib_refs_conformance(case, monkeypatch):
    for k, v in case.get("env", {}).items():
        monkeypatch.setenv(k, v)
    fixture = TIER / case["fixture"]
    if case["expect"] == "same_as_twin":
        assert _loaded(fixture) == _loaded(TIER / case["twin"])
        return
    assert case["expect"] == "error"
    with pytest.raises(Exception) as info:
        f = load_path(fixture)
        if case["driver"] == "flatten":
            flatten(f)
    assert _code(info.value) == case["code"], repr(info.value)


def test_bundle_matches_repo_lib():
    names = sorted(p.name for p in (REPO / "lib").glob("*.esm"))
    bundled = sorted(p.name for p in Path(esm_stdlib.STDLIB_DIR).glob("*.esm"))
    assert bundled == names
    for n in names:
        assert (REPO / "lib" / n).read_bytes() == (Path(esm_stdlib.STDLIB_DIR) / n).read_bytes()


def test_load_string_without_base_reaches_the_library(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)  # nowhere near lib/
    text = (TIER / "import_interp.esm").read_text()
    loaded = _comparable(load_string(text))
    assert loaded == _loaded(TIER / "twins" / "import_interp.esm")


# --- substitute bundle ------------------------------------------------------


def _lib(name: str, imports: list[str] | None = None) -> dict:
    doc = {
        "esm": "1.1.0",
        "metadata": {"name": name},
        "expression_templates": {
            f"{name}_twice": {"params": ["x"], "body": {"op": "*", "args": [2, "x"]}}
        },
    }
    if imports:
        doc["expression_template_imports"] = [{"ref": r} for r in imports]
    return doc


def _consumer(ref: str, template: str) -> str:
    return json.dumps(
        {
            "esm": "1.1.0",
            "metadata": {"name": "consumer"},
            "models": {
                "M": {
                    "expression_template_imports": [{"ref": ref}],
                    "variables": {
                        "x": {"type": "unknown", "units": "1", "default": 1.0},
                        "y": {"type": "unknown", "units": "1"},
                    },
                    "equations": [
                        {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 0.0},
                        {
                            "lhs": "y",
                            "rhs": {
                                "op": "apply_expression_template",
                                "args": [],
                                "name": template,
                                "bindings": {"x": "x"},
                            },
                        },
                    ],
                }
            },
        }
    )


@pytest.fixture
def bundle(tmp_path, monkeypatch):
    d = tmp_path / "bundle"
    d.mkdir()
    monkeypatch.setattr(esm_stdlib, "STDLIB_DIR", str(d))

    def put(name: str, doc: dict) -> None:
        (d / name).write_text(json.dumps(doc))

    return put


def _y_rhs(f):
    return json.loads(to_json(f))["models"]["M"]["equations"][1]["rhs"]


@pytest.mark.parametrize("sibling", ["b.esm", "./b.esm", "esm:std/b.esm"])
def test_bundled_file_imports_a_sibling(bundle, tmp_path, sibling):
    bundle("a.esm", _lib("a", [sibling]))
    bundle("b.esm", _lib("b"))
    f = load_string(_consumer("esm:std/a.esm", "b_twice"), base_path=str(tmp_path))
    assert _y_rhs(f) == {"op": "*", "args": [2, "x"]}


def test_bundled_file_ref_leaving_the_bundle_is_unresolved(bundle, tmp_path):
    # x.esm exists right beside the bundle directory, so a plain path join
    # would find it; inside the bundle a relative ref names only siblings.
    (tmp_path / "x.esm").write_text(json.dumps(_lib("x")))
    bundle("a.esm", _lib("a", ["../x.esm"]))
    with pytest.raises(Exception) as info:
        load_string(_consumer("esm:std/a.esm", "a_twice"), base_path=str(tmp_path))
    assert _code(info.value) == "template_import_unresolved"


def test_cycle_keys_on_the_std_identity(bundle, tmp_path):
    bundle("a.esm", _lib("a", ["esm:std/b.esm"]))
    bundle("b.esm", _lib("b", ["a.esm"]))
    with pytest.raises(Exception) as info:
        load_string(_consumer("esm:std/a.esm", "a_twice"), base_path=str(tmp_path))
    assert _code(info.value) == "template_import_cycle"


def test_an_on_disk_copy_is_not_the_bundled_file(bundle, tmp_path):
    # Same bytes in the bundle and on disk: two different files, no cycle.
    bundle("b.esm", _lib("b"))
    (tmp_path / "b.esm").write_text(json.dumps(_lib("b")))
    doc = json.loads(_consumer("esm:std/b.esm", "b_twice"))
    doc["models"]["M"]["expression_template_imports"].append({"ref": "./b.esm"})
    f = load_string(json.dumps(doc), base_path=str(tmp_path))
    assert _y_rhs(f) == {"op": "*", "args": [2, "x"]}


def test_bundled_subsystem_mounts_a_sibling(bundle, tmp_path):
    bundle(
        "inner.esm",
        {
            "esm": "1.1.0",
            "metadata": {"name": "inner"},
            "models": {
                "Inner": {
                    "variables": {"k": {"type": "parameter", "units": "1", "default": 3.0}},
                    "equations": [],
                }
            },
        },
    )
    bundle(
        "outer.esm",
        {
            "esm": "1.1.0",
            "metadata": {"name": "outer"},
            "models": {
                "Outer": {
                    "subsystems": {"In": {"ref": "inner.esm"}},
                    "variables": {"z": {"type": "unknown", "units": "1"}},
                    "equations": [{"lhs": "z", "rhs": "In.k"}],
                }
            },
        },
    )
    doc = {
        "esm": "1.1.0",
        "metadata": {"name": "top"},
        "models": {
            "Top": {
                "subsystems": {"O": {"ref": "esm:std/outer.esm"}},
                "variables": {},
                "equations": [],
            }
        },
    }
    f = load_string(json.dumps(doc), base_path=str(tmp_path))
    out = json.loads(to_json(f))
    assert (
        out["models"]["Top"]["subsystems"]["O"]["subsystems"]["In"]["variables"]["k"]["default"]
        == 3.0
    )


def test_url_loaded_base_does_not_join_a_std_ref():
    from earthsci_ast.parse import _ref_location

    loc = _ref_location("esm:std/interp.esm", "https://example.com/models")
    assert loc == os.path.join(esm_stdlib.STDLIB_DIR, "interp.esm")
