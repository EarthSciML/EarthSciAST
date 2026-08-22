package esm

// migration.go implements the ESM format version-migration surface of
// esm-libraries-spec §8.3: Migrate, CanMigrate, SupportedMigrationTargets and
// the typed MigrationError.
//
// A migration here is a pure version-MARKER bump: it changes the `esm` field
// and touches nothing else. That is only ever sound along an ADDITIVE line — a
// run of schema releases each of which introduced its changes as additive,
// backward-compatible fields, so an older file already loads under the newer
// schema without any mechanical transform. The current additive line is
// `1.0.0 … <current schema version>`.
//
// THERE IS NO MIGRATION ACROSS THE 1.0.0 BOUNDARY. esm 1.0.0 is a clean break
// with no deprecation path: the five declared variable types collapse to two,
// an observed variable's `expression` becomes an equation, `data_loaders`
// becomes a non-component `data_sources` registry, and parameter mutation moves
// off events onto the parameter. None of that is a marker bump — every one of
// them RESHAPES the document, and several need information (which unknowns are
// ODE states) that only the equations carry. A 0.x source therefore yields no
// supported targets rather than a bump that would produce a file claiming
// 1.0.0 while still carrying 0.x shapes. Converting a 0.x document is a
// rewrite, and deliberately not offered as an automated one — the canonical
// statement of this is `tests/version_compatibility/compatibility_matrix.json`
// ("under a clean break migration is a rewrite a human performs, not something
// the loader does") and its migration_test_from_0_0_5 → migration_test_to_1_0_0
// fixture pair, whose SOURCE is deliberately unloadable by this library.
//
// The single supported target for an additive-line source is the CURRENT schema
// version (SchemaVersion); arbitrary intermediate targets are deliberately NOT
// offered — there is no per-minor transform to encode, only "bring this file up
// to current". Sources outside that line (newer than current, a different
// major, or malformed) yield no supported targets.
//
// Reference binding: TypeScript `pkg/earthsci-ast-ts/src/migration.ts`, whose
// semantics this reproduces exactly. It deliberately does NOT reproduce Rust's
// `src/migration.rs`, which still encodes a single pre-break rule (0.0.5 →
// 0.1.x ppbv→mol/mol species-unit conversion): both of those versions are on
// the far side of the 1.0.0 clean break, so a 1.x library cannot load either
// endpoint, and the shared fixture corpus records the TypeScript rule as the
// contract.

import (
	"fmt"
	"regexp"
	"strconv"
)

// schemaIDVersionRe extracts the version segment of the embedded schema's
// `$id` (https://earthsciml.org/schemas/esm/<version>/esm.schema.json).
var schemaIDVersionRe = regexp.MustCompile(`/esm/(\d+\.\d+\.\d+)/`)

// SchemaVersion is the schema version this library implements, derived from the
// embedded schema's `$id` so it cannot hand-drift from the canonical
// esm-schema.json. Mirrors TypeScript's `SCHEMA_VERSION`.
var SchemaVersion = func() string {
	m := schemaIDVersionRe.FindSubmatch(embeddedSchema)
	if m == nil {
		panic("embedded ESM schema $id does not carry a version")
	}
	return string(m[1])
}()

// MigrationError is returned when a migration cannot be performed. It carries
// the endpoint versions alongside the message so a caller can report the pair
// without re-deriving it (mirrors the Rust binding's `MigrationError` fields).
type MigrationError struct {
	Message     string
	FromVersion string
	ToVersion   string
}

func (e *MigrationError) Error() string {
	if e.FromVersion == "" && e.ToVersion == "" {
		return "migration error: " + e.Message
	}
	return fmt.Sprintf("migration error: %s (%s → %s)", e.Message, e.FromVersion, e.ToVersion)
}

// semVer holds the parsed components of a `major.minor.patch` version string.
type semVer struct {
	Major int
	Minor int
	Patch int
}

// parseSemVer parses a strict `major.minor.patch` string. Prerelease and build
// metadata are NOT admitted — the schema's `esm` pattern accepts only the three
// numeric components (see tests/version_compatibility/version_with_prerelease.esm).
func parseSemVer(version string) (semVer, bool) {
	m := semverRe.FindStringSubmatch(version)
	if m == nil {
		return semVer{}, false
	}
	major, err1 := strconv.Atoi(m[1])
	minor, err2 := strconv.Atoi(m[2])
	patch, err3 := strconv.Atoi(m[3])
	if err1 != nil || err2 != nil || err3 != nil {
		return semVer{}, false
	}
	return semVer{Major: major, Minor: minor, Patch: patch}, true
}

// compareSemVer reports -1, 0 or +1 as a is older than, equal to, or newer than
// b. Components are compared NUMERICALLY, never lexicographically: 1.10.0 is
// newer than 1.2.0, and 1.0.100 is a patch of 1.0, not a minor bump.
func compareSemVer(a, b semVer) int {
	switch {
	case a.Major != b.Major:
		return sign(a.Major - b.Major)
	case a.Minor != b.Minor:
		return sign(a.Minor - b.Minor)
	default:
		return sign(a.Patch - b.Patch)
	}
}

func sign(n int) int {
	switch {
	case n < 0:
		return -1
	case n > 0:
		return 1
	default:
		return 0
	}
}

// additiveFloor is the oldest version a marker bump can carry forward.
//
// It is 1.0.0, not 0.1.0: the 0.x line ended at a clean break, so no 0.x
// version can be carried forward. `onAdditiveLine` already requires the majors
// to agree, which makes a 0.x source ineligible on its own; the floor is stated
// at 1.0.0 as well so the intent survives the next major.
var additiveFloor = semVer{Major: 1, Minor: 0, Patch: 0}

// currentSchemaSemVer is SchemaVersion parsed once.
var currentSchemaSemVer = func() semVer {
	v, ok := parseSemVer(SchemaVersion)
	if !ok {
		panic("embedded ESM schema version is not a strict semantic version: " + SchemaVersion)
	}
	return v
}()

// onAdditiveLine reports whether `v` sits on the additive line
// `1.0.0 … <current schema version>` and can therefore be carried to the
// current schema version by a marker-only, no-op migration.
func onAdditiveLine(v semVer) bool {
	return v.Major == currentSchemaSemVer.Major &&
		compareSemVer(v, additiveFloor) >= 0 &&
		compareSemVer(v, currentSchemaSemVer) <= 0
}

// SupportedMigrationTargets returns the schema versions `sourceVersion` can be
// migrated to.
//
//   - any version on the additive line `1.0.0 … <current schema version>` →
//     [SchemaVersion] (a no-op marker bump to the current schema).
//   - everything else — including EVERY 0.x version, which 1.0.0's clean break
//     puts out of reach of a marker bump — → an empty slice.
//
// The canonical name drops TypeScript's `get` prefix.
func SupportedMigrationTargets(sourceVersion string) []string {
	if v, ok := parseSemVer(sourceVersion); ok && onAdditiveLine(v) {
		return []string{SchemaVersion}
	}
	return []string{}
}

// CanMigrate reports whether a migration from `sourceVersion` to
// `targetVersion` is supported.
func CanMigrate(sourceVersion, targetVersion string) bool {
	for _, t := range SupportedMigrationTargets(sourceVersion) {
		if t == targetVersion {
			return true
		}
	}
	return false
}

// Migrate migrates an ESM file from its declared schema version to
// `targetVersion`.
//
// Every supported step is a pure version-marker bump with no structural
// transform: an additive-line source (`1.0.0 … <current>`) advanced to the
// current schema version (see the file header). Any other version pair — a 0.x
// source included — returns a *MigrationError. Content-level changes are not
// performed; they are modeling decisions, not mechanical migrations.
//
// The input file is never mutated: a shallow copy carrying the updated `esm`
// marker is returned. A shallow copy is exactly what the marker bump needs and
// exactly what the other bindings do (`{...file, esm}` in TypeScript) — since
// nothing else is written, the copy and the original may share their component
// maps and slices.
func Migrate(file *ESMFile, targetVersion string) (*ESMFile, error) {
	if file == nil {
		return nil, &MigrationError{Message: "cannot migrate a nil file", ToVersion: targetVersion}
	}
	sourceVersion := file.ESM
	if sourceVersion == "" {
		return nil, &MigrationError{
			Message:   "source file has no 'esm' version field",
			ToVersion: targetVersion,
		}
	}
	if !CanMigrate(sourceVersion, targetVersion) {
		return nil, &MigrationError{
			Message:     fmt.Sprintf("migration from %s to %s is not supported", sourceVersion, targetVersion),
			FromVersion: sourceVersion,
			ToVersion:   targetVersion,
		}
	}

	migrated := *file
	migrated.ESM = targetVersion
	return &migrated, nil
}
