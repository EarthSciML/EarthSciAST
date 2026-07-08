package esm

// Execution runner for inline `tests` blocks on the tests/simulation/*.esm
// physics fixtures (gt-l1fk). Mirrors the Julia reference at
// pkg/EarthSciAST.jl/test/tests_blocks_execution_test.jl.
//
// The Go binding is parse-only (no ODE solver), so this runner does not
// execute assertions numerically. Instead it closes the schema-vs-binding gap
// for every tests/simulation/ fixture by:
//   1. Parsing the fixture via Load (schema-validated).
//   2. Walking every model/reaction_system that carries a `tests` block,
//      confirming each Test has a time_span and at least one assertion with
//      the required (variable, time, expected) shape.
//
// If a future Go ODE backend lands, this runner is the place to wire
// numerical execution in — the fixture walk and the tolerance-precedence
// helpers already live in this package (resolveUnitsFixtureTol).

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// checkTestsBlock validates the structural shape of one `tests` block entry
// and returns the number of assertions it declares.
func checkTestsBlock(t *testing.T, label string, testsRaw []interface{}) int {
	t.Helper()
	assertions := 0
	for i, tcRaw := range testsRaw {
		tc, ok := tcRaw.(map[string]interface{})
		if !ok {
			t.Fatalf("%s: tests[%d] not an object", label, i)
		}
		id, _ := tc["id"].(string)
		if id == "" {
			t.Fatalf("%s: tests[%d] missing id", label, i)
		}
		tsRaw, ok := tc["time_span"].(map[string]interface{})
		if !ok {
			t.Fatalf("%s/%s: missing time_span", label, id)
		}
		if _, ok := tsRaw["start"].(float64); !ok {
			t.Fatalf("%s/%s: time_span.start not numeric", label, id)
		}
		if _, ok := tsRaw["end"].(float64); !ok {
			t.Fatalf("%s/%s: time_span.end not numeric", label, id)
		}
		aRaw, _ := tc["assertions"].([]interface{})
		if len(aRaw) == 0 {
			t.Fatalf("%s/%s: expected at least one assertion", label, id)
		}
		for j, raw := range aRaw {
			a, ok := raw.(map[string]interface{})
			if !ok {
				t.Fatalf("%s/%s: assertions[%d] not an object", label, id, j)
			}
			if v, _ := a["variable"].(string); v == "" {
				t.Fatalf("%s/%s: assertions[%d] missing variable", label, id, j)
			}
			if _, ok := a["time"].(float64); !ok {
				t.Fatalf("%s/%s: assertions[%d].time not numeric", label, id, j)
			}
			if _, ok := a["expected"].(float64); !ok {
				t.Fatalf("%s/%s: assertions[%d].expected not numeric", label, id, j)
			}
			assertions++
		}
	}
	return assertions
}

// TestSimulationFixturesBlocksExecution walks tests/simulation/*.esm and
// verifies every inline `tests` block round-trips cleanly through the Go
// binding. This is the parse-only counterpart to the Julia runner at
// pkg/EarthSciAST.jl/test/tests_blocks_execution_test.jl.
//
// When a Go ODE simulator lands, replace the `skipNumeric = true` branch
// with real execution and keep the fixture walk.
func TestSimulationFixturesBlocksExecution(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	simDir := filepath.Join(repoRoot, "tests", "simulation")
	entries, err := os.ReadDir(simDir)
	if err != nil {
		t.Fatalf("read %s: %v", simDir, err)
	}

	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".esm") {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		t.Fatalf("no .esm fixtures in %s", simDir)
	}

	totalTests := 0
	totalAssertions := 0
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(simDir, name)

			// 1. Load via Go's schema-validated loader. We only need the
			//    side effect (schema + subsystem-ref resolution); the Go
			//    struct does not yet expose the `tests` block.
			if _, err := Load(path); err != nil {
				t.Fatalf("Load(%s): %v", name, err)
			}

			// 2. Walk raw JSON to find inline `tests` blocks. The Go struct
			//    does not yet expose them, so we walk the doc directly — same
			//    pattern used by units_fixture_test.go.
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			var doc map[string]interface{}
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatalf("unmarshal %s: %v", name, err)
			}

			fixtureTests := 0
			models := mapOr(doc, "models")
			for mname, mraw := range models {
				model, ok := mraw.(map[string]interface{})
				if !ok {
					continue
				}
				tsRaw, _ := model["tests"].([]interface{})
				if len(tsRaw) == 0 {
					continue
				}
				label := fmt.Sprintf("%s/models/%s", name, mname)
				totalAssertions += checkTestsBlock(t, label, tsRaw)
				fixtureTests += len(tsRaw)
			}
			rsys := mapOr(doc, "reaction_systems")
			for rsname, rraw := range rsys {
				rs, ok := rraw.(map[string]interface{})
				if !ok {
					continue
				}
				tsRaw, _ := rs["tests"].([]interface{})
				if len(tsRaw) == 0 {
					continue
				}
				label := fmt.Sprintf("%s/reaction_systems/%s", name, rsname)
				totalAssertions += checkTestsBlock(t, label, tsRaw)
				fixtureTests += len(tsRaw)
			}
			totalTests += fixtureTests
		})
	}

	// Spec §4.7 tests/simulation fixtures must carry inline tests blocks
	// for at least one model — this guards against silent regressions where
	// all tests blocks get stripped during a migration.
	if totalTests == 0 {
		t.Fatalf("expected at least one inline test across tests/simulation/ fixtures, got 0")
	}
	if totalAssertions == 0 {
		t.Fatalf("expected at least one assertion across tests/simulation/ fixtures, got 0")
	}
}
