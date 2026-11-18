package esm

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
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
			// DeprecatedOp lists the JSON pointers the load's ONE
			// `deprecated_op` warning names (esm-spec §4.2).
			DeprecatedOp []string `json:"deprecated_op"`
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
//   - a fixture on the additive line (3.0.0 … current), the 2.x line
//     (2.0.0 … 2.3.0) or the 1.x line (1.0.0 … 1.3.0) migrates to SchemaVersion by a marker bump;
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
			wantMigratable := isString && wellFormed &&
				(onAdditiveLine(parsed, currentSchemaSemVer) || onRelabelLine(parsed, currentSchemaSemVer))

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

// TestMatrixDeprecatedOpWarnings loads, through LoadPath, every matrix
// fixture that carries a `deprecated_op` list and asserts the load writes
// exactly ONE `deprecated_op` warning naming exactly those JSON pointers, and
// no forward-compatibility version warning (esm-spec §4.2 "Deprecated ops").
func TestMatrixDeprecatedOpWarnings(t *testing.T) {
	dir, m := loadCompatMatrix(t)
	checked := 0
	for _, tc := range m.Matrix.TestCases {
		if tc.DeprecatedOp == nil {
			continue
		}
		checked++
		tc := tc
		t.Run(tc.File, func(t *testing.T) {
			file, stderr := loadCapturingStderr(t, filepath.Join(dir, tc.File))
			var warnings []string
			for _, line := range strings.Split(stderr, "\n") {
				if strings.Contains(line, codeDeprecatedOp) {
					warnings = append(warnings, line)
				}
			}
			if len(warnings) != 1 {
				t.Fatalf("want exactly one %s warning, got %d: %q", codeDeprecatedOp, len(warnings), stderr)
			}
			_, list, ok := strings.Cut(warnings[0], "Rewritten at: ")
			if !ok {
				t.Fatalf("warning names no rewritten nodes: %q", warnings[0])
			}
			var pointers []string
			for _, site := range strings.Split(strings.TrimSuffix(strings.TrimSpace(list), "."), ", ") {
				pointer, _, _ := strings.Cut(site, " (")
				pointers = append(pointers, pointer)
			}
			if strings.Join(pointers, "\n") != strings.Join(tc.DeprecatedOp, "\n") {
				t.Fatalf("warning names %q, matrix lists %q", pointers, tc.DeprecatedOp)
			}
			if strings.Contains(stderr, "is newer than") {
				t.Fatalf("unexpected forward-compat warning: %q", stderr)
			}
			if tc.File == "version_2_3_0_deprecated_neg.esm" {
				rhs, ok := asExprNode(file.Models["Decay"].Equations[0].RHS)
				if !ok || len(rhs.Args) == 0 {
					t.Fatalf("Decay rhs is not an operator with args: %+v", file.Models["Decay"].Equations[0].RHS)
				}
				arg, ok := asExprNode(rhs.Args[0])
				if !ok || arg.Op != "-" {
					t.Fatalf("Decay rhs args[0] = %+v, want op \"-\" (neg not rewritten)", rhs.Args[0])
				}
			}
		})
	}
	if checked == 0 {
		t.Fatal("no matrix entry carries a deprecated_op list")
	}
}

// TestMigrationPairIsARewriteNotAMarkerBump pins the corpus's one migration
// pair: the 0.0.5 SOURCE is on the far side of the 1.0.0 clean break and is
// NOT migratable, while the 1.0.0 TARGET is relabelled to the current version.
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
			// The target is on the 1.x line, so it migrates to the current
			// version by a marker bump.
			if !CanMigrate(tgtVersion, SchemaVersion) {
				t.Fatalf("CanMigrate(%q, %q) = false; the migrated target must sit on the 1.x line",
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

// v2 is the 2.0.0 schema version the relabel tests run against, independent of
// the embedded schema this package was built with.
var v2 = semVer{Major: 2}

// A 1.x document that uses none of the removed constructs is relabelled to
// 2.0.0; a 2.x document on the additive line migrates to itself; a 1.x minor
// past 1.3.0 and a 0.x document are not offered.
func TestMigrationRelabels1xTo2(t *testing.T) {
	for _, v := range []string{"1.0.0", "1.2.0", "1.3.0", "2.0.0"} {
		if got := migrationTargets(v, v2, "2.0.0"); len(got) != 1 || got[0] != "2.0.0" {
			t.Errorf("migrationTargets(%q) = %v, want [2.0.0]", v, got)
		}
	}
	for _, v := range []string{"0.9.0", "1.4.0", "1.10.0", "2.0.1", "3.0.0"} {
		if got := migrationTargets(v, v2, "2.0.0"); len(got) != 0 {
			t.Errorf("migrationTargets(%q) = %v, want []", v, got)
		}
	}
	file := &ESMFile{
		ESM:      "1.3.0",
		Metadata: Metadata{Name: "m"},
		Models: map[string]Model{"m": {
			Variables: map[string]ModelVariable{"x": {Type: VarTypeUnknown}},
			Equations: []Equation{{LHS: "x", RHS: ExprNode{Op: "floor", Args: []any{"x"}}}},
		}},
	}
	got, err := migrateAgainst(file, "2.0.0", v2, "2.0.0")
	if err != nil {
		t.Fatalf("relabel: %v", err)
	}
	if got.ESM != "2.0.0" || file.ESM != "1.3.0" {
		t.Fatalf("esm = %q (input %q), want 2.0.0 (input 1.3.0)", got.ESM, file.ESM)
	}
}

// A 1.x document that uses a removed op is refused with `removed_op`, naming
// the op, where it is, and the codemod.
func TestMigrationRefusesRemovedOps(t *testing.T) {
	for op := range removedOps {
		op := op
		t.Run(op, func(t *testing.T) {
			file := &ESMFile{
				ESM:      "1.1.0",
				Metadata: Metadata{Name: "m"},
				Models: map[string]Model{"m": {
					Variables: map[string]ModelVariable{"x": {Type: VarTypeUnknown}},
					Equations: []Equation{{LHS: "x", RHS: ExprNode{Op: "+", Args: []any{
						1.0, ExprNode{Op: op, Args: []any{"x"}},
					}}}},
				}},
			}
			_, err := migrateAgainst(file, "2.0.0", v2, "2.0.0")
			var me *MigrationError
			if !errors.As(err, &me) || me.Code != "removed_op" {
				t.Fatalf("err = %v, want a MigrationError with code removed_op", err)
			}
			var de DiagnosticError
			if !errors.As(err, &de) || de.DiagnosticCode() != "removed_op" {
				t.Fatalf("errors.As(DiagnosticError) = %v, want removed_op", err)
			}
			for _, want := range []string{"`\"op\": \"" + op + "\"`", "/models/m/equations/0/rhs/args/1"} {
				if !strings.Contains(me.Message, want) {
					t.Errorf("message %q does not name %s", me.Message, want)
				}
			}
			switch removedOps[op] {
			case "2.0.0":
				if !strings.Contains(me.Message, migrateCommand) {
					t.Errorf("message %q does not name the codemod", me.Message)
				}
			case "3.0.0":
				if strings.Contains(me.Message, migrateCommand) || !strings.Contains(me.Message, "esm 3.0.0") {
					t.Errorf("message %q must point at MIGRATION.md \"esm 3.0.0\", not the codemod", me.Message)
				}
			}
		})
	}
}

// v3 is the 3.0.0 schema version: the library implements major 3 and relabels
// majors 1 and 2.
var v3 = semVer{Major: 3}

// Under a 3.x library a 1.x or 2.x document that uses no removed construct is
// relabelled to current; a minor past the last release of its major (1.3.0,
// 2.3.0), a 0.x document and a future major are not offered.
func TestMigrationRelabels1xAnd2xTo3(t *testing.T) {
	for _, v := range []string{"1.0.0", "1.3.0", "2.0.0", "2.1.0", "2.3.0", "3.0.0"} {
		if got := migrationTargets(v, v3, "3.0.0"); len(got) != 1 || got[0] != "3.0.0" {
			t.Errorf("migrationTargets(%q) = %v, want [3.0.0]", v, got)
		}
	}
	for _, v := range []string{"0.9.0", "1.4.0", "1.10.0", "2.3.1", "2.5.1", "3.0.1", "4.0.0"} {
		if got := migrationTargets(v, v3, "3.0.0"); len(got) != 0 {
			t.Errorf("migrationTargets(%q) = %v, want []", v, got)
		}
	}
	file := &ESMFile{
		ESM:      "2.3.0",
		Metadata: Metadata{Name: "m"},
		Models: map[string]Model{"m": {
			Variables: map[string]ModelVariable{"x": {Type: VarTypeUnknown}},
			Equations: []Equation{{LHS: "x", RHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("y")}}},
		}},
	}
	got, err := migrateAgainst(file, "3.0.0", v3, "3.0.0")
	if err != nil {
		t.Fatalf("relabel: %v", err)
	}
	if got.ESM != "3.0.0" || file.ESM != "2.3.0" {
		t.Fatalf("esm = %q (input %q), want 3.0.0 (input 2.3.0)", got.ESM, file.ESM)
	}
}

// A 2.x document that uses `grad`, `div` or `laplacian` is refused with
// `removed_op`, pointing at MIGRATION.md "esm 3.0.0" and not at the codemod.
func TestMigrationRefuses3xRemovedOpsFrom2x(t *testing.T) {
	for _, op := range []string{"grad", "div", "laplacian"} {
		file := &ESMFile{
			ESM:      "2.3.0",
			Metadata: Metadata{Name: "m"},
			Models: map[string]Model{"m": {
				Variables: map[string]ModelVariable{"x": {Type: VarTypeUnknown}},
				Equations: []Equation{{LHS: "x", RHS: ExprNode{Op: op, Args: []any{"x"}}}},
			}},
		}
		_, err := migrateAgainst(file, "3.0.0", v3, "3.0.0")
		var me *MigrationError
		if !errors.As(err, &me) || me.Code != "removed_op" {
			t.Fatalf("%s: err = %v, want a MigrationError with code removed_op", op, err)
		}
		if strings.Contains(me.Message, migrateCommand) || !strings.Contains(me.Message, "esm 3.0.0") {
			t.Errorf("%s: message %q must point at MIGRATION.md \"esm 3.0.0\", not the codemod", op, me.Message)
		}
	}
}
