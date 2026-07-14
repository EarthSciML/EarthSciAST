package esm

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This file pins the Go findings of audits/bug_audit_2026-07-14.md.
//
// The common root cause of the walker cluster (G1–G5, G11, G15) is that a
// hand-rolled traversal only looked at `args`, so every expression-bearing
// SIDECAR field (`expr`, `axes`, `lower`, `upper`, `filter`, `key`, `values`,
// `bindings`, `join`, …) was invisible to it. Each test below reaches a
// reference through a sidecar and asserts the pass sees it. They are written
// against the shapes a real document produces — i.e. built by DECODING JSON,
// not by hand-assembling an ExprNode — because part of the bug was that decode
// left sidecar subtrees as raw map[string]any.

// sidecarAggregateJSON is `aggregate(reduce:+, expr: index(w,i) * y)` — the
// reference to `y` lives in the `expr` sidecar, not in `args`.
const sidecarAggregateJSON = `{"op":"aggregate","args":[],"reduce":"+","output_idx":[],` +
	`"ranges":{"i":[1,3]},"expr":{"op":"*","args":[{"op":"index","args":["w","i"]},"y"]}}`

// --- G1: the shared walk sees names reachable only through a sidecar ---------

func TestAuditG1_FreeVariablesSeesSidecarFields(t *testing.T) {
	expr, err := UnmarshalExpression([]byte(sidecarAggregateJSON))
	if err != nil {
		t.Fatal(err)
	}
	vars := FreeVariables(expr)
	for _, want := range []string{"w", "i", "y"} {
		if !vars[want] {
			t.Errorf("FreeVariables missed %q (reachable only via the `expr` sidecar); got %v", want, vars)
		}
	}
	if !Contains(expr, "y") {
		t.Error("Contains(expr, \"y\") = false; `y` is referenced inside the aggregate body")
	}
}

// --- G2: the DAE contract must not delete a still-referenced equation --------

// TestAuditG2_DAEContractNoDanglingReference is the model-corruption guard.
//
// `y ~ a*2.0` is a trivial algebraic equation, so the DAE contract factors it
// out: it substitutes y's body into every other equation and DELETES y's
// defining equation. The other equation references `y` only from inside an
// aggregate's `expr` sidecar. When the substitution could not reach that field,
// the equation was deleted anyway and the survivor went on citing a variable
// that no longer had a definition — a corrupt model, returned with err == nil.
//
// The assertion is made on the SERIALIZED survivor rather than via
// FreeVariables, so it cannot pass vacuously if the walker regressed.
func TestAuditG2_DAEContractNoDanglingReference(t *testing.T) {
	src := `{
	  "esm":"0.2.0",
	  "metadata":{"name":"g2"},
	  "models":{"M":{
	    "variables":{
	      "z":{"type":"state","default":0.0},
	      "a":{"type":"parameter","default":2.0},
	      "w":{"type":"parameter","default":1.0},
	      "y":{"type":"observed","expression":{"op":"*","args":["a",2.0]}}
	    },
	    "equations":[
	      {"lhs":"y","rhs":{"op":"*","args":["a",2.0]}},
	      {"lhs":{"op":"D","args":["z"],"wrt":"t"},"rhs":` + sidecarAggregateJSON + `}
	    ]}}}`

	file, err := LoadString(src)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ApplyDAEContract(file); err != nil {
		t.Fatalf("ApplyDAEContract: %v", err)
	}

	eqs := file.Models["M"].Equations
	if len(eqs) != 1 {
		t.Fatalf("expected the trivial equation for `y` to be factored out, leaving 1 equation; got %d", len(eqs))
	}
	rhs, err := SerializeExpression(eqs[0].RHS)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(rhs, `"y"`) {
		t.Errorf("MODEL CORRUPTION: `y` is still referenced by the surviving equation after its "+
			"defining equation was deleted.\nsurviving RHS: %s", rhs)
	}
	if !strings.Contains(rhs, `"a"`) {
		t.Errorf("expected `y` to be replaced by its body (a*2.0) inside the aggregate `expr`; "+
			"`a` is absent.\nsurviving RHS: %s", rhs)
	}
}

// --- G3: Substitute reaches into sidecar fields ------------------------------

func TestAuditG3_SubstituteReachesSidecar(t *testing.T) {
	expr, err := UnmarshalExpression([]byte(sidecarAggregateJSON))
	if err != nil {
		t.Fatal(err)
	}
	out, err := Substitute(expr, map[string]Expression{"y": 99.0})
	if err != nil {
		t.Fatalf("Substitute: %v", err)
	}
	got, err := SerializeExpression(out)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got, `"y"`) {
		t.Errorf("Substitute left `y` unsubstituted inside the `expr` sidecar: %s", got)
	}
	if !strings.Contains(got, "99") {
		t.Errorf("Substitute did not write the bound value into the `expr` sidecar: %s", got)
	}
}

// --- G4: Flatten must not drop non-`args` fields on rebuild ------------------

// The rebuild used to spell `ExprNode{Op, Args, Wrt, Dim}`, silently destroying
// every other field — an event affect calling the closed-registry function
// `datetime.year` came out of Flatten with its `name` GONE, i.e. an unnamed
// function call.
func TestAuditG4_FlattenPreservesFnName(t *testing.T) {
	src := `{
	  "esm":"0.2.0",
	  "metadata":{"name":"g4"},
	  "models":{"M":{
	    "variables":{
	      "x":{"type":"state","default":0.0},
	      "t_utc":{"type":"parameter","default":0.0},
	      "yr":{"type":"parameter","default":0.0}
	    },
	    "equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":1.0}],
	    "discrete_events":[{
	      "trigger":{"type":"periodic","interval":1.0},
	      "affects":[{"lhs":"yr","rhs":{"op":"fn","name":"datetime.year","args":["t_utc"]}}]
	    }]}}}`

	file, err := LoadString(src)
	if err != nil {
		t.Fatal(err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}
	if len(flat.Events) == 0 {
		t.Fatal("expected the discrete event to survive Flatten")
	}
	ev, ok := flat.Events[0].(DiscreteEvent)
	if !ok {
		t.Fatalf("flattened event has unexpected type %T", flat.Events[0])
	}
	if len(ev.Affects) == 0 {
		t.Fatal("expected the affect to survive Flatten")
	}
	rhs, err := SerializeExpression(ev.Affects[0].RHS)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rhs, "datetime.year") {
		t.Errorf("Flatten dropped the `fn` node's `name`, leaving an unnamed function call: %s", rhs)
	}
	if !strings.Contains(rhs, "M.t_utc") {
		t.Errorf("Flatten failed to namespace the fn argument: %s", rhs)
	}
}

// --- G5: operator_compose flatten must be deterministic ----------------------

// operatorComposeSwapFile builds the pathological case: a translate map whose
// two entries swap names ("A.q" -> "B.r" and "B.r" -> "A.q"). Applying the
// entries one at a time, in Go's randomized map order, let the renames CHAIN,
// so flattening the same file twice could produce different systems.
func operatorComposeSwapFile(t *testing.T) *ESMFile {
	t.Helper()
	src := `{
	  "esm":"0.2.0",
	  "metadata":{"name":"g5"},
	  "models":{
	    "A":{"variables":{"x":{"type":"state","default":0.0},"q":{"type":"parameter","default":1.0}},
	         "equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":{"op":"+","args":["q","q"]}}]},
	    "B":{"variables":{"y":{"type":"state","default":0.0},"r":{"type":"parameter","default":2.0}},
	         "equations":[{"lhs":{"op":"D","args":["y"],"wrt":"t"},"rhs":"r"}]}
	  },
	  "coupling":[{"type":"operator_compose","systems":["A","B"],
	               "translate":{"A.q":"B.r","B.r":"A.q"}}]}`
	file, err := LoadString(src)
	if err != nil {
		t.Fatal(err)
	}
	return file
}

// TestAuditG5_OperatorComposeIsDeterministic flattens the same document many
// times and requires byte-identical output every time. A single pass proves
// nothing about a randomized map order, so this repeats in-process; the suite is
// additionally run with -count>1 in CI.
func TestAuditG5_OperatorComposeIsDeterministic(t *testing.T) {
	var want []FlattenedEquation
	for iter := 0; iter < 200; iter++ {
		flat, err := Flatten(operatorComposeSwapFile(t))
		if err != nil {
			t.Fatalf("Flatten: %v", err)
		}
		if iter == 0 {
			want = flat.Equations
			continue
		}
		if len(flat.Equations) != len(want) {
			t.Fatalf("iteration %d: equation count %d != %d", iter, len(flat.Equations), len(want))
		}
		for i := range want {
			if flat.Equations[i] != want[i] {
				t.Fatalf("NON-DETERMINISTIC flatten at iteration %d, equation %d:\n first run: %+v\n this run: %+v",
					iter, i, want[i], flat.Equations[i])
			}
		}
	}
}

// TestAuditG5_RenamesDoNotChain pins the semantics the determinism rests on: the
// translate map is a SIMULTANEOUS substitution, so a value written out by one
// rename is never re-read as the key of another.
func TestAuditG5_RenamesDoNotChain(t *testing.T) {
	got := replaceVarTokens("A.q + B.r", map[string]string{"A.q": "B.r", "B.r": "A.q"})
	if want := "B.r + A.q"; got != want {
		t.Errorf("replaceVarTokens swap = %q, want %q (renames must not chain)", got, want)
	}
	// Token boundaries: "A.x" must not corrupt "A.x2" or "BA.x".
	if got := replaceVarTokens("A.x2 + BA.x + A.x", map[string]string{"A.x": "Z"}); got != "A.x2 + BA.x + Z" {
		t.Errorf("replaceVarTokens is not token-aware: %q", got)
	}
}

// --- G6: the closed comparison / boolean tier is evaluable -------------------

func TestAuditG6_ComparisonAndBooleanTier(t *testing.T) {
	bindings := map[string]float64{"x": 2, "y": 5}
	cases := []struct {
		src  string
		want float64
	}{
		{`{"op":"<","args":["x","y"]}`, 1},
		{`{"op":">","args":["x","y"]}`, 0},
		{`{"op":">=","args":["x",2]}`, 1},
		{`{"op":"<=","args":["y",2]}`, 0},
		{`{"op":"==","args":["x",2]}`, 1},
		{`{"op":"!=","args":["x",2]}`, 0},
		{`{"op":"not","args":[{"op":">","args":["x","y"]}]}`, 1},
		{`{"op":"and","args":[{"op":"<","args":["x","y"]},{"op":"==","args":["x",2]}]}`, 1},
		{`{"op":"or","args":[{"op":">","args":["x","y"]},{"op":"==","args":["x",2]}]}`, 1},
		{`{"op":"ifelse","args":[{"op":"<","args":["x","y"]},10,20]}`, 10},
		{`{"op":"true","args":[]}`, 1},
		{`{"op":"Pre","args":["x"]}`, 2},
	}
	for _, tc := range cases {
		expr, err := UnmarshalExpression([]byte(tc.src))
		if err != nil {
			t.Fatalf("%s: %v", tc.src, err)
		}
		got, err := Evaluate(expr, bindings)
		if err != nil {
			t.Errorf("%s: Evaluate returned error %v (the closed comparison/boolean tier must be evaluable)", tc.src, err)
			continue
		}
		if got != tc.want {
			t.Errorf("%s = %v, want %v", tc.src, got, tc.want)
		}
	}
}

// TestAuditG6_ShortCircuitGuardsDomainErrors pins the canonical guard idiom: the
// untaken branch of an `ifelse`, and the operand an `and`/`or` short-circuits
// past, MUST NOT be evaluated — otherwise the domain error the expression exists
// to guard against is raised anyway.
func TestAuditG6_ShortCircuitGuardsDomainErrors(t *testing.T) {
	cases := []struct {
		name string
		src  string
		vars map[string]float64
		want float64
	}{
		{
			name: "ifelse guards log of a non-positive value",
			src:  `{"op":"ifelse","args":[{"op":">","args":["x",0]},{"op":"log","args":["x"]},0]}`,
			vars: map[string]float64{"x": -1},
			want: 0,
		},
		{
			name: "ifelse guards division by zero",
			src:  `{"op":"ifelse","args":[{"op":"!=","args":["x",0]},{"op":"/","args":[1,"x"]},0]}`,
			vars: map[string]float64{"x": 0},
			want: 0,
		},
		{
			name: "or short-circuits past an unbound variable",
			src:  `{"op":"or","args":[{"op":"==","args":["x",1]},"unbound"]}`,
			vars: map[string]float64{"x": 1},
			want: 1,
		},
		{
			name: "and short-circuits past an unbound variable",
			src:  `{"op":"and","args":[{"op":"==","args":["x",0]},"unbound"]}`,
			vars: map[string]float64{"x": 1},
			want: 0,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			expr, err := UnmarshalExpression([]byte(tc.src))
			if err != nil {
				t.Fatal(err)
			}
			got, err := Evaluate(expr, tc.vars)
			if err != nil {
				t.Fatalf("Evaluate raised %v; the untaken branch must not be evaluated", err)
			}
			if got != tc.want {
				t.Errorf("Evaluate = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestAuditG6_UnloweredOperatorCode pins the spec code an OPEN rewrite-target op
// gets when it reaches evaluation, rather than an untyped "unknown operation".
func TestAuditG6_UnloweredOperatorCode(t *testing.T) {
	expr, err := UnmarshalExpression([]byte(`{"op":"godunov_hamiltonian","args":["x"]}`))
	if err != nil {
		t.Fatal(err)
	}
	_, err = Evaluate(expr, map[string]float64{"x": 1})
	if err == nil {
		t.Fatal("expected an error for an unlowered rewrite-target operator")
	}
	var evalErr *EvaluationError
	if !errors.As(err, &evalErr) {
		t.Fatalf("error is %T, want *EvaluationError with a spec-pinned code", err)
	}
	if evalErr.DiagnosticCode() != "unlowered_operator" {
		t.Errorf("DiagnosticCode = %q, want \"unlowered_operator\"", evalErr.DiagnosticCode())
	}
}

// --- G7: data loaders are a scopable namespace and a coupling endpoint -------

func TestAuditG7_LoaderScopedReferencesResolve(t *testing.T) {
	src := `{
	  "esm":"0.2.0",
	  "metadata":{"name":"g7"},
	  "models":{"Transport":{
	    "variables":{"c":{"type":"state","default":0.0},"u":{"type":"parameter","default":0.0}},
	    "equations":[{"lhs":{"op":"D","args":["c"],"wrt":"t"},
	                  "rhs":{"op":"*","args":["GEOSFP_MeteoData.u","c"]}}]}},
	  "data_loaders":{"GEOSFP_MeteoData":{
	    "kind":"grid",
	    "source":{"url_template":"file:///data/GEOSFP/{date:%Y%m%d}.nc"},
	    "variables":{"u":{"file_variable":"u","units":"m/s"}}}},
	  "coupling":[{"type":"variable_map","from":"GEOSFP_MeteoData.u","to":"Transport.u",
	               "transform":"param_to_var"}]}`

	file, err := LoadString(src)
	if err != nil {
		t.Fatal(err)
	}
	res := ValidateFile(file, src)
	for _, se := range res.StructuralErrors {
		if se.Level == "warning" {
			continue
		}
		switch se.Code {
		case ErrorUnresolvedScopedRef, ErrorUndefinedSystem:
			t.Errorf("a data loader is a legal scoped namespace and coupling endpoint, but got [%s] %s @%s",
				se.Code, se.Message, se.Path)
		}
	}
}

// --- G8: `id` and `expect_cadence` round-trip -------------------------------

// `id` is the referent of a derived index set (`index_sets.<x>.from_faq`), so
// dropping it on a round-trip breaks that linkage.
func TestAuditG8_IDAndExpectCadenceRoundTrip(t *testing.T) {
	const src = `{"op":"*","args":["a",2.0],"id":"my_node_id","expect_cadence":"const"}`
	expr, err := UnmarshalExpression([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	node, ok := expr.(ExprNode)
	if !ok {
		t.Fatalf("decoded expression is %T, want ExprNode", expr)
	}
	if node.ID == nil || *node.ID != "my_node_id" {
		t.Errorf("ExprNode.ID = %v, want \"my_node_id\"", node.ID)
	}
	if node.ExpectCadence == nil || *node.ExpectCadence != "const" {
		t.Errorf("ExprNode.ExpectCadence = %v, want \"const\"", node.ExpectCadence)
	}
	out, err := SerializeExpression(expr)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "my_node_id") {
		t.Errorf("Serialize silently dropped `id`: %s", out)
	}
	if !strings.Contains(out, "expect_cadence") {
		t.Errorf("Serialize silently dropped `expect_cadence`: %s", out)
	}
}

// --- G9: the canonical emitter's field gate is an allow-list ----------------

// The gate used to be a hand-maintained DENY-list that omitted `label`, so a
// skolem node's relation tag was silently dropped from the canonical JSON
// instead of being rejected. It is now derived from the struct by reflection, so
// it fails closed.
func TestAuditG9_CanonicalRejectsNonEmissibleLabel(t *testing.T) {
	expr, err := UnmarshalExpression([]byte(`{"op":"skolem","args":["a","b"],"label":"edge"}`))
	if err != nil {
		t.Fatal(err)
	}
	out, err := CanonicalJSON(expr)
	if err == nil {
		t.Fatalf("CanonicalJSON silently dropped `label` and emitted %s; want ErrCanonicalUnsupportedField", out)
	}
	if !errors.Is(err, ErrCanonicalUnsupportedField) {
		t.Errorf("error = %v, want ErrCanonicalUnsupportedField", err)
	}
}

// TestAuditG9_GateSurvivesTheAlgebraicRewrites closes the other half of G9.
//
// The algebraic rewrites (canonAdd/canonMul/canonNeg) rebuild their node from
// scratch and drop every non-`args` field. When the emissibility gate ran only
// on the REWRITTEN tree, a non-emissible field on a `+`/`*`/`neg` node was
// silently dropped before the gate could ever see it — so the fail-closed gate
// was a fiction for exactly the most common operators. The gate now screens the
// input tree, so a `label` is rejected wherever it appears, not just on the ops
// that happen to survive canonicalization unrewritten.
func TestAuditG9_GateSurvivesTheAlgebraicRewrites(t *testing.T) {
	for _, src := range []string{
		`{"op":"*","args":["a",2.0],"label":"edge"}`,
		`{"op":"+","args":["a",0],"label":"edge"}`,
		`{"op":"neg","args":["a"],"label":"edge"}`,
	} {
		expr, err := UnmarshalExpression([]byte(src))
		if err != nil {
			t.Fatal(err)
		}
		out, err := CanonicalJSON(expr)
		if err == nil {
			t.Errorf("%s: CanonicalJSON silently dropped `label` and emitted %s; want a rejection", src, out)
			continue
		}
		if !errors.Is(err, ErrCanonicalUnsupportedField) {
			t.Errorf("%s: error = %v, want ErrCanonicalUnsupportedField", src, err)
		}
	}
}

// TestAuditG9_InertAnnotationsAreIgnoredNotRejected pins the flip side: `id` and
// `expect_cadence` are semantically INERT annotations that appear on ordinary
// documents (tests/valid/cadence/*.esm), so the canonical form drops them rather
// than refusing to canonicalize the file. They round-trip through Serialize
// (G8); they simply are not part of the value the canonical key denotes.
func TestAuditG9_InertAnnotationsAreIgnoredNotRejected(t *testing.T) {
	expr, err := UnmarshalExpression([]byte(
		`{"op":"*","args":["a",2.0],"id":"my_node_id","expect_cadence":"const"}`))
	if err != nil {
		t.Fatal(err)
	}
	out, err := CanonicalJSON(expr)
	if err != nil {
		t.Fatalf("CanonicalJSON rejected a node carrying only inert annotations: %v", err)
	}
	got := string(out)
	if strings.Contains(got, "my_node_id") || strings.Contains(got, "expect_cadence") {
		t.Errorf("inert annotations must not appear in the canonical encoding: %s", got)
	}
}

// --- G11: the dependency graph sees edges through sidecar fields -------------

func TestAuditG11_GraphWalkSeesSidecarFields(t *testing.T) {
	expr, err := UnmarshalExpression([]byte(sidecarAggregateJSON))
	if err != nil {
		t.Fatal(err)
	}
	got := extractVariablesFromExpression(expr)
	seen := make(map[string]bool, len(got))
	for _, v := range got {
		seen[v] = true
	}
	for _, want := range []string{"w", "i", "y"} {
		if !seen[want] {
			t.Errorf("the dependency-graph walk missed %q, so its edge vanishes silently; got %v", want, got)
		}
	}
}

// --- G12: a metaparameter must never rewrite the `op` slot -------------------

// With `max` bound as a metaparameter, {"op":"max", …} used to become
// {"op":3, …} and the document died in LoadString with a raw unmarshal error.
func TestAuditG12_MetaparamDoesNotRewriteOpSlot(t *testing.T) {
	src := `{
	  "esm":"0.8.0",
	  "metadata":{"name":"g12"},
	  "metaparameters":{"max":{"type":"integer","default":3}},
	  "models":{"M":{
	    "variables":{"x":{"type":"state","default":0.0},"k":{"type":"parameter","default":1.0}},
	    "equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},
	                  "rhs":{"op":"max","args":["k",0.0]}}]}}}`

	file, err := LoadString(src, WithMetaparameters(map[string]int64{"max": 3}))
	if err != nil {
		t.Fatalf("a metaparameter sharing a name with an operator must not corrupt the `op` slot: %v", err)
	}
	rhs, err := SerializeExpression(file.Models["M"].Equations[0].RHS)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rhs, `"op": "max"`) && !strings.Contains(rhs, `"op":"max"`) {
		t.Errorf("the `op` slot was rewritten by the metaparameter binding: %s", rhs)
	}
}

// --- G13: text splices must be precedence- and token-safe -------------------

// A `factor` was spliced as UNPARENTHESIZED text, so substituting `A.x -> 2*B.y`
// into `A.x^2` produced `2*B.y^2`, which re-parses as `2*(B.y^2)` when the
// correct reading is `(2*B.y)^2`.
func TestAuditG13_VariableMapFactorIsParenthesized(t *testing.T) {
	src := `{
	  "esm":"0.2.0",
	  "metadata":{"name":"g13"},
	  "models":{
	    "A":{"variables":{"p":{"type":"state","default":0.0},"x":{"type":"parameter","default":1.0}},
	         "equations":[{"lhs":{"op":"D","args":["p"],"wrt":"t"},
	                       "rhs":{"op":"^","args":["x",2.0]}}]},
	    "B":{"variables":{"q":{"type":"state","default":0.0},"y":{"type":"parameter","default":1.0}},
	         "equations":[{"lhs":{"op":"D","args":["q"],"wrt":"t"},"rhs":"y"}]}
	  },
	  "coupling":[{"type":"variable_map","from":"A.x","to":"B.y",
	               "transform":"conversion_factor","factor":2.0}]}`

	file, err := LoadString(src)
	if err != nil {
		t.Fatal(err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}
	for _, eq := range flat.Equations {
		if !strings.Contains(eq.RHS, "B.y") {
			continue
		}
		if strings.Contains(eq.RHS, "(2*B.y)") {
			return // parenthesized: precedence-safe in every context
		}
		t.Errorf("the factor splice is not parenthesized, so it re-parses under the "+
			"surrounding precedence: RHS = %q", eq.RHS)
		return
	}
	t.Fatal("no flattened equation referenced the mapped variable")
}

// TestAuditG13_ConnectorTargetMatchIsTokenAware pins the other half of G13: the
// connector-target test was a bare strings.Contains, so a target of "A.v" also
// matched the equation for the longer name "A.v2".
func TestAuditG13_ConnectorTargetMatchIsTokenAware(t *testing.T) {
	if !lhsMentionsVar("D(Sys.v, t)", "Sys.v") {
		t.Error("lhsMentionsVar must find the target inside a derivative LHS")
	}
	if !lhsMentionsVar("Sys.v", "Sys.v") {
		t.Error("lhsMentionsVar must find a bare target")
	}
	if lhsMentionsVar("D(A.v2, t)", "A.v") {
		t.Error("lhsMentionsVar matched a LONGER variable that merely has the target as a prefix")
	}
	if lhsMentionsVar("D(BA.v, t)", "A.v") {
		t.Error("lhsMentionsVar matched a variable that merely has the target as a suffix")
	}
}

// --- G15: enum lowering reaches events and sidecar fields --------------------

// The enum-lowering walk skipped discrete_events / continuous_events entirely,
// so an `enum` there survived LowerEnums — violating the pass's post-condition
// that no `enum` node remains, and leaving `unknown_enum` dead in that position.
func TestAuditG15_LowerEnumsReachesEvents(t *testing.T) {
	src := `{
	  "esm":"0.2.0",
	  "metadata":{"name":"g15"},
	  "enums":{"phase":{"solid":1,"liquid":2}},
	  "models":{"M":{
	    "variables":{"x":{"type":"state","default":0.0},"s":{"type":"parameter","default":0.0}},
	    "equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":1.0}],
	    "discrete_events":[{
	      "trigger":{"type":"condition","expression":{"op":"==","args":["s",{"op":"enum","args":["phase","solid"]}]}},
	      "affects":[{"lhs":"s","rhs":{"op":"enum","args":["phase","liquid"]}}]
	    }]}}}`

	file, err := LoadString(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := LowerEnums(file); err != nil {
		t.Fatalf("LowerEnums: %v", err)
	}
	ev := file.Models["M"].DiscreteEvents[0]
	trig, err := SerializeExpression(ev.Trigger.Expression)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(trig, `"enum"`) {
		t.Errorf("an `enum` survived LowerEnums in a discrete-event trigger: %s", trig)
	}
	affect, err := SerializeExpression(ev.Affects[0].RHS)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(affect, `"enum"`) {
		t.Errorf("an `enum` survived LowerEnums in a discrete-event affect: %s", affect)
	}
	if !strings.Contains(affect, "2") {
		t.Errorf("the affect's enum was not lowered to its integer value (liquid = 2): %s", affect)
	}
}

// TestAuditG15_UnknownEnumIsDiagnosedInEvents pins that the diagnostic is live in
// the position it used to be dead in.
func TestAuditG15_UnknownEnumIsDiagnosedInEvents(t *testing.T) {
	src := `{
	  "esm":"0.2.0",
	  "metadata":{"name":"g15b"},
	  "enums":{"phase":{"solid":1}},
	  "models":{"M":{
	    "variables":{"x":{"type":"state","default":0.0},"s":{"type":"parameter","default":0.0}},
	    "equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":1.0}],
	    "discrete_events":[{
	      "trigger":{"type":"periodic","interval":1.0},
	      "affects":[{"lhs":"s","rhs":{"op":"enum","args":["phase","plasma"]}}]
	    }]}}}`

	// Enum lowering runs as part of the load pipeline, so the diagnostic surfaces
	// here. While events were skipped by the walk, the undeclared symbol simply
	// slipped through and the file loaded clean.
	_, err := LoadString(src)
	if err == nil {
		t.Fatal("expected the undeclared enum symbol `plasma` inside a discrete event to be diagnosed")
	}
	if !strings.Contains(err.Error(), "plasma") {
		t.Errorf("error does not name the offending symbol: %v", err)
	}
	if !strings.Contains(err.Error(), "unknown_enum_symbol") {
		t.Errorf("error does not carry the spec-pinned `unknown_enum_symbol` code: %v", err)
	}
}

// --- G14: warning-level findings must not invalidate a document -------------

func TestAuditG14_WarningsDoNotInvalidate(t *testing.T) {
	res := &ValidationResult{
		StructuralErrors: []StructuralError{
			{Code: "duplicate_reaction_species", Message: "advisory", Level: "warning"},
		},
	}
	if countStructuralErrorLevel(res.StructuralErrors) != 0 {
		t.Error("a warning-level finding must not count as an error")
	}
}

// --- T4: the units-severity policy ------------------------------------------
//
// T4 was a cross-binding POLICY question: TypeScript promoted unit findings to
// hard validation errors while Go/Python/Rust/Julia kept them as warnings. The
// policy is now settled, and these tests pin Go's half of it:
//
//   - a PROVABLE dimensional mismatch is a HARD ERROR (`unit_inconsistency`);
//   - an UNREAL/unparseable unit string is a HARD ERROR (the defect is in the
//     file, not in the checker);
//   - an UNDETERMINABLE finding stays a WARNING — a symbolic exponent, or an
//     operator the units engine has no dimensional rule for. Those report what
//     the checker could not determine, and must never invalidate a document.
//
// The rationale is the shared corpus itself: tests/invalid/expected_errors.json
// pins every units_*.esm fixture as `is_valid: false` with a STRUCTURAL error,
// so a binding that files these as warnings ACCEPTS files the corpus declares
// invalid.

// unitsDimensionalFixtures are the eight tests/invalid/units_*.esm fixtures whose
// pinned defect is a DIMENSIONAL one — i.e. decidable by propagating units
// through the expression tree — mapped to the JSON Pointer(s) that
// expected_errors.json pins for them. (The other units_* fixtures are pinned on
// specialized checks — reaction-rate order, conversion factors, physical
// constants, coupling maps — which have their own tests.)
//
// Every one of these was ACCEPTED by Go before this fix: five of them because
// the units checker walked only `model.equations` and never looked at observed
// variables' `expression`, where their defect lives; the other three because a
// mismatch was filed as an advisory warning.
var unitsDimensionalFixtures = map[string][]string{
	"units_incompatible_assignment.esm":      {"/models/BadUnitsModel/equations/0"},
	"units_invalid_derivative.esm":           {"/models/BadUnitsModel/equations/0"},
	"units_inconsistent_addition.esm":        {"/models/BadUnitsModel/variables/invalid_sum"},
	"units_inconsistent_subtraction.esm":     {"/models/BadUnitsModel/variables/invalid_diff"},
	"units_invalid_exponent.esm":             {"/models/BadUnitsModel/variables/invalid_power"},
	"units_invalid_logarithm.esm":            {"/models/BadUnitsModel/variables/invalid_log"},
	"units_gradient_operator_mismatch.esm":   {"/models/SpatialModel/variables/bad_sum"},
	"units_mixed_dimensional_operations.esm": {"/models/ComplexUnitsModel/variables/invalid_sum", "/models/ComplexUnitsModel/variables/invalid_transcendental"},
}

func TestAuditT4_DimensionalMismatchIsAHardError(t *testing.T) {
	for name, wantPaths := range unitsDimensionalFixtures {
		t.Run(name, func(t *testing.T) {
			file, content := loadInvalidFixture(t, name)
			result := ValidateFile(file, content)

			if result.IsValid {
				t.Fatalf("%s is pinned is_valid:false in expected_errors.json; Go accepted it", name)
			}
			for _, wantPath := range wantPaths {
				if !hasStructuralError(result, ErrorUnitInconsistency, wantPath) {
					t.Errorf("want %s @ %s; got %+v", ErrorUnitInconsistency, wantPath, result.StructuralErrors)
				}
			}
		})
	}
}

// An UNDETERMINABLE finding must never invalidate a document. Both cases here
// are Go's correct "return unknown and skip the check" behavior (the audit's T3
// endorses it); this test guards it against being swept up by the promotion.
func TestAuditT4_UndeterminableFindingsStayWarnings(t *testing.T) {
	// In both models an OBSERVED variable is declared `kg` while its expression
	// is built from an `m` state. The declared units are contradicted only if the
	// checker claims to know the expression's dimension — and in neither case can
	// it, so neither may be reported as a defect in the file.
	//
	//   - `x ^ alpha`  — a SYMBOLIC exponent: the dimension depends on alpha's
	//                    runtime VALUE.
	//   - `table_lookup(x)` — an operator the units engine has no rule for.
	//
	// Built as structs (not JSON) so the case is about the units policy and not
	// about satisfying the schema's shape rules for these ops.
	observed := func(expr Expression) *ESMFile {
		return &ESMFile{
			ESM:      "0.1.0",
			Metadata: Metadata{Name: "T", Authors: []string{"Test Author"}},
			Models: map[string]Model{
				"M": {
					Variables: map[string]ModelVariable{
						"x":     {Type: VarTypeState, Units: strPtr("m")},
						"alpha": {Type: VarTypeParameter, Units: strPtr("dimensionless")},
						"y":     {Type: VarTypeObserved, Units: strPtr("kg"), Expression: expr},
					},
					Equations: []Equation{
						{LHS: ExprNode{Op: OpDerivative, Args: []any{"x"}, Wrt: strPtr("t")}, RHS: "x"},
					},
				},
			},
		}
	}
	cases := map[string]Expression{
		"symbolic_exponent": ExprNode{Op: "^", Args: []any{"x", "alpha"}},
		"unknown_op":        ExprNode{Op: "table_lookup", Args: []any{"x"}},
	}
	for label, expr := range cases {
		t.Run(label, func(t *testing.T) {
			result := ValidateStructuralWithCodes(observed(expr))
			for _, se := range result.StructuralErrors {
				if se.Code == ErrorUnitInconsistency {
					t.Errorf("an undeterminable finding must not become a hard error: %+v", se)
				}
			}
			if !result.Valid {
				t.Errorf("document must stay valid: %+v", result.StructuralErrors)
			}
		})
	}
}

// A checker that hard-fails on mismatches must not FABRICATE a dimension it
// cannot know. These are the three fabrications that, once findings became hard
// errors, falsely rejected valid corpus files — 29 of them between them.
func TestAuditT4_NoFabricatedDimensions(t *testing.T) {
	env := mkEnv(t, map[string]string{"conc_ppb": "ppb", "x": "m", "n": "dimensionless"})

	// A bare literal is not dimensionless: `conc_ppb * 1.23` is a unit-carrying
	// conversion, not a dimensionless quantity.
	u, err := PropagateDimension(ExprNode{Op: "*", Args: []any{"conc_ppb", 1.23}}, env)
	if err != nil || u != nil {
		t.Errorf("a product with a literal factor must be indeterminate, got %v (err %v)", u, err)
	}
	// A derivative w.r.t. an UNDECLARED independent variable is not "per second".
	u, err = PropagateDimension(ExprNode{Op: "D", Args: []any{"x"}}, env)
	if err != nil || u != nil {
		t.Errorf("D(x) with undeclared t must be indeterminate, got %v (err %v)", u, err)
	}
	// A symbolic exponent does not preserve the base's dimension.
	u, err = PropagateDimension(ExprNode{Op: "^", Args: []any{"x", "n"}}, env)
	if err != nil || u != nil {
		t.Errorf("x^n must be indeterminate, got %v (err %v)", u, err)
	}
}

// The unit REGISTRY and GRAMMAR are a cross-binding contract: promoting an
// unresolvable unit string to a hard error is only sound if every unit the
// shared corpus actually uses resolves. A registry gap would turn into a false
// rejection of a legitimate file.
func TestAuditT4_UnitRegistryAndGrammarContract(t *testing.T) {
	// Every one of these appears in tests/valid/** and MUST parse.
	for _, s := range []string{
		// SI base, scaled, and derived.
		"m", "kg", "s", "mol", "K", "A", "cd", "rad",
		"g", "mg", "ug", "dm", "cm", "mm", "um", "nm", "km",
		"ms", "us", "ns", "min", "h", "hr", "day", "yr", "year",
		"L", "l", "mL", "Hz", "N", "Pa", "J", "kJ", "cal", "kcal", "W",
		"kmol", "mmol", "umol", "nmol", "M",
		// Pressure and energy multiples.
		"atm", "bar", "hPa", "kPa", "mbar", "Torr", "mmHg", "psi",
		"erg", "BTU", "Wh", "kWh", "kW", "MW",
		// Electromagnetic. "C" is the COULOMB (Celsius is degC/°C).
		"C", "V", "Ohm", "F", "T",
		// Temperature and angle.
		"degC", "degF", "deg",
		// Mixing ratios and count nouns.
		"ppm", "ppb", "ppt", "ppmv", "ppbv", "pptv",
		"molec", "individuals", "vehicles", "units", "count", "Dobson", "DU",
		// The dimensionless spellings.
		"", "1", "dimensionless",
		// GRAMMAR: parentheses, '**' exponents, whitespace juxtaposition,
		// negative exponents, and non-ASCII spellings.
		"J/(mol*K)", "m/s^2", "kg*m^2/s^3", "cm^3/molec/s", "1/s",
		"Pa*m**3", "m**3", "ppb^-1 s^-1", "kg m^2 s^-2",
		"°C", "μg/m^3", "µmol/(m^2*s)", "km^2/(individuals*year)",
	} {
		if _, err := ParseUnit(s); err != nil {
			t.Errorf("ParseUnit(%q) must resolve — a registry/grammar gap becomes a FALSE REJECTION now that an unparseable unit is a hard error: %v", s, err)
		}
	}

	// "C" must be the coulomb: charge × electric field is a force, and reading C
	// as Celsius silently injected a temperature dimension into every
	// electromagnetic expression in tests/valid/units_dimensional_analysis.esm.
	env := mkEnv(t, map[string]string{"q": "C", "E": "V/m"})
	force, err := PropagateDimension(ExprNode{Op: "*", Args: []any{"q", "E"}}, env)
	if err != nil || force == nil {
		t.Fatalf("q*E: %v (err %v)", force, err)
	}
	newton, err := ParseUnit("N")
	if err != nil {
		t.Fatal(err)
	}
	if !force.Dim.Equal(newton.Dim) {
		t.Errorf("charge × field must be a force (N), got %s — is \"C\" bound to Celsius?", force.Dim)
	}

	// A string that denotes NO real unit must still fail — the hard error the
	// policy rests on has to have something to fire on.
	if _, err := ParseUnit("not_a_unit"); err == nil {
		t.Error("ParseUnit must reject a unit string that denotes no real unit")
	}
}

// loadInvalidFixture loads a shared tests/invalid/*.esm fixture and returns both
// the parsed file and its raw text (ValidateFile needs both).
func loadInvalidFixture(t *testing.T, name string) (*ESMFile, string) {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	content, err := os.ReadFile(filepath.Join(repoRoot, "tests", "invalid", name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	file, err := LoadString(string(content))
	if err != nil {
		t.Fatalf("load %s: %v", name, err)
	}
	return file, string(content)
}

// --- Schema mirror: the bundled copy must match the ROOT esm-schema.json -----
//
// Go validates against a BUNDLED copy of esm-schema.json (pkg/esm/esm-schema.json),
// synced from the repo root by scripts/sync-schema.sh. The root schema had
// gained `pattern` constraints for the date-time / URI / DOI formats — because
// JSON Schema `format` is an ANNOTATION, not an assertion, so those three
// fixtures passed schema validation in every binding — but the mirrors were
// never re-synced, leaving Go validating against the old schema.
//
// Rather than diff the files (which only restates sync-schema.sh), this pins the
// BEHAVIOR the re-sync restores: the three malformed-format fixtures are
// rejected.
func TestAuditSchemaMirrorEnforcesFormatPatterns(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	for _, name := range []string{
		"invalid_date_format.esm",
		"invalid_url_format.esm",
		"malformed_doi.esm",
	} {
		t.Run(name, func(t *testing.T) {
			content, err := os.ReadFile(filepath.Join(repoRoot, "tests", "invalid", name))
			if err != nil {
				t.Fatalf("read %s: %v", name, err)
			}
			// LoadString runs schema validation, so a schema-invalid document
			// fails to load at all.
			if _, err := LoadString(string(content)); err == nil {
				t.Fatalf("%s is pinned is_valid:false; Go accepted it — is the bundled "+
					"esm-schema.json stale? Run scripts/sync-schema.sh", name)
			}
		})
	}
}
