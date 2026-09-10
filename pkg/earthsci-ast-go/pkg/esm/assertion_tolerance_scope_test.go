package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// assertion_tolerance_scope_test.go is Go's read of the SHARED
// `assertion_tolerance` conformance manifest (CONFORMANCE_SPEC §5.37,
// tests/conformance/assertion_tolerance/manifest.json).
//
// Go cannot run that category: its contract is the esm-spec §6.6.3 pass
// predicate as a pure function of (actual, expected, rel, abs), and this
// binding has no such function ANYWHERE — not in production, not in its own
// tests. It parses a `tests` block as data (see Tolerance in types.go, whose
// doc comment carries the predicate so a future runner does not have to
// re-derive it) and never compares an actual to an expectation. The manifest
// says so in `scope_excluded`, and this test is what keeps that claim honest.
//
// Why a test rather than a line in a document. A shared corpus that only some
// bindings read is a failure this suite has already had once: a rejection
// corpus was being consumed by two of five bindings, and the three that ignored
// it could have diverged silently for as long as nobody looked. An exclusion is
// the same hazard one level down — invisible by construction. So all five
// bindings read this manifest, and the one that cannot execute it asserts its
// own exclusion: giving Go a §6.6.3 predicate goes RED here until Go is moved
// into `bindings_required` with a real adapter, instead of the category quietly
// covering one binding fewer than it claims.
//
// Note the contrast with assertion_nonfinite (§5.20), which excludes both Go
// and TypeScript: that category needs a SIMULATOR. This one needs only
// arithmetic, which is why TypeScript is required here and Go is not — the
// difference is a missing function, not a missing capability.
func TestAssertionToleranceExcludesGoWithAReason(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	categoryDir := filepath.Join(repoRoot, "tests", "conformance", "assertion_tolerance")

	manifestPath := filepath.Join(categoryDir, "manifest.json")
	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read %s: %v", manifestPath, err)
	}
	var manifest struct {
		Category         string            `json:"category"`
		ReferenceBinding string            `json:"reference_binding"`
		BindingsRequired []string          `json:"bindings_required"`
		ScopeExcluded    map[string]string `json:"scope_excluded"`
		Golden           string            `json:"golden"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse %s: %v", manifestPath, err)
	}

	if manifest.Category != "assertion_tolerance" {
		t.Fatalf("category = %q, want assertion_tolerance", manifest.Category)
	}
	if manifest.ReferenceBinding != "analytic" {
		t.Fatalf("reference_binding = %q, want analytic: the verdicts are computed "+
			"from §6.6.3, not read off a binding", manifest.ReferenceBinding)
	}
	for _, b := range manifest.BindingsRequired {
		if b == "go" {
			t.Fatal("the manifest requires Go, but Go has no §6.6.3 predicate to gate; " +
				"either give Go one with an adapter, or keep it in scope_excluded")
		}
	}
	if reason, ok := manifest.ScopeExcluded["go"]; !ok || reason == "" {
		t.Fatal("the manifest must say, in scope_excluded, WHY Go does not run this category")
	}
	// The other four bindings must actually be on the hook. An exclusion is only
	// safe while somebody else is executing the contract.
	if len(manifest.BindingsRequired) < 4 {
		t.Fatalf("bindings_required = %v; the four bindings with a predicate must all "+
			"be required, or this exclusion hides a gap rather than recording one",
			manifest.BindingsRequired)
	}

	// The golden must be present and non-vacuous. Go cannot evaluate the
	// predicate, but it can check that the category still carries BOTH verdicts
	// and can still see every known wrong reading of §6.6.3 — a golden of one
	// verdict would be satisfied by a binding that answered a constant.
	goldenPath := filepath.Join(repoRoot, "tests", manifest.Golden)
	graw, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read %s: %v", goldenPath, err)
	}
	var golden struct {
		ReadingsDiscriminated map[string]int `json:"readings_discriminated"`
		Cases                 []struct {
			ID     string `json:"id"`
			Passed bool   `json:"passed"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(graw, &golden); err != nil {
		t.Fatalf("parse %s: %v", goldenPath, err)
	}
	if len(golden.Cases) == 0 {
		t.Fatalf("%s declares no cases", goldenPath)
	}
	var nPass, nFail int
	for _, c := range golden.Cases {
		if c.Passed {
			nPass++
		} else {
			nFail++
		}
	}
	if nPass == 0 || nFail == 0 {
		t.Fatalf("%s: %d pass / %d fail cases; the category needs both to be non-vacuous",
			goldenPath, nPass, nFail)
	}
	for _, reading := range []string{"asymmetric", "sum_form", "epsilon_floor", "no_finiteness_guard"} {
		n, ok := golden.ReadingsDiscriminated[reading]
		if !ok {
			t.Fatalf("%s: readings_discriminated is missing %q", goldenPath, reading)
		}
		if n == 0 {
			t.Fatalf("%s: no case discriminates the %q reading of §6.6.3", goldenPath, reading)
		}
	}
}
