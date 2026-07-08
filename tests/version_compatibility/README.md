# ESM Format Version Compatibility Test Fixtures

This directory contains comprehensive test fixtures for validating ESM format version compatibility handling across all library implementations.

## Overview

Based on Section 8 of the ESM Libraries Specification, libraries must handle version compatibility as follows:

- **Reject** files with a major version they don't support
- **Accept** files with a minor version ≤ their supported minor version (backward compatible)
- **Warn** on files with a higher minor version but attempt to load (forward compatible)
- **Skip JSON Schema validation** for forward-compatible files with newer minor versions

## Test Files

### Valid Version Tests

| File | Version | Expected Behavior | Description |
|------|---------|-------------------|-------------|
| `version_0_1_0_baseline.esm` | 0.1.0 | Load successfully | Baseline test for exact version match |
| `version_0_0_1_backwards_compat.esm` | 0.0.1 | Load successfully | Older minor version (backward compatible) |
| `version_0_1_5_patch_upgrade.esm` | 0.1.5 | Load successfully | Newer patch version (fully compatible) |
| `version_0_2_0_minor_upgrade.esm` | 0.2.0 | Load with warning | Newer minor version (forward compatible) |
| `version_0_3_0_with_unknown_fields.esm` | 0.3.0 | Load with warning | Future version with unknown fields |

### Invalid Version Tests

| File | Version | Expected Behavior | Description |
|------|---------|-------------------|-------------|
| `version_1_0_0_major_upgrade.esm` | 1.0.0 | Reject with error | Major version 1.x.x not supported by 0.x.x libraries |
| `version_2_5_1_major_rejection.esm` | 2.5.1 | Reject with error | Major version 2.x.x not supported |
| `invalid_version_string.esm` | "not.a.version" | Schema validation error | Invalid semver format |
| `missing_version_field.esm` | (missing) | Schema validation error | Missing required `esm` field |

### Migration Tests

| Source | Target | Description |
|---------|--------|-------------|
| `migration_test_from_0_0_5.esm` | `migration_test_to_0_1_0.esm` | Example migration from older to current format |

## Test Matrix

The `compatibility_matrix.json` file contains the complete test specification including:

- Expected behaviors for each test file
- Warning messages that should be generated
- Error codes and messages for rejection cases
- Migration examples showing format evolution
- Validation rules that libraries must implement

## Library Implementation Requirements

Each ESM format library must:

1. **Parse version strings** using semantic versioning rules (major.minor.patch)
2. **Check major version compatibility** and reject incompatible files
3. **Handle minor version differences** according to backward/forward compatibility rules
4. **Generate appropriate warnings** for forward-compatible files
5. **Skip schema validation** for newer minor versions to allow unknown fields
6. **Implement version migration functions** to update files between versions

## Usage in Tests

### TypeScript/JavaScript
```typescript
import { load } from '@earthsciml/ast';

// Should load successfully
const file1 = load('version_0_1_0_baseline.esm');

// Should reject with error
try {
  const file2 = load('version_1_0_0_major_upgrade.esm');
} catch (error) {
  expect(error.message).toContain('Unsupported major version');
}

// Should warn but load
const file3 = load('version_0_2_0_minor_upgrade.esm');
expect(warnings).toContain('File version 0.2.0 is newer');
```

### Julia
```julia
using EarthSciAST

# Should load successfully
file1 = EarthSciAST.load("version_0_1_0_baseline.esm")

# Should reject with error
@test_throws VersionError EarthSciAST.load("version_1_0_0_major_upgrade.esm")

# Should warn but load
file3 = EarthSciAST.load("version_0_2_0_minor_upgrade.esm")
@test length(warnings()) > 0
```

### Python
```python
import earthsci_ast as esm

# Should load successfully
file1 = esm.load('version_0_1_0_baseline.esm')

# Should reject with error
with pytest.raises(esm.UnsupportedVersionError):
    file2 = esm.load('version_1_0_0_major_upgrade.esm')

# Should warn but load
with pytest.warns(esm.ForwardCompatibilityWarning):
    file3 = esm.load('version_0_2_0_minor_upgrade.esm')
```

## Conformance Testing

All library implementations must pass the same version compatibility tests to ensure consistent behavior across languages. The test matrix serves as the canonical specification for expected behaviors.

## Future Considerations

As the ESM format evolves:

- **Major version bumps** indicate breaking changes that require library updates
- **Minor version bumps** add new features but maintain backward compatibility
- **Patch version bumps** are fully compatible (bug fixes, documentation)
- **Migration functions** help users upgrade files between incompatible versions
- **Deprecation warnings** should be used before breaking changes in major versions

## Error Codes

Libraries should use consistent error codes for version-related issues:

- `UNSUPPORTED_MAJOR_VERSION` - File major version not supported
- `INVALID_VERSION_FORMAT` - Version string doesn't match semver pattern
- `MISSING_VERSION_FIELD` - Required 'esm' field is missing
- `SCHEMA_VALIDATION_ERROR` - File doesn't conform to JSON Schema