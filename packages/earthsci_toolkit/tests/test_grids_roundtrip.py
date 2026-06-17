"""
Round-trip tests for §6 top-level `grids` schema support (gt-5kq3).

These tests verify the minimal viable round-trip path for the
grid families (cartesian, unstructured) as laid out in
docs/rfcs/discretization.md §6. Fixtures live at repo-root
``tests/grids/*.esm`` and are shared across language bindings.
"""

import copy
import json
from pathlib import Path

import pytest

from earthsci_toolkit import load, save
from earthsci_toolkit.esm_types import Grid, GridMetricGenerator


REPO_ROOT = Path(__file__).resolve().parents[3]
GRIDS_DIR = REPO_ROOT / "tests" / "grids"


FIXTURES = [
    ("cartesian_uniform", "atmos_rect", "cartesian"),
    ("unstructured_mpas", "mpas_cvmesh", "unstructured"),
]


def _load_fixture_json(name: str) -> dict:
    with open(GRIDS_DIR / f"{name}.esm", "r") as f:
        return json.load(f)


@pytest.mark.parametrize("fixture_name,grid_id,family", FIXTURES)
def test_grid_fixture_loads_with_expected_family(fixture_name, grid_id, family):
    """load() parses each grid fixture and exposes the top-level grid."""
    esm = load(GRIDS_DIR / f"{fixture_name}.esm")
    assert grid_id in esm.grids, f"missing grid '{grid_id}' after load"
    grid = esm.grids[grid_id]
    assert isinstance(grid, Grid)
    assert grid.family == family
    # Propagated name (matches the dict key).
    assert grid.name == grid_id


@pytest.mark.parametrize("fixture_name,grid_id,family", FIXTURES)
def test_grid_roundtrip_equality(fixture_name, grid_id, family):
    """grids subtree survives load -> save -> load unchanged."""
    original = _load_fixture_json(fixture_name)
    esm = load(GRIDS_DIR / f"{fixture_name}.esm")
    reserialized = json.loads(save(esm))
    assert "grids" in reserialized
    # Key-order-insensitive comparison of the grids subtree.
    assert reserialized["grids"] == original["grids"], (
        "grids subtree did not round-trip. Original vs reserialized:\n"
        f"original: {original['grids']}\n"
        f"actual:   {reserialized['grids']}"
    )

    # And a second round-trip stays stable.
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".esm", delete=False) as tf:
        tf.write(json.dumps(reserialized))
        tmp_path = tf.name
    esm2 = load(tmp_path)
    assert grid_id in esm2.grids
    assert esm2.grids[grid_id].family == family


def test_grid_counts_match_fixtures():
    """Each fixture declares exactly one grid."""
    for fixture_name, grid_id, _family in FIXTURES:
        esm = load(GRIDS_DIR / f"{fixture_name}.esm")
        assert len(esm.grids) == 1, (
            f"expected 1 grid in {fixture_name}, got {len(esm.grids)}"
        )


def test_loader_generator_references_validate():
    """Loader-backed metric arrays / connectivity resolve to declared loaders."""
    # cartesian: one loader-backed metric array (dz -> zlev_file)
    esm = load(GRIDS_DIR / "cartesian_uniform.esm")
    dz_gen = esm.grids["atmos_rect"].metric_arrays["dz"].generator
    assert dz_gen.kind == "loader"
    assert dz_gen.loader == "zlev_file"
    assert dz_gen.loader in esm.data_loaders

    # unstructured: all metric arrays + connectivity go through 'mpas_mesh'
    esm = load(GRIDS_DIR / "unstructured_mpas.esm")
    mpas = esm.grids["mpas_cvmesh"]
    for name, arr in mpas.metric_arrays.items():
        assert arr.generator.kind == "loader", f"{name}: not loader-backed"
        assert arr.generator.loader in esm.data_loaders
    for name, conn in mpas.connectivity.items():
        assert conn.loader in esm.data_loaders, (
            f"{name}: loader '{conn.loader}' not declared"
        )


def test_expression_generator_roundtrips():
    """Expression generators survive load -> save structurally."""
    original = _load_fixture_json("cartesian_uniform")
    esm = load(GRIDS_DIR / "cartesian_uniform.esm")
    dx_gen = esm.grids["atmos_rect"].metric_arrays["dx"].generator
    assert dx_gen.kind == "expression"
    # Round-trip JSON equality on the dx generator subtree.
    reserialized = json.loads(save(esm))
    assert (
        reserialized["grids"]["atmos_rect"]["metric_arrays"]["dx"]
        == original["grids"]["atmos_rect"]["metric_arrays"]["dx"]
    )


def test_unknown_loader_raises(tmp_path):
    """A metric_array generator referencing an undeclared loader is rejected."""
    data = _load_fixture_json("cartesian_uniform")
    # Point the dz generator at a nonexistent loader.
    data = copy.deepcopy(data)
    data["grids"]["atmos_rect"]["metric_arrays"]["dz"]["generator"]["loader"] = \
        "no_such_loader"
    broken = tmp_path / "broken.esm"
    broken.write_text(json.dumps(data))
    with pytest.raises(Exception) as excinfo:
        load(broken)
    msg = str(excinfo.value)
    assert "E_UNKNOWN_LOADER" in msg or "no_such_loader" in msg
