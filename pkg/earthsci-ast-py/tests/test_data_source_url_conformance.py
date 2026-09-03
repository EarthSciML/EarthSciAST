"""esm-spec §8.2.1 data-source location resolution, against the SHARED pin.

Reads ``tests/conformance/data_source_url/manifest.json`` — the one place the
expected resolution is written down — and asserts this binding against it. Every
binding's own suite reads the same file, so a path rule that differed between
bindings (which would silently make documents non-portable, the defect §8.2.1
closes) fails here rather than downstream.

Expectations are repo-relative paths, not literal URLs: the resolved form is a
machine-specific absolute ``file://`` URL and a golden holding one would only
pass on the machine that wrote it.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import earthsci_ast

REPO_ROOT = Path(__file__).resolve().parents[3]
SUITE = REPO_ROOT / "tests" / "conformance" / "data_source_url"
MANIFEST = json.loads((SUITE / "manifest.json").read_text())


def _expected(spec: dict) -> str:
    if "verbatim" in spec:
        return spec["verbatim"]
    return "file://" + str(REPO_ROOT / spec["repo_path"])


def _fixture(fixture_id: str) -> dict:
    for f in MANIFEST["fixtures"]:
        if f["id"] == fixture_id:
            return f
    raise AssertionError(f"no fixture {fixture_id!r} in the shared manifest")


@pytest.mark.parametrize(
    "source_name",
    sorted(_fixture("relative_catalog")["sources"]),
)
def test_relative_catalog_resolves_as_pinned(source_name: str) -> None:
    fixture = _fixture("relative_catalog")
    loaded = earthsci_ast.load_path(str(SUITE / fixture["path"]))
    pin = fixture["sources"][source_name]
    source = loaded.data_sources[source_name].source

    assert source.url_template == _expected(pin["url_template"])
    if "mirrors" in pin:
        assert [str(m) for m in (source.mirrors or [])] == [
            _expected(m) for m in pin["mirrors"]
        ]


def test_resolution_is_idempotent_so_parse_emit_parse_is_stable(tmp_path: Path) -> None:
    """§8.2.1: the resolved form is scheme-led, so a second pass is a no-op.

    Re-loaded from a DIFFERENT directory, so a template that had somehow stayed
    relative would resolve somewhere else and be caught, rather than resolving
    to the same place by accident.
    """
    fixture = _fixture("relative_catalog")
    first = earthsci_ast.load_path(str(SUITE / fixture["path"]))
    emitted = tmp_path / "emitted.esm"
    emitted.write_text(earthsci_ast.to_json(first))
    second = earthsci_ast.load_path(str(emitted))

    for name, ds in first.data_sources.items():
        assert second.data_sources[name].source.url_template == ds.source.url_template
        assert list(second.data_sources[name].source.mirrors or []) == list(
            ds.source.mirrors or []
        )


@pytest.mark.parametrize("fixture_id", ["env_var_catalog", "env_var_mirror_catalog"])
def test_an_unresolvable_template_is_refused_by_a_diagnostic_that_names_it(
    fixture_id: str,
) -> None:
    """The refusal, in the direction that matters (§8.2.1).

    Not merely "it does not resolve": the diagnostic has to NAME the entry and
    the template. Treating ``${MOVES_SNAPSHOTS}`` as a directory name yields an
    I/O error about a path nobody wrote, one step away from a source that
    delivers a consuming parameter's default and compares nothing.
    """
    fixture = _fixture(fixture_id)
    with pytest.raises(Exception) as excinfo:  # noqa: PT011 - the code is the assertion
        earthsci_ast.load_path(str(SUITE / fixture["path"]))

    err = excinfo.value
    assert getattr(err, "code", None) == fixture["error_code"], (
        f"expected diagnostic code {fixture['error_code']!r}, got {err!r}"
    )
    for needle in fixture["message_contains"]:
        assert needle in str(err), f"the diagnostic must name {needle!r}; got: {err}"


def test_loading_a_dict_does_not_resolve_urls_inside_the_callers_own_dict() -> None:
    """§8.2.1 resolution must not be a side effect on a caller's argument.

    ``load_document`` shallow-copies, so ``data["data_sources"]`` and every
    nested ``source`` dict are still the caller's objects. An in-place rewrite
    there would (a) mutate an argument, and (b) make a SECOND load of the same
    dict resolve an already-resolved URL -- which, against a different base,
    silently reads a different file. That is the silent-wrong-value shape, so it
    is pinned rather than left to review.
    """
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "M", "description": "d", "authors": ["a"], "license": "MIT"},
        "data_sources": {
            "t": {"kind": "static", "source": {"url_template": "./tables/probe.parquet"}}
        },
    }
    source = doc["data_sources"]["t"]["source"]

    first = earthsci_ast.load_document(doc, base_path="/base/one")
    assert first.data_sources["t"].source.url_template == "file:///base/one/tables/probe.parquet"
    assert source["url_template"] == "./tables/probe.parquet", (
        "the caller's own dict must still hold the AUTHORED template"
    )

    # The same dict, a different base: it must resolve afresh, not compound.
    second = earthsci_ast.load_document(doc, base_path="/base/two")
    assert second.data_sources["t"].source.url_template == "file:///base/two/tables/probe.parquet"
