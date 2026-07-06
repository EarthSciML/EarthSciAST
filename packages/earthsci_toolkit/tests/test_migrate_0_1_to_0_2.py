"""Tests for the v0.1 -> v0.2 boundary-condition migration tool.

Covers ``earthsci_toolkit.migration.migrate_file_0_1_to_0_2`` (pure dict
transform) and the ``esm-migrate`` CLI (``earthsci_toolkit.cli.migrate``).

Spec references: docs/rfcs/discretization.md §10.1 and §16.1.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR, REPO_ROOT

from earthsci_toolkit.cli import migrate as cli_migrate
from earthsci_toolkit.migration import migrate_file_0_1_to_0_2


# --- Helpers -----------------------------------------------------------------


def _minimal_v01(
    domain_bcs,
    model_variables=None,
    domain_name: str = "default",
    model_domain: str | None = None,
):
    """Build a minimal v0.1.0 ESM file with a given list of domain BCs."""
    variables = model_variables or {"u": {"type": "state", "default": 0.0}}
    model = {"variables": variables, "equations": []}
    if model_domain is not None:
        model["domain"] = model_domain
    return {
        "esm": "0.1.0",
        "metadata": {
            "name": "MigrateTest",
            "description": "Fixture for migration tests",
            "authors": ["pytest"],
            "created": "2026-04-19T00:00:00Z",
        },
        "models": {"TestModel": model},
        "domains": {
            domain_name: {
                "independent_variable": "t",
                "temporal": {
                    "start": "2024-01-01T00:00:00Z",
                    "end": "2024-01-01T01:00:00Z",
                },
                "spatial": {
                    "x": {"min": 0.0, "max": 1.0, "units": "m"},
                },
                "initial_conditions": {"type": "constant", "value": 0.0},
                "boundary_conditions": domain_bcs,
            }
        },
    }


# --- Dict-level migration ----------------------------------------------------


class TestMigrateFile:
    def test_version_bump(self):
        src = _minimal_v01([])
        out = migrate_file_0_1_to_0_2(src)
        assert out["esm"] == "0.2.0"
        # Input is not mutated (pure transform).
        assert src["esm"] == "0.1.0"

    def test_zero_gradient_x_fans_out_to_xmin_and_xmax(self):
        src = _minimal_v01([{"type": "zero_gradient", "dimensions": ["x"]}])
        out = migrate_file_0_1_to_0_2(src)
        bcs = out["models"]["TestModel"]["boundary_conditions"]
        assert set(bcs.keys()) == {
            "u_zero_gradient_xmin",
            "u_zero_gradient_xmax",
        }
        assert bcs["u_zero_gradient_xmin"] == {
            "variable": "u",
            "side": "xmin",
            "kind": "zero_gradient",
        }
        assert bcs["u_zero_gradient_xmax"]["side"] == "xmax"

    def test_periodic_emits_only_min_side(self):
        """RFC §9.2.1: declare periodic once on the min side."""
        src = _minimal_v01([{"type": "periodic", "dimensions": ["lon"]}])
        out = migrate_file_0_1_to_0_2(src)
        bcs = out["models"]["TestModel"]["boundary_conditions"]
        # lon is not in the closed short-axis set → lon_min/lon_max.
        assert set(bcs.keys()) == {"u_periodic_lon_min"}
        assert bcs["u_periodic_lon_min"]["side"] == "lon_min"

    def test_multiple_dimensions_in_one_entry(self):
        src = _minimal_v01([{"type": "zero_gradient", "dimensions": ["x", "y"]}])
        out = migrate_file_0_1_to_0_2(src)
        bcs = out["models"]["TestModel"]["boundary_conditions"]
        assert set(bcs.keys()) == {
            "u_zero_gradient_xmin",
            "u_zero_gradient_xmax",
            "u_zero_gradient_ymin",
            "u_zero_gradient_ymax",
        }

    def test_value_and_robin_fields_preserved(self):
        src = _minimal_v01(
            [
                {
                    "type": "robin",
                    "dimensions": ["x"],
                    "robin_alpha": 2.0,
                    "robin_beta": 1.0,
                    "robin_gamma": 3.5,
                },
                {"type": "dirichlet", "dimensions": ["y"], "value": 42.0},
            ]
        )
        out = migrate_file_0_1_to_0_2(src)
        bcs = out["models"]["TestModel"]["boundary_conditions"]
        robin_xmin = bcs["u_robin_xmin"]
        assert robin_xmin["robin_alpha"] == 2.0
        assert robin_xmin["robin_beta"] == 1.0
        assert robin_xmin["robin_gamma"] == 3.5
        dirichlet = bcs["u_dirichlet_ymin"]
        assert dirichlet["value"] == 42.0

    def test_parameters_do_not_get_bcs(self):
        """Only state variables should receive relocated BCs."""
        src = _minimal_v01(
            [{"type": "zero_gradient", "dimensions": ["x"]}],
            model_variables={
                "u": {"type": "state", "default": 0.0},
                "k_diff": {"type": "parameter", "default": 1.0},
            },
        )
        out = migrate_file_0_1_to_0_2(src)
        bcs = out["models"]["TestModel"]["boundary_conditions"]
        # Only state var 'u' gets BCs, not parameter 'k_diff'.
        for key in bcs:
            assert bcs[key]["variable"] == "u"

    def test_domain_boundary_conditions_removed(self):
        src = _minimal_v01([{"type": "zero_gradient", "dimensions": ["x"]}])
        out = migrate_file_0_1_to_0_2(src)
        assert "boundary_conditions" not in out["domains"]["default"]

    def test_multi_domain_respects_model_domain_field(self):
        """A model with an explicit ``domain`` field only receives BCs from
        that matching domain, not from unrelated domains."""
        src = {
            "esm": "0.1.0",
            "metadata": {
                "name": "MultiDomain",
                "description": "d",
                "authors": ["pytest"],
                "created": "2026-04-19T00:00:00Z",
            },
            "models": {
                "Atmos": {
                    "domain": "atmosphere",
                    "variables": {"T": {"type": "state", "default": 288.0}},
                    "equations": [],
                },
                "Ocean": {
                    "domain": "ocean",
                    "variables": {"S": {"type": "state", "default": 35.0}},
                    "equations": [],
                },
            },
            "domains": {
                "atmosphere": {
                    "independent_variable": "t",
                    "temporal": {"start": "2024-01-01T00:00:00Z", "end": "2024-01-01T01:00:00Z"},
                    "spatial": {"x": {"min": 0.0, "max": 1.0, "units": "m"}},
                    "initial_conditions": {"type": "constant", "value": 0.0},
                    "boundary_conditions": [{"type": "zero_gradient", "dimensions": ["x"]}],
                },
                "ocean": {
                    "independent_variable": "t",
                    "temporal": {"start": "2024-01-01T00:00:00Z", "end": "2024-01-01T01:00:00Z"},
                    "spatial": {"y": {"min": 0.0, "max": 1.0, "units": "m"}},
                    "initial_conditions": {"type": "constant", "value": 0.0},
                    "boundary_conditions": [{"type": "periodic", "dimensions": ["y"]}],
                },
            },
        }
        out = migrate_file_0_1_to_0_2(src)
        atmos_bcs = out["models"]["Atmos"]["boundary_conditions"]
        ocean_bcs = out["models"]["Ocean"]["boundary_conditions"]
        # Atmos gets the x BCs (domain=atmosphere), Ocean gets the y BC.
        assert all(bc["variable"] == "T" for bc in atmos_bcs.values())
        assert set(b["side"] for b in atmos_bcs.values()) == {"xmin", "xmax"}
        assert all(bc["variable"] == "S" for bc in ocean_bcs.values())
        assert set(b["side"] for b in ocean_bcs.values()) == {"ymin"}

    def test_provenance_recorded_in_metadata(self):
        src = _minimal_v01([])
        out = migrate_file_0_1_to_0_2(src)
        assert "migrated_from_v01" in out["metadata"]["tags"]
        assert "0.1.0" in out["metadata"]["description"]
        assert "0.2.0" in out["metadata"]["description"]


# --- CLI ---------------------------------------------------------------------


class TestCli:
    def test_migrate_to_stdout(self, tmp_path, capsys):
        src = _minimal_v01([{"type": "zero_gradient", "dimensions": ["x"]}])
        in_path = tmp_path / "in.esm"
        in_path.write_text(json.dumps(src))
        rc = cli_migrate.main(["--from", "0.1.0", "--to", "0.2.0", str(in_path)])
        assert rc == 0
        out = capsys.readouterr().out
        parsed = json.loads(out)
        assert parsed["esm"] == "0.2.0"
        assert "boundary_conditions" not in parsed["domains"]["default"]
        assert "boundary_conditions" in parsed["models"]["TestModel"]

    def test_migrate_in_place(self, tmp_path):
        src = _minimal_v01([{"type": "zero_gradient", "dimensions": ["x"]}])
        in_path = tmp_path / "in.esm"
        in_path.write_text(json.dumps(src))
        rc = cli_migrate.main(["--from", "0.1.0", "--to", "0.2.0", "--in-place", str(in_path)])
        assert rc == 0
        parsed = json.loads(in_path.read_text())
        assert parsed["esm"] == "0.2.0"

    def test_migrate_to_output_file(self, tmp_path):
        src = _minimal_v01([])
        in_path = tmp_path / "in.esm"
        out_path = tmp_path / "out.esm"
        in_path.write_text(json.dumps(src))
        rc = cli_migrate.main(
            [
                "--from",
                "0.1.0",
                "--to",
                "0.2.0",
                "-o",
                str(out_path),
                str(in_path),
            ]
        )
        assert rc == 0
        # Input untouched, output has migrated version.
        assert json.loads(in_path.read_text())["esm"] == "0.1.0"
        assert json.loads(out_path.read_text())["esm"] == "0.2.0"

    def test_dry_run_shows_diff(self, tmp_path, capsys):
        src = _minimal_v01([{"type": "zero_gradient", "dimensions": ["x"]}])
        in_path = tmp_path / "in.esm"
        in_path.write_text(json.dumps(src))
        rc = cli_migrate.main(["--from", "0.1.0", "--to", "0.2.0", "--dry-run", str(in_path)])
        assert rc == 0
        out = capsys.readouterr().out
        # Input is unchanged on disk.
        assert json.loads(in_path.read_text())["esm"] == "0.1.0"
        # Diff shows the esm version bump and BC relocation.
        assert '-  "esm": "0.1.0"' in out
        assert '+  "esm": "0.2.0"' in out

    def test_unsupported_path_returns_error(self, tmp_path, capsys):
        src = _minimal_v01([])
        in_path = tmp_path / "in.esm"
        in_path.write_text(json.dumps(src))
        rc = cli_migrate.main(["--from", "0.2.0", "--to", "0.1.0", str(in_path)])
        assert rc == 1
        err = capsys.readouterr().err
        assert "Unsupported migration path" in err

    def test_missing_input_returns_error(self, tmp_path, capsys):
        rc = cli_migrate.main(
            [
                "--from",
                "0.1.0",
                "--to",
                "0.2.0",
                str(tmp_path / "nonexistent.esm"),
            ]
        )
        assert rc == 2


# --- Acceptance: fixtures round-trip through the parser ---------------------


class TestConformanceFixtures:
    """Run ``tests/conformance/migration/0_1_to_0_2/*.json`` fixtures.

    These are the cross-binding acceptance fixtures: every binding's
    migration tool must produce ``expected`` byte-for-byte from ``input``.
    """

    def _load_manifest(self) -> dict:
        manifest = CONFORMANCE_DIR / "migration/0_1_to_0_2/manifest.json"
        with manifest.open() as f:
            return json.load(f)

    def test_all_conformance_fixtures_match(self):
        data = self._load_manifest()
        base = CONFORMANCE_DIR / "migration/0_1_to_0_2"
        assert data["fixtures"], "no fixtures declared in manifest"
        for entry in data["fixtures"]:
            fix_path = base / entry["path"]
            with fix_path.open() as f:
                fx = json.load(f)
            got = migrate_file_0_1_to_0_2(fx["input"])
            assert got == fx["expected"], f"Fixture {entry['id']!r} output diverged from expected"


@pytest.mark.parametrize(
    "fixture",
    [
        "tests/valid/minimal_chemistry.esm",
        "tests/valid/full_coupled.esm",
        "tests/valid/model_only.esm",
        "tests/end_to_end/land_atmosphere_hydrology.esm",
        "tests/valid/wildfire_atmosphere_ocean.esm",
    ],
)
def test_migrated_fixture_validates_under_v02_schema(fixture):
    """Migrated pre-0.2 fixtures must pass JSON-schema validation under 0.2.0.

    We intentionally check schema validation (not the full loader) because
    some pre-0.2 fixtures carry orthogonal semantic issues (e.g., ``grad``
    operator references not yet paired with a declared coord) that the 0.2
    structural validator now enforces; those are the subject of other beads.
    This acceptance test's scope is that migration produces schema-valid
    v0.2.0 output.
    """
    import jsonschema

    path = REPO_ROOT / fixture
    if not path.exists():
        pytest.skip(f"fixture not found: {path}")
    with path.open() as f:
        data = json.load(f)
    if data.get("esm", "").startswith("0.2"):
        pytest.skip("already at 0.2")
    migrated = migrate_file_0_1_to_0_2(data)
    schema_path = REPO_ROOT / "esm-schema.json"
    with schema_path.open() as f:
        schema = json.load(f)
    jsonschema.validate(instance=migrated, schema=schema)
