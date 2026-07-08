package esm

// Units fixtures consumption runner (gt-dt0o).
//
// The three units_*.esm files in tests/valid/ carry inline `tests` blocks
// (id / parameter_overrides / initial_conditions / time_span / assertions)
// added in gt-p3v. Schema parse coverage is asserted in
// units_fixtures_test.go (TestUnitsFixturesCrossBinding). This file closes
// the schema-vs-execution gap: every assertion's target (all of which are
// observed variables at t = 0) is actually evaluated under the test's
// bindings and compared against the expected value within the resolved
// tolerance (assertion → test → model, falling back to rtol = 1e-6).
//
// Corrupting an expected value in any fixture — or reverting the
// pressure_drop fix from gt-p3v — must cause this suite to fail.
//
// The Go `Model` struct does not currently carry the inline `tests` block,
// so this runner walks the raw JSON directly rather than going through
// LoadString. The shape is schema-validated elsewhere; here we only need
// the fields listed above.

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
)

type unitsFixtureTolerance struct {
	Rel float64
	Abs float64
}

func parseTol(raw interface{}) (unitsFixtureTolerance, bool) {
	if raw == nil {
		return unitsFixtureTolerance{}, false
	}
	m, ok := raw.(map[string]interface{})
	if !ok {
		return unitsFixtureTolerance{}, false
	}
	out := unitsFixtureTolerance{}
	if v, ok := m["rel"]; ok {
		if f, ok := v.(float64); ok {
			out.Rel = f
		}
	}
	if v, ok := m["abs"]; ok {
		if f, ok := v.(float64); ok {
			out.Abs = f
		}
	}
	return out, true
}

func resolveUnitsFixtureTol(modelTol, testTol, assertionTol interface{}) (float64, float64) {
	for _, raw := range []interface{}{assertionTol, testTol, modelTol} {
		if t, ok := parseTol(raw); ok {
			return t.Rel, t.Abs
		}
	}
	return 1e-6, 0.0
}

// evalFixtureExpr evaluates a raw JSON expression (numbers, variable
// strings, operator nodes as map[string]interface{}). Returns ok=false if
// any variable reference is unbound so the caller can defer observed
// resolution.
func evalFixtureExpr(expr interface{}, bindings map[string]float64) (float64, bool) {
	switch e := expr.(type) {
	case nil:
		return 0, false
	case float64:
		return e, true
	case int:
		return float64(e), true
	case string:
		v, ok := bindings[e]
		return v, ok
	case map[string]interface{}:
		opRaw, ok := e["op"].(string)
		if !ok {
			return 0, false
		}
		argsRaw, ok := e["args"].([]interface{})
		if !ok {
			return 0, false
		}
		args := make([]float64, len(argsRaw))
		for i, a := range argsRaw {
			v, ok := evalFixtureExpr(a, bindings)
			if !ok {
				return 0, false
			}
			args[i] = v
		}
		switch opRaw {
		case "+":
			sum := 0.0
			for _, v := range args {
				sum += v
			}
			return sum, true
		case "-":
			switch len(args) {
			case 1:
				return -args[0], true
			case 2:
				return args[0] - args[1], true
			default:
				panic(fmt.Sprintf("'-' needs 1 or 2 args, got %d", len(args)))
			}
		case "*":
			prod := 1.0
			for _, v := range args {
				prod *= v
			}
			return prod, true
		case "/":
			if len(args) != 2 {
				panic(fmt.Sprintf("'/' needs 2 args, got %d", len(args)))
			}
			return args[0] / args[1], true
		case "^", "**":
			if len(args) != 2 {
				panic(fmt.Sprintf("'^' needs 2 args, got %d", len(args)))
			}
			return math.Pow(args[0], args[1]), true
		case "log":
			return math.Log(args[0]), true
		case "exp":
			return math.Exp(args[0]), true
		case "sqrt":
			return math.Sqrt(args[0]), true
		case "sin":
			return math.Sin(args[0]), true
		case "cos":
			return math.Cos(args[0]), true
		case "tan":
			return math.Tan(args[0]), true
		case "abs":
			return math.Abs(args[0]), true
		default:
			panic(fmt.Sprintf("unsupported op: %q", opRaw))
		}
	default:
		return 0, false
	}
}

func resolveUnitsFixtureObserved(variables map[string]interface{}, bindings map[string]float64) {
	n := len(variables) + 1
	for i := 0; i < n; i++ {
		progress := false
		for vname, vraw := range variables {
			v, ok := vraw.(map[string]interface{})
			if !ok {
				continue
			}
			if v["type"] != "observed" {
				continue
			}
			if _, already := bindings[vname]; already {
				continue
			}
			expr, has := v["expression"]
			if !has {
				continue
			}
			val, ok := evalFixtureExpr(expr, bindings)
			if !ok {
				continue
			}
			bindings[vname] = val
			progress = true
		}
		if !progress {
			return
		}
	}
}

func buildUnitsFixtureBindings(
	variables map[string]interface{},
	initialConditions, parameterOverrides map[string]interface{},
) map[string]float64 {
	bindings := map[string]float64{}
	for vname, vraw := range variables {
		v, ok := vraw.(map[string]interface{})
		if !ok {
			continue
		}
		typ, _ := v["type"].(string)
		if typ != "parameter" && typ != "state" {
			continue
		}
		if d, ok := v["default"].(float64); ok {
			bindings[vname] = d
		}
	}
	for k, v := range initialConditions {
		if f, ok := v.(float64); ok {
			bindings[k] = f
		}
	}
	for k, v := range parameterOverrides {
		if f, ok := v.(float64); ok {
			bindings[k] = f
		}
	}
	return bindings
}

func mapOr(m map[string]interface{}, key string) map[string]interface{} {
	if v, ok := m[key].(map[string]interface{}); ok {
		return v
	}
	return nil
}

func checkUnitsFixtureAssertion(
	t *testing.T,
	label string,
	actual, expected, rel, abs float64,
) {
	t.Helper()
	diff := math.Abs(actual - expected)
	bound := abs
	if rel > 0 {
		relBound := rel * math.Max(math.Abs(expected), math.SmallestNonzeroFloat64)
		if relBound > bound {
			bound = relBound
		}
	}
	if !(diff <= bound) {
		t.Fatalf("%s: actual=%g expected=%g rel=%g abs=%g diff=%g",
			label, actual, expected, rel, abs, diff)
	}
}

func TestUnitsFixturesInlineTestsExecution(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	fixtures := []string{
		"units_conversions.esm",
		"units_dimensional_analysis.esm",
		"units_propagation.esm",
	}
	totalTests := 0
	for _, name := range fixtures {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(repoRoot, "tests", "valid", name)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			var doc map[string]interface{}
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatalf("unmarshal %s: %v", name, err)
			}
			models := mapOr(doc, "models")
			if len(models) == 0 {
				t.Fatalf("%s: no models", name)
			}
			fixtureTests := 0
			for mname, mraw := range models {
				model, ok := mraw.(map[string]interface{})
				if !ok {
					continue
				}
				testsRaw, _ := model["tests"].([]interface{})
				if len(testsRaw) == 0 {
					continue
				}
				variables := mapOr(model, "variables")
				modelTol := model["tolerance"]
				for _, tcRaw := range testsRaw {
					tc, ok := tcRaw.(map[string]interface{})
					if !ok {
						continue
					}
					id, _ := tc["id"].(string)
					ic := mapOr(tc, "initial_conditions")
					po := mapOr(tc, "parameter_overrides")
					bindings := buildUnitsFixtureBindings(variables, ic, po)
					resolveUnitsFixtureObserved(variables, bindings)

					assertionsRaw, _ := tc["assertions"].([]interface{})
					testTol := tc["tolerance"]
					subname := fmt.Sprintf("%s/%s", mname, id)
					t.Run(subname, func(t *testing.T) {
						for _, aRaw := range assertionsRaw {
							a, ok := aRaw.(map[string]interface{})
							if !ok {
								continue
							}
							variable, _ := a["variable"].(string)
							expected, _ := a["expected"].(float64)
							aTol := a["tolerance"]
							rel, abs := resolveUnitsFixtureTol(modelTol, testTol, aTol)
							actual, ok := bindings[variable]
							if !ok {
								t.Fatalf("%s::%s::%s: observed %q did not resolve (bindings=%v)",
									name, mname, id, variable, bindings)
							}
							label := fmt.Sprintf("%s::%s::%s::%s", name, mname, id, variable)
							checkUnitsFixtureAssertion(t, label, actual, expected, rel, abs)
						}
					})
					fixtureTests++
					totalTests++
				}
			}
			if fixtureTests == 0 {
				t.Fatalf("%s: expected at least one inline test across its models", name)
			}
		})
	}
	if totalTests == 0 {
		t.Fatalf("expected at least one inline test across the units fixtures")
	}
}
