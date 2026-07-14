package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// (h) The keystone contract
// ---------------------------------------------------------------------------

// exprNodeNonExpressionFields are the ExprNode fields that carry no child
// Expression at all — an op name, a `wrt`/`dim` axis, a binder symbol, a literal
// payload. mapExprChildren does not walk them and reference integrity has no
// business in them.
//
// Everything NOT in this list is expression-bearing and MUST be populated by
// fullyPopulatedExprNode below, which is what forces a newly-added field to be
// classified (see TestExprRefChildrenCoverTheKeystone).
var exprNodeNonExpressionFields = map[string]bool{
	"op": true, "wrt": true, "dim": true, "fn": true, "var": true,
	"name": true, "table": true, "manifold": true, "reduce": true,
	"semiring": true, "distinct": true, "label": true, "arg": true,
	"id": true, "expect_cadence": true,
	// Expression-TYPED but deliberately not walked by the keystone: `value` is a
	// const payload, `shape`/`perm`/`axis` are literal array metadata and
	// `output_idx` is a binder source (credited via boundIndexSymbols).
	"value": true, "shape": true, "perm": true, "axis": true, "output_idx": true,
}

// fullyPopulatedExprNode returns an ExprNode with EVERY expression-bearing field
// populated with a unique sentinel string, plus the map from sentinel → the
// JSON-Pointer field it was placed in.
func fullyPopulatedExprNode() (ExprNode, map[string]string) {
	where := map[string]string{}
	mark := func(sentinel, field string) Expression {
		where[sentinel] = field
		return sentinel
	}
	return ExprNode{
		Op:        "aggregate",
		Args:      []any{mark("s_args", "args")},
		Lower:     mark("s_lower", "lower"),
		Upper:     mark("s_upper", "upper"),
		Expr:      mark("s_expr", "expr"),
		Filter:    mark("s_filter", "filter"),
		Key:       mark("s_key", "key"),
		Values:    []any{mark("s_values", "values")},
		TableAxes: map[string]Expression{"a": mark("s_axes", "axes")},
		Bindings:  map[string]any{"b": mark("s_bindings", "bindings")},
		Output:    mark("s_output", "output"),
		Attrs:     map[string]any{"scheme": mark("s_attrs", "attrs")},
		Ranges:    map[string]any{"i": mark("s_ranges", "ranges")},
		Join:      []any{mark("s_join", "join")},
		Regions:   [][][]any{{{mark("s_regions", "regions")}}},
	}, where
}

// TestExprRefChildrenCoverTheKeystone pins the invariant that makes the
// sidecar-omission bug class unrepresentable:
//
//	{reference children} ∪ {declared non-reference slots} == {every child
//	                                                          mapExprChildren walks}
//
// Reference integrity walks exprRefChildren. If a field is expression-bearing and
// the keystone walks it, it is either a reference site (checked) or one of the
// five slots explicitly declared non-referential (esm-spec §4.5/§9.7.6). It
// CANNOT be silently skipped — which is exactly how an undefined name hiding in
// an aggregate `expr`, an integral bound, a `makearray` `values` entry or a
// `table_lookup` axis stayed invisible to the validator.
//
// Adding a new expression-bearing field to ExprNode fails this test until the
// author classifies it, because the field-coverage check below requires
// fullyPopulatedExprNode to populate it.
func TestExprRefChildrenCoverTheKeystone(t *testing.T) {
	node, where := fullyPopulatedExprNode()

	// Every expression-bearing ExprNode field must be exercised by the test node,
	// so that a new field cannot slip past the classification below.
	populated := map[string]bool{}
	for _, field := range where {
		populated[field] = true
	}
	typ := reflect.TypeOf(ExprNode{})
	for i := 0; i < typ.NumField(); i++ {
		name := strings.Split(typ.Field(i).Tag.Get("json"), ",")[0]
		if name == "" || exprNodeNonExpressionFields[name] {
			continue
		}
		if !populated[name] {
			t.Errorf("ExprNode field %q is expression-bearing but fullyPopulatedExprNode does not "+
				"populate it: classify it as a reference child (exprRefChildren) or a non-reference "+
				"slot (exprRefNonRefSlots), then populate it here", name)
		}
	}

	// What the KEYSTONE walks.
	keystone := map[string]bool{}
	if _, err := mapExprChildren(node, func(child Expression) (Expression, error) {
		if s, ok := child.(string); ok {
			keystone[where[s]] = true
		}
		return child, nil
	}); err != nil {
		t.Fatalf("mapExprChildren: %v", err)
	}

	// What REFERENCE INTEGRITY walks.
	refs := map[string]bool{}
	for _, child := range exprRefChildren(node) {
		s, ok := child.Child.(string)
		if !ok {
			continue
		}
		refs[where[s]] = true
	}

	// The declared non-reference slots.
	nonRef := map[string]bool{}
	for _, slot := range exprRefNonRefSlots {
		nonRef[slot] = true
	}

	for field := range keystone {
		if refs[field] == nonRef[field] { // in both, or in neither
			t.Errorf("field %q is walked by mapExprChildren but is not classified exactly once: "+
				"reference child=%v, non-reference slot=%v", field, refs[field], nonRef[field])
		}
	}
	for field := range refs {
		if !keystone[field] {
			t.Errorf("exprRefChildren walks %q, which the keystone does not — it cannot be a child", field)
		}
	}
	for slot := range nonRef {
		if !keystone[slot] {
			t.Errorf("exprRefNonRefSlots declares %q, which the keystone does not walk — stale entry", slot)
		}
	}
}

// TestExprRefChildrenTagsPointerPaths pins that each reference child is tagged
// with the JSON-Pointer segment of the field it came from, so a diagnostic names
// the sidecar the bad reference actually lives in (".../rhs/expr/args/1") rather
// than the node as a whole.
func TestExprRefChildrenTagsPointerPaths(t *testing.T) {
	node := ExprNode{
		Op:        "aggregate",
		Args:      []any{"a0"},
		Expr:      "e",
		Lower:     "lo",
		TableAxes: map[string]Expression{"lat": "ax"},
		Values:    []any{"v0", "v1"},
	}
	got := map[string]string{}
	for _, child := range exprRefChildren(node) {
		got[child.Path] = child.Child.(string)
	}
	want := map[string]string{
		"/args/0": "a0", "/expr": "e", "/lower": "lo",
		"/axes/lat": "ax", "/values/0": "v0", "/values/1": "v1",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("exprRefChildren paths = %v; want %v", got, want)
	}
}

// ---------------------------------------------------------------------------
// (h) Every reference-bearing ENTRY POINT is actually entered
// ---------------------------------------------------------------------------

// TestInvalidCorpusStructuralPins sweeps EVERY fixture in tests/invalid that
// pins structural errors and asserts the Go validator actually rejects it with
// the pinned code, at the pinned path.
//
// No such sweep existed. The Go suite pinned invalid fixtures only in scattered,
// hand-picked tests, so a fixture could be added to the shared corpus — or a
// whole class of reference site could go unchecked — while the suite stayed
// green. That is how eleven reference-bearing sites (observed `expression`,
// `guesses`, `initialization_equations`, event triggers/conditions/affects,
// assertion `reference`, data-loader `unit_conversion`, connector `expression`
// and `variable_map` `transform`) were reachable by a typo'd variable name and
// silently accepted.
func TestInvalidCorpusStructuralPins(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	invalidDir := filepath.Join(repoRoot, "tests", "invalid")

	raw, err := os.ReadFile(filepath.Join(invalidDir, "expected_errors.json"))
	if err != nil {
		t.Fatalf("read expected_errors.json: %v", err)
	}
	var expected map[string]struct {
		StructuralErrors []struct {
			Path string `json:"path"`
			Code string `json:"code"`
		} `json:"structural_errors"`
		ResolverOnly bool `json:"resolver_only"`
	}
	if err := json.Unmarshal(raw, &expected); err != nil {
		t.Fatalf("parse expected_errors.json: %v", err)
	}

	names := make([]string, 0, len(expected))
	for name := range expected {
		names = append(names, name)
	}
	sort.Strings(names)

	swept := 0
	for _, name := range names {
		entry := expected[name]
		// resolver_only fixtures are rejected at LOAD by the §9.7 resolver and are
		// pinned by TestTemplateImports; they are not structural-scan findings.
		if len(entry.StructuralErrors) == 0 || entry.ResolverOnly {
			continue
		}
		path := filepath.Join(invalidDir, name)
		if _, err := os.Stat(path); err != nil {
			continue // fixture lives in a subdirectory with its own harness
		}
		swept++

		t.Run(name, func(t *testing.T) {
			file, loadErr := Load(path)
			gotCodes := map[string]bool{}
			gotPaths := []string{}
			if loadErr == nil {
				res := ValidateStructuralWithCodes(file)
				if res.Valid {
					t.Fatalf("fixture is pinned INVALID but the validator ACCEPTED it "+
						"(pinned: %v)", entry.StructuralErrors)
				}
				for _, e := range res.StructuralErrors {
					gotCodes[e.Code] = true
					gotPaths = append(gotPaths, e.Path)
				}
			}

			for _, want := range entry.StructuralErrors {
				// Some fixtures (an ambiguous / missing subsystem ref) are rejected by
				// the resolver during Load, before the structural scan runs at all. A
				// rejection is a rejection — assert the pinned code is the one raised.
				if loadErr != nil {
					if !loadErrHasCode(loadErr, want.Code) {
						t.Errorf("rejected at load, but not with pinned code %q: %v", want.Code, loadErr)
					}
					continue
				}
				if !gotCodes[want.Code] {
					t.Errorf("pinned code %q not produced; got %v", want.Code, sortedSet(gotCodes))
					continue
				}
				if loadErr != nil {
					continue
				}
				if !anyPathMatches(gotPaths, want.Path) {
					t.Errorf("pinned code %q produced, but at none of the pinned path %q; got paths %v",
						want.Code, want.Path, gotPaths)
				}
			}
		})
	}

	// A guard against the sweep silently becoming a no-op (the failure mode this
	// whole test exists to prevent): the corpus pins dozens of structural fixtures.
	if swept < 50 {
		t.Fatalf("swept only %d structurally-pinned invalid fixtures; the corpus has far more — "+
			"the sweep is not reaching the fixtures", swept)
	}
}

// anyPathMatches reports whether some produced path is the pinned path or sits
// beneath it — a diagnostic may legitimately point DEEPER than the pin (the pin
// names the equation, the validator names the offending argument inside it).
func anyPathMatches(got []string, want string) bool {
	for _, p := range got {
		if p == want || strings.HasPrefix(p, strings.TrimSuffix(want, "/")+"/") || strings.HasPrefix(want, p) {
			return true
		}
	}
	return false
}

func sortedSet(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// loadErrHasCode reports whether a Load error carries the given stable
// diagnostic code. The subsystem resolver embeds its code in the message as a
// bracketed token ("[ambiguous_subsystem_ref] referenced file …"), so a
// containment check on that token is the stable way to read it.
func loadErrHasCode(err error, code string) bool {
	type coder interface{ Code() string }
	if c, ok := err.(coder); ok {
		return c.Code() == code
	}
	return strings.Contains(err.Error(), "["+code+"]")
}

// ---------------------------------------------------------------------------
// Reaction-system reference sites (no shared fixture pins these)
// ---------------------------------------------------------------------------

// TestReactionSystemReferenceSites pins the two reaction-system reference sites
// that reference integrity never entered: `constraint_equations` and the event
// blocks. A reaction system was reference-checked through `reaction.rate` and
// nowhere else, so an undeclared species in a constraint equation or an event
// was accepted silently. An undeclared bare name in a reaction system is an
// `undefined_parameter` (the code the shared corpus pins for this component
// kind).
func TestReactionSystemReferenceSites(t *testing.T) {
	const tmpl = `{
	  "esm": "0.1.0",
	  "metadata": {"name": "RefSites", "description": "reaction-system reference sites"},
	  "reaction_systems": {
	    "Chem": {
	      "species": {"A": {"units": "mol/m^3", "default": 1.0}},
	      "parameters": {"k": {"units": "1/s", "default": 1.0}},
	      "reactions": [
	        {"substrates": [{"species": "A", "stoichiometry": 1}],
	         "products": [],
	         "rate": {"op": "*", "args": ["k", "A"]}}
	      ],
	      %s
	    }
	  }
	}`

	cases := []struct {
		name  string
		block string
		path  string
	}{
		{
			name:  "constraint_equations",
			block: `"constraint_equations": [{"lhs": "A", "rhs": {"op": "*", "args": ["k", "undefined_xyz"]}}]`,
			path:  "/reaction_systems/Chem/constraint_equations/0/rhs",
		},
		{
			name: "discrete_event_trigger",
			block: `"discrete_events": [{"trigger": {"type": "condition", "expression": {"op": ">", "args": ["undefined_xyz", 1.0]}},
			         "affects": [{"lhs": "A", "rhs": 0.0}]}]`,
			path: "/reaction_systems/Chem/discrete_events/0/trigger/expression",
		},
		{
			name: "discrete_event_affect",
			block: `"discrete_events": [{"trigger": {"type": "condition", "expression": {"op": ">", "args": ["A", 1.0]}},
			         "affects": [{"lhs": "A", "rhs": {"op": "*", "args": ["k", "undefined_xyz"]}}]}]`,
			path: "/reaction_systems/Chem/discrete_events/0/affects/0/rhs",
		},
		{
			name: "continuous_event_condition",
			block: `"continuous_events": [{"conditions": [{"op": "-", "args": ["undefined_xyz", 1.0]}],
			         "affects": [{"lhs": "A", "rhs": 0.0}]}]`,
			path: "/reaction_systems/Chem/continuous_events/0/conditions/0",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var file ESMFile
			doc := strings.Replace(tmpl, "%s", tc.block, 1)
			if err := json.Unmarshal([]byte(doc), &file); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			res := ValidateStructuralWithCodes(&file)
			if res.Valid {
				t.Fatalf("undefined name in reaction-system %s was ACCEPTED", tc.name)
			}
			found := false
			for _, e := range res.StructuralErrors {
				if e.Code == ErrorUndefinedParameter && strings.HasPrefix(e.Path, tc.path) {
					found = true
				}
			}
			if !found {
				t.Errorf("want %s at %s; got %v", ErrorUndefinedParameter, tc.path, res.StructuralErrors)
			}
		})
	}

	// A well-formed reaction system with the SAME shapes must still be accepted —
	// the check must reject undefined names, not the constructs themselves.
	t.Run("valid_constructs_still_accepted", func(t *testing.T) {
		block := `"constraint_equations": [{"lhs": "A", "rhs": {"op": "*", "args": ["k", "A"]}}],
		          "discrete_events": [{"trigger": {"type": "condition", "expression": {"op": ">", "args": ["A", 1.0]}},
		                               "affects": [{"lhs": "A", "rhs": {"op": "*", "args": ["k", "A"]}}]}]`
		var file ESMFile
		if err := json.Unmarshal([]byte(strings.Replace(tmpl, "%s", block, 1)), &file); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		for _, e := range ValidateStructuralWithCodes(&file).StructuralErrors {
			if e.Code == ErrorUndefinedParameter || e.Code == ErrorUndefinedVariable {
				t.Errorf("false positive on a valid reaction system: %+v", e)
			}
		}
	})
}

// TestCallbackVariablesAreADeclarationSite pins conformance row (k): a name
// injected by a CALLBACK coupling is DECLARED, and referencing it is not an
// error.
//
// `coupling[i].config.callback_variables[j].name` is a declaration site
// (esm-spec §4.9.5) that lives outside `models[M].variables`. Reference
// integrity that knows only about the variables block rejects
// tests/coupling/callback_examples.esm, whose WeatherModel equations reference
// the injected `external_temperature_forcing` — a false positive, and a strictly
// worse outcome than the false negative it was meant to fix.
func TestCallbackVariablesAreADeclarationSite(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "coupling", "callback_examples.esm")
	file, err := Load(path)
	if err != nil {
		t.Fatalf("load callback_examples.esm: %v", err)
	}
	for _, e := range ValidateStructuralWithCodes(file).StructuralErrors {
		if e.Code == ErrorUndefinedVariable || e.Code == ErrorUndefinedParameter {
			t.Errorf("callback-injected name reported as undefined: %s at %s (details=%v)",
				e.Message, e.Path, e.Details)
		}
	}

	// …and the credit is SCOPED to the callback's target_system: a model that is
	// not the target does not silently gain the injected name.
	const doc = `{
	  "esm": "0.1.0",
	  "metadata": {"name": "CallbackScope", "description": "callback credit is target-scoped"},
	  "models": {
	    "Target":  {"variables": {"y": {"type": "state", "units": "1", "default": 0.0}},
	                "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": "injected"}]},
	    "Bystander": {"variables": {"z": {"type": "state", "units": "1", "default": 0.0}},
	                "equations": [{"lhs": {"op": "D", "args": ["z"], "wrt": "t"}, "rhs": "injected"}]}
	  },
	  "coupling": [
	    {"type": "callback", "callback_id": "CB",
	     "config": {"target_system": "Target",
	                "callback_variables": [{"name": "injected", "units": "1/s"}]}}
	  ]
	}`
	var file2 ESMFile
	if err := json.Unmarshal([]byte(doc), &file2); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	var targetErrs, bystanderErrs int
	for _, e := range ValidateStructuralWithCodes(&file2).StructuralErrors {
		if e.Code != ErrorUndefinedVariable {
			continue
		}
		if strings.HasPrefix(e.Path, "/models/Target/") {
			targetErrs++
		}
		if strings.HasPrefix(e.Path, "/models/Bystander/") {
			bystanderErrs++
		}
	}
	if targetErrs != 0 {
		t.Errorf("target_system did not receive the injected name (%d undefined-variable errors)", targetErrs)
	}
	if bystanderErrs == 0 {
		t.Error("a NON-target model silently gained the injected name; the credit must be target-scoped")
	}
}
