package esm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// esm-spec §4.7 "Each file is held to its OWN declared `esm` version": every
// version gate judges the file that contains the gated construct against that
// file's own `esm`, never the resolved document against the mounting file's.
// tests/valid/version_gate_older_mounts_newer.esm pins the newer-leaf case in
// the shared corpus; these pin the two directions it does not.

const perFileGateLeaf = `{
  "esm": "%s",
  "metadata": {"name": "leaf"},
  "models": {"Leaf": {
    "variables": {
      "p_gauge": {"type": "parameter", "units": "Pa", "default": 2500.0},
      "p_abs": {"type": "unknown", "units": "Pa"}
    },
    "equations": [{"lhs": "p_abs", "rhs": {"op": "+", "args": ["p_gauge",
      {"op": "const", "args": [], "value": 101325.0, "units": "Pa"}]}}]
  }}
}`

func writePerFileGateDoc(t *testing.T, dir, name, text string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func perFileGateRoot(esm, rhs string) string {
	return `{
  "esm": "` + esm + `",
  "metadata": {"name": "root"},
  "models": {"Station": {
    "variables": {"p_reading": {"type": "unknown", "units": "Pa"}},
    "equations": [{"lhs": "p_reading", "rhs": ` + rhs + `}],
    "subsystems": {"Leaf": {"ref": "./leaf.esm"}}
  }}
}`
}

// An OLDER leaf carrying a construct its own version does not admit is refused,
// even when the mounting document declares a version that would admit it.
func TestVersionGateReadsTheMountedLeafsOwnVersion(t *testing.T) {
	dir := t.TempDir()
	writePerFileGateDoc(t, dir, "leaf.esm", strings.Replace(perFileGateLeaf, "%s", "1.0.0", 1))
	root := writePerFileGateDoc(t, dir, "root.esm", perFileGateRoot("1.2.0", `"Leaf.p_abs"`))
	_, err := LoadPath(root)
	if err == nil || !strings.Contains(err.Error(), CodeConstUnitsVersionTooOld) {
		t.Fatalf("a 1.0.0 leaf with a unit-bearing const must be refused under a 1.2.0 root, got %v", err)
	}
}

// The root's OWN constructs are still gated against the root's version when it
// mounts something: neither the unit-bearing const nor the `faq` gate is
// excused by the mounted content.
func TestVersionGateReadsTheMountingRootsOwnVersion(t *testing.T) {
	dir := t.TempDir()
	writePerFileGateDoc(t, dir, "leaf.esm", strings.Replace(perFileGateLeaf, "%s", "1.2.0", 1))

	ownConst := writePerFileGateDoc(t, dir, "own_const.esm", perFileGateRoot("1.0.0",
		`{"op": "+", "args": ["Leaf.p_abs", {"op": "const", "args": [], "value": 0.0, "units": "Pa"}]}`))
	if _, err := LoadPath(ownConst); err == nil || !strings.Contains(err.Error(), CodeConstUnitsVersionTooOld) {
		t.Fatalf("a 1.0.0 root's own unit-bearing const must be refused, got %v", err)
	}

	// The leaf is 1.2.0, so it carries `faq` legally; the root spells `faq`
	// itself at 1.0.0, which the floor raised for the mounted content must not
	// excuse.
	ownFaq := writePerFileGateDoc(t, dir, "own_faq.esm", perFileGateRoot("1.0.0",
		`{"op": "faq", "args": [], "output_idx": [], "ranges": {}, "expr": "Leaf.p_abs"}`))
	if _, err := LoadPath(ownFaq); err == nil || !strings.Contains(err.Error(), "faq_version_too_old") {
		t.Fatalf("a 1.0.0 root's own `faq` must be refused, got %v", err)
	}

	// The control: the same root, carrying nothing newer than 1.0.0, loads.
	plain := writePerFileGateDoc(t, dir, "plain.esm", perFileGateRoot("1.0.0", `"Leaf.p_abs"`))
	if _, err := LoadPath(plain); err != nil {
		t.Fatalf("a 1.0.0 root mounting a 1.2.0 leaf must load: %v", err)
	}
}
