package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// versionCompatDir locates the SHARED tests/version_compatibility corpus, whose
// compatibility_matrix.json is the canonical, cross-binding specification of
// which versions this library accepts and which it can migrate.
func versionCompatDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	repoRoot := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..")
	return filepath.Join(repoRoot, "tests", "version_compatibility")
}

type compatMatrix struct {
	Matrix struct {
		LibraryVersion string `json:"library_version"`
		TestCases      []struct {
			File             string `json:"file"`
			ExpectedBehavior string `json:"expected_behavior"`
			Description      string `json:"description"`
		} `json:"test_cases"`
		MigrationTests []struct {
			Source      string `json:"source"`
			Target      string `json:"target"`
			Description string `json:"description"`
		} `json:"migration_tests"`
	} `json:"version_compatibility_test_matrix"`
}

func loadCompatMatrix(t *testing.T) (string, compatMatrix) {
	t.Helper()
	dir := versionCompatDir(t)
	raw, err := os.ReadFile(filepath.Join(dir, "compatibility_matrix.json"))
	if err != nil {
		t.Fatalf("read compatibility_matrix.json: %v", err)
	}
	var m compatMatrix
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse compatibility_matrix.json: %v", err)
	}
	if len(m.Matrix.TestCases) == 0 {
		t.Fatal("compatibility matrix carries no test cases")
	}
	return dir, m
}

// declaredVersion reads the `esm` marker straight out of a fixture's JSON,
// without going through Load — several fixtures are deliberately unloadable
// (wrong major, non-semver marker, missing marker) and the migration surface
// still has to answer for them.
func declaredVersion(t *testing.T, path string) (string, bool) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	v, ok := doc["esm"].(string)
	return v, ok
}

// TestSchemaVersionMatchesMatrix pins SchemaVersion (derived from the embedded
// schema's $id) to the `library_version` the shared matrix declares. If these
// drift, every expectation below is measuring the wrong library.
func TestSchemaVersionMatchesMatrix(t *testing.T) {
	_, m := loadCompatMatrix(t)
	if SchemaVersion != m.Matrix.LibraryVersion {
		t.Fatalf("SchemaVersion = %q, matrix library_version = %q", SchemaVersion, m.Matrix.LibraryVersion)
	}
}

// TestMigrationOverSharedCorpus drives EVERY fixture in the shared
// version-compatibility corpus through SupportedMigrationTargets / CanMigrate /
// Migrate and asserts the contract the matrix states:
//
//   - a fixture on the additive line (major 1, ≤ current) migrates to
//     SchemaVersion by a marker bump;
//   - every other fixture — the 0.x pre-break documents, the future majors,
//     and the malformed markers — has NO supported target, and Migrate refuses.
func TestMigrationOverSharedCorpus(t *testing.T) {
	dir, m := loadCompatMatrix(t)

	for _, tc := range m.Matrix.TestCases {
		tc := tc
		t.Run(tc.File, func(t *testing.T) {
			path := filepath.Join(dir, tc.File)
			version, isString := declaredVersion(t, path)

			parsed, wellFormed := parseSemVer(version)
			// The additive line is exactly "same major as the library, at or
			// below the current version, at or above 1.0.0".
			wantMigratable := isString && wellFormed && onAdditiveLine(parsed)

			targets := SupportedMigrationTargets(version)
			if wantMigratable {
				if len(targets) != 1 || targets[0] != SchemaVersion {
					t.Fatalf("SupportedMigrationTargets(%q) = %v, want [%q]", version, targets, SchemaVersion)
				}
				if !CanMigrate(version, SchemaVersion) {
					t.Fatalf("CanMigrate(%q, %q) = false, want true", version, SchemaVersion)
				}
			} else {
				if len(targets) != 0 {
					t.Fatalf("SupportedMigrationTargets(%q) = %v, want [] (%s)", version, targets, tc.Description)
				}
				if CanMigrate(version, SchemaVersion) {
					t.Fatalf("CanMigrate(%q, %q) = true, want false (%s)", version, SchemaVersion, tc.Description)
				}
			}

			// Migrate agrees with the predicate, on a file built from the
			// fixture's declared marker (the fixture itself may be unloadable).
			file := &ESMFile{ESM: version, Metadata: Metadata{Name: "compat"}}
			got, err := Migrate(file, SchemaVersion)
			if wantMigratable {
				if err != nil {
					t.Fatalf("Migrate(%q → %q): %v", version, SchemaVersion, err)
				}
				if got.ESM != SchemaVersion {
					t.Fatalf("migrated esm = %q, want %q", got.ESM, SchemaVersion)
				}
				if file.ESM != version {
					t.Fatalf("Migrate mutated its input: esm = %q, want %q", file.ESM, version)
				}
			} else {
				if err == nil {
					t.Fatalf("Migrate(%q → %q) succeeded, want MigrationError (%s)", version, SchemaVersion, tc.Description)
				}
				var me *MigrationError
				if !asMigrationError(err, &me) {
					t.Fatalf("Migrate returned %T, want *MigrationError", err)
				}
			}
		})
	}
}

// TestMigrationPairIsARewriteNotAMarkerBump pins the corpus's one migration
// pair: the 0.0.5 SOURCE is on the far side of the 1.0.0 clean break and is
// NOT migratable, while the 1.0.0 TARGET already sits on the additive line.
// That asymmetry is what "migration across the break is a rewrite a human
// performs" means in code.
func TestMigrationPairIsARewriteNotAMarkerBump(t *testing.T) {
	dir, m := loadCompatMatrix(t)
	if len(m.Matrix.MigrationTests) == 0 {
		t.Fatal("compatibility matrix carries no migration_tests")
	}
	for _, mt := range m.Matrix.MigrationTests {
		mt := mt
		t.Run(mt.Source, func(t *testing.T) {
			srcVersion, _ := declaredVersion(t, filepath.Join(dir, mt.Source))
			tgtVersion, _ := declaredVersion(t, filepath.Join(dir, mt.Target))

			if got := SupportedMigrationTargets(srcVersion); len(got) != 0 {
				t.Fatalf("source %s (%s) offers targets %v; a pre-break document must offer none",
					mt.Source, srcVersion, got)
			}
			if CanMigrate(srcVersion, tgtVersion) {
				t.Fatalf("CanMigrate(%q, %q) = true; the 1.0.0 break carries no automated path",
					srcVersion, tgtVersion)
			}
			// The target is already on the additive line, so it migrates to
			// itself by a no-op marker bump.
			if !CanMigrate(tgtVersion, SchemaVersion) {
				t.Fatalf("CanMigrate(%q, %q) = false; the migrated target must sit on the additive line",
					tgtVersion, SchemaVersion)
			}
		})
	}
}

// TestMigrateIsAMarkerBumpOnly asserts that a successful migration touches the
// `esm` field and nothing else.
func TestMigrateIsAMarkerBumpOnly(t *testing.T) {
	desc := "a model"
	file := &ESMFile{
		ESM:      "1.0.0",
		Metadata: Metadata{Name: "m", Description: &desc},
		Models: map[string]Model{
			"m": {
				Variables: map[string]ModelVariable{"x": {Type: VarTypeUnknown}},
				Equations: []Equation{{LHS: "x", RHS: float64(1)}},
			},
		},
	}
	before, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("marshal before: %v", err)
	}

	got, err := Migrate(file, SchemaVersion)
	if err != nil {
		t.Fatalf("Migrate: %v", err)
	}
	if got.ESM != SchemaVersion {
		t.Fatalf("esm = %q, want %q", got.ESM, SchemaVersion)
	}

	after, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("marshal after: %v", err)
	}
	if string(before) != string(after) {
		t.Fatalf("Migrate mutated its input:\n before: %s\n  after: %s", before, after)
	}

	// Everything but `esm` is carried across unchanged.
	got.ESM = file.ESM
	roundTrip, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal migrated: %v", err)
	}
	if string(roundTrip) != string(before) {
		t.Fatalf("Migrate changed more than the version marker:\n want: %s\n  got: %s", before, roundTrip)
	}
}

// TestMigrationErrorCases covers the surface the shared corpus does not reach:
// a nil file, a file with no `esm` marker, and a target that is not the
// current schema version.
func TestMigrationErrorCases(t *testing.T) {
	if _, err := Migrate(nil, SchemaVersion); err == nil {
		t.Fatal("Migrate(nil) succeeded, want error")
	}

	if _, err := Migrate(&ESMFile{Metadata: Metadata{Name: "m"}}, SchemaVersion); err == nil {
		t.Fatal("Migrate on a file with no esm marker succeeded, want error")
	}

	// An arbitrary intermediate target is deliberately NOT offered: there is no
	// per-minor transform to encode, only "bring this file up to current".
	if CanMigrate("1.0.0", "1.0.1") && SchemaVersion != "1.0.1" {
		t.Fatal(`CanMigrate("1.0.0", "1.0.1") = true; only SchemaVersion is offered`)
	}
	if _, err := Migrate(&ESMFile{ESM: "1.0.0", Metadata: Metadata{Name: "m"}}, "9.9.9"); err == nil {
		t.Fatal("Migrate to an unsupported target succeeded, want error")
	}
}

// TestVersionComparisonIsNumeric pins the matrix's `version_comparison` rule:
// components compare numerically, never lexicographically.
func TestVersionComparisonIsNumeric(t *testing.T) {
	mustParse := func(s string) semVer {
		v, ok := parseSemVer(s)
		if !ok {
			t.Fatalf("parseSemVer(%q) failed", s)
		}
		return v
	}
	if compareSemVer(mustParse("1.10.0"), mustParse("1.2.0")) <= 0 {
		t.Fatal("1.10.0 must compare newer than 1.2.0")
	}
	if compareSemVer(mustParse("1.0.100"), mustParse("1.1.0")) >= 0 {
		t.Fatal("1.0.100 is a patch of 1.0, not a minor bump past 1.1.0")
	}
	if compareSemVer(mustParse("1.0.0"), mustParse("1.0.0")) != 0 {
		t.Fatal("equal versions must compare equal")
	}
	for _, bad := range []string{"not.a.version", "1.0", "1.0.0-alpha.1", ""} {
		if _, ok := parseSemVer(bad); ok {
			t.Fatalf("parseSemVer(%q) succeeded, want failure", bad)
		}
	}
}

// asMigrationError is a local errors.As, kept explicit so the assertion reads
// as a type check rather than an errors-package idiom.
func asMigrationError(err error, out **MigrationError) bool {
	me, ok := err.(*MigrationError)
	if ok {
		*out = me
	}
	return ok
}
