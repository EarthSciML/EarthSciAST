# ESM Format Version Compatibility Test Fixtures

Shared fixtures for the version-compatibility gate, exercised by every language
binding. `compatibility_matrix.json` is the canonical specification: each fixture
appears there with its declared version, its expected behavior, and the warning
or error text that behavior should produce.

## The contract

The library implements **major version 1**. Section 8 of the ESM Libraries
Specification asks for:

- **Reject** a file whose major version differs from the library's, in *either*
  direction.
- **Accept** a file with a minor version ≤ the library's, within that major
  (backward compatible).
- **Warn** on a higher minor version but attempt to load it (forward compatible).
- **Skip JSON Schema validation** for those forward-compatible files, so a block
  the library cannot model does not make the file unreadable. *(Not implemented
  — see the OPEN note at the end.)*
- **Compare version components numerically.** `1.10.0` is newer than `1.2.0`;
  `1.0.100` is a patch of `1.0`, not a minor bump.

esm 1.0.0 is a **clean break with no deprecation path**, which is why every 0.x
fixture below sits on the *rejected* side of that line. That is the inversion
from this category's 0.x form, where major 1 was the thing being refused.

**Every fixture declares the version it is named for.** These files exist to
exercise the version *gate*, so a fixture restamped to the library's own version
tests nothing — `version_2_5_1_major_rejection.esm` declaring `1.0.0` would load
clean and its assertion would pass for the wrong reason.

## Test Files

### The supported major

| File | Version | Expected Behavior | Description |
|------|---------|-------------------|-------------|
| `version_1_0_0_baseline.esm` | 1.0.0 | Load successfully | Exact version match |
| `version_1_0_5_patch_upgrade.esm` | 1.0.5 | Load successfully | Newer patch — fully compatible |
| `version_1_0_100_large_patch.esm` | 1.0.100 | Load successfully | Three-digit patch, not a minor bump |
| `version_1_1_0_minor_upgrade.esm` | 1.1.0 | Load with warning | Newer minor — forward compatible |
| `version_1_10_0_double_digit.esm` | 1.10.0 | Load with warning | Double-digit minor; newer than 1.2.0 |
| `version_1_2_0_with_unknown_fields.esm` | 1.2.0 | **Schema error** | Newer minor carrying two unmodelled top-level blocks — see the OPEN note |

### Rejected — the wrong major

| File | Version | Expected Behavior | Description |
|------|---------|-------------------|-------------|
| `version_0_1_0_pre_break.esm` | 0.1.0 | Reject with error | A pre-1.0 document; no migration path |
| `version_0_0_1_pre_break.esm` | 0.0.1 | Reject with error | The oldest published version — age earns no leniency |
| `version_0_9_0_last_pre_break.esm` | 0.9.0 | Reject with error | The release immediately before the break; no deprecation window |
| `version_2_5_1_major_rejection.esm` | 2.5.1 | Reject with error | A *future* major, refused in the other direction |
| `version_12_34_56_large_numbers.esm` | 12.34.56 | Reject with error | Large major version |

### Rejected — the version string itself

| File | Version | Expected Behavior | Description |
|------|---------|-------------------|-------------|
| `invalid_version_string.esm` | `"not.a.version"` | Schema validation error | Not semver |
| `missing_version_field.esm` | (missing) | Schema validation error | Missing required `esm` field |
| `malformed_version_number.esm` | `1.0` (a number) | Schema validation error | `esm` must be a string |
| `version_with_prerelease.esm` | `"1.0.0-alpha.1"` | Schema validation error | The pattern admits `major.minor.patch` only |

`version_with_prerelease.esm` carries a **supported** major deliberately: at
`0.1.0-alpha.1` it would fail for two independent reasons, and a test asserting
the refusal could not tell which rule fired.

### Migration

| Source | Target | Description |
|---------|--------|-------------|
| `migration_test_from_0_0_5.esm` | `migration_test_to_1_0_0.esm` | One reaction system carried across the 1.0.0 break |

The source is **unloadable** by a 1.x library and the target **loads**. That
asymmetry is the point: under a clean break, migration is a rewrite a human
performs, not something the loader does. The migration note lives in
`metadata.description` rather than a bespoke `metadata.migration_notes` key,
because `metadata` is a closed object — the old 0.1.0 target carried that key and
was therefore invalid itself, which made it a poor demonstration of a *target*.

## Library Implementation Requirements

Each ESM format library must:

1. **Parse version strings** using semantic versioning rules (major.minor.patch),
   comparing components numerically.
2. **Check major version compatibility** and reject files on either side of it.
3. **Handle minor version differences** according to the backward/forward rules
   above.
4. **Generate appropriate warnings** for forward-compatible files.
5. **Skip schema validation** for newer minor versions to allow unknown fields —
   asked for by the spec, implemented by none of the five; see the OPEN note.

## Usage in Tests

### TypeScript/JavaScript
```typescript
import { load } from '@earthsciml/ast';

// Loads
const file1 = load(readFixture('version_compatibility', 'version_1_0_0_baseline.esm'));

// Rejected — wrong major
expect(() => load(readFixture('version_compatibility', 'version_0_1_0_pre_break.esm')))
  .toThrow(/Unsupported major version 0/);

// Warns but loads
const file3 = load(readFixture('version_compatibility', 'version_1_1_0_minor_upgrade.esm'))
expect(warnings).toContain('1.1.0 is newer')
```

### Julia
```julia
using EarthSciAST

file1 = EarthSciAST.load("version_1_0_0_baseline.esm")
@test_throws VersionError EarthSciAST.load("version_0_1_0_pre_break.esm")

file3 = EarthSciAST.load("version_1_1_0_minor_upgrade.esm")   # warns
```

### Python
```python
import earthsci_ast as esm

file1 = esm.load(load_fixture('version_1_0_0_baseline.esm'))

with pytest.raises(esm.UnsupportedVersionError):
    esm.load(load_fixture('version_0_1_0_pre_break.esm'))

with pytest.warns(UserWarning, match="1.1.0 is newer"):
    file3 = esm.load(load_fixture('version_1_1_0_minor_upgrade.esm'))
```

## Conformance Testing

All library implementations must pass the same version compatibility tests, so
the matrix is the canonical specification of expected behavior rather than any
one binding's assertions.

## Future Considerations

As the ESM format evolves:

- **Major version bumps** indicate breaking changes that require library updates.
  When one lands, this category is re-based the way 1.0.0 re-based it: the
  gradation moves to the new major and one or two files of the outgoing major
  stay behind as the wrong-major negatives.
- **Minor version bumps** add new features but maintain backward compatibility.
- **Patch version bumps** are fully compatible (bug fixes, documentation).
- **Migration** across a major is a rewrite, demonstrated by a source/target pair
  rather than performed by the loader.

## Error Codes

Libraries should use consistent error codes for version-related issues:

- `UNSUPPORTED_MAJOR_VERSION` - File major version is not supported
- `INVALID_VERSION_FORMAT` - Version string doesn't match the semver pattern
- `MISSING_VERSION_FIELD` - Required `esm` field is missing
- `SCHEMA_VALIDATION_ERROR` - File doesn't conform to the JSON Schema

## OPEN: no binding skips schema validation for a forward-compatible file

`esm-libraries-spec` §8 asks a library to skip JSON Schema validation when the
file's minor version exceeds its own, so that a block the library cannot model is
ignored rather than fatal. **No binding does this.** The schema carries
`additionalProperties: false` at the top level and is applied to every document,
so `version_1_2_0_with_unknown_fields.esm` is *rejected* — the forward-
compatibility warning is never reached.

The rule went unnoticed because the fixture meant to exercise it carried
`coupling`, a block the schema *does* model, so the skip path was never entered
and the case passed for the wrong reason. The fixture now carries two genuinely
unmodelled blocks, and the matrix records the behavior the five bindings actually
share rather than the one the spec asks for.

The companion claim — "unknown fields in forward-compatible files are ignored
silently" — fails for the same reason and at *every* level, not only the document
root: the schema sets `additionalProperties: false` on each object it defines, so
adding a key to `metadata` in a 1.1.0 file makes that file unreadable too.

Closing this is a decision about the loader contract, not a test fix: implementing
the skip weakens validation for every future minor version, in all five bindings
at once. Until it is made, forward compatibility here means *"a newer minor loads
with a warning, provided it uses no block this library does not know about."*
