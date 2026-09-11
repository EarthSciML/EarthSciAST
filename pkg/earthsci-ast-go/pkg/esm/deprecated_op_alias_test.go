package esm

import (
	"encoding/json"
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
