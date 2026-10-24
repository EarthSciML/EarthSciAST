package esm

// esm-spec §2.2.6 `solver.external` resolution, against the SHARED pin.
//
// Reads tests/conformance/solver_external/manifest.json and asserts this
// binding against it: what the typed document holds, what the accessor
// returns, and what emit writes. Expectations are repo-relative or
// working-directory-relative paths, never literal absolute URLs, because a
// resolved location is machine-specific. Nothing a fixture names exists on
// disk, and nothing here creates it.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type sxPin struct {
	RepoPath *string `json:"repo_path"`
	CwdPath  *string `json:"cwd_path"`
	Verbatim *string `json:"verbatim"`
}

type sxFixture struct {
	ID              string          `json:"id"`
	Path            string          `json:"path"`
	Load            string          `json:"load"`
	Base            *sxPin          `json:"base"`
	Expect          string          `json:"expect"`
	External        *string         `json:"external"`
	Location        *sxPin          `json:"location"`
	Solver          json.RawMessage `json:"solver"`
	ErrorCode       string          `json:"error_code"`
	MessageContains []string        `json:"message_contains"`
}

type sxManifest struct {
	BindingsRequired []string    `json:"bindings_required"`
	Fixtures         []sxFixture `json:"fixtures"`
	Invariance       struct {
		With    string `json:"with"`
		Without string `json:"without"`
	} `json:"invariance"`
}

func sxSuiteDir(t *testing.T) string {
	return filepath.Join(dsuRepoRoot(t), "tests", "conformance", "solver_external")
}

func sxLoadManifest(t *testing.T) sxManifest {
	t.Helper()
	p := filepath.Join(sxSuiteDir(t), "manifest.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("the shared pin %s must be readable: %v", p, err)
	}
	var m sxManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("manifest.json must be JSON: %v", err)
	}
	return m
}

// sxExpand turns a pin into the string the accessor must return.
func sxExpand(t *testing.T, pin *sxPin) string {
	t.Helper()
	switch {
	case pin == nil:
		return ""
	case pin.Verbatim != nil:
		return *pin.Verbatim
	case pin.RepoPath != nil:
		return "file://" + removeURLDotSegments(filepath.ToSlash(filepath.Join(dsuRepoRoot(t), *pin.RepoPath)))
	case pin.CwdPath != nil:
		cwd, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		return "file://" + removeURLDotSegments(filepath.ToSlash(cwd)+"/"+*pin.CwdPath)
	}
	t.Fatalf("a location pin must carry repo_path, cwd_path or verbatim")
	return ""
}

func sxLoad(t *testing.T, f sxFixture) (*ESMFile, error) {
	t.Helper()
	path := filepath.Join(sxSuiteDir(t), f.Path)
	switch f.Load {
	case "path":
		return LoadPath(path)
	case "string":
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return LoadString(string(raw))
	}
	t.Fatalf("%s: unknown load mode %q", f.ID, f.Load)
	return nil, nil
}

// sxEmittedSolver returns the emitted document's `solver` value, or nil.
func sxEmittedSolver(t *testing.T, file *ESMFile) any {
	t.Helper()
	out, err := ToJSON(file)
	if err != nil {
		t.Fatalf("emit: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("emitted text is not JSON: %v", err)
	}
	return doc["solver"]
}

func TestSolverExternalManifestRequiresGo(t *testing.T) {
	m := sxLoadManifest(t)
	for _, b := range m.BindingsRequired {
		if b == "go" {
			return
		}
	}
	t.Fatalf("bindings_required %v does not name go", m.BindingsRequired)
}

func TestSolverExternalResolutionMatchesTheSharedPin(t *testing.T) {
	m := sxLoadManifest(t)
	accepted := 0
	for _, f := range m.Fixtures {
		if f.Expect != "accepted" {
			continue
		}
		accepted++
		t.Run(f.ID, func(t *testing.T) {
			file, err := sxLoad(t, f)
			if err != nil {
				t.Fatalf("must load: %v", err)
			}

			var held *string
			if file.SolverHints != nil {
				held = file.SolverHints.External
			}
			if (held == nil) != (f.External == nil) || (held != nil && *held != *f.External) {
				t.Errorf("solver.external = %v, want %v", sxStr(held), sxStr(f.External))
			}

			base := ""
			if f.Base != nil {
				if f.Base.RepoPath == nil {
					t.Fatalf("base must be a repo_path pin")
				}
				base = filepath.Join(dsuRepoRoot(t), *f.Base.RepoPath)
			}
			got, err := SolverExternalLocation(file, base)
			if err != nil {
				t.Fatalf("accessor: %v", err)
			}
			if want := sxExpand(t, f.Location); got != want {
				t.Errorf("SolverExternalLocation = %q, want %q", got, want)
			}

			var want any
			if err := json.Unmarshal(f.Solver, &want); err != nil {
				t.Fatal(err)
			}
			if emitted := sxEmittedSolver(t, file); !reflect.DeepEqual(emitted, want) {
				t.Errorf("emitted solver = %#v, want %#v", emitted, want)
			}
		})
	}
	if accepted == 0 {
		t.Fatal("the manifest has no accepted fixtures")
	}
}

func TestSolverExternalRefusalMatchesTheSharedPin(t *testing.T) {
	m := sxLoadManifest(t)
	refused := 0
	for _, f := range m.Fixtures {
		if f.Expect != "refused" {
			continue
		}
		refused++
		t.Run(f.ID, func(t *testing.T) {
			if f.ErrorCode != CodeSolverExternalUnresolved {
				t.Fatalf("the manifest pins %q; this binding's constant is %q",
					f.ErrorCode, CodeSolverExternalUnresolved)
			}
			_, err := sxLoad(t, f)
			if err == nil {
				t.Fatal("must be REFUSED at load")
			}
			var de DiagnosticError
			if !errors.As(err, &de) || de.DiagnosticCode() != f.ErrorCode {
				t.Fatalf("error %v must carry code %q", err, f.ErrorCode)
			}
			for _, needle := range f.MessageContains {
				if !strings.Contains(err.Error(), needle) {
					t.Errorf("the diagnostic must contain %q; got: %s", needle, err)
				}
			}
		})
	}
	if refused == 0 {
		t.Fatal("the manifest has no refused fixtures")
	}
}

// The resolved form is never written back: emitting into a different
// directory and reloading keeps the authored string and moves the location.
func TestSolverExternalRoundTripKeepsTheAuthoredString(t *testing.T) {
	src := filepath.Join(sxSuiteDir(t), "fixtures", "dot_relative.esm")
	file, err := LoadPath(src)
	if err != nil {
		t.Fatal(err)
	}
	out, err := ToJSON(file)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	moved := filepath.Join(dir, "moved.esm")
	if err := os.WriteFile(moved, []byte(out), 0o644); err != nil {
		t.Fatal(err)
	}
	again, err := LoadPath(moved)
	if err != nil {
		t.Fatalf("the emitted document must reload: %v", err)
	}
	if again.SolverHints == nil || again.SolverHints.External == nil ||
		*again.SolverHints.External != "./runs/probe.run.json" {
		t.Fatalf("external must stay authored, got %+v", again.SolverHints)
	}
	got, err := SolverExternalLocation(again, "")
	if err != nil {
		t.Fatal(err)
	}
	absDir, _ := filepath.Abs(dir)
	if want := "file://" + filepath.ToSlash(absDir) + "/runs/probe.run.json"; got != want {
		t.Errorf("location after the move = %q, want %q", got, want)
	}
}

func TestSolverExternalDoesNotChangeTheFlattenedSystem(t *testing.T) {
	m := sxLoadManifest(t)
	flat := func(rel string) []byte {
		t.Helper()
		file, err := LoadPath(filepath.Join(sxSuiteDir(t), rel))
		if err != nil {
			t.Fatalf("%s must load: %v", rel, err)
		}
		fs, err := Flatten(file)
		if err != nil {
			t.Fatalf("%s must flatten: %v", rel, err)
		}
		b, err := json.Marshal(fs)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	with, without := flat(m.Invariance.With), flat(m.Invariance.Without)
	if string(with) != string(without) {
		t.Errorf("flattening with and without solver.external differs:\nwith:    %s\nwithout: %s", with, without)
	}
}

// The two corpus documents the schema admits but every binding refuses at load.
func TestSolverExternalCorpusRefusals(t *testing.T) {
	invalid := filepath.Join(dsuRepoRoot(t), "tests", "invalid")
	pins := resolverOnlyPins(t, dsuRepoRoot(t))
	for _, name := range []string{"solver_external_version_too_old.esm", "solver_external_env_var.esm"} {
		t.Run(name, func(t *testing.T) {
			want, ok := pins[name]
			if !ok || want == "" {
				t.Fatalf("%s must be pinned resolver_only with a resolver_error_code", name)
			}
			_, err := LoadPath(filepath.Join(invalid, name))
			if err == nil {
				t.Fatal("must be REFUSED at load")
			}
			var de DiagnosticError
			if !errors.As(err, &de) || de.DiagnosticCode() != want {
				t.Fatalf("error %v must carry code %q", err, want)
			}
			if !strings.Contains(err.Error(), "/solver/external") {
				t.Errorf("the diagnostic must name /solver/external; got: %s", err)
			}
		})
	}
}

// Version-gate edges: 1.1.0/1.2.0 with `external` is refused at
// /solver/external, the same block without it is legal, and below 1.1.0 the
// older whole-block gate answers first.
func TestSolverExternalVersionGate(t *testing.T) {
	doc := func(esm, solver string) string {
		return `{"esm":"` + esm + `","metadata":{"name":"T"},"solver":` + solver +
			`,"models":{"M":{"variables":{"x":{"type":"unknown","units":"m","default":1.0}},` +
			`"equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":{"op":"neg","args":["x"]}}]}}}`
	}
	code := func(err error) string {
		var de DiagnosticError
		if errors.As(err, &de) {
			return de.DiagnosticCode()
		}
		return ""
	}
	for _, c := range []struct{ esm, solver, want string }{
		{"1.2.0", `{"external":"a.json"}`, CodeSolverExternalVersionTooOld},
		{"1.1.0", `{"reltol":1e-6,"external":"a.json"}`, CodeSolverExternalVersionTooOld},
		{"1.0.0", `{"external":"a.json"}`, CodeSolverVersionTooOld},
		{"1.2.0", `{"external":"${X}/a.json"}`, CodeSolverExternalVersionTooOld},
		{"1.2.0", `{"reltol":1e-6}`, ""},
		{"1.3.0", `{"external":"a.json"}`, ""},
	} {
		_, err := LoadString(doc(c.esm, c.solver))
		if got := code(err); got != c.want || (c.want == "" && err != nil) {
			t.Errorf("esm %s solver %s: got code %q (err %v), want %q", c.esm, c.solver, got, err, c.want)
		}
	}
	view := map[string]any{"esm": "1.2.0", "solver": map[string]any{"external": "a.json"}}
	if err := RejectSolverExternalPreV13(view); code(err) != CodeSolverExternalVersionTooOld {
		t.Errorf("RejectSolverExternalPreV13 = %v", err)
	}
}

// A relative explicit base is taken against the working directory, then dot
// segments removed; a struct built in code has no recorded directory and
// resolves against the working directory.
func TestSolverExternalBaseEdges(t *testing.T) {
	ext := "x/../run.json"
	file := &ESMFile{SolverHints: &Solver{External: &ext}}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	cwd = filepath.ToSlash(cwd)
	for _, c := range []struct{ base, want string }{
		{"", "file://" + removeURLDotSegments(cwd+"/run.json")},
		{"rel/./dir", "file://" + removeURLDotSegments(cwd+"/rel/dir/run.json")},
		{"/abs/a/../b", "file:///abs/b/run.json"},
	} {
		got, err := SolverExternalLocation(file, c.base)
		if err != nil {
			t.Fatal(err)
		}
		if got != c.want {
			t.Errorf("base %q: got %q, want %q", c.base, got, c.want)
		}
	}
	if got, err := SolverExternalLocation(&ESMFile{}, ""); got != "" || err != nil {
		t.Errorf("no external: got %q, %v", got, err)
	}
	bad := "${HOME}/r.json"
	if _, err := SolverExternalLocation(&ESMFile{SolverHints: &Solver{External: &bad}}, ""); err == nil {
		t.Error("an in-memory `${` must be refused by the accessor")
	}
}

func sxStr(p *string) string {
	if p == nil {
		return "<none>"
	}
	return *p
}
