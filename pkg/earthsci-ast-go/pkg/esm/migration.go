package esm

// migration.go implements the ESM format version-migration surface of
// esm-libraries-spec §8.3: Migrate, CanMigrate, SupportedMigrationTargets and
// the typed MigrationError.
//
// A migration here is a pure version-MARKER bump: it changes the `esm` field
// and touches nothing else. Two lines of versions can be carried to the current
// schema version that way:
//
//   - the ADDITIVE line `2.0.0 … <current schema version>`: a run of schema
//     releases each of which introduced its changes as additive,
//     backward-compatible fields, so an older file already loads under the
//     newer schema without any mechanical transform;
//   - the 1.x line `1.0.0 … 1.3.0` (last1x). esm 2.0.0 is a break that only
//     REMOVES constructs — the closed-function call `fn`, `function_tables` and
//     `table_lookup`, `skolem`, `rank`, the geometry leaves and the `argmin` /
//     `argmax` op forms (removed_ops.go) — so a 1.x document that uses none of
//     them means the same under 2.0.0 and is relabelled. One that uses any is
//     REFUSED with the `removed_op` diagnostic: rewriting it to the esm:std
//     templates is the job of the one codemod (`python -m earthsci_ast.migrate`),
//     not of a marker bump.
//
// THERE IS NO MIGRATION ACROSS THE 1.0.0 BOUNDARY. esm 1.0.0 is a clean break
// with no deprecation path: the five declared variable types collapse to two,
// an observed variable's `expression` becomes an equation, `data_loaders`
// becomes a non-component `data_sources` registry, and parameter mutation moves
// off events onto the parameter. None of that is a marker bump — every one of
// them RESHAPES the document, and several need information (which unknowns are
// ODE states) that only the equations carry. A 0.x source therefore yields no
// supported targets rather than a bump that would produce a file claiming
// a 1.x or 2.x version while still carrying 0.x shapes. The canonical statement
// of this is `tests/version_compatibility/compatibility_matrix.json` and its
// migration_test_from_0_0_5 → migration_test_to_1_0_0 fixture pair, whose
// SOURCE is deliberately unloadable by this library.
//
// The single supported target is the CURRENT schema version (SchemaVersion);
// arbitrary intermediate targets are deliberately NOT offered — there is no
// per-minor transform to encode, only "bring this file up to current". Sources
// outside both lines (newer than current, another major, a 1.x minor past
// last1x, or malformed) yield no supported targets.

import (
	"encoding/json"
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
	// Code is the diagnostic code of a refusal that has one: `removed_op` for a
	// 1.x document that uses a construct esm 2.0.0 removed. Empty otherwise.
	Code  string
	cause error
}

// Unwrap returns the diagnostic behind a coded refusal, so errors.As reaches
// it as a DiagnosticError.
func (e *MigrationError) Unwrap() error { return e.cause }

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

// additiveFloor is the oldest version of the additive line. The 1.x line ended
// at the 2.0.0 break, so it is 2.0.0; a 1.x source is carried forward only by
// the relabel of onRelabelLine.
var additiveFloor = semVer{Major: 2, Minor: 0, Patch: 0}

// first1x and last1x bound the 1.x line a 2.x library relabels: 1.3.0 is the
// last 1.x schema release, so a later 1.x minor names a format that never
// existed and is not offered.
var (
	first1x = semVer{Major: 1, Minor: 0, Patch: 0}
	last1x  = semVer{Major: 1, Minor: 3, Patch: 0}
)

// currentSchemaSemVer is SchemaVersion parsed once.
var currentSchemaSemVer = func() semVer {
	v, ok := parseSemVer(SchemaVersion)
	if !ok {
		panic("embedded ESM schema version is not a strict semantic version: " + SchemaVersion)
	}
	return v
}()

// onAdditiveLine reports whether `v` sits on the additive line
// `2.0.0 … current` and can therefore be carried to current by a marker-only,
// no-op migration.
func onAdditiveLine(v, current semVer) bool {
	return v.Major == current.Major &&
		compareSemVer(v, additiveFloor) >= 0 &&
		compareSemVer(v, current) <= 0
}

// onRelabelLine reports whether `v` is a 1.x version a 2.x library relabels to
// current when the document uses no removed construct.
func onRelabelLine(v, current semVer) bool {
	return current.Major == 2 &&
		compareSemVer(v, first1x) >= 0 &&
		compareSemVer(v, last1x) <= 0
}

// migrationTargets is SupportedMigrationTargets against an explicit current
// schema version.
func migrationTargets(sourceVersion string, current semVer, currentStr string) []string {
	if v, ok := parseSemVer(sourceVersion); ok && (onAdditiveLine(v, current) || onRelabelLine(v, current)) {
		return []string{currentStr}
	}
	return []string{}
}

// SupportedMigrationTargets returns the schema versions `sourceVersion` can be
// migrated to.
//
//   - any version on the additive line `2.0.0 … <current schema version>`, or
//     on the 1.x line `1.0.0 … 1.3.0` → [SchemaVersion]. A 1.x source is
//     offered by VERSION; Migrate still refuses a 1.x document that uses a
//     removed construct.
//   - everything else — including EVERY 0.x version, which 1.0.0's clean break
//     puts out of reach of a marker bump — → an empty slice.
//
// The canonical name drops TypeScript's `get` prefix.
func SupportedMigrationTargets(sourceVersion string) []string {
	return migrationTargets(sourceVersion, currentSchemaSemVer, SchemaVersion)
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
// transform: a source on the additive line or the 1.x line advanced to the
// current schema version (see the file header). A 1.x document that uses a
// removed op returns a *MigrationError whose Code is `removed_op`, naming the
// op, where it is, and the codemod; errors.As finds the underlying diagnostic
// as a DiagnosticError. Any other version pair — a 0.x source included —
// returns a *MigrationError. Content-level changes are not performed; they are
// modeling decisions, not mechanical migrations.
//
// The input file is never mutated: a shallow copy carrying the updated `esm`
// marker is returned. A shallow copy is exactly what the marker bump needs and
// exactly what the other bindings do (`{...file, esm}` in TypeScript) — since
// nothing else is written, the copy and the original may share their component
// maps and slices.
func Migrate(file *ESMFile, targetVersion string) (*ESMFile, error) {
	return migrateAgainst(file, targetVersion, currentSchemaSemVer, SchemaVersion)
}

// migrateAgainst is Migrate against an explicit current schema version.
func migrateAgainst(file *ESMFile, targetVersion string, current semVer, currentStr string) (*ESMFile, error) {
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
	supported := false
	for _, t := range migrationTargets(sourceVersion, current, currentStr) {
		supported = supported || t == targetVersion
	}
	if !supported {
		return nil, &MigrationError{
			Message:     fmt.Sprintf("migration from %s to %s is not supported", sourceVersion, targetVersion),
			FromVersion: sourceVersion,
			ToVersion:   targetVersion,
		}
	}
	if v, _ := parseSemVer(sourceVersion); onRelabelLine(v, current) {
		if removed, err := findRemovedInFile(file); err != nil {
			return nil, &MigrationError{
				Message:     err.Error(),
				FromVersion: sourceVersion,
				ToVersion:   targetVersion,
			}
		} else if removed != nil {
			return nil, &MigrationError{
				Message:     removed.Message,
				FromVersion: sourceVersion,
				ToVersion:   targetVersion,
				Code:        codeRemovedOp,
				cause:       removed,
			}
		}
	}

	migrated := *file
	migrated.ESM = targetVersion
	return &migrated, nil
}

// findRemovedInFile reports the first removed construct an in-memory document
// uses, by the same walk the wire boundary runs (findRemovedConstruct). The
// typed model has no `function_tables` field, so only an op can be found.
func findRemovedInFile(file *ESMFile) (*removedOpError, error) {
	raw, err := json.Marshal(file)
	if err != nil {
		return nil, err
	}
	var doc any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	return findRemovedConstruct(doc), nil
}
