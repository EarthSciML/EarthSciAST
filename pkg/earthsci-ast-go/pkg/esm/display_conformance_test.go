package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestAllOperatorsDisplayConformance pins the Go binding against the shared
// cross-language display fixtures (esm-libraries-spec §6).
//
// Go participated in this corpus only through the out-of-process cross-language
// runner (cmd/esm-conformance driving scripts/conformance_corpus.py), so an
// in-package `go test` could not catch a rendering divergence. That is the same
// gap that let the Rust binding disagree with the other four in 19 of the 50
// parent/child precedence combinations — including a LaTeX case that changed
// meaning — until it was wired in directly. This closes it for Go.
func TestAllOperatorsDisplayConformance(t *testing.T) {
	path := filepath.Join("..", "..", "..", "..", "tests", "display", "all_operators.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared display fixture: %v", err)
	}
	var cases []struct {
		Input   json.RawMessage `json:"input"`
		Unicode *string         `json:"unicode"`
		Latex   *string         `json:"latex"`
		Ascii   *string         `json:"ascii"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatalf("parse shared display fixture: %v", err)
	}
	if len(cases) < 91 {
		t.Fatalf("fixture shrank unexpectedly: %d entries", len(cases))
	}

	for i, c := range cases {
		expr, err := UnmarshalExpression(c.Input)
		if err != nil {
			t.Errorf("case %d: input did not deserialize: %v", i, err)
			continue
		}
		// Not every fixture pins every format.
		if c.Ascii != nil {
			if got := ToAscii(expr); got != *c.Ascii {
				t.Errorf("case %d ascii: want %q, got %q", i, *c.Ascii, got)
			}
		}
		if c.Unicode != nil {
			if got := ToUnicode(expr); got != *c.Unicode {
				t.Errorf("case %d unicode: want %q, got %q", i, *c.Unicode, got)
			}
		}
		if c.Latex != nil {
			if got := ToLatex(expr); got != *c.Latex {
				t.Errorf("case %d latex: want %q, got %q", i, *c.Latex, got)
			}
		}
	}
}
