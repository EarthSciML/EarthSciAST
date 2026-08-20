"""
Test fixtures for ESM format version compatibility.

Tests the version compatibility handling as specified in Section 8
of the ESM Libraries Specification.

esm 1.0.0 is a CLEAN BREAK: the supported major version is 1, and a major
version 0 document is REJECTED (``UnsupportedVersionError``) rather than
migrated — there is no deprecation path. The version-compatibility fixtures at
the repository root all carry ``"esm": "1.0.0"`` now, so the cases that need a
DIFFERENT version string synthesize it from the baseline fixture rather than
leaning on a fixture whose whole point was the version literal it no longer
carries.
"""

import copy
import warnings
from contextlib import contextmanager

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


def at_version(filename: str, version: str) -> dict:
    """The named fixture, re-stamped with ``version``.

    The CONTENT is format-1.0.0 either way; only the declared version string
    varies, and that string is exactly what the compatibility gate reads.
    """
    doc = copy.deepcopy(load_fixture(filename))
    doc["esm"] = version
    return doc


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
        """Should load the current version (1.0.0) successfully.

        The `version_0_*.esm` fixtures deliberately keep declaring the versions
        they are NAMED for -- they exist to exercise the version GATE, and
        restamping them would destroy the thing they test. The fixture that
        declares the CURRENT version is the 1.0.0 one.
        """
        fixture = load_fixture("version_1_0_0_major_upgrade.esm")
        assert fixture["esm"] == _EXPECTED_VERSION == "1.0.0"
        result = load(fixture)

        assert result.esm == _EXPECTED_VERSION

    def test_major_version_zero_rejection(self):
        """A 0.x document is REJECTED: 1.0.0 is a clean break, so there is no
        backward-compatible read of the previous major version."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 0"):
            load(at_version("version_0_1_0_baseline.esm", "0.1.0"))

    def test_major_version_zero_rejection_last_0x_release(self):
        """Even the immediately preceding release (0.9.0) is rejected — the
        clean break has no deprecation window."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 0"):
            load(at_version("version_0_0_1_backwards_compat.esm", "0.9.0"))

    def test_backward_compatibility_newer_patch(self):
        """Should load a newer patch of the current minor (1.0.5), no warning."""
        with no_version_warning():
            result = load(at_version("version_0_1_5_patch_upgrade.esm", "1.0.5"))

        assert result.esm == "1.0.5"
        assert result.metadata.name == "Version_0_1_5_PatchUpgrade"

    def test_forward_compatibility_warning(self):
        """A newer MINOR (1.1.0) loads, but warns that it postdates the library."""
        with pytest.warns(UserWarning, match="1.1.0 is newer than"):
            result = load(at_version("version_0_2_0_minor_upgrade.esm", "1.1.0"))

        assert result.esm == "1.1.0"
        assert result.metadata.name == "Version_0_2_0_MinorUpgrade"

    def test_forward_compatibility_unknown_fields(self):
        """A same-version document loads cleanly and drops unmodelled fields.

        The fixture is re-stamped in memory: on disk it declares 0.3.0, which
        1.0.0 rejects outright, but the version string is not what this test is
        about -- the CONTENT is what matters, and it is format-1.0.0 either way.
        """
        fixture = at_version("version_0_3_0_with_unknown_fields.esm", _EXPECTED_VERSION)

        # Same version as the library — no forward-compat warning expected.
        with no_version_warning():
            result = load(fixture)

        assert result.esm == _EXPECTED_VERSION
        assert result.metadata.name == "Version_0_3_0_WithUnknownFields"

        # Unknown fields should be ignored (not present in result)
        assert not hasattr(result, "performance_hints")
        assert not hasattr(result, "validation_metadata")

    def test_major_version_rejection_2_5_1(self):
        """Should reject major version 2.5.1."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 2"):
            load(at_version("version_2_5_1_major_rejection.esm", "2.5.1"))

    def test_invalid_version_string(self):
        """Should reject invalid version string format."""
        fixture = load_fixture("invalid_version_string.esm")

        with pytest.raises(SchemaValidationError):
            load(fixture)

    def test_missing_version_field(self):
        """Should reject a document with no version field."""
        fixture = load_fixture("version_0_1_0_baseline.esm")
        fixture.pop("esm")

        with pytest.raises(SchemaValidationError):
            load(fixture)

    def test_double_digit_version_parsing(self):
        """Should correctly handle double-digit version numbers."""
        with pytest.warns(UserWarning, match="1.10.0 is newer than"):
            result = load(at_version("version_0_10_0_double_digit.esm", "1.10.0"))

        assert result.esm == "1.10.0"

    def test_large_patch_version(self):
        """Should handle large patch version numbers."""
        result = load(at_version("version_0_1_100_large_patch.esm", "1.0.100"))

        assert result.esm == "1.0.100"

    def test_large_version_numbers_rejection(self):
        """Should reject files with large version numbers."""
        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 12"):
            load(at_version("version_12_34_56_large_numbers.esm", "12.34.56"))


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
    """Test migration between versions.

    Both fixtures keep their original 0.x version strings -- they are named for
    them, and under the clean break such a document is never READ, only
    rewritten. What the pair demonstrates is therefore the CONTENT migration (a
    species' units) that a reader has to perform by hand, not a version the
    loader accepts.
    """

    def test_migration_unit_change(self):
        """Should demonstrate the ppbv -> mol/mol content migration."""
        old_version = load_fixture("migration_test_from_0_0_5.esm")
        new_version = load_fixture("migration_test_to_0_1_0.esm")

        # Both predate the clean break, so NEITHER is loadable — the migration
        # is a rewrite a human performs, which is exactly why the pair is read
        # as raw JSON here rather than through `load`. The two rejections differ
        # in KIND (the 0.0.5 one trips the version gate; the 0.1.0 one carries a
        # `metadata.migration_notes` the schema does not model and never reaches
        # it), so the assertion is that neither loads, not how each fails.
        assert old_version["esm"] < new_version["esm"] < _EXPECTED_VERSION
        for doc in (old_version, new_version):
            with pytest.raises((UnsupportedVersionError, SchemaValidationError)):
                load(doc)

        # Check that CH4 units were migrated from ppbv to mol/mol
        old_ch4 = old_version["reaction_systems"]["LegacyChemistry"]["species"]["CH4"]
        new_ch4 = new_version["reaction_systems"]["LegacyChemistry"]["species"]["CH4"]

        assert old_ch4["units"] == "ppbv"
        assert old_ch4["default"] == 1900  # ppbv

        assert new_ch4["units"] == "mol/mol"
        assert new_ch4["default"] == 1.9e-6  # converted to mol/mol

        # Check that migration notes were added
        assert "migration_notes" in new_version["metadata"]
        assert "Migrated from version 0.0.5" in new_version["metadata"]["migration_notes"]


class TestLibraryVersionInfo:
    """Test library version information."""

    def test_current_library_version(self):
        """Should expose current library version.

        ``__version__`` falls back to ``0.0.0+unknown`` when the package is
        imported straight from the source tree (no installed distribution
        metadata); only an installed distribution can be checked for lockstep
        with ``parse._CURRENT_VERSION``.
        """
        if VERSION.startswith("0.0.0+"):
            pytest.skip("source-tree import: no distribution metadata to check")
        assert VERSION == _EXPECTED_VERSION

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
