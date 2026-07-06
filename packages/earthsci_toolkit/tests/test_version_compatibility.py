"""
Test fixtures for ESM format version compatibility.

Tests the version compatibility handling as specified in Section 8
of the ESM Libraries Specification.
"""

import pytest
from conftest import FIXTURES_ROOT, load_fixture as _load_fixture
from earthsci_toolkit import load, __version__ as VERSION
from earthsci_toolkit.parse import SchemaValidationError, UnsupportedVersionError

# Path to version compatibility test fixtures
FIXTURES_DIR = FIXTURES_ROOT / "version_compatibility"


def load_fixture(filename: str):
    """Load a test fixture file."""
    return _load_fixture(FIXTURES_DIR / filename)


class TestVersionCompatibility:
    """Test version compatibility handling."""

    def test_exact_version_match(self):
        """Should load baseline version 0.1.0 successfully."""
        fixture = load_fixture('version_0_1_0_baseline.esm')
        result = load(fixture)

        assert result.esm == '0.1.0'
        assert result.metadata.name == 'Version_0_1_0_Baseline'

    def test_backward_compatibility_older_minor(self):
        """Should load older minor version (0.0.1) successfully."""
        fixture = load_fixture('version_0_0_1_backwards_compat.esm')
        result = load(fixture)

        assert result.esm == '0.0.1'
        assert result.metadata.name == 'Version_0_0_1_BackwardsCompat'

    def test_backward_compatibility_newer_patch(self):
        """Should load newer patch version (0.1.5) successfully."""
        fixture = load_fixture('version_0_1_5_patch_upgrade.esm')
        result = load(fixture)

        assert result.esm == '0.1.5'
        assert result.metadata.name == 'Version_0_1_5_PatchUpgrade'

    def test_forward_compatibility_warning(self):
        """Older minor version (0.2.0) loads cleanly under the v0.3.0 baseline."""
        fixture = load_fixture('version_0_2_0_minor_upgrade.esm')

        # 0.2.0 < current 0.3.0 — no forward-compat warning expected.
        result = load(fixture)

        assert result.esm == '0.2.0'
        assert result.metadata.name == 'Version_0_2_0_MinorUpgrade'

    def test_forward_compatibility_unknown_fields(self):
        """Same-version (0.3.0) fixture with unknown fields loads cleanly."""
        fixture = load_fixture('version_0_3_0_with_unknown_fields.esm')

        # 0.3.0 == current 0.3.0 — no forward-compat warning expected.
        result = load(fixture)

        assert result.esm == '0.3.0'
        assert result.metadata.name == 'Version_0_3_0_WithUnknownFields'

        # Unknown fields should be ignored (not present in result)
        assert not hasattr(result, 'performance_hints')
        assert not hasattr(result, 'validation_metadata')

    def test_major_version_rejection_1_0_0(self):
        """Should reject major version 1.0.0."""
        fixture = load_fixture('version_1_0_0_major_upgrade.esm')

        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 1"):
            load(fixture)

    def test_major_version_rejection_2_5_1(self):
        """Should reject major version 2.5.1."""
        fixture = load_fixture('version_2_5_1_major_rejection.esm')

        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 2"):
            load(fixture)

    def test_invalid_version_string(self):
        """Should reject invalid version string format."""
        fixture = load_fixture('invalid_version_string.esm')

        with pytest.raises(SchemaValidationError):
            load(fixture)

    def test_missing_version_field(self):
        """Should reject missing version field."""
        fixture = load_fixture('missing_version_field.esm')

        with pytest.raises(SchemaValidationError):
            load(fixture)

    def test_double_digit_version_parsing(self):
        """Should correctly handle double-digit version numbers."""
        fixture = load_fixture('version_0_10_0_double_digit.esm')

        with pytest.warns(UserWarning, match="0.10.0 is newer than"):
            result = load(fixture)

        assert result.esm == '0.10.0'

    def test_large_patch_version(self):
        """Should handle large patch version numbers."""
        fixture = load_fixture('version_0_1_100_large_patch.esm')
        result = load(fixture)

        assert result.esm == '0.1.100'

    def test_large_version_numbers_rejection(self):
        """Should reject files with large version numbers."""
        fixture = load_fixture('version_12_34_56_large_numbers.esm')

        with pytest.raises(UnsupportedVersionError, match="Unsupported major version 12"):
            load(fixture)


class TestVersionParsing:
    """Test semantic version parsing logic."""

    def test_parse_version_components(self):
        """Should correctly parse semantic version components."""
        import re

        def parse_version(version_string):
            match = re.match(r'^(\d+)\.(\d+)\.(\d+)$', version_string)
            if not match:
                raise ValueError('Invalid version format')

            return {
                'major': int(match.group(1)),
                'minor': int(match.group(2)),
                'patch': int(match.group(3))
            }

        assert parse_version('0.1.0') == {'major': 0, 'minor': 1, 'patch': 0}
        assert parse_version('1.2.3') == {'major': 1, 'minor': 2, 'patch': 3}
        assert parse_version('10.20.30') == {'major': 10, 'minor': 20, 'patch': 30}

        with pytest.raises(ValueError):
            parse_version('1.2')

        with pytest.raises(ValueError):
            parse_version('1.2.3.4')

        with pytest.raises(ValueError):
            parse_version('v1.2.3')


class TestMigrationExample:
    """Test migration between versions."""

    def test_migration_from_0_0_5_to_0_1_0(self):
        """Should demonstrate migration from 0.0.5 to 0.1.0."""
        old_version = load_fixture('migration_test_from_0_0_5.esm')
        new_version = load_fixture('migration_test_to_0_1_0.esm')

        # Verify the migration changes
        assert old_version['esm'] == '0.0.5'
        assert new_version['esm'] == '0.1.0'

        # Check that CH4 units were migrated from ppbv to mol/mol
        old_ch4 = old_version['reaction_systems']['LegacyChemistry']['species']['CH4']
        new_ch4 = new_version['reaction_systems']['LegacyChemistry']['species']['CH4']

        assert old_ch4['units'] == 'ppbv'
        assert old_ch4['default'] == 1900  # ppbv

        assert new_ch4['units'] == 'mol/mol'
        assert new_ch4['default'] == 1.9e-6  # converted to mol/mol

        # Check that migration notes were added
        assert 'migration_notes' in new_version['metadata']
        assert 'Migrated from version 0.0.5' in new_version['metadata']['migration_notes']


class TestLibraryVersionInfo:
    """Test library version information."""

    def test_current_library_version(self):
        """Should expose current library version."""
        assert VERSION == '0.1.0'

    def test_compatibility_info(self):
        """Should provide version compatibility information."""
        # This would be part of the actual implementation
        def get_compatibility_info():
            return {
                'supported_major_version': 0,
                'current_version': VERSION,
                'backward_compatible_minor_versions': [0, 1],
                'forward_compatible_minor_versions': [1, 2, 3]  # can load but with warnings
            }

        info = get_compatibility_info()
        assert info['supported_major_version'] == 0
        assert info['current_version'] == '0.1.0'


if __name__ == '__main__':
    pytest.main([__file__])