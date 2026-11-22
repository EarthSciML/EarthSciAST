package esm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// pdeDeclaredDoc has a model `Heat` that declares the dropped "pde" kind (its
// equations derive "ode": a time derivative and a spatial one), a subsystem
// that declares it too, and a model `Steady` that declares "ode" while
// deriving "nonlinear".
const pdeDeclaredDoc = `{
  "esm": "2.4.0",
  "metadata": {"name": "declared_pde"},
  "models": {
    "Heat": {
      "system_kind": "pde",
      "variables": {"u": {"type": "unknown", "default": 0.0},
                    "k": {"type": "parameter", "default": 1.0}},
      "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                     "rhs": {"op": "*", "args": ["k",
                       {"op": "D", "args": [{"op": "D", "args": ["u"], "wrt": "x"}], "wrt": "x"}]}}],
      "subsystems": {
        "Inner": {
          "system_kind": "pde",
          "variables": {"v": {"type": "unknown", "default": 0.0}},
          "equations": [{"lhs": {"op": "D", "args": ["v"], "wrt": "t"}, "rhs": 1.0}]
        }
      }
    }
  }
}`

// A declared "pde" loads with ONE `deprecated_system_kind` warning naming
// every such model by JSON pointer; the field is kept as written, and
// DeclaredSystemKind treats it as absent so the model is its derived kind.
func TestDeclaredPdeSystemKindWarnsAndIsIgnored(t *testing.T) {
	path := filepath.Join(t.TempDir(), "declared_pde.esm")
	if err := os.WriteFile(path, []byte(pdeDeclaredDoc), 0o644); err != nil {
		t.Fatal(err)
	}
	file, stderr := loadCapturingStderr(t, path)
	if n := strings.Count(stderr, codeDeprecatedSystemKind); n != 1 {
		t.Fatalf("want exactly one %s warning, got %d: %q", codeDeprecatedSystemKind, n, stderr)
	}
	for _, site := range []string{"/models/Heat/system_kind", "/models/Heat/subsystems/Inner/system_kind"} {
		if !strings.Contains(stderr, site) {
			t.Errorf("warning does not name %s: %q", site, stderr)
		}
	}
	heat := file.Models["Heat"]
	if heat.SystemKind == nil || *heat.SystemKind != "pde" {
		t.Errorf("declared system_kind not kept as written: %v", heat.SystemKind)
	}
	if got := DeclaredSystemKind(&heat); got != nil {
		t.Errorf("DeclaredSystemKind = %q, want nil for the deprecated \"pde\"", *got)
	}
	if got := SystemKind(&heat); got != SystemKindODE {
		t.Errorf("SystemKind = %q, want %q (spatial derivatives do not enter the derivation)", got, SystemKindODE)
	}
	if got := EffectiveSystemKind(&heat); got != SystemKindODE {
		t.Errorf("EffectiveSystemKind = %q, want the derived %q", got, SystemKindODE)
	}
}

// `system_kind_mismatch` is never reported for a declared "pde"; a declared
// kind that still exists and contradicts the derivation is.
func TestDeclaredPdeSystemKindIsNotAMismatch(t *testing.T) {
	if result := validateSrc(t, pdeDeclaredDoc); hasCode(result, ErrorSystemKindMismatch) {
		t.Errorf("declared \"pde\" reported as %s: %+v", ErrorSystemKindMismatch, result.StructuralErrors)
	}
	declaredOde := strings.Replace(pdeDeclaredDoc, `"system_kind": "pde",
      "variables": {"u"`, `"system_kind": "nonlinear",
      "variables": {"u"`, 1)
	if declaredOde == pdeDeclaredDoc {
		t.Fatal("test document did not change")
	}
	if result := validateSrc(t, declaredOde); !hasCode(result, ErrorSystemKindMismatch) {
		t.Errorf("declared \"nonlinear\" on an ode model must report %s: %+v",
			ErrorSystemKindMismatch, result.StructuralErrors)
	}
}
