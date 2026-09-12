package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The `aggregate` -> `faq` deprecated-op-alias contract (esm 1.1.0).
//
// Gates tests/conformance/deprecated_op_alias/ and the `removed_op` rejection
// of `arrayop`. See CONFORMANCE_SPEC §7 and
// docs/content/rfcs/faq-node-rename.md.

func aliasConfDir(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(root, "tests", "conformance", "deprecated_op_alias")
}

// allOps collects every `op` string in a decoded document, depth-first.
func allOps(node any, out []string) []string {
	switch v := node.(type) {
	case map[string]any:
		if op, isStr := v["op"].(string); isStr {
			out = append(out, op)
		}
		for _, child := range v {
			out = allOps(child, out)
		}
	case []any:
		for _, child := range v {
			out = allOps(child, out)
		}
	}
	return out
}

func TestDeprecatedOpAlias_NeverSurvivesTheLoader(t *testing.T) {
	f, err := LoadPath(filepath.Join(aliasConfDir(t), "aliased.esm"))
	if err != nil {
		t.Fatalf("the deprecated alias must still load: %v", err)
	}
	s, err := ToJSON(f)
	if err != nil {
		t.Fatalf("emit: %v", err)
	}
	var doc any
	if err := json.Unmarshal([]byte(s), &doc); err != nil {
		t.Fatalf("decode emit: %v", err)
	}
	sawFaq := false
	for _, op := range allOps(doc, nil) {
		if op == "aggregate" {
			t.Fatalf("the deprecated alias reached emit")
		}
		if op == "faq" {
			sawFaq = true
		}
	}
	if !sawFaq {
		t.Fatalf("emitted document carries no `faq` node")
	}
}

func TestDeprecatedOpAlias_EmitsTheCanonicalDocument(t *testing.T) {
	dir := aliasConfDir(t)
	aliased, err := LoadPath(filepath.Join(dir, "aliased.esm"))
	if err != nil {
		t.Fatalf("load aliased: %v", err)
	}
	canonical, err := LoadPath(filepath.Join(dir, "canonical.esm"))
	if err != nil {
		t.Fatalf("load canonical: %v", err)
	}
	got, err := ToJSON(aliased)
	if err != nil {
		t.Fatalf("emit aliased: %v", err)
	}
	want, err := ToJSON(canonical)
	if err != nil {
		t.Fatalf("emit canonical: %v", err)
	}
	// The two fixtures differ ONLY in the op tag, so normalization at the wire
	// boundary must make their emitted forms byte-identical.
	if got != want {
		t.Errorf("emit(load(aliased)) != emit(load(canonical))")
	}
}

func TestRemovedOp_ArrayopIsRejectedByName(t *testing.T) {
	// `arrayop` matches the `op` pattern, so without a by-name rejection it
	// would load as an OPEN rewrite-target op (esm-spec §4.2) and fail only
	// much later as `unlowered_operator`.
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(root, "tests", "invalid", "faq", "arrayop_op_removed.esm")
	_, err = LoadPath(path)
	if err == nil {
		t.Fatalf("expected `arrayop` to be rejected at load")
	}
	if !strings.Contains(err.Error(), "removed_op") {
		t.Errorf("rejection must carry the `removed_op` diagnostic, got: %v", err)
	}
}

// --- the wire boundary covers REFERENCED documents, not just the root -------
//
// Every other fixture here is a single self-contained document, which is
// exactly why five green binding suites missed the leak: the normalizer ran on
// the root's bytes and ref resolution then read child files raw.

func TestDeprecatedOpAlias_NormalizedInsideAReferencedChild(t *testing.T) {
	f, err := LoadPath(filepath.Join(aliasConfDir(t), "ref_parent_aliased.esm"))
	if err != nil {
		t.Fatalf("parent mounting an aliased child must load: %v", err)
	}
	s, err := ToJSON(f)
	if err != nil {
		t.Fatalf("emit: %v", err)
	}
	var doc any
	if err := json.Unmarshal([]byte(s), &doc); err != nil {
		t.Fatalf("decode emit: %v", err)
	}
	for _, op := range allOps(doc, nil) {
		if op == "aggregate" {
			t.Fatalf("the alias survived a {ref} into emit")
		}
	}
}

func TestRemovedOp_ArrayopInsideAReferencedChildIsRejected(t *testing.T) {
	_, err := LoadPath(filepath.Join(aliasConfDir(t), "ref_parent_arrayop.esm"))
	if err == nil {
		t.Fatalf("expected a child's `arrayop` to be rejected")
	}
	if !strings.Contains(err.Error(), "removed_op") {
		t.Errorf("rejection must carry `removed_op`, got: %v", err)
	}
}

// --- the esm 1.1.0 version gate --------------------------------------------

func atVersion(t *testing.T, name, version string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(aliasConfDir(t), name))
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

func TestFaqVersionGate(t *testing.T) {
	// `faq` arrives at esm 1.1.0 — the gate the top-level `solver` block uses.
	if _, err := LoadPath(atVersion(t, "canonical.esm", "1.0.0")); err == nil {
		t.Errorf("expected `faq` below 1.1.0 to be rejected")
	} else if !strings.Contains(err.Error(), "faq_version_too_old") {
		t.Errorf("rejection must carry `faq_version_too_old`, got: %v", err)
	}
	// `aggregate` IS the pre-1.1.0 spelling, so the gate reads the AUTHORED
	// form and must not catch it; normalization raises the version with it.
	f, err := LoadPath(atVersion(t, "aliased.esm", "1.0.0"))
	if err != nil {
		t.Fatalf("the alias below 1.1.0 is legal, got: %v", err)
	}
	if f.ESM != "1.1.0" {
		t.Errorf("declared version = %q; want 1.1.0 (floor raised with the rewrite)", f.ESM)
	}
}
