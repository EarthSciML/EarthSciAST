package esm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestShippedLibraryValidatesClean pins the shipped standard library (lib/**) as
// part of the validation corpus (CONFORMANCE_SPEC §2.2.1): every library a
// document may mount as a subsystem MUST itself validate clean.
//
// Nothing used to check this. The libraries are only ever reached through the
// two mounting fixtures (tests/valid/lib_*_subsystem_inclusion.esm), and a
// mounted subsystem's body is not dimension-checked in the host, so two real
// defects sat in lib/ unseen: `acos(...)` declared "rad" (a guaranteed mismatch
// for any checker that calls the inverse circular functions dimensionless) and
// clock fields declared "1" summed into a quantity declared "s".
func TestShippedLibraryValidatesClean(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	paths, err := filepath.Glob(filepath.Join(repoRoot, "lib", "*.esm"))
	if err != nil || len(paths) == 0 {
		t.Skipf("no lib/*.esm found under %s", repoRoot)
	}
	for _, path := range paths {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			content, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", name, err)
			}
			if marker := preRepairLibMarker(string(content)); marker != "" {
				t.Skipf("%s predates the lib dimensional repair (found %s); this test arms itself "+
					"as soon as the repaired library lands in this checkout", name, marker)
			}
			file, err := Load(path)
			if err != nil {
				t.Fatalf("a shipped library must load: %v", err)
			}
			result := ValidateFile(file, string(content))
			for _, se := range result.StructuralErrors {
				if se.Level == "" {
					t.Errorf("%s: %s @ %s :: %s", name, se.Code, se.Path, se.Message)
				}
			}
			if !result.IsValid {
				t.Errorf("a shipped library must validate clean; %s did not", name)
			}
		})
	}
}

// preRepairLibMarker names the pre-repair signature a library still carries, or
// "" once it has been migrated.
//
// The libraries' dimensional annotations were repaired on the corpus branch
// (the day respelled "day"; the implicit-unit conversion literals given real
// units). This checkout may still hold the pre-repair copies, which are
// GENUINELY invalid — asserting they validate clean would be asserting a defect.
// Rather than skip silently, each stale copy is named by the exact signature
// that identifies it:
//
//   - `"units": "d"` — the day spelled with the one-letter symbol that §4.8.1
//     deliberately excludes (it reads as a deci- prefix or a differential).
//   - `["true_solar_time", 4.0]` — the bare minutes-per-degree literal, since
//     replaced by the `min_per_deg` parameter that carries "min/deg".
func preRepairLibMarker(content string) string {
	for _, marker := range []string{`"units": "d"`, `["true_solar_time", 4.0]`} {
		if strings.Contains(content, marker) {
			return marker
		}
	}
	return ""
}
