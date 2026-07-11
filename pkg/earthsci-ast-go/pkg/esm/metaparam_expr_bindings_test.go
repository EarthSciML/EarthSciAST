package esm

// Tests for metaparameter-EXPRESSION binding values at import / subsystem edges
// (esm-spec §9.7.6). Mirrors the Python reference suite
// pkg/earthsci-ast-py/tests/test_metaparam_expr_bindings.py.
//
// Before this feature both an import edge's and a §4.7 subsystem edge's
// `bindings` accepted only integer literals, so a child metaparameter could be
// unified with a parent one by *rename* (name→name) but never *derived* as an
// arithmetic combination (`NTGT = NX*NY`). This relaxes the binding VALUE to a
// metaparameter expression (integer literal, name, or `{op: +|-|*|/, args}`)
// whose free names resolve in the importing document's metaparameter scope:
//
//   - import edge — the value is carried symbolically into the child and folds
//     when the importing document closes (the importer's names are not yet
//     closed at edge time, innermost-first);
//   - subsystem / model edge — the referenced document is resolved to concrete
//     integers at the mount, so the value folds immediately against the
//     mounting document's already-closed metaparameter environment.
//
// NB the Python reference expresses the subsystem-edge case as a top-level
// `models` ref (`resolve_model_refs`); the Go binding has no top-level model-ref
// path — its only §4.7 mount mechanism is `subsystems: {ref, bindings}`
// (resolveSubsystemMap) — so the mount tests below use that form. The site-3
// semantics (fold against the mounting document's closed environment) are
// identical.

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"
)

// --------------------------------------------------------------------------
// helpers
// --------------------------------------------------------------------------

// metaExprIndexSize reads a folded interval `size` out of a raw resolved view
// (the resolveTemplateMachinery output shape).
func metaExprIndexSize(t *testing.T, view map[string]any, name string) int64 {
	t.Helper()
	is, ok := view["index_sets"].(map[string]any)
	if !ok {
		t.Fatalf("view has no index_sets")
	}
	decl, ok := is[name].(map[string]any)
	if !ok {
		t.Fatalf("index set %q missing from view", name)
	}
	switch v := decl["size"].(type) {
	case int64:
		return v
	case int:
		return int64(v)
	case json.Number:
		i, err := v.Int64()
		if err != nil {
			t.Fatalf("index set %q size %v is not an integer: %v", name, v, err)
		}
		return i
	case float64:
		return int64(v)
	default:
		t.Fatalf("index set %q size is %T (%v); want an integer", name, decl["size"], decl["size"])
		return 0
	}
}

// mountIndexSize reads a folded interval `size` from a loaded document's merged
// index-set registry (esm-spec §4.7 subsystem index-set merge).
func mountIndexSize(t *testing.T, f *ESMFile, name string) int {
	t.Helper()
	is, ok := f.IndexSets[name]
	if !ok {
		t.Fatalf("index set %q not in document registry", name)
	}
	if is.Size == nil {
		t.Fatalf("index set %q size is nil (unfolded)", name)
	}
	return *is.Size
}

// --------------------------------------------------------------------------
// 1. The folding / validation helpers
// --------------------------------------------------------------------------

func TestMetaExpr_EvalFoldsProduct(t *testing.T) {
	got, err := evalMetaExpr(
		map[string]any{"op": "*", "args": []any{"NX", "NY"}},
		map[string]int64{"NX": 18, "NY": 20}, "t")
	if err != nil {
		t.Fatalf("evalMetaExpr: %v", err)
	}
	if got != 360 {
		t.Errorf("NX*NY = %d; want 360", got)
	}
}

func TestMetaExpr_EvalNameAndLiteral(t *testing.T) {
	if got, err := evalMetaExpr("NX", map[string]int64{"NX": 7}, "t"); err != nil || got != 7 {
		t.Errorf("evalMetaExpr(name) = %d, %v; want 7, nil", got, err)
	}
	if got, err := evalMetaExpr(5, map[string]int64{}, "t"); err != nil || got != 5 {
		t.Errorf("evalMetaExpr(literal) = %d, %v; want 5, nil", got, err)
	}
}

func TestMetaExpr_EvalNestedArithmetic(t *testing.T) {
	// (NX + 2) * NY  with NX=4, NY=3  -> 18
	expr := map[string]any{"op": "*", "args": []any{
		map[string]any{"op": "+", "args": []any{"NX", 2}},
		"NY",
	}}
	got, err := evalMetaExpr(expr, map[string]int64{"NX": 4, "NY": 3}, "t")
	if err != nil {
		t.Fatalf("evalMetaExpr: %v", err)
	}
	if got != 18 {
		t.Errorf("(NX+2)*NY = %d; want 18", got)
	}
}

func TestMetaExpr_RequireReturnsUnfolded(t *testing.T) {
	expr := map[string]any{"op": "*", "args": []any{"NX", "NY"}}
	got, err := requireMetaExpr(expr, "t")
	if err != nil {
		t.Fatalf("requireMetaExpr: %v", err)
	}
	if gjson, ejson := mustJSON(t, got), mustJSON(t, expr); gjson != ejson {
		t.Errorf("requireMetaExpr returned %s; want it unchanged (%s)", gjson, ejson)
	}
}

func TestMetaExpr_HelperDiagnostics(t *testing.T) {
	cases := []struct {
		name string
		expr any
		env  map[string]int64
		code string
	}{
		// Bad op is caught structurally at the edge, even with a symbolic arg.
		{"bad_op", map[string]any{"op": "%", "args": []any{"NX", 2}}, map[string]int64{}, "metaparameter_type_error"},
		{"empty_args", map[string]any{"op": "*", "args": []any{}}, map[string]int64{}, "metaparameter_type_error"},
		{"float_literal", 1.5, map[string]int64{}, "metaparameter_type_error"},
		// Unknown free name is caught at fold time.
		{"unknown_name", map[string]any{"op": "*", "args": []any{"NZ", "NY"}}, map[string]int64{"NX": 18, "NY": 20}, "template_import_unknown_name"},
		// Inexact division is rejected.
		{"inexact_div", map[string]any{"op": "/", "args": []any{"NX", 7}}, map[string]int64{"NX": 18}, "metaparameter_type_error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Mirror the Python `(require_meta_expr(...), eval_meta_expr(...))`
			// ordering: structural validation first, then the fold.
			if _, err := requireMetaExpr(tc.expr, "t"); err != nil {
				if code := tiErrCode(t, err); code != tc.code {
					t.Fatalf("requireMetaExpr code = %s; want %s", code, tc.code)
				}
				return
			}
			if _, err := evalMetaExpr(tc.expr, tc.env, "t"); err != nil {
				if code := tiErrCode(t, err); code != tc.code {
					t.Fatalf("evalMetaExpr code = %s; want %s", code, tc.code)
				}
				return
			}
			t.Fatalf("expected error %s; got nil", tc.code)
		})
	}
}

// --------------------------------------------------------------------------
// 2. Import edge: GX = NX*NY carried symbolically, folds at the doc close
// --------------------------------------------------------------------------

func metaExprLibGrid() string {
	return `{
      "esm": "0.8.0",
      "metadata": {"name": "lib_grid"},
      "metaparameters": {"GX": {"type": "integer", "default": 2}},
      "index_sets": {"cells": {"kind": "interval", "size": "GX"}},
      "expression_templates": {"one": {"params": [], "body": 1}}
    }`
}

func metaExprModelImporting(binding string) string {
	return fmt.Sprintf(`{
      "esm": "0.8.0",
      "metadata": {"name": "model_import"},
      "metaparameters": {
        "NX": {"type": "integer", "default": 3},
        "NY": {"type": "integer", "default": 4}
      },
      "models": {
        "M": {
          "expression_template_imports": [
            {"ref": "./lib_grid.esm", "bindings": {"GX": %s}}
          ],
          "variables": {"a": {"type": "parameter", "shape": ["cells"], "default": 0.0}},
          "equations": []
        }
      }
    }`, binding)
}

func TestMetaExpr_ImportEdgeProductBindingFoldsAtClose(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "lib_grid.esm"), metaExprLibGrid())
	prod := `{"op": "*", "args": ["NX", "NY"]}`

	// Explicit API bindings NX=3, NY=4.
	src := metaExprModelImporting(prod)
	view := decodeFixture(t, src)
	if _, err := resolveTemplateMachinery(view, extractTemplateOrders(src), dir,
		map[string]int64{"NX": 3, "NY": 4}); err != nil {
		t.Fatalf("resolve (API): %v", err)
	}
	if got := metaExprIndexSize(t, view, "cells"); got != 12 {
		t.Errorf("cells size = %d; want 12 (GX=NX*NY folded at close)", got)
	}

	// Via metaparameter defaults (3 * 4).
	src2 := metaExprModelImporting(prod)
	view2 := decodeFixture(t, src2)
	if _, err := resolveTemplateMachinery(view2, extractTemplateOrders(src2), dir, nil); err != nil {
		t.Fatalf("resolve (defaults): %v", err)
	}
	if got := metaExprIndexSize(t, view2, "cells"); got != 12 {
		t.Errorf("cells size (defaults) = %d; want 12", got)
	}
}

// --------------------------------------------------------------------------
// 3. Subsystem / model edge: NTGT = NX*NY folds at the mount
// --------------------------------------------------------------------------

func metaExprChildRegrid() string {
	return `{
      "esm": "0.8.0",
      "metadata": {"name": "child_regrid"},
      "metaparameters": {
        "NX": {"type": "integer", "default": 2},
        "NY": {"type": "integer", "default": 2},
        "NTGT": {"type": "integer", "default": 4}
      },
      "index_sets": {
        "tgt_cells": {"kind": "interval", "size": "NTGT"},
        "gx": {"kind": "interval", "size": "NX"},
        "gy": {"kind": "interval", "size": "NY"}
      },
      "models": {
        "Regrid": {
          "variables": {
            "field": {"type": "parameter", "shape": ["tgt_cells"], "default": 0.0},
            "grid": {"type": "parameter", "shape": ["gx", "gy"], "default": 0.0}
          },
          "equations": []
        }
      }
    }`
}

func metaExprParentMount(bindings string) string {
	return fmt.Sprintf(`{
      "esm": "0.8.0",
      "metadata": {"name": "parent_mount"},
      "metaparameters": {
        "NX": {"type": "integer", "default": 18},
        "NY": {"type": "integer", "default": 20}
      },
      "models": {
        "Assembly": {
          "variables": {},
          "equations": [],
          "subsystems": {
            "Regrid": {"ref": "./child_regrid.esm", "bindings": %s}
          }
        }
      }
    }`, bindings)
}

func TestMetaExpr_MountEdgeProductBindingFoldsToConcrete(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "child_regrid.esm"), metaExprChildRegrid())
	p := filepath.Join(dir, "parent_mount.esm")
	writeFileString(t, p, metaExprParentMount(
		`{"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}}`))

	f, err := Load(p, WithMetaparameters(map[string]int64{"NX": 18, "NY": 20}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := mountIndexSize(t, f, "tgt_cells"); got != 360 {
		t.Errorf("tgt_cells = %d; want 360 (NX*NY, derived — not a hand-supplied literal)", got)
	}
	if got := mountIndexSize(t, f, "gx"); got != 18 {
		t.Errorf("gx = %d; want 18", got)
	}
	if got := mountIndexSize(t, f, "gy"); got != 20 {
		t.Errorf("gy = %d; want 20", got)
	}
}

func TestMetaExpr_MountEdgeFoldsAgainstParentDefaults(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "child_regrid.esm"), metaExprChildRegrid())
	p := filepath.Join(dir, "parent_mount.esm")
	writeFileString(t, p, metaExprParentMount(
		`{"NX": "NX", "NY": "NY", "NTGT": {"op": "*", "args": ["NX", "NY"]}}`))

	// No API bindings -> parent defaults NX=18, NY=20.
	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := mountIndexSize(t, f, "tgt_cells"); got != 360 {
		t.Errorf("tgt_cells = %d; want 360 (folded against parent defaults)", got)
	}
}

func TestMetaExpr_MountEdgePlainIntegerRegression(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "child_regrid.esm"), metaExprChildRegrid())
	p := filepath.Join(dir, "parent_plain.esm")
	writeFileString(t, p, metaExprParentMount(`{"NX": 5, "NY": 6, "NTGT": 30}`))

	f, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := mountIndexSize(t, f, "tgt_cells"); got != 30 {
		t.Errorf("tgt_cells = %d; want 30", got)
	}
	if got := mountIndexSize(t, f, "gx"); got != 5 {
		t.Errorf("gx = %d; want 5", got)
	}
	if got := mountIndexSize(t, f, "gy"); got != 6 {
		t.Errorf("gy = %d; want 6", got)
	}
}

func TestMetaExpr_MountEdgeUnknownParentNameIsLoud(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "child_regrid.esm"), metaExprChildRegrid())
	p := filepath.Join(dir, "parent_bad.esm")
	writeFileString(t, p, metaExprParentMount(
		`{"NX": "NX", "NY": "NX", "NTGT": {"op": "*", "args": ["NX", "NZZ"]}}`))

	_, err := Load(p, WithMetaparameters(map[string]int64{"NX": 18}))
	if code := tiErrCode(t, err); code != "template_import_unknown_name" {
		t.Errorf("mount-edge unknown name code = %s; want template_import_unknown_name", code)
	}
}
