package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Drives tests/conformance/removed_spellings/manifest.json: the two removed
// spellings of the `faq` node — `arrayop` (removed at esm 0.8.0) and
// `aggregate` (removed at 2.0.0) — are refused BY NAME with `removed_op`, in
// the root and in a referenced child, and `faq` below esm 1.1.0 is
// `faq_version_too_old`. See CONFORMANCE_SPEC §7 and
// docs/content/rfcs/faq-node-rename.md.

func removedSpellingsDir(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(root, "tests", "conformance", "removed_spellings")
}

type removedSpellingsManifest struct {
	Cases []struct {
		ID    string `json:"id"`
		Input string `json:"input"`
	} `json:"cases"`
}

// atVersion writes a copy of the tier's `name` declaring `version`.
func atVersion(t *testing.T, name, version string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(removedSpellingsDir(t), name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	doc["esm"] = version
	out := filepath.Join(t.TempDir(), "v.esm")
	enc, _ := json.Marshal(doc)
	if err := os.WriteFile(out, enc, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	return out
}

func TestRemovedSpellingsConformance(t *testing.T) {
	dir := removedSpellingsDir(t)
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m removedSpellingsManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, c := range m.Cases {
		c := c
		seen[c.ID] = true
		t.Run(c.ID, func(t *testing.T) {
			switch c.ID {
			case "canonical_loads":
				path := filepath.Join(dir, c.Input)
				f, err := LoadPath(path)
				if err != nil {
					t.Fatalf("load: %v", err)
				}
				out, err := ToJSON(f)
				if err != nil {
					t.Fatalf("emit: %v", err)
				}
				src, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				var got, want any
				if err := json.Unmarshal([]byte(out), &got); err != nil {
					t.Fatal(err)
				}
				if err := json.Unmarshal(src, &want); err != nil {
					t.Fatal(err)
				}
				if !jsonEqual(got, want) {
					t.Errorf("emit(load(x)) != x:\n%s", out)
				}
			case "faq_requires_v11":
				_, err := LoadPath(atVersion(t, "canonical.esm", "1.0.0"))
				if err == nil || !strings.Contains(err.Error(), "faq_version_too_old") {
					t.Errorf("err = %v, want faq_version_too_old", err)
				}
			default:
				_, err := LoadPath(filepath.Join(dir, c.Input))
				if err == nil || !strings.Contains(err.Error(), "removed_op") {
					t.Errorf("err = %v, want removed_op", err)
				}
			}
		})
	}
	for _, id := range []string{"canonical_loads", "aggregate_rejected", "arrayop_rejected",
		"aggregate_in_referenced_child", "arrayop_in_referenced_child", "faq_requires_v11"} {
		if !seen[id] {
			t.Errorf("manifest has no case %q", id)
		}
	}
}
