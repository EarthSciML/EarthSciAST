"""Manifest-driven adapter for ``tests/conformance/loader_unit_conversion``.

The Python side of the cross-binding contract in that directory's README:
esm-spec §8.5 says the runtime applies a loader variable's ``unit_conversion``
when producing values in the declared ``units``, and the ESIO provider path is
where a loader-fed model actually gets its numbers.

Driven entirely by ``manifest.json`` + each fixture's golden: adding a fixture
needs no change here.
"""

from __future__ import annotations

import json
import pathlib
import struct

import numpy as np
import pytest

esio = pytest.importorskip("earthsciio", reason="EarthSciIO not installed")

from earthsci_ast.data_loaders.esio_provider import (  # noqa: E402
    providers_from_document,
)

TESTS_DIR = pathlib.Path(__file__).resolve().parents[3] / "tests"
MANIFEST = TESTS_DIR / "conformance" / "loader_unit_conversion" / "manifest.json"


def _bits(values) -> list[int]:
    """f64 bit patterns — the comparison the manifest asks for, so 0.0/-0.0 and
    any last-ulp disagreement are visible rather than rounded away."""
    return [struct.unpack("<Q", struct.pack("<d", float(v)))[0] for v in values]


def _manifest() -> dict:
    assert MANIFEST.is_file(), f"conformance manifest not found: {MANIFEST}"
    return json.loads(MANIFEST.read_text())


def _cases() -> list[dict]:
    return _manifest()["fixtures"]


def _ids(cases) -> list[str]:
    return [c["id"] for c in cases]


@pytest.fixture(params=_cases(), ids=_ids(_cases()))
def case(request, tmp_path):
    """One manifest entry: its document (URLs patched onto the committed data
    files), its golden, and the providers the document declares."""
    case = request.param
    doc = json.loads((TESTS_DIR / case["document"]).read_text())
    golden = json.loads((TESTS_DIR / case["golden"]).read_text())
    overrides = {
        loader: f"file://{(TESTS_DIR / rel).resolve()}"
        for loader, rel in case.get("url_overrides", {}).items()
    }
    providers = providers_from_document(
        doc,
        cache_root=str(tmp_path / "cache"),
        loaders=case.get("loaders"),
        url_overrides=overrides,
    )
    return case, golden, providers


def _delivered(providers, key) -> np.ndarray:
    assert key in providers, f"the document declares no provider {key!r}"
    return np.asarray(providers[key].sample(0.0), dtype=float)


def test_the_declared_conversion_is_applied_bit_for_bit(case):
    """§8.5: the delivered array is the golden's, on the f64 bits."""
    _c, golden, providers = case
    for key, want in golden["delivered"].items():
        got = _delivered(providers, key)
        assert len(got) == golden["records"], f"{key}: wrong record count"
        assert _bits(got) == _bits(want), f"{key}: delivered {list(got)}, want {want}"


def test_a_variable_declaring_no_conversion_delivers_the_raw_column(case):
    """The NO-OP property: adding §8.5 support must change nothing for a
    document that declares no conversion."""
    _c, golden, providers = case
    for key in golden["no_conversion_declared"]:
        got = _delivered(providers, key)
        assert _bits(got) == _bits(golden["raw_columns"][key]), (
            f"{key} declares no unit_conversion, so it must deliver the raw column"
        )


def test_every_converted_variable_actually_moved(case):
    """The fixture is load-bearing: an implementation that applies nothing
    cannot pass it."""
    _c, golden, providers = case
    for key in golden["delivered"]:
        if key in golden["no_conversion_declared"]:
            continue
        got = _delivered(providers, key)
        assert _bits(got) != _bits(golden["raw_columns"][key]), (
            f"{key} declares a unit_conversion, so it must NOT deliver the raw column"
        )
