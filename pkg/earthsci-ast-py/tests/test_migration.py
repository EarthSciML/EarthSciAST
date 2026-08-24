"""Version-migration tests (esm-libraries-spec §8.3).

A migration is a pure version-MARKER bump, sound only along an ADDITIVE line —
a run of releases whose changes were additive, so an older file already loads
under the newer schema. The current line is ``1.0.0 … <current schema version>``.

Nothing crosses the 1.0.0 boundary. esm 1.0.0 is a clean break: the five
declared variable types collapse to two, an observed variable's ``expression``
becomes an equation, ``data_loaders`` becomes a non-component ``data_sources``
registry, and parameter mutation moves off events onto the parameter. Each of
those RESHAPES the document, so a 0.x source has no supported target at all —
offering one would produce a file claiming 1.0.0 while still carrying 0.x
shapes, which is worse than refusing because the claim would be believed.

That is what the shared fixtures pin: ``tests/version_compatibility``'s
``compatibility_matrix.json`` (its README calls it "the canonical
specification") records ``migration_path[0]`` as "There is no automatic path: a
0.x document must be rewritten", and its migration pair's SOURCE is deliberately
unloadable by a 1.x library while only the TARGET loads. This mirrors the
TypeScript implementation, the only other one rebased onto the break.
"""

from __future__ import annotations

import dataclasses
import json

import pytest
from conftest import FIXTURES_ROOT

import earthsci_ast as esm
from earthsci_ast.errors import EarthSciAstError
from earthsci_ast.migration import (
    SCHEMA_VERSION,
    MigrationError,
    can_migrate,
    migrate,
    supported_migration_targets,
)

VERSION_DIR = FIXTURES_ROOT / "version_compatibility"


@pytest.fixture
def baseline_file():
    return esm.load_string((VERSION_DIR / "version_1_0_0_baseline.esm").read_text())


def _at_version(file, version):
    """A shallow copy of ``file`` restamped to ``version``."""
    return dataclasses.replace(file, version=version)


# ---------------------------------------------------------------------------
# supported_migration_targets
# ---------------------------------------------------------------------------


class TestSupportedMigrationTargets:
    @pytest.mark.parametrize("source", ["0.0.1", "0.0.5", "0.1.0", "0.3.0", "0.8.0", "0.9.0"])
    def test_no_target_for_any_0x_source(self, source):
        """The clean break is uncrossable, whatever the 0.x version."""
        assert supported_migration_targets(source) == []

    @pytest.mark.parametrize("source", ["1.0.0", SCHEMA_VERSION])
    def test_additive_line_source_bumps_to_current(self, source):
        assert supported_migration_targets(source) == [SCHEMA_VERSION]

    def test_version_newer_than_the_current_schema(self):
        """Same major, but beyond the current additive ceiling."""
        assert supported_migration_targets("1.99.0") == []

    @pytest.mark.parametrize("source", ["2.0.0", "2.5.1", "12.34.56"])
    def test_higher_major(self, source):
        assert supported_migration_targets(source) == []

    @pytest.mark.parametrize(
        "source", ["not-a-version", "not.a.version", "1.0", "1.0.0-alpha.1", ""]
    )
    def test_malformed_version_string(self, source):
        assert supported_migration_targets(source) == []

    def test_non_string_input(self):
        assert supported_migration_targets(None) == []


# ---------------------------------------------------------------------------
# can_migrate
# ---------------------------------------------------------------------------


class TestCanMigrate:
    def test_rejects_every_0x_source_whatever_the_target(self):
        assert can_migrate("0.0.5", "0.1.0") is False
        assert can_migrate("0.9.0", "1.0.0") is False
        assert can_migrate("0.9.0", SCHEMA_VERSION) is False

    def test_accepts_an_additive_line_source(self):
        assert can_migrate("1.0.0", SCHEMA_VERSION) is True

    def test_identity_no_op(self):
        assert can_migrate(SCHEMA_VERSION, SCHEMA_VERSION) is True

    def test_rejects_an_intermediate_target(self):
        """Only the current schema is a valid target; per-minor jumps are not offered."""
        assert can_migrate("1.0.0", "1.0.1") is False
        assert can_migrate("1.0.0", "2.0.0") is False

    def test_agrees_with_supported_targets_for_every_pair(self):
        """`can_migrate` and `migrate` must share ONE source of truth.

        Rust's ``can_migrate`` never consults its registered-migration table
        while its ``migrate`` does, so it reports a pair as migratable and then
        errors on it. Nothing here may reproduce that.
        """
        versions = [
            "0.0.5",
            "0.9.0",
            "1.0.0",
            "1.0.1",
            "1.99.0",
            "2.0.0",
            "bogus",
            SCHEMA_VERSION,
        ]
        for source in versions:
            targets = supported_migration_targets(source)
            for target in versions:
                assert can_migrate(source, target) == (target in targets)


# ---------------------------------------------------------------------------
# migrate
# ---------------------------------------------------------------------------


class TestMigrate:
    def test_bumps_an_additive_line_file(self, baseline_file):
        source = _at_version(baseline_file, "1.0.0")
        migrated = migrate(source, SCHEMA_VERSION)
        assert migrated.esm == SCHEMA_VERSION
        assert migrated.version == SCHEMA_VERSION
        assert migrated is not source
        assert source.version == "1.0.0", "the input must not be mutated"

    def test_identity_no_op_still_returns_a_fresh_object(self, baseline_file):
        source = _at_version(baseline_file, SCHEMA_VERSION)
        migrated = migrate(source, SCHEMA_VERSION)
        assert migrated.esm == SCHEMA_VERSION
        assert migrated is not source

    def test_marker_only_bump_preserves_every_other_field(self, baseline_file):
        source = _at_version(baseline_file, "1.0.0")
        migrated = migrate(source, SCHEMA_VERSION)
        assert migrated.metadata is source.metadata
        assert migrated.models == source.models
        assert migrated.reaction_systems == source.reaction_systems
        assert migrated.coupling == source.coupling

    def test_refuses_a_0x_source_rather_than_bumping_its_marker(self, baseline_file):
        source = _at_version(baseline_file, "0.9.0")
        with pytest.raises(MigrationError):
            migrate(source, SCHEMA_VERSION)
        assert source.version == "0.9.0"

    @pytest.mark.parametrize(
        ("source_version", "target"),
        [("1.0.0", "2.0.0"), ("0.1.0", SCHEMA_VERSION), ("1.0.0", "1.0.1")],
    )
    def test_unsupported_pair_raises(self, baseline_file, source_version, target):
        with pytest.raises(MigrationError):
            migrate(_at_version(baseline_file, source_version), target)

    def test_missing_version_field_raises(self, baseline_file):
        with pytest.raises(MigrationError, match="no 'esm' version field"):
            migrate(_at_version(baseline_file, ""), SCHEMA_VERSION)

    def test_error_derives_from_the_package_root_exception(self, baseline_file):
        """Every earthsci_ast exception derives from EarthSciAstError."""
        assert issubclass(MigrationError, EarthSciAstError)
        with pytest.raises(EarthSciAstError):
            migrate(_at_version(baseline_file, "0.9.0"), SCHEMA_VERSION)


# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


class TestSharedFixtures:
    def test_schema_version_matches_the_matrix_library_version(self):
        matrix = json.loads((VERSION_DIR / "compatibility_matrix.json").read_text())
        spec = matrix["version_compatibility_test_matrix"]
        assert SCHEMA_VERSION == spec["library_version"]

    def test_matrix_declares_no_automatic_0x_path(self):
        """The canonical specification, quoted so a change to it fails here."""
        matrix = json.loads((VERSION_DIR / "compatibility_matrix.json").read_text())
        notes = matrix["version_compatibility_test_matrix"]["migration_notes"]
        path = notes["0.x_to_1.0.0"]["migration_path"]
        assert "no automatic path" in path[0]

    def test_the_migration_pair_is_a_rewrite_not_a_loader_step(self):
        """The SOURCE is unloadable by this 1.x library; only the TARGET loads.

        That asymmetry IS the contract: under a clean break, migration is a
        rewrite a human performs.
        """
        source_doc = json.loads((VERSION_DIR / "migration_test_from_0_0_5.esm").read_text())
        assert source_doc["esm"] == "0.0.5"
        with pytest.raises(esm.UnsupportedVersionError):
            esm.load_string(json.dumps(source_doc))

        target = esm.load_string((VERSION_DIR / "migration_test_to_1_0_0.esm").read_text())
        assert target.esm == "1.0.0"
        # And the library declines to produce that target automatically.
        assert supported_migration_targets("0.0.5") == []
        assert not can_migrate("0.0.5", "1.0.0")

    def test_the_baseline_fixture_migrates_to_current(self):
        file = esm.load_string((VERSION_DIR / "version_1_0_0_baseline.esm").read_text())
        assert can_migrate(file.esm, SCHEMA_VERSION)
        assert migrate(file, SCHEMA_VERSION).esm == SCHEMA_VERSION

    @pytest.mark.parametrize(
        "fixture",
        [
            "version_1_0_5_patch_upgrade.esm",
            "version_1_0_100_large_patch.esm",
            "version_1_1_0_minor_upgrade.esm",
            "version_1_10_0_double_digit.esm",
        ],
    )
    def test_forward_compatible_fixtures_have_no_migration_target(self, fixture):
        """A file NEWER than the current schema sits above the additive ceiling.

        These load (the version gate accepts a newer patch outright and a newer
        minor with a warning), but there is nothing to migrate them TO: the line
        runs up to the current schema, not past it. TypeScript refuses `1.99.0`
        for the same reason.
        """
        doc = json.loads((VERSION_DIR / fixture).read_text())
        assert supported_migration_targets(doc["esm"]) == []

    @pytest.mark.parametrize(
        "fixture",
        [
            "version_0_1_0_pre_break.esm",
            "version_0_0_1_pre_break.esm",
            "version_0_9_0_last_pre_break.esm",
            "version_2_5_1_major_rejection.esm",
            "version_12_34_56_large_numbers.esm",
        ],
    )
    def test_wrong_major_fixtures_have_no_migration_target(self, fixture):
        doc = json.loads((VERSION_DIR / fixture).read_text())
        assert supported_migration_targets(doc["esm"]) == []


def test_exported_from_the_package():
    for name in (
        "migrate",
        "can_migrate",
        "supported_migration_targets",
        "MigrationError",
    ):
        assert name in esm.__all__, f"{name} missing from __all__"
        assert hasattr(esm, name)
    assert esm.MigrationError is MigrationError
