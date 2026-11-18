"""A mounted file is held to its OWN declared ``esm`` (esm-spec §4.7): every
file-level version gate the root runs also runs on each ``{ref}`` leaf, so a
newer root cannot make an older leaf's construct legal. (The 1.3.0 gates on
``solver.external`` / ``solver.time_span`` are root-only by §2.2.6/§2.2.7 and
are pinned by the ``solver_external`` / ``solver_time_span`` conformance
manifests.)"""

from __future__ import annotations

import json

import pytest
from conftest import INVALID_DIR, VALID_DIR

from earthsci_ast import load_path

_EXPECTED = json.loads((INVALID_DIR / "expected_errors.json").read_text())


@pytest.mark.parametrize(
    "fname",
    [
        "version_gate_newer_mounts_older_const_units.esm",
        "version_gate_newer_mounts_older_solver.esm",
    ],
)
def test_a_newer_root_does_not_make_an_older_leaf_legal(fname):
    with pytest.raises(Exception) as excinfo:
        load_path(INVALID_DIR / fname)
    assert getattr(excinfo.value, "code", None) == _EXPECTED[fname]["resolver_error_code"]


def test_a_template_library_is_held_to_its_own_version():
    """A template library is a file held to its own version too (esm-spec §4.7,
    §4.8.5 item 6): a 1.1.0 library whose template body carries a unit-bearing
    const is refused, whatever the importing document declares."""
    fname = "version_gate_library_older_const_units.esm"
    with pytest.raises(Exception) as excinfo:
        load_path(INVALID_DIR / fname)
    assert getattr(excinfo.value, "code", None) == _EXPECTED[fname]["resolver_error_code"]


def test_an_older_root_may_mount_a_newer_leaf():
    load_path(VALID_DIR / "version_gate_older_mounts_newer.esm")
