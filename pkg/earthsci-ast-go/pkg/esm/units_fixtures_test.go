package esm

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestUnitsFixturesCrossBinding wires the three canonical units fixtures
// (tests/valid/units_*.esm) into the Go test suite as part of gt-gtf.
// These fixtures are shared across Julia/Python/Rust/TypeScript/Go and
// exist specifically to drive cross-binding agreement on units handling.
//
// Each binding's unit registry covers a different subset of physical
// units; the fixtures intentionally exercise the union. The test asserts:
//   - every fixture loads via the public Load API,
//   - every fixture has at least one model,
//   - ValidateFile runs to completion on every fixture (warnings are
//     logged but not asserted, because per-binding registry coverage
//     differs and is the audit signal these fixtures exist to surface).
func TestUnitsFixturesCrossBinding(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	fixtures := []string{
		"units_conversions.esm",
		"units_dimensional_analysis.esm",
		"units_propagation.esm",
	}
	for _, name := range fixtures {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(repoRoot, "tests", "valid", name)
			content, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			file, err := LoadString(string(content))
			if err != nil {
				t.Fatalf("load %s: %v", name, err)
			}
			if len(file.Models) == 0 {
				t.Fatalf("%s: expected at least one model", name)
			}
			result := ValidateFile(file, string(content))
			t.Logf("%s: %d unit warnings (cross-binding registry coverage signal)",
				name, len(result.UnitWarnings))
			for _, w := range result.UnitWarnings {
				t.Logf("  %s: %s", w.Path, w.Message)
			}
		})
	}
}

// TestGradientOperatorMismatchFixtureRejected pins the v0.8.0 contract of
// tests/invalid/units_gradient_operator_mismatch.esm as declared in
// tests/invalid/expected_errors.json.
//
// The fixture is schema-VALID ("schema_errors": []): it carries a grad applied
// over a coordinate 'x' the model declares WITHOUT units, plus a companion
// 'bad_sum' observed variable that adds metres to kilograms. Its intended
// rejections are two *structural* "unit_inconsistency" errors.
//
// This test previously asserted the OPPOSITE — that Go raises no
// unit_inconsistency at all, on the grounds that Go "intentionally implements NO
// units/dimensional validator". Go does implement one, and a provable
// dimensional mismatch is now a hard error, so the fixture must be REJECTED.
//
// Go surfaces the 'bad_sum' error (`/models/SpatialModel/variables/bad_sum`).
// The grad-specific error at `/models/SpatialModel/equations/0` requires
// resolving the grad `dim` against the model's declared variables, which only
// Julia does today — the fixture's own notes track that as a follow-up for
// Go/TS/Rust, and note that `bad_sum` exists precisely so bindings without
// grad-unit support still reject the file.
func TestGradientOperatorMismatchFixtureRejected(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "invalid", "units_gradient_operator_mismatch.esm")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	file, err := LoadString(string(content))
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}
	result := ValidateFile(file, string(content))

	// The fixture is schema-valid per expected_errors.json ("schema_errors": []).
	if len(result.SchemaErrors) != 0 {
		t.Fatalf("expected fixture to be schema-valid (schema_errors: []), got: %+v", result.SchemaErrors)
	}

	if result.IsValid {
		t.Fatal("fixture is pinned is_valid:false; Go accepted it")
	}
	if !hasStructuralError(result, ErrorUnitInconsistency, "/models/SpatialModel/variables/bad_sum") {
		t.Errorf("want unit_inconsistency @ /models/SpatialModel/variables/bad_sum, got %+v", result.StructuralErrors)
	}
}

// hasStructuralError reports whether an error-level structural error with the
// given code sits at the given JSON Pointer.
func hasStructuralError(result *ValidationResult, code, path string) bool {
	for _, e := range result.StructuralErrors {
		if e.Code == code && e.Path == path && e.Level == "" {
			return true
		}
	}
	return false
}

// TestReactionRateUnitsMismatchFixtureRejected verifies that the shared
// tests/invalid/units_reaction_rate_mismatch.esm fixture (2nd-order reaction
// A + B -> C whose rate parameter is declared with 1/s units) is rejected
// as a structural error with code "unit_inconsistency". This mirrors the
// Python/TS/Julia/Rust checks so all five bindings agree (gt-zs9o).
func TestReactionRateUnitsMismatchFixtureRejected(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "invalid", "units_reaction_rate_mismatch.esm")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	file, err := LoadString(string(content))
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}
	result := ValidateFile(file, string(content))
	if result.IsValid {
		t.Fatalf("expected fixture to fail validation, got is_valid=true")
	}
	var found *StructuralError
	for i, e := range result.StructuralErrors {
		if e.Code == ErrorUnitInconsistency {
			found = &result.StructuralErrors[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("expected unit_inconsistency error, got: %+v", result.StructuralErrors)
	}
	// Match the contract in tests/invalid/expected_errors.json.
	if found.Message != "Reaction rate expression has incompatible units for reaction stoichiometry" {
		t.Errorf("unexpected message: %q", found.Message)
	}
	expectDetail := func(key string, want any) {
		t.Helper()
		got, ok := found.Details[key]
		if !ok {
			t.Errorf("details[%q] missing", key)
			return
		}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("details[%q] = %v, want %v", key, got, want)
		}
	}
	expectDetail("reaction_id", "R1")
	expectDetail("rate_units", "1/s")
	expectDetail("expected_rate_units", "L/(mol*s)")
	expectDetail("reaction_order", 2)
}

// TestICInReactionSystemFixtureRejected verifies that the shared
// tests/invalid/ic_in_reaction_system.esm fixture (an `ic`-op equation placed
// inside a reaction system's constraint_equations) is SCHEMA-VALID but rejected
// as a structural error with code "ic_in_reaction_system" (spec §11.4.1). This
// mirrors the Python/TS/Julia/Rust checks so all five bindings agree.
func TestICInReactionSystemFixtureRejected(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "invalid", "ic_in_reaction_system.esm")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	// Schema-valid: LoadString must accept it (rejection is structural, not schema).
	file, err := LoadString(string(content))
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}
	result := ValidateFile(file, string(content))
	if result.IsValid {
		t.Fatalf("expected fixture to fail validation, got is_valid=true")
	}
	if len(result.SchemaErrors) != 0 {
		t.Fatalf("expected no schema errors, got: %+v", result.SchemaErrors)
	}
	var found *StructuralError
	for i, e := range result.StructuralErrors {
		if e.Code == ErrorIcInReactionSystem {
			found = &result.StructuralErrors[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("expected ic_in_reaction_system error, got: %+v", result.StructuralErrors)
	}
	if found.Path != "/reaction_systems/Chemistry/constraint_equations/0" {
		t.Errorf("unexpected path: %q", found.Path)
	}
	expectDetail := func(key string, want any) {
		t.Helper()
		got, ok := found.Details[key]
		if !ok {
			t.Errorf("details[%q] missing", key)
			return
		}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("details[%q] = %v, want %v", key, got, want)
		}
	}
	expectDetail("system", "Chemistry")
	expectDetail("species", "O3")
	expectDetail("constraint_equation_index", 0)
}

// TestReactionSystemNonICConstraintOK verifies that a reaction system whose
// constraint_equations carry no `ic` op does not trip the
// ic_in_reaction_system diagnostic (no false positives).
func TestReactionSystemNonICConstraintOK(t *testing.T) {
	jsonStr := `{
		"esm": "0.8.0",
		"metadata": {"name": "ok"},
		"reaction_systems": {
			"Chemistry": {
				"species": {"O3": {"units": "mol/mol", "default": 4.0e-8}},
				"parameters": {"k": {"units": "1/s", "default": 1.0e-3}},
				"reactions": [{
					"id": "R1", "name": "O3_loss",
					"substrates": [{"species": "O3", "stoichiometry": 1}],
					"products": null, "rate": "k"
				}],
				"constraint_equations": [
					{"lhs": "O3", "rhs": 4.0e-8}
				]
			}
		}
	}`
	file, err := LoadString(jsonStr)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	result := ValidateFile(file, jsonStr)
	for _, e := range result.StructuralErrors {
		if e.Code == ErrorIcInReactionSystem {
			t.Fatalf("unexpected ic_in_reaction_system false positive: %+v", e)
		}
	}
}

// TestConversionFactorErrorFixtureRejected verifies that
// tests/invalid/units_conversion_factor_error.esm (observed variable in Pa
// assigned `50000 * p_atm` where p_atm is in atm — expected factor 101325) is
// rejected as a structural error with code "unit_inconsistency". Mirrors
// Python's parse._check_conversion_factor_consistency (gt-nvdv / gt-abh1).
func TestConversionFactorErrorFixtureRejected(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "invalid", "units_conversion_factor_error.esm")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	file, err := LoadString(string(content))
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}
	result := ValidateFile(file, string(content))
	if result.IsValid {
		t.Fatalf("expected fixture to fail validation, got is_valid=true")
	}
	var found *StructuralError
	for i, e := range result.StructuralErrors {
		if e.Code == ErrorUnitInconsistency {
			found = &result.StructuralErrors[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("expected unit_inconsistency error, got: %+v", result.StructuralErrors)
	}
	if found.Path != "/models/BadUnitsModel/variables/converted_pressure" {
		t.Errorf("unexpected path: %q", found.Path)
	}
	if found.Message != "Unit conversion factor is incorrect for specified unit transformation" {
		t.Errorf("unexpected message: %q", found.Message)
	}
	expectDetail := func(key string, want any) {
		t.Helper()
		got, ok := found.Details[key]
		if !ok {
			t.Errorf("details[%q] missing", key)
			return
		}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("details[%q] = %v, want %v", key, got, want)
		}
	}
	expectDetail("variable", "converted_pressure")
	expectDetail("declared_units", "Pa")
	expectDetail("source_units", "atm")
	expectDetail("declared_factor", 50000.0)
	expectDetail("expected_factor", 101325.0)
}

// TestPhysicalConstantDimensionalErrorFixtureRejected verifies that
// tests/invalid/units_dimensional_constant_error.esm (ideal gas constant 'R'
// declared with units 'kcal/mol' — missing temperature dimension) is rejected
// as a structural unit_inconsistency error at the usage site. Mirrors Python's
// parse._check_physical_constant_units (gt-j91l / gt-3tgv).
func TestPhysicalConstantDimensionalErrorFixtureRejected(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "invalid", "units_dimensional_constant_error.esm")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	file, err := LoadString(string(content))
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}
	result := ValidateFile(file, string(content))
	if result.IsValid {
		t.Fatalf("expected fixture to fail validation, got is_valid=true")
	}
	var found *StructuralError
	for i, e := range result.StructuralErrors {
		if e.Code == ErrorUnitInconsistency && e.Message == "Physical constant used with incorrect dimensional analysis" {
			found = &result.StructuralErrors[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("expected unit_inconsistency error for physical constant, got: %+v", result.StructuralErrors)
	}
	if found.Path != "/models/ConstantUnitsModel/variables/gas_law_calculation" {
		t.Errorf("unexpected path: %q", found.Path)
	}
	expectDetail := func(key string, want any) {
		t.Helper()
		got, ok := found.Details[key]
		if !ok {
			t.Errorf("details[%q] missing", key)
			return
		}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("details[%q] = %v, want %v", key, got, want)
		}
	}
	expectDetail("constant_name", "R")
	expectDetail("constant_description", "ideal gas constant")
	expectDetail("declared_units", "kcal/mol")
	expectDetail("canonical_units", "J/(mol*K)")
}
