package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestClosedFunctionsConformance drives every fixture under
// tests/closed_functions/<module>/<name>/{canonical.esm, expected.json}.
//
// For each fixture:
//  1. Load canonical.esm (exercises the parser's `fn`-op handling).
//  2. For each scenario in expected.json, evaluate the named closed
//     function with the given inputs and assert agreement with the
//     reference output within the declared tolerance.
//  3. For interp.searchsorted, drive `error_scenarios` and assert the
//     spec-pinned diagnostic code surfaces.
//
// All five bindings MUST run the same fixtures (esm-spec §9.4 / esm-aia).
func TestClosedFunctionsConformance(t *testing.T) {
	root := closedFunctionsFixturesDir(t)
	entries, err := walkClosedFnDirs(root)
	if err != nil {
		t.Fatalf("walk fixtures: %v", err)
	}
	if len(entries) == 0 {
		t.Fatalf("no closed-function fixtures under %s", root)
	}
	for _, e := range entries {
		e := e
		t.Run(e.label, func(t *testing.T) {
			// Step 1: load the canonical.esm. We only need the parser to
			// accept it — every fixture's RHS is a single `fn` invocation
			// of the function we're testing.
			if _, err := Load(e.canonical); err != nil {
				t.Fatalf("Load(%s): %v", e.canonical, err)
			}

			// Step 2 + 3: drive expected.json against EvaluateClosedFunction.
			raw, err := os.ReadFile(e.expected)
			if err != nil {
				t.Fatalf("read %s: %v", e.expected, err)
			}
			var fixture closedFnFixture
			if err := json.Unmarshal(raw, &fixture); err != nil {
				t.Fatalf("parse %s: %v", e.expected, err)
			}
			if fixture.Function == "" {
				t.Fatalf("%s: missing `function` field", e.expected)
			}
			if !IsClosedFunction(fixture.Function) {
				// Spec-first phased rollout (esm-94w and similar): a new
				// closed-function fixture lands in the spec PR before this
				// binding's implementation. Skip rather than fail; the
				// per-language [Impl] bead adds the function to the registry
				// and the fixture starts running automatically.
				t.Skipf("fixture function %q not yet implemented in this binding", fixture.Function)
			}
			for _, sc := range fixture.Scenarios {
				sc := sc
				t.Run("ok/"+sc.Name, func(t *testing.T) {
					args, err := normalizeFixtureArgs(sc.Inputs)
					if err != nil {
						t.Fatalf("normalize inputs: %v", err)
					}
					out, err := EvaluateClosedFunction(fixture.Function, args)
					if err != nil {
						t.Fatalf("EvaluateClosedFunction(%s, %v): %v", fixture.Function, args, err)
					}
					if err := assertCloseEnough(out, sc.Expected, fixture.Tolerance); err != nil {
						t.Fatalf("scenario %s (%s): %v", sc.Name, sc.Description, err)
					}
				})
			}
			for _, sc := range fixture.ErrorScenarios {
				sc := sc
				t.Run("err/"+sc.Name, func(t *testing.T) {
					args, err := normalizeFixtureArgs(sc.Inputs)
					if err != nil {
						t.Fatalf("normalize inputs: %v", err)
					}
					_, err = EvaluateClosedFunction(fixture.Function, args)
					if err == nil {
						t.Fatalf("expected error %q, got nil", sc.ExpectedErrorCode)
					}
					cfErr, ok := err.(*ClosedFunctionError)
					if !ok {
						t.Fatalf("expected *ClosedFunctionError, got %T: %v", err, err)
					}
					if cfErr.Code != sc.ExpectedErrorCode {
						t.Fatalf("error code mismatch: got %q, want %q (%s)",
							cfErr.Code, sc.ExpectedErrorCode, sc.Description)
					}
				})
			}
		})
	}
}

type closedFnFixture struct {
	Function       string                  `json:"function"`
	Tolerance      closedFnTolerance       `json:"tolerance"`
	Scenarios      []closedFnScenario      `json:"scenarios"`
	ErrorScenarios []closedFnErrorScenario `json:"error_scenarios"`
}

type closedFnTolerance struct {
	Abs float64 `json:"abs"`
	Rel float64 `json:"rel"`
}

type closedFnScenario struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Inputs      []interface{}   `json:"inputs"`
	Expected    json.RawMessage `json:"expected"`
}

type closedFnErrorScenario struct {
	Name              string        `json:"name"`
	Description       string        `json:"description"`
	Inputs            []interface{} `json:"inputs"`
	ExpectedErrorCode string        `json:"expected_error_code"`
}

type closedFnEntry struct {
	label     string // e.g. "datetime/year"
	canonical string
	expected  string
}

// walkClosedFnDirs returns every <module>/<function> directory under root
// that has both canonical.esm and expected.json.
func walkClosedFnDirs(root string) ([]closedFnEntry, error) {
	var out []closedFnEntry
	modules, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	for _, mod := range modules {
		if !mod.IsDir() {
			continue
		}
		modDir := filepath.Join(root, mod.Name())
		fns, err := os.ReadDir(modDir)
		if err != nil {
			return nil, err
		}
		for _, fn := range fns {
			if !fn.IsDir() {
				continue
			}
			fnDir := filepath.Join(modDir, fn.Name())
			canonical := filepath.Join(fnDir, "canonical.esm")
			expected := filepath.Join(fnDir, "expected.json")
			if _, err := os.Stat(canonical); err != nil {
				continue
			}
			if _, err := os.Stat(expected); err != nil {
				continue
			}
			out = append(out, closedFnEntry{
				label:     mod.Name() + "/" + fn.Name(),
				canonical: canonical,
				expected:  expected,
			})
		}
	}
	return out, nil
}

// normalizeFixtureArgs converts the JSON-decoded input slice into the
// types EvaluateClosedFunction expects: numbers stay as float64; nested
// arrays stay as []interface{}; the literal string "NaN" is converted to
// math.NaN(); other strings are forwarded for diagnostic purposes.
func normalizeFixtureArgs(inputs []interface{}) ([]interface{}, error) {
	out := make([]interface{}, len(inputs))
	for i, raw := range inputs {
		out[i] = normalizeFixtureValue(raw)
	}
	return out, nil
}

func normalizeFixtureValue(v interface{}) interface{} {
	switch x := v.(type) {
	case string:
		if x == "NaN" || x == "nan" || x == "NAN" {
			return math.NaN()
		}
		return x
	case []interface{}:
		out := make([]interface{}, len(x))
		for i, e := range x {
			out[i] = normalizeFixtureValue(e)
		}
		return out
	default:
		return v
	}
}

// assertCloseEnough compares a closed-function output to its expected
// reference within (abs OR rel) tolerance. Integer-typed outputs are
// promoted to float64 for the comparison; the spec pins zero tolerance
// for every entry except `datetime.julian_day` (≤ 1 ulp).
func assertCloseEnough(got interface{}, expectedRaw json.RawMessage, tol closedFnTolerance) error {
	want, err := decodeExpectedScalar(expectedRaw)
	if err != nil {
		return err
	}
	gf, ok := toFloat64(got)
	if !ok {
		return errf("got non-numeric scalar %T (%v)", got, got)
	}
	if math.IsNaN(want) {
		if math.IsNaN(gf) {
			return nil
		}
		return errf("expected NaN, got %g", gf)
	}
	diff := math.Abs(gf - want)
	if diff <= tol.Abs {
		return nil
	}
	if want != 0 && diff/math.Abs(want) <= tol.Rel {
		return nil
	}
	return errf("got %g, want %g (|diff|=%g, tol=abs %g rel %g)",
		gf, want, diff, tol.Abs, tol.Rel)
}

func decodeExpectedScalar(raw json.RawMessage) (float64, error) {
	s := strings.TrimSpace(string(raw))
	if s == "\"NaN\"" || s == "\"nan\"" || s == "\"NAN\"" {
		return math.NaN(), nil
	}
	var f float64
	if err := json.Unmarshal(raw, &f); err != nil {
		return 0, err
	}
	return f, nil
}

// errf is a tiny formatted-error helper used by the conformance harness.
func errf(format string, args ...interface{}) error {
	return fmt.Errorf(format, args...)
}

func closedFunctionsFixturesDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	pkgDir := filepath.Dir(thisFile)
	// pkg/esm/closed_functions_test.go -> repo root is 4 levels up.
	repoRoot := filepath.Join(pkgDir, "..", "..", "..", "..")
	return filepath.Join(repoRoot, "tests", "closed_functions")
}
