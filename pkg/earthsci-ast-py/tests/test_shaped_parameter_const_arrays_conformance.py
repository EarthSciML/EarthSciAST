"""Cross-language conformance: a caller's ``const_arrays`` entry for a SHAPED
parameter is keyed like a ``parameter_overrides`` entry (esm-spec §6.6.2,
CONFORMANCE_SPEC §5.32.5).

Shared fixtures and the expected values live under
``tests/conformance/shaped_parameter_const_arrays/`` (repo root); the Julia runner
(``conformance_shaped_parameter_const_arrays_test.jl``) and the Rust runner
(``shaped_parameter_const_arrays_conformance.rs``) read the same manifest.

Python matched a ``const_arrays`` key against the flattened name only, so a
model-local key (``k`` for ``Column.k``) left the parameter bound as a scalar:
with no ``default`` the per-cell read raised "index applied to scalar value", and
with one the run used the default and ignored the caller's array.
``canonicalize_const_array_keys`` now resolves the key by the override rules.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast import esm_problem, observed_field

_ROOT = (
    Path(__file__).resolve().parents[3] / "tests" / "conformance" / "shaped_parameter_const_arrays"
)
_MANIFEST = _ROOT / "manifest.json"


def _manifest() -> dict:
    return json.loads(_MANIFEST.read_text())


def test_manifest_declares_the_three_executing_bindings() -> None:
    manifest = _manifest()
    assert manifest["category"] == "shaped_parameter_const_arrays"
    assert set(manifest["bindings_required"]) == {"julia", "python", "rust"}
    assert manifest["cases"]


@pytest.mark.parametrize("compiler", _manifest()["compilers"])
@pytest.mark.parametrize("case", _manifest()["cases"], ids=lambda c: c["id"])
def test_const_array_key_binds_the_shaped_parameter(case: dict, compiler: str) -> None:
    arrays = {k: np.asarray(v, dtype=float) for k, v in case["const_arrays"].items()}
    prob = esm_problem(
        str(_ROOT / case["fixture"]), (0.0, 1.0), compiler=compiler, const_arrays=arrays
    )
    got = np.asarray(observed_field(prob, case["observed"]), dtype=float)
    assert got.tolist() == [float(x) for x in case["expected"]]
