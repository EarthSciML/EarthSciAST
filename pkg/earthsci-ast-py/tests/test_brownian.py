"""Round-trip tests for Brownian (SDE) parameters.

In esm 1.0.0 there is no ``brownian`` variable type: a Wiener noise source is a
``parameter`` carrying a ``distribution`` plus ``update: {"kind": "wiener"}``.
"Is this a Brownian parameter?" is therefore a DERIVED question, answered by
``earthsci_ast.brownian_parameters`` / ``system_kind`` rather than by reading a
declared type off the variable.
"""

import json

import pytest
from conftest import FIXTURES_ROOT

from earthsci_ast import brownian_parameters, system_kind
from earthsci_ast.parse import load, SchemaValidationError
from earthsci_ast.serialize import save


SDE_DIR = FIXTURES_ROOT / "fixtures" / "sde"


def _assert_wiener(var):
    """A parameter is Brownian iff it is wiener-updated and has a distribution."""
    assert var.type == "parameter"
    assert var.update is not None and var.update.kind == "wiener"
    assert var.distribution is not None


def test_ornstein_uhlenbeck_round_trip(tmp_path):
    parsed = load(str(SDE_DIR / "ornstein_uhlenbeck.esm"))
    model = parsed.models["OU"]
    _assert_wiener(model.variables["Bw"])
    assert brownian_parameters(model) == ["Bw"]
    # A brownian parameter promotes the enclosing model to an SDE.
    assert system_kind(model) == "sde"

    out_path = tmp_path / "ou.esm"
    save(parsed, str(out_path))
    reparsed = load(str(out_path))
    remodel = reparsed.models["OU"]
    _assert_wiener(remodel.variables["Bw"])
    assert brownian_parameters(remodel) == ["Bw"]
    assert system_kind(remodel) == "sde"


def test_correlated_noise_round_trip(tmp_path):
    """Correlated noise is ONE vector-valued wiener parameter with an explicit
    covariance matrix — the 0.x ``correlation_group`` tag is gone, and the
    correlation it only named is now stated as ``distribution.cov``."""
    parsed = load(str(SDE_DIR / "correlated_noise.esm"))
    model = parsed.models["TwoBody"]
    noise = model.variables["B"]
    _assert_wiener(noise)
    assert noise.shape == ["wind_noise"]
    assert noise.distribution.cov == [[1.0, 0.5], [0.5, 1.0]]
    assert brownian_parameters(model) == ["B"]
    assert system_kind(model) == "sde"

    out_path = tmp_path / "cn.esm"
    save(parsed, str(out_path))
    reparsed = load(str(out_path))
    remodel = reparsed.models["TwoBody"]
    renoise = remodel.variables["B"]
    _assert_wiener(renoise)
    assert renoise.shape == ["wind_noise"]
    assert renoise.distribution.cov == [[1.0, 0.5], [0.5, 1.0]]
    assert brownian_parameters(remodel) == ["B"]
    assert system_kind(remodel) == "sde"


def test_schema_rejects_wiener_update_without_distribution(tmp_path):
    """``update.kind == "wiener"`` resamples the parameter's own distribution,
    so it REQUIRES one (and takes no value form of its own)."""
    bad = {
        "esm": "1.0.0",
        "metadata": {"name": "Bad"},
        "models": {
            "M": {
                "variables": {
                    "b": {"type": "parameter", "update": {"kind": "wiener"}}
                },
                "equations": [],
            }
        },
    }
    bad_path = tmp_path / "bad.esm"
    bad_path.write_text(json.dumps(bad))
    with pytest.raises(SchemaValidationError):
        load(str(bad_path))


def test_schema_rejects_update_on_an_unknown(tmp_path):
    """An unknown's behaviour comes from the equations and nowhere else, so it
    cannot carry the parameter-only ``update`` / ``distribution`` slots."""
    bad = {
        "esm": "1.0.0",
        "metadata": {"name": "Bad"},
        "models": {
            "M": {
                "variables": {
                    "x": {
                        "type": "unknown",
                        "distribution": {"kind": "normal", "mean": 0.0, "std": 1.0},
                        "update": {"kind": "wiener"},
                    }
                },
                "equations": [],
            }
        },
    }
    bad_path = tmp_path / "bad.esm"
    bad_path.write_text(json.dumps(bad))
    with pytest.raises(SchemaValidationError):
        load(str(bad_path))
