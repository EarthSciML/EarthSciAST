package esm

// esm-spec §2.2.7 `solver.time_span`, against the SHARED pin.
//
// Reads tests/conformance/solver_time_span/manifest.json and asserts this
// binding against it: what ResolveTimeSpan returns (binary64 equality), what
// emit writes for the root's `solver` block, and how a refused fixture fails.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type stsFixture struct {
	ID              string          `json:"id"`
	Path            string          `json:"path"`
	Expect          string          `json:"expect"`
	Solver          json.RawMessage `json:"solver"`
	Seconds         *[2]float64     `json:"seconds"`
	ErrorCode       string          `json:"error_code"`
	MessageContains []string        `json:"message_contains"`
}

type stsManifest struct {
	BindingsRequired []string     `json:"bindings_required"`
	Fixtures         []stsFixture `json:"fixtures"`
	CallSite         struct {
		Cases []struct {
			Fixture  string      `json:"fixture"`
			CallSite *[2]float64 `json:"call_site"`
			Resolved *[2]float64 `json:"resolved"`
		} `json:"cases"`
	} `json:"call_site"`
}

func stsSuiteDir(t *testing.T) string {
	return filepath.Join(dsuRepoRoot(t), "tests", "conformance", "solver_time_span")
}

func stsLoadManifest(t *testing.T) stsManifest {
	t.Helper()
	p := filepath.Join(stsSuiteDir(t), "manifest.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("the shared pin %s must be readable: %v", p, err)
	}
	var m stsManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("manifest.json must be JSON: %v", err)
	}
	return m
}

func stsLoad(t *testing.T, f stsFixture) (*ESMFile, error) {
	t.Helper()
	return LoadPath(filepath.Join(stsSuiteDir(t), f.Path))
}

func TestSolverTimeSpanManifestRequiresGo(t *testing.T) {
	m := stsLoadManifest(t)
	for _, b := range m.BindingsRequired {
		if b == "go" {
			return
		}
	}
	t.Fatalf("bindings_required %v does not name go", m.BindingsRequired)
}

func TestSolverTimeSpanAcceptedMatchesTheSharedPin(t *testing.T) {
	m := stsLoadManifest(t)
	accepted := 0
	for _, f := range m.Fixtures {
		if f.Expect != "accepted" {
			continue
		}
		accepted++
		t.Run(f.ID, func(t *testing.T) {
			file, err := stsLoad(t, f)
			if err != nil {
				t.Fatalf("must load: %v", err)
			}
			got, err := ResolveTimeSpan(file, nil)
			if err != nil {
				t.Fatalf("accessor: %v", err)
			}
			switch {
			case f.Seconds == nil && got != nil:
				t.Errorf("ResolveTimeSpan = %v, want no interval", *got)
			case f.Seconds != nil && got == nil:
				t.Errorf("ResolveTimeSpan = nil, want %v", *f.Seconds)
			case f.Seconds != nil && *got != *f.Seconds:
				t.Errorf("ResolveTimeSpan = %v, want exactly %v", *got, *f.Seconds)
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

func TestSolverTimeSpanRefusalMatchesTheSharedPin(t *testing.T) {
	m := stsLoadManifest(t)
	refused := 0
	for _, f := range m.Fixtures {
		if f.Expect != "refused" {
			continue
		}
		refused++
		t.Run(f.ID, func(t *testing.T) {
			if f.ErrorCode != CodeSolverTimeSpanInvalid && f.ErrorCode != CodeSolverTimeSpanVersionTooOld {
				t.Fatalf("the manifest pins %q, which this binding has no constant for", f.ErrorCode)
			}
			_, err := stsLoad(t, f)
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

func TestSolverTimeSpanCallSiteWins(t *testing.T) {
	m := stsLoadManifest(t)
	byID := map[string]stsFixture{}
	for _, f := range m.Fixtures {
		byID[f.ID] = f
	}
	if len(m.CallSite.Cases) == 0 {
		t.Fatal("the manifest has no call_site cases")
	}
	for _, c := range m.CallSite.Cases {
		f, ok := byID[c.Fixture]
		if !ok {
			t.Fatalf("call_site case names unknown fixture %q", c.Fixture)
		}
		file, err := stsLoad(t, f)
		if err != nil {
			t.Fatalf("%s must load: %v", c.Fixture, err)
		}
		got, err := ResolveTimeSpan(file, c.CallSite)
		if err != nil {
			t.Fatalf("%s: accessor: %v", c.Fixture, err)
		}
		if got == nil || c.Resolved == nil || *got != *c.Resolved {
			t.Errorf("%s: ResolveTimeSpan(call site %v) = %v, want %v", c.Fixture, c.CallSite, got, c.Resolved)
		}
	}
}

// A leaf loaded on its own IS checked; only the mount exempts it.
func TestSolverTimeSpanLeafAloneIsChecked(t *testing.T) {
	for name, code := range map[string]string{
		"leaf_reversed.esm":            CodeSolverTimeSpanInvalid,
		"leaf_v120_with_time_span.esm": CodeSolverTimeSpanVersionTooOld,
	} {
		_, err := LoadPath(filepath.Join(stsSuiteDir(t), "fixtures", "leaves", name))
		var de DiagnosticError
		if err == nil || !errors.As(err, &de) || de.DiagnosticCode() != code {
			t.Errorf("%s loaded alone: got %v, want code %q", name, err, code)
		}
	}
}

// The shared corpus files for the field: the valid and version-compat
// documents load, the resolver-only invalid ones are refused with their pinned
// code, and the schema-invalid ones carry the pinned (path, keyword).
func TestSolverTimeSpanCorpusFixtures(t *testing.T) {
	root := dsuRepoRoot(t)
	for _, rel := range []string{
		"tests/valid/solver_time_span.esm",
		"tests/valid/solver_time_span_only.esm",
		"tests/version_compatibility/version_1_3_0_solver_time_span.esm",
	} {
		if _, err := LoadPath(filepath.Join(root, rel)); err != nil {
			t.Errorf("%s must load: %v", rel, err)
		}
	}
	for name, code := range map[string]string{
		"solver_time_span_reversed.esm":        CodeSolverTimeSpanInvalid,
		"solver_time_span_version_too_old.esm": CodeSolverTimeSpanVersionTooOld,
	} {
		_, err := LoadPath(filepath.Join(root, "tests", "invalid", name))
		var de DiagnosticError
		if err == nil || !errors.As(err, &de) || de.DiagnosticCode() != code {
			t.Errorf("%s: got %v, want code %q", name, err, code)
		}
	}
	for name, want := range map[string][2]string{
		"solver_time_span_missing_end.esm": {"/solver/time_span", "required"},
		"solver_time_span_offset.esm":      {"/solver/time_span/start", "oneOf"},
	} {
		raw, err := os.ReadFile(filepath.Join(root, "tests", "invalid", name))
		if err != nil {
			t.Fatal(err)
		}
		res := ValidateText(string(raw))
		found := false
		for _, se := range res.SchemaErrors {
			if se.Path == want[0] && se.Keyword == want[1] {
				found = true
			}
		}
		if !found {
			t.Errorf("%s: want schema error %s @ %s; got %+v", name, want[1], want[0], res.SchemaErrors)
		}
		if _, err := LoadPath(filepath.Join(root, "tests", "invalid", name)); err == nil {
			t.Errorf("%s must be refused at load", name)
		}
	}
}

// esm-spec §2.2.7: a PRESENT origin key selects that field whatever its value
// (JSON null included) and never falls back to the next one; an unreadable one
// refuses the document naming its pointer. `:60` seconds and an offset out of
// range are unreadable.
func TestSolverTimeSpanPresentOriginNeverFallsBack(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(stsSuiteDir(t), "fixtures", "timestamps_reference_time.esm"))
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name     string
		temporal map[string]any
		pointer  string
	}{
		{"null_reference_time", map[string]any{"reference_time": nil, "start": "2019-07-01T00:00:00Z"}, "/domain/temporal/reference_time"},
		{"null_start", map[string]any{"start": nil}, "/domain/temporal/start"},
		{"leap_second", map[string]any{"reference_time": "2016-12-31T23:59:60Z"}, "/domain/temporal/reference_time"},
		{"offset_hour_24", map[string]any{"start": "2019-07-01T00:00:00+24:00"}, "/domain/temporal/start"},
		{"offset_minute_60", map[string]any{"start": "2019-07-01T00:00:00+01:60"}, "/domain/temporal/start"},
		{"not_a_day", map[string]any{"reference_time": "2019-02-29T00:00:00Z"}, "/domain/temporal/reference_time"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			doc["domain"] = map[string]any{"temporal": c.temporal}
			text, err := json.Marshal(doc)
			if err != nil {
				t.Fatal(err)
			}
			_, err = LoadString(string(text))
			var de DiagnosticError
			if err == nil || !errors.As(err, &de) || de.DiagnosticCode() != CodeSolverTimeSpanInvalid {
				t.Fatalf("got %v, want code %q", err, CodeSolverTimeSpanInvalid)
			}
			for _, needle := range []string{"/solver/time_span", c.pointer} {
				if !strings.Contains(err.Error(), needle) {
					t.Errorf("the diagnostic must contain %q; got: %s", needle, err)
				}
			}
		})
	}
}
