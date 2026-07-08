"""
Tests that the new STAC-like DataLoader schema can express every data loader
implemented in EarthSciData.jl.

Each fixture under tests/fixtures/data_loaders/*.esm hand-constructs an
instantiation of one EarthSciData.jl FileSet using the new kind/source/temporal/
grid/variables shape. The test ensures:

1. The fixture validates against the schema (no validation errors).
2. It round-trips through parse -> serialize without loss of DataLoader fields.

Fixtures carry a comment header pointing at the EarthSciData.jl source file/lines
they correspond to.
"""

import json
from pathlib import Path

import pytest

from earthsci_ast import load, save


FIXTURES_DIR = Path(__file__).parent / "fixtures" / "data_loaders"

# Expected fixture filenames — each corresponds to a distinct EarthSciData.jl loader.
EXPECTED_FIXTURES = [
    "geosfp.esm",
    "era5.esm",
    "wrf.esm",
    "nei2016monthly.esm",
    "ceds.esm",
    "edgar_v81_monthly.esm",
    "usgs3dep.esm",
    "usgs3dep_slopes.esm",
    "openaq.esm",
    "ncep_ncar_reanalysis.esm",
    "landfire.esm",
]


def _strip_comments(data):
    """Recursively drop fields whose key starts with '_comment'."""
    if isinstance(data, dict):
        return {k: _strip_comments(v) for k, v in data.items() if not k.startswith("_comment")}
    if isinstance(data, list):
        return [_strip_comments(v) for v in data]
    return data


@pytest.mark.parametrize("fixture_name", EXPECTED_FIXTURES)
def test_earthscidata_fixture_validates(fixture_name):
    """Each EarthSciData.jl coverage fixture must validate and parse cleanly."""
    fixture_path = FIXTURES_DIR / fixture_name
    assert fixture_path.exists(), f"Missing fixture: {fixture_path}"

    content = fixture_path.read_text()
    # Strip leading _comment keys before loading since the schema is strict.
    raw = json.loads(content)
    cleaned = _strip_comments(raw)
    cleaned_content = json.dumps(cleaned)

    esm = load(cleaned_content)
    assert esm.data_loaders, f"{fixture_name}: no data_loaders parsed"


@pytest.mark.parametrize("fixture_name", EXPECTED_FIXTURES)
def test_earthscidata_fixture_roundtrips(fixture_name):
    """Each fixture's DataLoader block must survive parse -> serialize unchanged."""
    fixture_path = FIXTURES_DIR / fixture_name
    raw = json.loads(fixture_path.read_text())
    cleaned = _strip_comments(raw)
    cleaned_content = json.dumps(cleaned)

    esm = load(cleaned_content)
    out = save(esm)
    out_data = json.loads(out)

    orig_loaders = cleaned["data_loaders"]
    out_loaders = out_data.get("data_loaders", {})
    assert set(orig_loaders.keys()) == set(out_loaders.keys()), (
        f"{fixture_name}: loader names differ"
    )

    for name, orig in orig_loaders.items():
        new = out_loaders[name]
        for field in ("kind", "source", "variables"):
            assert new.get(field) == orig.get(field), (
                f"{fixture_name}/{name}/{field}: round-trip lost field"
            )
        for field in ("temporal", "grid", "mesh", "determinism"):
            if field in orig:
                assert new.get(field) == orig.get(field), (
                    f"{fixture_name}/{name}/{field}: round-trip changed field"
                )


def test_all_expected_fixtures_present():
    """The fixtures directory must contain every loader listed in EXPECTED_FIXTURES."""
    present = {p.name for p in FIXTURES_DIR.glob("*.esm")}
    missing = set(EXPECTED_FIXTURES) - present
    assert not missing, f"Missing EarthSciData.jl coverage fixtures: {sorted(missing)}"
