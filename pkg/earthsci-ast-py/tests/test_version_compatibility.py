"""Version compatibility for the ESM format, per Section 8 of the ESM Libraries
Specification and ``tests/version_compatibility/compatibility_matrix.json``.

The library implements MAJOR VERSION 1, so a different major is rejected in
either direction and a newer minor loads with a warning. esm 1.0.0 is a CLEAN
BREAK with no deprecation path, which puts every 0.x document on the rejected
side of that line — the polarity of this suite is inverted from its 0.x form,
where major 1 was the thing being refused.

Every case reads the fixture that DECLARES the version under test. The shared
fixtures are named for the version they carry, and keeping the two in step is
what makes them test the gate rather than the loader's own version constant.
"""

import warnings
from contextlib import contextmanager

import re

import pytest
from conftest import FIXTURES_ROOT, load_fixture as _load_fixture
from earthsci_ast import load, __version__ as VERSION
from earthsci_ast.parse import _CURRENT_VERSION

# The package version (__version__, from distribution metadata) is kept in
# lockstep with the supported ESM format version (parse._CURRENT_VERSION).
# Derive the expectation from the latter so this test never re-hardcodes a
# literal that goes stale on the next version bump.
_EXPECTED_VERSION = ".".join(str(v) for v in _CURRENT_VERSION)
from earthsci_ast.parse import SchemaValidationError, UnsupportedVersionError

# Path to version compatibility test fixtures
FIXTURES_DIR = FIXTURES_ROOT / "version_compatibility"


def load_fixture(filename: str):
    """Load a test fixture file."""
    return _load_fixture(FIXTURES_DIR / filename)


@contextmanager
def no_version_warning():
    """Assert the body emits no forward-compatibility UserWarning."""
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        yield
    stale = [w for w in caught if "is newer than" in str(w.message)]
    assert not stale, f"unexpected forward-compat warning: {[str(w.message) for w in stale]}"


class TestVersionCompatibility:
    """Test version compatibility handling."""

    def test_exact_version_match(self):
        """The library's own version loads with no warning."""
        fixture = load_fixture("version_1_0_0_baseline.esm")
        assert fixture["esm"] == _EXPECTED_VERSION == "1.0.0"

        with no_version_warning():
            result = load(fixture)

        assert result.esm == _EXPECTED_VERSION

    def test_major_version_zero_rejection(self):
        """A 0.x document is REJECTED: 1.0.0 is a clean break, so there is no
        backward-compatible read of the previous major version."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 0"):
            load(load_fixture("version_0_1_0_pre_break.esm"))

    def test_major_version_zero_rejection_oldest(self):
        """The oldest published version is refused like any other 0.x — age
        earns no leniency."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 0"):
            load(load_fixture("version_0_0_1_pre_break.esm"))

    def test_major_version_zero_rejection_last_0x_release(self):
        """Even the immediately preceding release (0.9.0) is rejected — the
        clean break has no deprecation window."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 0"):
            load(load_fixture("version_0_9_0_last_pre_break.esm"))

    def test_backward_compatibility_newer_patch(self):
        """A newer patch of the current minor loads with no warning."""
        with no_version_warning():
            result = load(load_fixture("version_1_0_5_patch_upgrade.esm"))

        assert result.esm == "1.0.5"
        assert result.metadata.name == "Version_1_0_5_PatchUpgrade"

    def test_forward_compatibility_warning(self):
        """A newer MINOR loads, but warns that it postdates the library."""
        with pytest.warns(UserWarning, match="1.1.0 is newer than"):
            result = load(load_fixture("version_1_1_0_minor_upgrade.esm"))

        assert result.esm == "1.1.0"
        assert result.metadata.name == "Version_1_1_0_MinorUpgrade"

    def test_forward_compatibility_unknown_fields_is_rejected(self):
        """A newer minor carrying an unmodelled TOP-LEVEL block is REJECTED.

        esm-libraries-spec §8 asks for the opposite — skip schema validation for
        a forward-compatible file so unknown fields are ignored — but no binding
        implements that, and `additionalProperties: false` fires before the
        forward-compatibility warning is reached. This pins what the five
        bindings actually do; see the OPEN note in the fixture directory's
        README.

        The rule went unnoticed because the fixture used to carry `coupling`, a
        block the schema DOES model, so the skip path was never entered.
        """
        fixture = load_fixture("version_1_2_0_with_unknown_fields.esm")
        assert {"performance_hints", "validation_metadata"} <= set(fixture)

        with pytest.raises(SchemaValidationError, match="performance_hints"):
            load(fixture)

    def test_forward_compatibility_unknown_key_in_a_modelled_block_is_rejected(self):
        """The same refusal one level down. The schema closes EVERY object, so
        there is no level at which an unknown field is merely ignored — a newer
        minor can add nothing at all without the file becoming unreadable."""
        fixture = load_fixture("version_1_1_0_minor_upgrade.esm")
        fixture["metadata"]["speculative_1_1_field"] = "ignored"

        with pytest.raises(SchemaValidationError, match="speculative_1_1_field"):
            load(fixture)

    def test_major_version_rejection_2_5_1(self):
        """A FUTURE major is rejected in the other direction."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 2"):
            load(load_fixture("version_2_5_1_major_rejection.esm"))

    def test_invalid_version_string(self):
        """Should reject invalid version string format."""
        with pytest.raises(SchemaValidationError):
            load(load_fixture("invalid_version_string.esm"))

    def test_missing_version_field(self):
        """Should reject a document with no version field."""
        with pytest.raises(SchemaValidationError):
            load(load_fixture("missing_version_field.esm"))

    def test_prerelease_identifier_is_rejected(self):
        """The semver pattern admits major.minor.patch only. The fixture carries
        a SUPPORTED major so this is the one rule that can fire."""
        fixture = load_fixture("version_with_prerelease.esm")
        assert fixture["esm"].startswith(f"{_CURRENT_VERSION[0]}.")

        with pytest.raises(SchemaValidationError):
            load(fixture)

    def test_double_digit_version_parsing(self):
        """1.10.0 is a NEWER minor than 1.2.0 — numerically, not
        lexicographically."""
        with pytest.warns(UserWarning, match="1.10.0 is newer than"):
            result = load(load_fixture("version_1_10_0_double_digit.esm"))

        assert result.esm == "1.10.0"

    def test_large_patch_version(self):
        """A three-digit patch is a patch, not a minor bump: no warning."""
        with no_version_warning():
            result = load(load_fixture("version_1_0_100_large_patch.esm"))

        assert result.esm == "1.0.100"

    def test_large_version_numbers_rejection(self):
        """Should reject files with large version numbers."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 12"):
            load(load_fixture("version_12_34_56_large_numbers.esm"))


class TestVersionParsing:
    """Test semantic version parsing logic."""

    def test_parse_version_components(self):
        """Should correctly parse semantic version components."""
        import re

        def parse_version(version_string):
            match = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version_string)
            if not match:
                raise ValueError("Invalid version format")

            return {
                "major": int(match.group(1)),
                "minor": int(match.group(2)),
                "patch": int(match.group(3)),
            }

        assert parse_version("0.1.0") == {"major": 0, "minor": 1, "patch": 0}
        assert parse_version("1.2.3") == {"major": 1, "minor": 2, "patch": 3}
        assert parse_version("10.20.30") == {"major": 10, "minor": 20, "patch": 30}

        with pytest.raises(ValueError):
            parse_version("1.2")

        with pytest.raises(ValueError):
            parse_version("1.2.3.4")

        with pytest.raises(ValueError):
            parse_version("v1.2.3")


class TestMigrationExample:
    """Migration across the 1.0.0 break.

    The SOURCE is unloadable by this library (wrong major) and the TARGET loads.
    That asymmetry is the demonstration: under a clean break, migration is a
    rewrite a human performs, not something the loader does. So the source is
    read as raw JSON and only the target goes through ``load``.
    """

    def test_migration_unit_change(self):
        """Should demonstrate the ppbv -> mol/mol content migration."""
        old_version = load_fixture("migration_test_from_0_0_5.esm")
        new_version = load_fixture("migration_test_to_1_0_0.esm")

        assert old_version["esm"] == "0.0.5"
        assert new_version["esm"] == _EXPECTED_VERSION

        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 0"):
            load(old_version)
        # …and the migrated form is a document this library actually reads. The
        # 0.x target this pair used to carry was itself unloadable, which made
        # it a poor demonstration of a migration TARGET.
        migrated = load(new_version)
        assert migrated.esm == _EXPECTED_VERSION

        # Check that CH4 units were migrated from ppbv to mol/mol
        old_ch4 = old_version["reaction_systems"]["LegacyChemistry"]["species"]["CH4"]
        new_ch4 = new_version["reaction_systems"]["LegacyChemistry"]["species"]["CH4"]

        assert old_ch4["units"] == "ppbv"
        assert old_ch4["default"] == 1900  # ppbv

        assert new_ch4["units"] == "mol/mol"
        assert new_ch4["default"] == 1.9e-6  # converted to mol/mol

        # The reaction's missing product species was added by the migration.
        assert "H2O" not in old_version["reaction_systems"]["LegacyChemistry"]["species"]
        assert "H2O" in new_version["reaction_systems"]["LegacyChemistry"]["species"]

        # `metadata` is a CLOSED object, so the migration note rides in
        # `description` rather than a bespoke key that would invalidate the file.
        assert "Migrated from version 0.0.5" in new_version["metadata"]["description"]


class TestLibraryVersionInfo:
    """Test library version information."""

    def test_current_library_version(self):
        """Should expose a well-formed package version.

        The PACKAGE version (``__version__``) and the esm FORMAT version
        (``parse._CURRENT_VERSION``) are independent: the format version is what
        a document carries in its ``esm`` field, while the package version
        tracks releases of this binding. They happened to coincide while both
        read 1.0.0, and asserting lockstep turned that coincidence into a rule --
        which broke as soon as the bindings were released as 0.1.0 against the
        1.0.0 format.

        ``__version__`` falls back to ``0.0.0+unknown`` when the package is
        imported straight from the source tree (no installed distribution
        metadata).
        """
        if VERSION.startswith("0.0.0+"):
            pytest.skip("source-tree import: no distribution metadata to check")
        assert re.match(r"^\d+\.\d+\.\d+", VERSION), VERSION

    def test_compatibility_info(self):
        """Should provide version compatibility information."""

        # This would be part of the actual implementation
        def get_compatibility_info():
            return {
                "supported_major_version": _CURRENT_VERSION[0],
                "current_version": _EXPECTED_VERSION,
                # 1.0.0 is the floor of the supported major version — major 0
                # is rejected outright, so there is no older minor to read.
                "backward_compatible_minor_versions": [0],
                "forward_compatible_minor_versions": [1, 2, 3],  # load, but warn
            }

        info = get_compatibility_info()
        assert info["supported_major_version"] == 1
        assert info["current_version"] == _EXPECTED_VERSION


if __name__ == "__main__":
    pytest.main([__file__])
