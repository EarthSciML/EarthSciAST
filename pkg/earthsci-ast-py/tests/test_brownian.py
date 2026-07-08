"""Round-trip tests for the brownian (SDE) variable type."""

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast.parse import load, SchemaValidationError
from earthsci_ast.serialize import save


SDE_DIR = FIXTURES_ROOT / "fixtures" / "sde"


def test_ornstein_uhlenbeck_round_trip(tmp_path):
    parsed = load(str(SDE_DIR / "ornstein_uhlenbeck.esm"))
    bw = parsed.models["OU"].variables["Bw"]
    assert bw.type == "brownian"
    assert bw.noise_kind == "wiener"

    out_path = tmp_path / "ou.esm"
    save(parsed, str(out_path))
    reparsed = load(str(out_path))
    rbw = reparsed.models["OU"].variables["Bw"]
    assert rbw.type == "brownian"
    assert rbw.noise_kind == "wiener"


def test_correlated_noise_round_trip(tmp_path):
    parsed = load(str(SDE_DIR / "correlated_noise.esm"))
    for name in ("Bx", "By"):
        bv = parsed.models["TwoBody"].variables[name]
        assert bv.type == "brownian"
        assert bv.correlation_group == "wind"

    out_path = tmp_path / "cn.esm"
    save(parsed, str(out_path))
    reparsed = load(str(out_path))
    for name in ("Bx", "By"):
        bv = reparsed.models["TwoBody"].variables[name]
        assert bv.type == "brownian"
        assert bv.correlation_group == "wind"


def test_schema_rejects_noise_kind_on_non_brownian(tmp_path):
    bad = {
        "esm": "0.1.0",
        "metadata": {"name": "Bad"},
        "models": {
            "M": {
                "variables": {"x": {"type": "state", "noise_kind": "wiener"}},
                "equations": [],
            }
        },
    }
    bad_path = tmp_path / "bad.esm"
    bad_path.write_text(json.dumps(bad))
    with pytest.raises(SchemaValidationError):
        load(str(bad_path))
