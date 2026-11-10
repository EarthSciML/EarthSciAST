package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The `removed_op` rejection of `arrayop` and the esm 1.1.0 `faq` version gate,
// over tests/conformance/deprecated_op_alias/. `aggregate`, the pre-1.1.0
// spelling of `faq`, was removed at esm 2.0.0 and is covered with the other
// removed ops in removed_ops_test.go. See CONFORMANCE_SPEC §7 and
// docs/content/rfcs/faq-node-rename.md.

func aliasConfDir(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(root, "tests", "conformance", "deprecated_op_alias")
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
}
